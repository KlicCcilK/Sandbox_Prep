# Sandbox_Prep

Bootstrap a usable Windows environment in minutes — especially [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview), where WinGet, the Microsoft Store, PowerShell 7, and Windows Terminal are usually missing.

The same scripts also work on a regular Windows 11 account or a freshly imaged PC.

## What you get

| Area | Result |
| --- | --- |
| Package manager | WinGet (App Installer) bootstrapped even when the Store is absent |
| Shell | PowerShell 7 installed machine-wide (`pwsh.exe`) |
| Terminal | Windows Terminal, with a GitHub MSIX fallback |
| Display | Scaling set to **150%** by default (registry + live DPI override) |
| Explorer | Hidden items shown; file name extensions shown |
| Context menu | Classic full right-click menu (no “Show more options”) |
| Snap / multitasking | Snap flyouts on; suggestion, auto-fill, joint resize, and snap groups off |
| Optional apps | Silent install of a local Notepad++ and Chrome installer if you drop them next to the script |

Windows Sandbox is disposable. Run this once at the start of a session and you have a workable desktop instead of a bare VM.

## Repository layout

```
Sandbox_Prep/
├── Sandbox_Config.ps1                 # Elevated bootstrap (WinGet, pwsh, Terminal, scale, extras)
├── Configure-WindowsEnvironment.ps1   # Per-user Explorer / snap / context-menu settings
└── LICENSE                            # MIT
```

Keep both `.ps1` files in the **same folder**. `Sandbox_Config.ps1` calls `Configure-WindowsEnvironment.ps1` at the end of a successful run.

## Requirements

- Windows 10/11 (Windows Sandbox, a new user profile, or a newly imaged machine)
- **Windows PowerShell 5.1** (`powershell.exe`) for the bootstrap script
- **Administrator** elevation for `Sandbox_Config.ps1`
- Network access (PSGallery and GitHub are used when WinGet / Terminal are not already present)

`Configure-WindowsEnvironment.ps1` writes only `HKCU` values and does **not** need elevation.

## Quick start

### 1. Get the scripts into the machine

Clone, download the ZIP from GitHub, or map the folder into Windows Sandbox with a `.wsb` file:

```xml
<MappedFolder>
  <HostFolder>C:\Path\To\Sandbox_Prep</HostFolder>
  <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\Sandbox_Prep</SandboxFolder>
  <ReadOnly>false</ReadOnly>
</MappedFolder>
```

### 2. Run the bootstrap (elevated)

From an **elevated** Windows PowerShell 5.1 window — not `pwsh`:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd C:\Path\To\Sandbox_Prep
.\Sandbox_Config.ps1
```

Typical first-run time in Sandbox is a few minutes: WinGet repair or GitHub MSIX download, then PowerShell 7 and Windows Terminal.

### 3. Shell settings only (no installs)

If WinGet / PowerShell 7 / Terminal are already present and you only want Explorer and snap tweaks:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Configure-WindowsEnvironment.ps1
```

Pass `-RestartExplorer:$false` if you do not want Explorer killed immediately.

## `Sandbox_Config.ps1`

Must run as Administrator under Windows PowerShell 5.1.

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-WaitSeconds` | `180` | How long to poll for WinGet, `pwsh`, and Windows Terminal |
| `-PollSeconds` | `3` | Poll interval |
| `-DisplayScalePercent` | `150` | Display scale, `100`–`500`. `150` is comfortable in Sandbox. |

Example:

```powershell
.\Sandbox_Config.ps1 -DisplayScalePercent 125 -WaitSeconds 240
```

### Install flow

1. Set display scale (LogPixels / AppliedDPI plus a live `SPI_SETLOGICALDPIOVERRIDE` call).
2. Try to register the already-staged `Microsoft.DesktopAppInstaller` package.
3. If `winget` is still missing, install `Microsoft.WinGet.Client` from PSGallery and run `Repair-WinGetPackageManager -AllUsers`.
4. If that still fails (common in Sandbox), download the latest App Installer `.msixbundle` and dependencies from the [winget-cli](https://github.com/microsoft/winget-cli) GitHub release.
5. Poll until `winget.exe --version` works.
6. `winget install Microsoft.PowerShell` machine-wide (WiX first, then a generic retry). Treat “already installed” as success.
7. Poll until `pwsh` reports a 7.x version.
8. `winget install Microsoft.WindowsTerminal`, then fall back to the latest stable MSIX from [microsoft/terminal](https://github.com/microsoft/terminal) if needed.
9. Run `Configure-WindowsEnvironment.ps1` from the same folder.
10. Optionally run local installers (see below).

The script refreshes `$env:PATH` in the current process so newly installed binaries are callable without opening a new window.

### Optional local installers

These are **skipped** if the files are not present. Nothing is downloaded for them.

| File next to the script | Action |
| --- | --- |
| `npp.*.Installer.x64.exe` | Silent Notepad++ install (`/S`) |
| `ChromeSetup.exe`, `GoogleChrome*.exe`, or `chrome_installer.exe` | Chrome install (`/passive`) |
| `Installer\SunappuServer_Install.ps1` | Optional project installer (failures are ignored) |

Drop the latest official offline installers into the repo folder when you want those apps in Sandbox.

## `Configure-WindowsEnvironment.ps1`

Applies current-user shell preferences. Safe to re-run.

| Setting | Value |
| --- | --- |
| Classic context menu | Enabled (`CLSID {86ca1aa0-34aa-4e8b-a509-50c905bae2a2}` empty `InprocServer32`) |
| Snap windows master switch | On |
| Snap Assist flyout (hover maximize) | On |
| Snap bar (drag to top) | On |
| Suggest what to snap next | Off |
| Auto-fill remaining space | Off |
| Joint resize of adjacent windows | Off |
| Snap groups on taskbar / Alt+Tab | Off |
| Snap before reaching the screen edge | Off |
| Show app tabs when snapping / Alt+Tab | Don’t show tabs |
| Virtual desktops — taskbar and Alt+Tab | Only the desktop in use |
| Title-bar window shake | Off |
| Hidden files | Shown |
| File name extensions | Shown |

Explorer is restarted by default so the classic menu and snap flyouts apply immediately.

```powershell
.\Configure-WindowsEnvironment.ps1 -RestartExplorer:$false
```

## Notes and limitations

- **Run `Sandbox_Config.ps1` as Administrator.** It will throw if the session is not elevated.
- **Use `powershell.exe`, not `pwsh`, for the bootstrap.** The comment-based help and `#Requires` statements target 5.1. PowerShell 7 can continue, but 5.1 is the intended host inside a stock Sandbox.
- Windows Sandbox has no persistent disk. Map this folder in, run the script, and treat the result as session-local unless you snapshot the host-side installers.
- WinGet app-execution aliases under `%LOCALAPPDATA%\Microsoft\WindowsApps` are often 0-byte stubs. The script looks for the real package binary under `Program Files\WindowsApps` and ignores stubs.
- Display scale is applied live when possible. Some windows already open may keep the old DPI until they are restarted.
- The repo About text says the context menu is “disabled.” The script actually **restores the classic full menu** and removes the Windows 11 compact flyout.

## License

[MIT](LICENSE) © 2026 Dave Maynard
