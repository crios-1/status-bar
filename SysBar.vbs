' Starts SysBar without a console window (used by the scheduled task and the desktop shortcut)
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
mon = "0"
If WScript.Arguments.Count > 0 Then mon = WScript.Arguments(0)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & dir & "\SysBar.ps1"" -Monitor " & mon, 0, False
