#Install winget and Powershell 7
#Optimixed for Windows Sandbx install

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstrap WinGet (App Installer) on Windows PowerShell 5.1, then install
    PowerShell 7 machine-wide. Designed to succeed in Windows Sandbox.

.DESCRIPTION
    Run from an elevated Windows PowerShell 5.1 window (the built-in
    powershell.exe, not pwsh).

    Flow:
      1. Register Microsoft.DesktopAppInstaller by family name (when the
         package is already staged/provisioned).
      2. If winget is still missing (typical of Windows Sandbox), bootstrap
         it with Microsoft.WinGet.Client / Repair-WinGetPackageManager, then
         fall back to the GitHub App Installer MSIX bundle + dependencies.
      3. Poll until winget.exe is callable.
      4. Install Microsoft.PowerShell machine-wide via winget.
      5. Poll until pwsh.exe is callable.

    Installs are system-wide where the installer supports it.
#>

[CmdletBinding()]
param(
    [int]$WaitSeconds = 180,
    [int]$PollSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 is required for PSGallery / GitHub on many PS 5.1 hosts.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not raise TLS protocol: $($_.Exception.Message)"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WinGetCommand {
    # App execution aliases and SYSTEM/Sandbox PATH are unreliable.
    # Prefer the real binary under WindowsApps, then PATH.
    $candidates = @()

    $winApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $winApps) { $candidates += $winApps }

    $pkgDirs = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') `
        -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe' } |
        Sort-Object Name

    foreach ($dir in $pkgDirs) {
        $exe = Join-Path $dir.FullName 'winget.exe'
        if (Test-Path -LiteralPath $exe) { $candidates += $exe }
    }

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Test-WinGetReady {
    $exe = Get-WinGetCommand
    if (-not $exe) { return $false }
    try {
        $out = & $exe --version 2>&1
        if ($LASTEXITCODE -ne 0 -and $null -eq $LASTEXITCODE) { return $false }
        $text = ($out | Out-String)
        return ($text -match '\d+\.\d+')
    } catch {
        return $false
    }
}

function Test-RealExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        # WindowsApps app-execution aliases are 0-byte stubs. Skip them.
        return ($item.Length -gt 0)
    } catch {
        return $false
    }
}

function Get-PwshCommand {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
    )
    $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-RealExecutable -Path $path) { return $path }
    }
    return $null
}

function Invoke-PwshCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$Command
    )
    # Call via an argument array so Windows PowerShell 5.1 does not
    # re-tokenize the command string and feed pwsh both -File and -Command.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PwshPath @('-NoLogo', '-NoProfile', '-Command', $Command) 2>&1
        return ($out | Out-String)
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

function Test-PwshReady {
    $exe = Get-PwshCommand
    if (-not $exe) { return $false }
    try {
        $text = Invoke-PwshCommand -PwshPath $exe -Command '$PSVersionTable.PSVersion.ToString()'
        return ($text -match '7\.\d+')
    } catch {
        return $false
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [string]$Name,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            Write-Host ("{0} is ready." -f $Name) -ForegroundColor Green
            return $true
        }
        Write-Host ("Waiting for {0}... ({1}s remaining)" -f $Name, [int]($deadline - (Get-Date)).TotalSeconds)
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Update-ProcessPath {
    # MSI/winget update Machine PATH in the registry; this process still
    # has the old PATH. Rebuild it, then prepend known install dirs.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts   = @()
    foreach ($chunk in @($machine, $user, $env:PATH)) {
        if ($chunk) { $parts += $chunk }
    }
    $env:PATH = ($parts -join ';')

    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    $ps7         = Join-Path $env:ProgramFiles 'PowerShell\7'
    foreach ($dir in @($ps7, $windowsApps)) {
        if ((Test-Path -LiteralPath $dir) -and ($env:PATH -notlike "*$dir*")) {
            $env:PATH = "$dir;$env:PATH"
        }
    }
}

function Register-DesktopAppInstaller {
    Write-Step "Registering Microsoft.DesktopAppInstaller by family name"

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Write-Host "RegisterByFamilyName completed."
    } catch {
        Write-Warning "RegisterByFamilyName did not succeed (common in Sandbox if the package is not staged): $($_.Exception.Message)"
    }

    # Alternate: re-register from an already-installed package location.
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (Test-Path -LiteralPath $manifest) {
                Write-Host "Re-registering from $manifest"
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        Write-Warning "Manifest re-register skipped: $($_.Exception.Message)"
    }

    # Win11 reset path if the package exists but is broken.
    try {
        $reset = Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue
        if ($reset) {
            $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
            if ($pkg) {
                $pkg | Reset-AppxPackage -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        # Reset-AppxPackage is not available on all builds.
    }
}

function Install-WinGetViaRepairModule {
    Write-Step "Bootstrapping WinGet with Microsoft.WinGet.Client (Sandbox-supported)"

	$savedConfirm = $ConfirmPreference
    $ConfirmPreference = 'None'
    try {
        Write-Host "Installing NuGet package provider (non-interactive)..."
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Confirm:$false
    } catch {
        Write-Warning "Install-PackageProvider NuGet: $($_.Exception.Message)"
    } finally {
        $ConfirmPreference = $savedConfirm
    }   

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Write-Host "Installing Microsoft.WinGet.Client module (AllUsers)..."
    Install-Module -Name Microsoft.WinGet.Client -Force -Confirm:$false -Scope AllUsers -AllowClobber -Repository PSGallery | Out-Null
    Import-Module Microsoft.WinGet.Client -Force

    if (-not (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)) {
        throw "Repair-WinGetPackageManager is not available after module install."
    }

    Write-Host "Running Repair-WinGetPackageManager -AllUsers..."
    Repair-WinGetPackageManager -AllUsers | Out-Null
}

function Get-LatestWinGetReleaseAssets {
    $api = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    $headers = @{
        'User-Agent' = 'Install-WinGetAndPowerShell7'
        'Accept'     = 'application/vnd.github+json'
    }
    return Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
}

function Install-WinGetFromGitHub {
    Write-Step "Falling back to GitHub App Installer MSIX bundle"

    $work = Join-Path $env:TEMP ('winget-bootstrap-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $release = Get-LatestWinGetReleaseAssets
        $assets  = @($release.assets)

        $bundle = $assets | Where-Object { $_.name -like 'Microsoft.DesktopAppInstaller*.msixbundle' } | Select-Object -First 1
        $license = $assets | Where-Object { $_.name -like '*License1.xml' } | Select-Object -First 1
        $depsZip = $assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1

        if (-not $bundle) {
            throw "Could not find DesktopAppInstaller msixbundle on the latest winget-cli release."
        }

        $bundlePath  = Join-Path $work $bundle.name
        Write-Host "Downloading $($bundle.name)..."
        Invoke-WebRequest -Uri $bundle.browser_download_url -OutFile $bundlePath -UseBasicParsing

        $licensePath = $null
        if ($license) {
            $licensePath = Join-Path $work $license.name
            Invoke-WebRequest -Uri $license.browser_download_url -OutFile $licensePath -UseBasicParsing
        }

        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }

        if ($depsZip) {
            $zipPath = Join-Path $work $depsZip.name
            Write-Host "Downloading dependencies..."
            Invoke-WebRequest -Uri $depsZip.browser_download_url -OutFile $zipPath -UseBasicParsing
            $depsDir = Join-Path $work 'deps'
            Expand-Archive -Path $zipPath -DestinationPath $depsDir -Force

            $depFiles = Get-ChildItem -Path $depsDir -Recurse -Include '*.appx','*.msix' |
                Where-Object { $_.FullName -match [regex]::Escape($arch) -or $_.Name -match $arch }

            foreach ($dep in $depFiles) {
                Write-Host "Installing dependency $($dep.Name)..."
                try {
                    Add-AppxPackage -Path $dep.FullName -ErrorAction Stop | Out-Null
                } catch {
                    if ($_.Exception.Message -notmatch '0x80073D06|0x80073CF0|higher version|already installed') {
                        Write-Warning "Dependency $($dep.Name): $($_.Exception.Message)"
                    }
                }
            }
        }

        Write-Host "Installing App Installer package..."
        try {
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Add-AppxPackage failed: $($_.Exception.Message). Trying provisioned install."
            if (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
                if ($licensePath) {
                    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -LicensePath $licensePath -ErrorAction Stop | Out-Null
                } else {
                    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -SkipLicense -ErrorAction Stop | Out-Null
                }
            } else {
                throw
            }
        }

        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-PowerShell7WithWinGet {
    Write-Step "Installing Microsoft.PowerShell (machine-wide)"

    $winget = Get-WinGetCommand
    if (-not $winget) {
        throw "winget.exe was not found after bootstrap."
    }

    Write-Host "Using: $winget"
    & $winget --info | Out-Host

    # Accept source agreements first so the first install is non-interactive.
    & $winget source update --disable-interactivity 2>$null | Out-Null

    $common = @(
        '--id', 'Microsoft.PowerShell',
        '--exact',
        '--source', 'winget',
        '--scope', 'machine',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    Write-Host "Attempting MSI/WiX machine-wide installer..."
    & $winget install @common --installer-type wix
    $exit = $LASTEXITCODE

    # 0 = success, -1978335189 (0x8A15002B) often means already installed.
    if ($exit -ne 0 -and $exit -ne -1978335189) {
        Write-Warning "WiX install returned $exit. Retrying without --installer-type."
        & $winget install @common
        $exit = $LASTEXITCODE
    }

    if ($exit -ne 0 -and $exit -ne -1978335189) {
        throw "winget install Microsoft.PowerShell failed with exit code $exit."
    }

    Write-Host "winget install completed (exit $exit)."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Step "Preflight"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Warning "This script is intended to run under Windows PowerShell 5.1. Continuing anyway."
}
if (-not (Test-IsAdmin)) {
    throw "This script must be run from an elevated (Run as administrator) PowerShell 5 window."
}
Write-Host ("Host: {0}  PS: {1}  User: {2}" -f $env:COMPUTERNAME, $PSVersionTable.PSVersion, $env:USERNAME)
Update-ProcessPath

if (-not (Test-WinGetReady)) {
    Register-DesktopAppInstaller
    Update-ProcessPath
}

if (-not (Test-WinGetReady)) {
    try {
        Install-WinGetViaRepairModule
    } catch {
        Write-Warning "Repair-WinGetPackageManager path failed: $($_.Exception.Message)"
    }
    Update-ProcessPath
}

if (-not (Test-WinGetReady)) {
    Install-WinGetFromGitHub
    Update-ProcessPath
}

Write-Step "Waiting until winget is installed and running"
if (-not (Wait-Until -Condition { Test-WinGetReady } -Name 'winget' -TimeoutSeconds $WaitSeconds -IntervalSeconds $PollSeconds)) {
    throw "Timed out waiting for winget after $WaitSeconds seconds."
}
$wingetExe = Get-WinGetCommand
Write-Host "winget path: $wingetExe"
& $wingetExe --version | Out-Host

if (-not (Test-PwshReady)) {
    Install-PowerShell7WithWinGet
}

# MSI installers write Machine PATH in the registry; refresh this process.
Update-ProcessPath

Write-Step "Waiting until PowerShell 7 is installed and running"
if (-not (Wait-Until -Condition { Test-PwshReady } -Name 'pwsh' -TimeoutSeconds $WaitSeconds -IntervalSeconds $PollSeconds)) {
    throw "Timed out waiting for pwsh.exe after $WaitSeconds seconds. Check Program Files\PowerShell\7."
}

Update-ProcessPath
$pwsh = Get-PwshCommand
Write-Host "pwsh path: $pwsh"
$verText = Invoke-PwshCommand -PwshPath $pwsh -Command '$PSVersionTable.PSVersion.ToString()'
Write-Host ("PowerShell {0} ready." -f $verText.Trim())

Write-Step "Done"
Write-Host "WinGet and PowerShell 7 are available."
Write-Host "This session PATH now includes C:\Program Files\PowerShell\7"
Write-Host "A brand-new window reads PATH from the registry; this window needed a refresh."

try { # Apply custom environment settings for current user
	& (Join-Path $PSScriptRoot 'Configure-WindowsEnvironment.ps1')
} catch { Write-Host "Configure-WindowsEnvironment.ps1 is missing. `nEnsure it is in the smae folder as Configure-WindowsEnvironment.ps1" -ForegroundColor Red }

try { # Install most recent version of Notepad++ if the installer is in the same folder
	$installer = Get-ChildItem -Path $PSScriptRoot -Filter 'npp.*.Installer.x64.exe' -File |
    Sort-Object Name -Descending |
    Select-Object -First 1

	if (-not $installer) {
		throw "No Notepad++ x64 installer found in $PSScriptRoot"
	}

	$p = Start-Process -FilePath $installer.FullName -ArgumentList '/S','/runNppAfterSilentInstall' -Wait -PassThru
	if ($p.ExitCode -ne 0) {
		throw "Install failed with exit code $($p.ExitCode)"
	}
} catch { Write-Host "Notepad++ installer is missing. `nEnsure it is in the smae folder as Configure-WindowsEnvironment.ps1" -ForegroundColor Red }

try { # Something I'm working on in a Windows Sandbox environment
& (Join-Path $PSScriptRoot 'Installer\SunappuServer_Install.ps1') 
} catch { }

exit 0