<#
.SYNOPSIS
    Intune Win32 app detection script for HP Support Assistant (Microsoft Store / AppX version).

.DESCRIPTION
    Reports HP Support Assistant as detected when the AppX package is either provisioned
    on the machine or installed for any user.

    Intune detection contract:
      - Detected     : exit code 0 AND something written to STDOUT
      - Not detected : any other outcome

    Run as SYSTEM (Intune default). Provisioned AppX state is machine-scoped, so the
    script needs SYSTEM or an elevated administrator.

    In the Intune detection rule set:
      - Run script as 32-bit process on 64-bit clients : No
      - Enforce script signature check                  : No (unless you sign it)

.PARAMETER LogDir
    Folder for the log file. Defaults to a folder under ProgramData (writable only by
    admins by default, unlike C:\Temp).

.PARAMETER ActiveSetupKeyName
    Name of the Active Setup component your installer creates to configure each user.
    Only used for the optional user-bridge check.

.PARAMETER RequireUserBridge
    Also require the Active Setup component to exist before reporting "detected".

.EXAMPLE
    .\Detect-HPSupportAssistant.ps1

.EXAMPLE
    .\Detect-HPSupportAssistant.ps1 -RequireUserBridge -ActiveSetupKeyName 'My-HPSA-Setup'

.NOTES
    Licence: MIT. Contributions welcome, see CONTRIBUTING.md.
#>
[CmdletBinding()]
param(
    [string]$LogDir = (Join-Path $env:ProgramData 'HPSupportAssistant-Intune\Logs'),
    [string]$ActiveSetupKeyName = 'HP-Support-Assistant',
    [switch]$RequireUserBridge
)

$ErrorActionPreference = 'Stop'

$AppName = 'HP Support Assistant'
$PackagePattern = '*HPSupportAssistant*'
$LogFile = Join-Path $LogDir 'Detection.log'
$MaxLogBytes = 1MB
$ActiveSetupRoot = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$ActiveSetupKeyName"

function Initialize-Logging {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        # Intune runs detection repeatedly. Keep one previous log and start fresh when the cap is hit.
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    }
    catch {
        # Logging must never change the detection result.
        $script:LoggingFailed = $true
    }
}

function Write-DetectionLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )

    if ($script:LoggingFailed) { return }
    try {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $LogFile -Value $line
    }
    catch {
        $script:LoggingFailed = $true
    }
}

function Test-AdminContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

$script:LoggingFailed = $false
Initialize-Logging

# Get-AppxProvisionedPackage -Online fails in a 32-bit PowerShell on 64-bit Windows.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-DetectionLog 'Running as a 32-bit process on 64-bit Windows. Set "Run script as 32-bit process" to No in the Intune detection rule.' -Level ERROR
    exit 1
}

if (-not (Test-AdminContext)) {
    Write-DetectionLog 'Detection must run as SYSTEM or an elevated administrator because provisioned AppX state is machine-scoped.' -Level ERROR
    exit 1
}

try {
    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -like $PackagePattern -or $_.PackageName -like $PackagePattern } |
        Select-Object -First 1
    $installed = Get-AppxPackage -AllUsers -Name $PackagePattern -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
catch {
    Write-DetectionLog "Could not query AppX state: $($_.Exception.Message)" -Level ERROR
    exit 1
}

$bridgePresent = Test-Path -LiteralPath $ActiveSetupRoot
$appPresent = [bool]($provisioned -or $installed)
$detected = $appPresent -and ($bridgePresent -or -not $RequireUserBridge)

if ($detected) {
    $summary = "$AppName detected. Provisioned=$([bool]$provisioned); InstalledForAnyUser=$([bool]$installed); UserBridge=$bridgePresent."
    Write-DetectionLog $summary -Level SUCCESS
    Write-Output $summary   # Intune needs STDOUT output for a "detected" result.
    exit 0
}

if ($appPresent) {
    Write-DetectionLog "$AppName present but the required user bridge ($ActiveSetupKeyName) is missing." -Level WARNING
}
else {
    Write-DetectionLog "$AppName not detected as provisioned or installed." -Level INFO
}
exit 1
