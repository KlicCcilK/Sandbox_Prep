#Requires -Version 5.1
<#
.SYNOPSIS
    Apply Dave's preferred Windows 11 shell / multitasking settings.

.DESCRIPTION
    Intended for a new device (including Windows Sandbox). Run under the
    user account that should receive the settings. HKCU writes do not
    require elevation.

    - Classic full right-click menu (no "Show more options")
    - Snap windows ON, but only the two snap-layout flyouts enabled
    - Alt+Tab / snap: don't show app tabs
    - Virtual desktops: only the desktop in use (taskbar + Alt+Tab)
    - Title bar window shake OFF

.PARAMETER RestartExplorer
    Restart explorer.exe so the classic context menu and snap flyouts
    apply immediately. Default: $true

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\Configure-WindowsEnvironment.ps1
#>

[CmdletBinding()]
param(
    [bool]$RestartExplorer = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
}

function Set-Dword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    Write-Host ("  {0}\{1} = {2}" -f $Path, $Name, $Value)
}

function Set-Sz {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    Write-Host ("  {0}\{1} = '{2}'" -f $Path, $Name, $Value)
}

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$desktop  = 'HKCU:\Control Panel\Desktop'

# -----------------------------------------------------------------------------
Write-Step "Classic right-click menu"
# Empty InprocServer32 default value blocks the Windows 11 compact menu handler.
$classicMenu = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
New-Item -Path $classicMenu -Force | Out-Null
# (Default) must exist and be an empty string — creating the key is not enough.
New-ItemProperty -LiteralPath $classicMenu -Name '(Default)' -PropertyType String -Value '' -Force | Out-Null
Write-Host "  $classicMenu\(Default) = ''"

# -----------------------------------------------------------------------------
Write-Step "System > Multitasking > Snap windows"
# Master switch must stay on or the two layout flyouts never appear.
Set-Sz    -Path $desktop  -Name 'WindowArrangementActive' -Value '1'

# ON — the two flyouts you want
Set-Dword -Path $advanced -Name 'EnableSnapAssistFlyout' -Value 1  # hover maximize button
Set-Dword -Path $advanced -Name 'EnableSnapBar'          -Value 1  # drag to top of screen

# OFF — every other Snap windows checkbox
Set-Dword -Path $advanced -Name 'SnapAssist'             -Value 0  # suggest what to snap next
Set-Dword -Path $advanced -Name 'SnapFill'               -Value 0  # auto-fill remaining space
Set-Dword -Path $advanced -Name 'JointResize'            -Value 0  # resize adjacent snapped window
Set-Dword -Path $advanced -Name 'EnableTaskGroups'       -Value 0  # snap groups on taskbar / Alt+Tab
Set-Dword -Path $advanced -Name 'DITest'                 -Value 0  # snap before reaching the screen edge

# -----------------------------------------------------------------------------
Write-Step "Show tabs from apps when snapping or pressing Alt+Tab"
# 0 = 20 tabs, 1 = 5, 2 = 3, 3 = Don't show tabs
Set-Dword -Path $advanced -Name 'MultiTaskingAltTabFilter' -Value 3

# -----------------------------------------------------------------------------
Write-Step "Desktops: Only on the desktop I'm using"
# 0 = On all desktops, 1 = Only on the desktop I'm using
Set-Dword -Path $advanced -Name 'VirtualDesktopTaskbarFilter' -Value 1  # taskbar
Set-Dword -Path $advanced -Name 'VirtualDesktopAltTabFilter'  -Value 1  # Alt+Tab

# -----------------------------------------------------------------------------
Write-Step "Title bar window shake"
# 1 = Disallow (feature OFF). Windows 11 default is already off; pin it.
Set-Dword -Path $advanced -Name 'DisallowShaking' -Value 1

# -----------------------------------------------------------------------------
Write-Step "Explorer View > Show"
Set-Dword -Path $advanced -Name 'Hidden'      -Value 1
Set-Dword -Path $advanced -Name 'HideFileExt' -Value 0

# -----------------------------------------------------------------------------
if ($RestartExplorer) {
    Write-Step "Restarting Explorer so shell settings apply"
    $shell = New-Object -ComObject Shell.Application
    $shell.Windows() | ForEach-Object {
        try { $_.Quit() } catch { }
    }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "$env:WINDIR\explorer.exe"
    }
    Write-Host "  Explorer restarted."
} else {
    Write-Host ""
    Write-Host "Explorer was not restarted. Sign out, or restart Explorer, for the classic menu to appear."
}

Write-Step "Done"
Write-Host "Settings written for the current user ($env:USERNAME)."
Write-Host "Confirm in Settings > System > Multitasking if you want a visual check."
exit 0
