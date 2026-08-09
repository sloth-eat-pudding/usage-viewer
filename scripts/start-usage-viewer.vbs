Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
overlayPath = folder & "\start-overlay.vbs"

' Stop readers and close Usage Viewer windows from previous launches before
' starting fresh processes.
cleanupReaders = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*claude-desktop-usage-read.js*' -or $_.CommandLine -like '*codex-usage-read.js*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" & Chr(34)
shell.Run cleanupReaders, 0, True

cleanupWindows = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & "Get-Process | Where-Object { $_.MainWindowTitle -eq 'Usage Viewer' } | Stop-Process -Force" & Chr(34)
shell.Run cleanupWindows, 0, True

publishedExe = fso.GetParentFolderName(folder) & "\dist\UsageViewer.exe"
If fso.FileExists(publishedExe) Then
  shell.Run Chr(34) & publishedExe & Chr(34), 0, False
Else
  shell.Run "wscript.exe " & Chr(34) & overlayPath & Chr(34), 0, False
End If
