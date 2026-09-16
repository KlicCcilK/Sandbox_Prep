#Install winget, Powershell 7, and Windows Terminal; set display scale to 150%
#Optimixed for Windows Sandbx install

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstrap WinGet (App Installer) on Windows PowerShell 5.1, then install
    PowerShell 7 machine-wide and Windows Terminal NotePadd++, Google Chrome, and set display scaling
    to 150%. Designed to succeed in Windows Sandbox.

.DESCRIPTION
    Run from an elevated Windows PowerShell 5.1 window (the built-in
    powershell.exe, not pwsh).

    Flow:
      1. Set display scaling to 150% (registry + live DPI override).
      2. Register Microsoft.DesktopAppInstaller by family name (when the
         package is already staged/provisioned).
      3. If winget is still missing (typical of Windows Sandbox), bootstrap
         it with Microsoft.WinGet.Client / Repair-WinGetPackageManager, then
         fall back to the GitHub App Installer MSIX bundle + dependencies.
      4. Poll until winget.exe is callable.
      5. Install Microsoft.PowerShell machine-wide via winget.
      6. Poll until pwsh.exe is callable.
      7. Install Microsoft.WindowsTerminal via winget, with a GitHub
         MSIX bundle fallback (typical of Windows Sandbox / no Store).
      8. Poll until Windows Terminal is registered.

    Installs are system-wide where the installer supports it.
#>

[CmdletBinding()]
param(
    [int]$WaitSeconds = 180,
    [int]$PollSeconds = 3,
    [ValidateRange(100, 500)]
    [int]$DisplayScalePercent = 150
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

function Set-DisplayScale {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(100, 500)]
        [int]$Percent
    )

    Write-Step ("Setting display scale to {0}%" -f $Percent)

    # 96 DPI = 100%. 150% => 144 LogPixels.
    $logPixels = [int][Math]::Round(96 * ($Percent / 100.0))
    $desktop   = 'HKCU:\Control Panel\Desktop'
    $metrics   = 'HKCU:\Control Panel\Desktop\WindowMetrics'

    if (-not (Test-Path -LiteralPath $desktop)) {
        New-Item -Path $desktop -Force | Out-Null
    }
    New-ItemProperty -Path $desktop -Name 'LogPixels' -PropertyType DWord -Value $logPixels -Force | Out-Null
    New-ItemProperty -Path $desktop -Name 'Win8DpiScaling' -PropertyType DWord -Value 1 -Force | Out-Null

    if (-not (Test-Path -LiteralPath $metrics)) {
        New-Item -Path $metrics -Force | Out-Null
    }
    New-ItemProperty -Path $metrics -Name 'AppliedDPI' -PropertyType DWord -Value $logPixels -Force | Out-Null

    Write-Host ("Registry DPI set: LogPixels={0}, Win8DpiScaling=1" -f $logPixels)

    # Live apply. SPI_SETLOGICALDPIOVERRIDE is a step index relative to the
    # recommended scale (usually 100% in Windows Sandbox), not an absolute %.
    # Steps: 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
    $steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
    $desiredIdx = 0
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ($steps[$i] -le $Percent) { $desiredIdx = $i }
    }

    try {
        if (-not ('SandboxDpi.Native' -as [type])) {
            Add-Type -Namespace SandboxDpi -Name Native -MemberDefinition @'
[DllImport("user32.dll", EntryPoint = "SystemParametersInfo", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);
'@
        }
        $SPI_SETLOGICALDPIOVERRIDE = [uint32]0x009F
        $SPIF_UPDATEINIFILE       = [uint32]0x0001
        $ok = [SandboxDpi.Native]::SystemParametersInfo(
            $SPI_SETLOGICALDPIOVERRIDE,
            [uint32]$desiredIdx,
            [IntPtr]::Zero,
            $SPIF_UPDATEINIFILE
        )
        if ($ok) {
            Write-Host ("Applied live scale override (step index {0} => {1}%)." -f $desiredIdx, $steps[$desiredIdx]) -ForegroundColor Green
        } else {
            Write-Warning "Live DPI override did not take effect immediately. Registry values are set; new windows should pick them up."
        }
    } catch {
        Write-Warning "Live DPI apply skipped: $($_.Exception.Message)"
    }
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

function Get-WindowsTerminalCommand {
    # App-execution aliases under WindowsApps are 0-byte stubs. Prefer the
    # real package binary, then a non-stub wt.exe on PATH.
    $candidates = @()

    $pkgDirs = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') `
        -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.WindowsTerminal_*_*__8wekyb3d8bbwe' } |
        Sort-Object Name

    foreach ($dir in $pkgDirs) {
        foreach ($name in @('wt.exe', 'WindowsTerminal.exe')) {
            $exe = Join-Path $dir.FullName $name
            if (Test-RealExecutable -Path $exe) { $candidates += $exe }
        }
    }

    $cmd = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    $winApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $winApps) { $candidates += $winApps }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-RealExecutable -Path $path) { return $path }
    }
    return $null
}

function Test-WindowsTerminalReady {
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($pkg) { return $true }
    } catch {
        # Get-AppxPackage can fail in some constrained sessions.
    }
    return [bool](Get-WindowsTerminalCommand)
}

function Install-WindowsTerminalWithWinGet {
    Write-Step "Installing Microsoft.WindowsTerminal"

    $winget = Get-WinGetCommand
    if (-not $winget) {
        throw "winget.exe was not found after bootstrap."
    }

    Write-Host "Using: $winget"

    $common = @(
        '--id', 'Microsoft.WindowsTerminal',
        '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    # Terminal is an MSIX package; --scope machine is not always offered.
    Write-Host "Attempting winget install of Windows Terminal..."
    & $winget install @common
    $exit = $LASTEXITCODE

    # 0 = success, -1978335189 (0x8A15002B) often means already installed.
    if ($exit -ne 0 -and $exit -ne -1978335189) {
        Write-Warning "Default-scope install returned $exit. Retrying with --scope machine."
        & $winget install @common --scope machine
        $exit = $LASTEXITCODE
    }

    if ($exit -ne 0 -and $exit -ne -1978335189) {
        throw "winget install Microsoft.WindowsTerminal failed with exit code $exit."
    }

    Write-Host "winget install completed (exit $exit)."
}

function Install-WindowsTerminalFromGitHub {
    Write-Step "Falling back to GitHub Windows Terminal MSIX bundle"

    $work = Join-Path $env:TEMP ('wt-bootstrap-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $api = 'https://api.github.com/repos/microsoft/terminal/releases/latest'
        $headers = @{
            'User-Agent' = 'Install-WinGetAndPowerShell7'
            'Accept'     = 'application/vnd.github+json'
        }
        $release = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
        $assets  = @($release.assets)

        $bundle = $assets |
            Where-Object {
                $_.name -like 'Microsoft.WindowsTerminal*.msixbundle' -and
                $_.name -notlike '*Preview*'
            } |
            Select-Object -First 1

        if (-not $bundle) {
            throw "Could not find Windows Terminal msixbundle on the latest microsoft/terminal release."
        }

        $bundlePath = Join-Path $work $bundle.name
        Write-Host "Downloading $($bundle.name)..."
        Invoke-WebRequest -Uri $bundle.browser_download_url -OutFile $bundlePath -UseBasicParsing

        Write-Host "Installing Windows Terminal package..."
        try {
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Add-AppxPackage failed: $($_.Exception.Message). Trying provisioned install."
            if (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
                Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -SkipLicense -ErrorAction Stop | Out-Null
            } else {
                throw
            }
        }

        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.WindowsTerminal_8wekyb3d8bbwe' -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
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

try {
    Set-DisplayScale -Percent $DisplayScalePercent
} catch {
    Write-Warning "Display scale configuration failed: $($_.Exception.Message)"
}

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

if (-not (Test-WindowsTerminalReady)) {
    try {
        Install-WindowsTerminalWithWinGet
    } catch {
        Write-Warning "winget Windows Terminal path failed: $($_.Exception.Message)"
        try {
            Install-WindowsTerminalFromGitHub
        } catch {
            Write-Warning "GitHub Windows Terminal path failed: $($_.Exception.Message)"
        }
    }
}

Write-Step "Waiting until Windows Terminal is installed"
if (-not (Wait-Until -Condition { Test-WindowsTerminalReady } -Name 'Windows Terminal' -TimeoutSeconds $WaitSeconds -IntervalSeconds $PollSeconds)) {
    Write-Warning "Timed out waiting for Windows Terminal after $WaitSeconds seconds. Continuing with remaining setup."
} else {
    $wt = Get-WindowsTerminalCommand
    if ($wt) { Write-Host "Windows Terminal path: $wt" }
    $wtPkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($wtPkg) {
        Write-Host ("Windows Terminal {0} ready." -f $wtPkg.Version)
    }
}

Write-Step "Done"
Write-Host "WinGet, PowerShell 7, and Windows Terminal are available."
Write-Host "This session PATH now includes C:\Program Files\PowerShell\7"
Write-Host "A brand-new window reads PATH from the registry; this window needed a refresh."

try { # Apply custom environment settings for current user
	& (Join-Path $PSScriptRoot 'Configure-WindowsEnvironment.ps1')
} catch { Write-Host "Configure-WindowsEnvironment.ps1 is missing. `nEnsure it is in the smae folder as Configure-WindowsEnvironment.ps1" -ForegroundColor Red }

Write-Step "Running Local Installers"

try { # Install most recent version of Notepad++ if the installer is in the same folder
	Write-Host "`nInstalling Notepad++"
	$installer = Get-ChildItem -Path $PSScriptRoot -Filter 'npp.*.Installer*.exe' -File |
    Sort-Object Name -Descending |
    Select-Object -First 1

	if (-not $installer) {
		throw "No Notepad++ x64 installer found in $PSScriptRoot"
	}

	$p = Start-Process -FilePath $installer.FullName -ArgumentList '/S','/runNppAfterSilentInstall' -Wait -PassThru
	if ($p.ExitCode -eq 5 ) {
		Write-Host "Install failed: Notepad++ already running" }
	elseif ($p.ExitCode -ne 0) {
		Write-Host "Install failed with exit code $($p.ExitCode)" -ForegroundColor Red
		throw "Install failed with exit code $($p.ExitCode)"
	}
} catch { Write-Host "Local Notepad++ installer missing. Skipping install." }

try { # Install most recent version of Chrome if the installer is in the same folder
	Write-Host "`nInstalling Google Chrome"
	
	if (Test-Path $(Join-Path $PSScriptRoot 'ChromeSetup*.exe')) { 
		$checkFile = 'ChromeSetup*.exe'
		write-host "hit: $checkFile" }
	if (Test-Path $(Join-Path $PSScriptRoot 'ChromeSetup*.msi')) { 
		$checkFile = 'ChromeSetup*.msi'
		write-host "hit: $checkFile" }
	elseif (Test-Path $(Join-Path $PSScriptRoot 'googlechrome*.exe' )) { 
		$checkFile = 'googlechrome*.exe'
		write-host "hit: $checkFile" }
	elseif (Test-Path $(Join-Path $PSScriptRoot 'googlechrome*.msi')) { 
		$checkFile = 'googlechrome*.msi'
		write-host "hit: $checkFile" }
	elseif (Test-Path $(Join-Path $PSScriptRoot 'chrome_installer*.exe')) { 
		$checkFile = 'chrome_installer*.exe' 
		write-host "hit: $checkFile" }
	elseif (Test-Path $(Join-Path $PSScriptRoot 'chrome_installer*.msi')) { 
		$checkFile = 'chrome_installer*.msi' 
		write-host "hit: $checkFile" }
	else { write-host "No hits on Google Chrome filter"}

	$installer = Get-ChildItem -Path $PSScriptRoot -Filter $checkFile -File |
    Select-Object -First 1
	
	if (-not $installer) {
		throw "No Google Chrome installer found in $PSScriptRoot"
	}

	$p = Start-Process -FilePath $installer.FullName -ArgumentList '/passive' -Wait -PassThru
	if ($p.ExitCode -ne 0) {
		throw "Install failed with exit code $($p.ExitCode)"
	}
} catch { Write-Host "Local Google Chrome installer missing. Skipping install." }

try { # Something I'm working on in a Windows Sandbox environment
	Write-Host "`nInstalling local project files"
	& (Join-Path $PSScriptRoot 'Installer\SunappuServer_Install.ps1') 
} catch { }

Write-Host "`nSandbox_Config.ps1 complete." -ForegroundColor Green

exit 0