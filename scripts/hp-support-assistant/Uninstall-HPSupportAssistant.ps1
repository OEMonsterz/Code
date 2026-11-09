<#
.SYNOPSIS
    Removes HP Support Assistant (Microsoft Store / AppX version) and the installer's per-user bridge.

.DESCRIPTION
    Removes the Active Setup bridge, the provisioned package and the package for all users,
    then verifies nothing is left. Exits 1 if the app is still present afterwards.

    Run as SYSTEM (Intune default) or an elevated administrator, in a 64-bit PowerShell.

.PARAMETER StateRoot
    State folder created by the install script. Its Logs folder is kept.

.PARAMETER ActiveSetupKeyName
    Name of the Active Setup component. Must match the install and detection scripts.

.EXAMPLE
    .\Uninstall-HPSupportAssistant.ps1

.NOTES
    Licence: MIT. Contributions welcome, see CONTRIBUTING.md.
#>
[CmdletBinding()]
param(
    [string]$StateRoot = (Join-Path $env:ProgramData 'HPSupportAssistant-Intune'),
    [string]$ActiveSetupKeyName = 'HP-Support-Assistant'
)

$ErrorActionPreference = 'Stop'

$AppName = 'HP Support Assistant'
$PackagePattern = '*HPSupportAssistant*'
$LogDir = Join-Path $StateRoot 'Logs'
$LogFile = Join-Path $LogDir 'Uninstall.log'
$MaxLogBytes = 1MB
$ActiveSetupRoot = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$ActiveSetupKeyName"

$script:LoggingFailed = $false

function Initialize-Logging {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    }
    catch {
        $script:LoggingFailed = $true
    }
}

function Write-UninstallLog {
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
}

function Test-AdminContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return ($identity.IsSystem -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

function Get-HPSAMachineState {
    $provisioned = @(Get-AppxProvisionedPackage -Online |
            Where-Object { $_.DisplayName -like $PackagePattern -or $_.PackageName -like $PackagePattern })
    $installed = @(Get-AppxPackage -AllUsers -Name $PackagePattern -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Provisioned = $provisioned; Installed = $installed }
}

Initialize-Logging
Write-UninstallLog "Starting $AppName uninstall."

try {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Running as a 32-bit process on 64-bit Windows. Run the script in a 64-bit PowerShell host.'
    }
    if (-not (Test-AdminContext)) {
        throw 'This script must run as SYSTEM or an elevated administrator.'
    }

    $before = Get-HPSAMachineState
    Write-UninstallLog "Before: $($before.Provisioned.Count) provisioned package(s), $($before.Installed.Count) installed package(s)."

    if (Test-Path -LiteralPath $ActiveSetupRoot) {
        Remove-Item -LiteralPath $ActiveSetupRoot -Recurse -Force
        Write-UninstallLog 'Removed Active Setup user-registration bridge.'
    }

    # Remove the provisioned copy first so the app is not re-registered for new users.
    foreach ($package in $before.Provisioned) {
        Write-UninstallLog "Removing provisioned package $($package.PackageName)."
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName | Out-Null
    }

    foreach ($package in $before.Installed) {
        Write-UninstallLog "Removing installed package $($package.PackageFullName) for all users."
        try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop }
        catch { Write-UninstallLog "Could not remove $($package.PackageFullName): $($_.Exception.Message)" -Level WARNING }
    }

    # Keep Logs, remove everything else the installer left behind.
    if (Test-Path -LiteralPath $StateRoot) {
        Get-ChildItem -LiteralPath $StateRoot -Force |
            Where-Object { $_.Name -ne 'Logs' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Verify.
    $after = Get-HPSAMachineState
    if ($after.Provisioned.Count -gt 0 -or $after.Installed.Count -gt 0) {
        throw "$AppName is still present after uninstall: $($after.Provisioned.Count) provisioned, $($after.Installed.Count) installed."
    }
    if (Test-Path -LiteralPath $ActiveSetupRoot) {
        throw 'Active Setup bridge is still present after uninstall.'
    }

    Write-UninstallLog "$AppName uninstall completed and verified." -Level SUCCESS
    exit 0
}
catch {
    Write-UninstallLog $_.Exception.Message -Level ERROR
    exit 1
}
