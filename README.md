# status-bar

An Ubuntu-style status bar for Windows 11, written in plain PowerShell + WPF (no installs).

![bar](https://img.shields.io/badge/Windows-11-blue)

## What it shows

Docked to the top of a monitor as a Windows *AppBar* (maximized windows leave room for it):

- **CPU** usage %
- **RAM** used / total — click for a memory breakdown (in use, available, committed, kernel, top 15 apps)
- **DISK** activity % with read/write throughput
- **CLAUDE** Claude Code sessions: count, busy, idle — click for a list per session (title, state, how long, RAM, started, app/CLI, Windows account) with a ✕ to end a session
- Clock in the middle, free space per fixed drive on the right
- A small notification + sound when a Claude session goes from busy to idle

Right-click the bar for: notifications on/off, test notification, close.

## Files

| File | Purpose |
|---|---|
| `SysBar.ps1` | The top status bar |
| `Start-SysBar.bat` | Starts the bar; optional monitor number (`Start-SysBar.bat 1`, `0` = primary) |
| `SysWidget.ps1` | Alternative: small floating, draggable stats widget |
| `Start-SysWidget.bat` | Starts the floating widget |

## Install / start at login

1. Copy the files to a permanent folder, e.g. `%LOCALAPPDATA%\SysBar`.
2. Double-click `Start-SysBar.bat` to try it.
3. To start with Windows: Win+R → `shell:startup` → add a shortcut with target
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%LOCALAPPDATA%\SysBar\SysBar.ps1" -Monitor 0`

## Notes

- Stats come from WMI performance classes, so they work on non-English Windows.
- Claude sessions are read from `%USERPROFILE%\.claude\sessions\*.json` for every readable profile on the machine (so sessions in an elevated terminal under a separate admin account show too). Session titles come from the transcript (`/rename` or the automatic title). `.key` files are never read.
- Ending a session belonging to another account may need a UAC prompt.
- `SysBar.ps1 -SelfTest` prints the current values without opening the bar.
