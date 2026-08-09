Set shell = CreateObject("WScript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
claudeReaderPath = folder & "\start-claude-desktop-reader.vbs"
codexReaderPath = folder & "\start-codex-reader.vbs"
overlayPath = folder & "\start-overlay-powershell.vbs"

' Close only Usage Viewer windows from previous launches. This avoids
' leaving an old EXE/PowerShell overlay above the newly started one.
cleanup = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & "Get-Process | Where-Object { $_.MainWindowTitle -eq 'Usage Viewer' } | Stop-Process -Force" & Chr(34)
shell.Run cleanup, 0, True

shell.Run "wscript.exe " & Chr(34) & claudeReaderPath & Chr(34), 0, False
shell.Run "wscript.exe " & Chr(34) & codexReaderPath & Chr(34), 0, False
WScript.Sleep 500
shell.Run "wscript.exe " & Chr(34) & overlayPath & Chr(34), 0, False
