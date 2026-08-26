Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
overlayPath = folder & "\start-overlay.vbs"
codexReaderPath = folder & "\start-codex-reader.vbs"
claudeReaderPath = folder & "\start-claude-desktop-reader.vbs"
remoteSyncPath = folder & "\sync-codex-remote.ps1"

' Stop readers and close Usage Viewer windows from previous launches before
' starting fresh processes.
cleanupReaders = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & "Get-CimInstance Win32_Process | Where-Object { (($_.Name -eq 'wscript.exe' -or $_.Name -eq 'cscript.exe') -and ($_.CommandLine -like '*start-claude-desktop-reader.vbs*' -or $_.CommandLine -like '*start-codex-reader.vbs*')) -or (($_.Name -eq 'node.exe' -or $_.Name -eq 'cmd.exe') -and ($_.CommandLine -like '*claude-desktop-usage-read.js*' -or $_.CommandLine -like '*codex-usage-read.js*')) -or ($_.Name -eq 'powershell.exe' -and ($_.CommandLine -like '*UsageOverlay.ps1*' -or $_.CommandLine -like '*sync-codex-remote.ps1*')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" & Chr(34)
shell.Run cleanupReaders, 0, True

On Error Resume Next
For Each readerLock In Array(shell.ExpandEnvironmentStrings("%TEMP%") & "\usage-viewer-claude-reader.lock", shell.ExpandEnvironmentStrings("%TEMP%") & "\usage-viewer-codex-reader.lock")
  If fso.FolderExists(readerLock) Then fso.DeleteFolder readerLock, True
Next
On Error GoTo 0

cleanupWindows = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & "Get-CimInstance Win32_Process | Where-Object { ($_.Name -eq 'UsageViewer.exe') -or ($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*UsageOverlay.ps1*') -or ($_.Name -eq 'ApplicationFrameHost.exe' -and $_.CommandLine -like '*Usage Viewer*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" & Chr(34)
shell.Run cleanupWindows, 0, True

' This entry point is intentionally independent from the WPF executable.
' It always runs the script-based readers and PowerShell overlay.
If fso.FileExists(remoteSyncPath) Then
  shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & remoteSyncPath & Chr(34), 0, False
End If
shell.Run "wscript.exe " & Chr(34) & claudeReaderPath & Chr(34), 0, False
shell.Run "wscript.exe " & Chr(34) & codexReaderPath & Chr(34), 0, False
displayMode = "combined"
If WScript.Arguments.Count > 0 Then displayMode = Replace(WScript.Arguments(0), "--", "")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & fso.GetParentFolderName(folder) & "\src\overlay\UsageOverlay.ps1" & Chr(34) & " -DisplayMode " & displayMode, 0, False
