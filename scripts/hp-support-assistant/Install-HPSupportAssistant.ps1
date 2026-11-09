<#
.SYNOPSIS
    Installs or updates HP Support Assistant (Microsoft Store / AppX version) from HP's download server.

.DESCRIPTION
    1. Resolves the current HP Support Assistant SoftPaq from HP's catalogue (HPCMSL). If the
       catalogue lookup fails, falls back to the pinned SoftPaq in the sources manifest.
    2. Downloads it over HTTPS from ftp.hp.com only (host allow-list, no plain FTP/HTTP).
    3. Verifies the download: size, HP's published hash (SHA256, or MD5 if that is all HP
       publishes) and the Authenticode signature (must be valid and signed by HP).
    4. Extracts it and verifies the AppX bundle identity (name, publisher, version).
    5. Provisions the package for all users, then verifies the provisioned version matches
       the bundle that was installed.
    6. Registers an Active Setup bridge so existing users get the app at next logon.
    7. Cleans up the downloaded and extracted files.

    Nothing is installed if any verification step fails.

    Run as SYSTEM (Intune default) or an elevated administrator, in a 64-bit PowerShell.

.PARAMETER ManifestPath
    Path to the sources manifest. Defaults to HPSupportAssistant.Sources.json next to this script.

.PARAMETER StateRoot
    Working and state folder. Defaults to a folder under ProgramData.

.PARAMETER ActiveSetupKeyName
    Name of the Active Setup component used for the per-user bridge. Must match the detection
    and uninstall scripts.

.PARAMETER Platform
    HP platform (system) ID used for the catalogue lookup, for example '83b2'. By default the
    current device's ID is used, which only works on HP hardware. Mainly useful for testing
    on non-HP machines.

.PARAMETER VerifyOnly
    Resolve, download, verify and extract, then stop before installing anything. Cleans up
    afterwards. Use this to test the download chain.

.PARAMETER NoModuleInstall
    Do not install HPCMSL from the PowerShell Gallery if it is missing. The manifest fallback
    is used instead.

.PARAMETER Force
    Reinstall even if the installed version is already current.

.EXAMPLE
    .\Install-HPSupportAssistant.ps1

.EXAMPLE
    .\Install-HPSupportAssistant.ps1 -VerifyOnly -Platform 83b2

.NOTES
    Licence: MIT. Contributions welcome, see CONTRIBUTING.md.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'HPSupportAssistant.Sources.json'),
    [string]$StateRoot = (Join-Path $env:ProgramData 'HPSupportAssistant-Intune'),
    [string]$ActiveSetupKeyName = 'HP-Support-Assistant',
    [string]$Platform,
    [switch]$VerifyOnly,
    [switch]$NoModuleInstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$AppName = 'HP Support Assistant'
$ManifestFile = $ManifestPath
$PlatformId = $Platform
$AllowModuleInstall = -not $NoModuleInstall
$PackagePattern = '*HPSupportAssistant*'
$LogDir = Join-Path $StateRoot 'Logs'
$LogFile = Join-Path $LogDir 'Install.log'
$MaxLogBytes = 1MB
$WorkRoot = Join-Path $StateRoot 'Work'
$ExtractRoot = Join-Path $WorkRoot 'Extracted'
$SoftPaqPath = Join-Path $WorkRoot 'HP-Support-Assistant.exe'
$CvaPath = Join-Path $WorkRoot 'HP-Support-Assistant.cva'
$StateFile = Join-Path $StateRoot 'InstalledSoftPaq.json'
$UserRegisterScript = Join-Path $StateRoot 'Register-HPSAForUser.ps1'
$ActiveSetupRoot = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$ActiveSetupKeyName"
$EventSource = 'HP Support Assistant Intune'
$ProcessTimeoutSeconds = 900
$ProvisionTimeoutSeconds = 300
$MinimumFreeBytes = 1GB

$script:Manifest = $null
$script:LoggingFailed = $false
$script:EventLogFailed = $false

# ---------------------------------------------------------------- logging

function Initialize-Logging {
    try {
        foreach ($path in @($StateRoot, $LogDir, $WorkRoot)) {
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
        }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
        if ((Get-Command New-EventLog -ErrorAction SilentlyContinue) -and
            -not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
        }
    }
    catch {
        # Logging problems must never stop an install. File logging is retried per line.
        $script:EventLogFailed = $true
    }
}

function Write-InstallLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $script:LoggingFailed) {
        try { Add-Content -Path $LogFile -Value $line }
        catch { $script:LoggingFailed = $true }
    }
    Write-Information $line -InformationAction Continue

    if (-not $script:EventLogFailed -and (Get-Command Write-EventLog -ErrorAction SilentlyContinue)) {
        $entryType = switch ($Level) {
            'ERROR' { 'Error' }
            'WARNING' { 'Warning' }
            default { 'Information' }
        }
        try { Write-EventLog -LogName Application -Source $EventSource -EntryType $entryType -EventId 4510 -Message $line -ErrorAction Stop }
        catch { $script:EventLogFailed = $true }
    }
}

# ---------------------------------------------------------------- helpers

function Test-AdminContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

function ConvertTo-VersionOrNull {
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [version]$Value } catch { return $null }
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Confirm-Prerequisite {
    # PowerShell 5.1 defaults to older TLS versions that HP's server and the PowerShell Gallery refuse.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Running as a 32-bit process on 64-bit Windows. Launch the script with the 64-bit PowerShell (%SystemRoot%\\SysNative\\WindowsPowerShell\\v1.0\\powershell.exe from a 32-bit process).'
    }
    if (-not (Test-AdminContext)) {
        throw 'This script must run as SYSTEM or an elevated administrator.'
    }

    $driveName = (Split-Path -Path $StateRoot -Qualifier).TrimEnd(':')
    $free = (Get-PSDrive -Name $driveName).Free
    if ($free -lt $MinimumFreeBytes) {
        throw "Not enough free disk space on ${driveName}: ($([math]::Round($free / 1MB)) MB free, $([math]::Round($MinimumFreeBytes / 1MB)) MB needed)."
    }
}

function Read-SourceManifest {
    if (-not (Test-Path -LiteralPath $ManifestFile)) {
        throw "Source manifest not found: $ManifestFile"
    }

    $manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    foreach ($field in 'softPaqName', 'category', 'fallbackSoftPaqNumber', 'fallbackDownloadUri', 'fallbackVersion', 'expectedSigner', 'expectedBundleName', 'expectedBundlePublisher', 'allowedHosts') {
        if (-not $manifest.$field) { throw "Manifest is missing required field '$field'." }
    }
    Confirm-DownloadUri -Uri $manifest.fallbackDownloadUri -AllowedHost @($manifest.allowedHosts)
    return $manifest
}

function Confirm-DownloadUri {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string[]]$AllowedHost = @($script:Manifest.allowedHosts)
    )

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw "Not a valid URL: $Uri"
    }
    if ($parsed.Scheme -ne 'https') {
        throw "Refusing non-HTTPS download URL: $Uri"
    }
    if ($AllowedHost -notcontains $parsed.Host) {
        throw "Refusing download from host '$($parsed.Host)'. Allowed: $($AllowedHost -join ', ')"
    }
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = $ProcessTimeoutSeconds
    )

    $runId = [Guid]::NewGuid().ToString('N')
    $stdoutFile = Join-Path $WorkRoot "process-$runId-stdout.log"
    $stderrFile = Join-Path $WorkRoot "process-$runId-stderr.log"
    Write-InstallLog "Running: $FilePath $($ArgumentList -join ' ')"

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -WindowStyle Hidden -PassThru
    $null = $process.Handle   # cache the handle, otherwise ExitCode can be empty in Windows PowerShell 5.1
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { Write-InstallLog "Failed to stop timed-out process: $($_.Exception.Message)" -Level WARNING }
        throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
    }
    $process.WaitForExit()

    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-InstallLog "stdout: $($stdout.Trim())" }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-InstallLog "stderr: $($stderr.Trim())" -Level WARNING }

    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-HPSAMachineState {
    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -like $PackagePattern -or $_.PackageName -like $PackagePattern } |
        Select-Object -First 1
    $installed = Get-AppxPackage -AllUsers -Name $PackagePattern -ErrorAction SilentlyContinue |
        Sort-Object { ConvertTo-VersionOrNull $_.Version } -Descending |
        Select-Object -First 1
    return [pscustomobject]@{ Provisioned = $provisioned; Installed = $installed }
}

function Get-HPSAFamilyName {
    param([Parameter(Mandatory)][pscustomobject]$State)

    if ($State.Installed) { return [string]$State.Installed.PackageFamilyName }
    # Provisioned PackageName looks like Name_Version_Arch_ResourceId_PublisherId.
    $parts = ([string]$State.Provisioned.PackageName) -split '_'
    return '{0}_{1}' -f $parts[0], $parts[-1]
}

# ---------------------------------------------------------------- resolve

function Import-HPSoftPaqModule {
    $minimum = ConvertTo-VersionOrNull $script:Manifest.minimumHpcmslVersion
    foreach ($moduleName in 'HP.Softpaq', 'HPCMSL') {
        try {
            Import-Module $moduleName -ErrorAction Stop
            if (Get-Command Get-HPSoftpaqList -ErrorAction SilentlyContinue) {
                Write-InstallLog "Loaded $moduleName module $((Get-Module $moduleName).Version)."
                return
            }
        }
        catch {
            Write-InstallLog "Could not load $moduleName from installed modules: $($_.Exception.Message)" -Level INFO
        }
    }

    if (-not $AllowModuleInstall) {
        throw 'HP SoftPaq cmdlets are not installed and -NoModuleInstall was specified.'
    }

    Write-InstallLog 'HP SoftPaq cmdlets not found. Installing HPCMSL from the PowerShell Gallery.' -Level WARNING
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    }
    Install-Module -Name HPCMSL -Scope AllUsers -Force -AllowClobber -SkipPublisherCheck -AcceptLicense -MinimumVersion $minimum.ToString()
    Import-Module HP.Softpaq -ErrorAction Stop
    Write-InstallLog "Installed and loaded HPCMSL (HP.Softpaq $((Get-Module HP.Softpaq).Version))."
}

function Resolve-HPSASoftPaq {
    $manifest = $script:Manifest
    try {
        Import-HPSoftPaqModule
        $listArgs = @{
            Category    = $manifest.category
            ReleaseType = @($manifest.releaseTypes)
            AddHttps    = $true
            Quiet       = $true
            ErrorAction = 'Stop'
        }
        if ($PlatformId) { $listArgs.Platform = $PlatformId }

        $candidate = @(Get-HPSoftpaqList @listArgs) |
            Where-Object { $_.Name -eq $manifest.softPaqName -and (ConvertTo-VersionOrNull $_.Version) } |
            Sort-Object { ConvertTo-VersionOrNull $_.Version } -Descending |
            Select-Object -First 1

        if ($candidate) {
            Write-InstallLog "Catalogue resolved $($candidate.Name) $($candidate.Version) as SoftPaq sp$($candidate.Id)."
            return [pscustomobject]@{
                Number  = [string]$candidate.Id
                Version = [string]$candidate.Version
                Url     = [string]$candidate.Url
                Source  = 'HPSoftPaqCatalog'
            }
        }
        Write-InstallLog "Catalogue returned no '$($manifest.softPaqName)' entry." -Level WARNING
    }
    catch {
        Write-InstallLog "Catalogue lookup failed: $($_.Exception.Message)" -Level WARNING
    }

    Write-InstallLog "Using manifest fallback sp$($manifest.fallbackSoftPaqNumber) $($manifest.fallbackVersion)." -Level WARNING
    return [pscustomobject]@{
        Number  = [string]$manifest.fallbackSoftPaqNumber
        Version = [string]$manifest.fallbackVersion
        Url     = [string]$manifest.fallbackDownloadUri
        Source  = 'ManifestFallback'
    }
}

# ---------------------------------------------------------------- download and verify

function Save-WebFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    Confirm-DownloadUri -Uri $Uri
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow on 5.1
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
                break
            }
            catch {
                Write-InstallLog "Download attempt $attempt of 3 failed for ${Uri}: $($_.Exception.Message)" -Level WARNING
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

function Get-HPSAExpectedHash {
    param([Parameter(Mandatory)][pscustomobject]$SoftPaq)

    $cvaUrl = $SoftPaq.Url -replace '\.exe$', '.cva'
    Write-InstallLog "Fetching HP metadata: $cvaUrl"
    Save-WebFile -Uri $cvaUrl -OutFile $CvaPath

    $fields = @{}
    foreach ($line in Get-Content -LiteralPath $CvaPath) {
        if ($line -match '^\s*([^=\[\];]+?)\s*=\s*(.*?)\s*$') { $fields[$Matches[1]] = $Matches[2] }
    }
    $shaKey = $fields.Keys | Where-Object { $_ -match 'SHA-?256' } | Select-Object -First 1
    $md5Key = $fields.Keys | Where-Object { $_ -match 'MD5' } | Select-Object -First 1
    Write-InstallLog "HP metadata read ($($fields.Count) fields). Hash fields present: $(@($shaKey, $md5Key | Where-Object { $_ }) -join ', ')."
    return [pscustomobject]@{
        Sha256 = if ($shaKey) { $fields[$shaKey] } else { $null }
        Md5    = if ($md5Key) { $fields[$md5Key] } else { $null }
    }
}

function Save-HPSASoftPaq {
    param([Parameter(Mandatory)][pscustomobject]$SoftPaq)

    Write-InstallLog "Downloading sp$($SoftPaq.Number) $($SoftPaq.Version) from $($SoftPaq.Url)"
    Save-WebFile -Uri $SoftPaq.Url -OutFile $SoftPaqPath
}

function Confirm-SoftPaqIntegrity {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'MD5 is only a secondary check, used when HP publishes no SHA256. The digital signature check is always mandatory.')]
    param(
        [Parameter(Mandatory)][pscustomobject]$SoftPaq,
        [Parameter(Mandatory)][pscustomobject]$Expected
    )

    if (-not (Test-Path -LiteralPath $SoftPaqPath)) { throw "SoftPaq download failed: $SoftPaqPath not found." }
    $size = (Get-Item -LiteralPath $SoftPaqPath).Length
    if ($size -lt 1MB) { throw "Downloaded file is only $size bytes. Expected a full installer." }

    $sha256 = (Get-FileHash -LiteralPath $SoftPaqPath -Algorithm SHA256).Hash
    if ($Expected.Sha256) {
        if ($sha256 -ine $Expected.Sha256) { throw "SHA256 mismatch. HP published $($Expected.Sha256), downloaded file is $sha256." }
        Write-InstallLog "SHA256 matches HP's published value ($sha256)."
    }
    elseif ($Expected.Md5) {
        $md5 = (Get-FileHash -LiteralPath $SoftPaqPath -Algorithm MD5).Hash
        if ($md5 -ine $Expected.Md5) { throw "MD5 mismatch. HP published $($Expected.Md5), downloaded file is $md5." }
        Write-InstallLog "MD5 matches HP's published value ($md5). HP did not publish a SHA256." -Level WARNING
    }
    else {
        Write-InstallLog "HP published no hash for sp$($SoftPaq.Number). Relying on the digital signature. SHA256=$sha256." -Level WARNING
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $SoftPaqPath
    if ($signature.Status -ne 'Valid') { throw "SoftPaq digital signature is not valid (status: $($signature.Status))." }
    $subject = $signature.SignerCertificate.Subject
    if ($subject -notlike "*$($script:Manifest.expectedSigner)*") { throw "SoftPaq is signed by an unexpected publisher: $subject" }
    Write-InstallLog "Digital signature is valid. Signer: $subject (thumbprint $($signature.SignerCertificate.Thumbprint))."

    return $sha256
}

# ---------------------------------------------------------------- extract and verify

function Expand-HPSASoftPaq {
    if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

    $result = Invoke-LoggedProcess -FilePath $SoftPaqPath -ArgumentList @('/s', '/e', '/f', "`"$ExtractRoot`"")
    Write-InstallLog "SoftPaq extraction finished with exit code $($result.ExitCode)."
}

function Get-HPSABundlePath {
    $bundle = Get-ChildItem -LiteralPath $ExtractRoot -Filter '*.appxbundle' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'HPSA9x|HPSupportAssistant|bb4581e782b34312af5e9dacdcce0c68' } |
        Sort-Object FullName |
        Select-Object -First 1
    if (-not $bundle) { throw "HP Support Assistant AppX bundle not found under $ExtractRoot." }
    return $bundle.FullName
}

function Get-HPSABundleIdentity {
    param([Parameter(Mandatory)][string]$BundlePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($BundlePath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -match 'AppxBundleManifest\.xml$' } | Select-Object -First 1
        if (-not $entry) { throw 'AppxBundleManifest.xml not found inside the bundle.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifestXml = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally {
        $zip.Dispose()
    }

    $identity = $manifestXml.Bundle.Identity
    return [pscustomobject]@{ Name = [string]$identity.Name; Publisher = [string]$identity.Publisher; Version = [string]$identity.Version }
}

function Confirm-HPSABundle {
    $bundlePath = Get-HPSABundlePath
    $identity = Get-HPSABundleIdentity -BundlePath $bundlePath
    Write-InstallLog "Bundle identity: Name=$($identity.Name); Version=$($identity.Version); Publisher=$($identity.Publisher)."

    if ($identity.Name -ne $script:Manifest.expectedBundleName) { throw "Unexpected package name in bundle: $($identity.Name) (expected $($script:Manifest.expectedBundleName))" }
    if ($identity.Publisher -ne $script:Manifest.expectedBundlePublisher) { throw "Unexpected package publisher in bundle: $($identity.Publisher) (expected $($script:Manifest.expectedBundlePublisher))" }
    if (-not (ConvertTo-VersionOrNull $identity.Version)) { throw "Bundle version is not a valid version: $($identity.Version)" }

    $signature = Get-AuthenticodeSignature -LiteralPath $bundlePath
    Write-InstallLog "Bundle signature check: $($signature.Status). Windows also validates the package signature during provisioning."

    return [pscustomobject]@{ Path = $bundlePath; Name = $identity.Name; Version = $identity.Version; Publisher = $identity.Publisher }
}

# ---------------------------------------------------------------- install and verify

function Install-HPSAProvisionedPackage {
    param([Parameter(Mandatory)][pscustomobject]$Bundle)

    $architecture = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
    $dependencyRoot = Join-Path (Split-Path -Path $Bundle.Path -Parent) "Dependencies\$architecture"
    $dependencies = @()
    if (Test-Path -LiteralPath $dependencyRoot) {
        $dependencies = @(Get-ChildItem -LiteralPath $dependencyRoot -Filter '*.appx' -File | Select-Object -ExpandProperty FullName)
    }
    Write-InstallLog "Provisioning $($Bundle.Path) with $($dependencies.Count) dependency package(s) from $dependencyRoot."

    $command = "Add-AppxProvisionedPackage -Online -PackagePath $(ConvertTo-PowerShellLiteral $Bundle.Path) -SkipLicense"
    if ($dependencies.Count -gt 0) {
        $command += ' -DependencyPackagePath @(' + (($dependencies | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ',') + ')'
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference='Stop'; $command | Out-Null"))

    # Add-AppxProvisionedPackage is a Windows PowerShell (DISM) cmdlet, so run it in powershell.exe 5.1.
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $result = Invoke-LoggedProcess -FilePath $windowsPowerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -TimeoutSeconds $ProvisionTimeoutSeconds
    if ($result.ExitCode -ne 0) { throw "AppX provisioning failed with exit code $($result.ExitCode)." }
}

function Confirm-HPSAInstalled {
    param([Parameter(Mandatory)][pscustomobject]$Bundle)

    $state = Get-HPSAMachineState
    if (-not $state.Provisioned) { throw "$AppName is not provisioned after installation." }

    $provisionedVersion = ConvertTo-VersionOrNull $state.Provisioned.Version
    $bundleVersion = ConvertTo-VersionOrNull $Bundle.Version
    if ($provisionedVersion -ne $bundleVersion) {
        throw "Provisioned version ($($state.Provisioned.Version)) does not match the installed bundle ($($Bundle.Version))."
    }
    Write-InstallLog "Verified: $AppName $($state.Provisioned.Version) is provisioned. InstalledForAnyUser=$([bool]$state.Installed)." -Level SUCCESS
    return $state
}

function Write-UserRegistrationBridge {
    param(
        [Parameter(Mandatory)][string]$FamilyName,
        [Parameter(Mandatory)][string]$Version
    )

    # Runs as each user at logon. It cannot query provisioned packages (that needs admin), so the
    # package family name and target version are baked in at install time.
    $bridge = @'
$ErrorActionPreference = 'Stop'
$family = '__FAMILY__'
$target = [version]'__VERSION__'
$logDir = Join-Path $env:LOCALAPPDATA 'HPSupportAssistant-Intune'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'UserRegistration.log'
function Write-BridgeLog {
    param([string]$Message)
    Add-Content -Path $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}
try {
    $current = Get-AppxPackage -Name '*HPSupportAssistant*' | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if ($current -and ([version]$current.Version) -ge $target) {
        Write-BridgeLog "Already registered for $env:USERNAME at $($current.Version)."
        exit 0
    }
    Add-AppxPackage -RegisterByFamilyName -MainPackage $family
    $after = Get-AppxPackage -Name '*HPSupportAssistant*' | Select-Object -First 1
    if ($after) { Write-BridgeLog "Registered $family for $env:USERNAME at $($after.Version)."; exit 0 }
    Write-BridgeLog "Registration ran but the package is not visible for $env:USERNAME."
    exit 1
}
catch {
    Write-BridgeLog "Registration failed for ${env:USERNAME}: $($_.Exception.Message)"
    exit 1
}
'@
    $bridge = $bridge.Replace('__FAMILY__', $FamilyName).Replace('__VERSION__', $Version)
    Set-Content -LiteralPath $UserRegisterScript -Value $bridge -Encoding UTF8

    # Active Setup runs the stub once per user per version, so tie the version to the app version.
    $activeSetupVersion = ((ConvertTo-VersionOrNull $Version).ToString() -replace '\.', ',')
    New-Item -Path $ActiveSetupRoot -Force | Out-Null
    New-ItemProperty -Path $ActiveSetupRoot -Name '(Default)' -Value 'HP Support Assistant user registration' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $ActiveSetupRoot -Name 'Version' -Value $activeSetupVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $ActiveSetupRoot -Name 'StubPath' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$UserRegisterScript`"" -PropertyType String -Force | Out-Null

    # Verify what was written.
    if (-not (Test-Path -LiteralPath $UserRegisterScript)) { throw 'User registration script was not written.' }
    $stub = (Get-ItemProperty -Path $ActiveSetupRoot -Name 'StubPath').StubPath
    if ($stub -notlike "*$UserRegisterScript*") { throw 'Active Setup StubPath was not written correctly.' }
    Write-InstallLog "Active Setup bridge verified (key $ActiveSetupKeyName, version $activeSetupVersion, family $FamilyName)."
}

function Write-InstallState {
    param(
        [Parameter(Mandatory)][pscustomobject]$SoftPaq,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][pscustomobject]$Bundle
    )

    [pscustomobject]@{
        softPaqNumber = $SoftPaq.Number
        softPaqVersion = $SoftPaq.Version
        source        = $SoftPaq.Source
        sha256        = $Sha256
        bundleVersion = $Bundle.Version
        installedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Clear-WorkFolder {
    if (Test-Path -LiteralPath $WorkRoot) {
        Get-ChildItem -LiteralPath $WorkRoot -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- main

Initialize-Logging
Write-InstallLog "Starting $AppName install/update.$(if ($VerifyOnly) { ' (VerifyOnly: nothing will be installed)' })"

try {
    Confirm-Prerequisite
    $script:Manifest = Read-SourceManifest
    Clear-WorkFolder

    $softPaq = Resolve-HPSASoftPaq
    $targetVersion = ConvertTo-VersionOrNull $softPaq.Version
    if (-not $targetVersion) { throw "Resolved SoftPaq version is not valid: $($softPaq.Version)" }
    Confirm-DownloadUri -Uri $softPaq.Url

    # Before: skip the download when the machine is already current.
    $stateBefore = Get-HPSAMachineState
    $currentVersions = @($stateBefore.Installed.Version, $stateBefore.Provisioned.Version) | ForEach-Object { ConvertTo-VersionOrNull $_ } | Where-Object { $_ }
    $currentVersion = $currentVersions | Sort-Object -Descending | Select-Object -First 1
    if (-not $VerifyOnly -and -not $Force -and $currentVersion -and $currentVersion -ge $targetVersion) {
        Write-InstallLog "$AppName $currentVersion is already at or above the target $targetVersion. Refreshing the user bridge only." -Level SUCCESS
        Write-UserRegistrationBridge -FamilyName (Get-HPSAFamilyName -State $stateBefore) -Version ([string]$currentVersion)
        exit 0
    }
    Write-InstallLog "Installed/provisioned version: $(if ($currentVersion) { $currentVersion } else { 'none' }). Target: $targetVersion."

    # Download and verify.
    $expected = Get-HPSAExpectedHash -SoftPaq $softPaq
    Save-HPSASoftPaq -SoftPaq $softPaq
    $sha256 = Confirm-SoftPaqIntegrity -SoftPaq $softPaq -Expected $expected

    # Extract and verify.
    Expand-HPSASoftPaq
    $bundle = Confirm-HPSABundle
    if ((ConvertTo-VersionOrNull $bundle.Version) -lt $targetVersion) {
        Write-InstallLog "Bundle version $($bundle.Version) is older than the catalogue version $targetVersion." -Level WARNING
    }

    if ($VerifyOnly) {
        Write-InstallLog "VerifyOnly: download, hash, signature and bundle checks all passed for $($bundle.Name) $($bundle.Version). Nothing installed." -Level SUCCESS
        exit 0
    }

    # Install and verify.
    Install-HPSAProvisionedPackage -Bundle $bundle
    $stateAfter = Confirm-HPSAInstalled -Bundle $bundle
    Write-UserRegistrationBridge -FamilyName (Get-HPSAFamilyName -State $stateAfter) -Version $bundle.Version
    Write-InstallState -SoftPaq $softPaq -Sha256 $sha256 -Bundle $bundle

    Write-InstallLog "$AppName $($bundle.Version) installed and verified." -Level SUCCESS
    exit 0
}
catch {
    Write-InstallLog $_.Exception.Message -Level ERROR
    exit 1
}
finally {
    Clear-WorkFolder
}
