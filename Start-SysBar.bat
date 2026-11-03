@echo off
rem Optional: pass a monitor number, e.g. Start-SysBar.bat 1  (0 = primary screen)
set MON=%1
if "%MON%"=="" set MON=0
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0SysBar.ps1" -Monitor %MON%
