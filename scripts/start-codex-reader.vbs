Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.GetParentFolderName(folder) & "\src\readers\codex-usage-read.js"
lockPath = shell.ExpandEnvironmentStrings("%TEMP%") & "\usage-viewer-codex-reader.lock"

If fso.FolderExists(lockPath) Then
  On Error Resume Next
  heartbeatPath = lockPath & "\heartbeat.txt"
  If fso.FileExists(heartbeatPath) Then
    lockAgeMinutes = DateDiff("n", fso.GetFile(heartbeatPath).DateLastModified, Now)
  Else
    lockAgeMinutes = 999
  End If
  If Err.Number <> 0 Or lockAgeMinutes < 10 Then
    WScript.Quit 0
  End If
  Err.Clear
  fso.DeleteFolder lockPath, True
  On Error GoTo 0
End If

On Error Resume Next
fso.CreateFolder lockPath
If Err.Number <> 0 Then
  WScript.Quit 0
End If
On Error GoTo 0

Do
  On Error Resume Next
  Set heartbeat = fso.OpenTextFile(lockPath & "\heartbeat.txt", 2, True)
  heartbeat.WriteLine Now
  heartbeat.Close
  On Error GoTo 0

  command = "cmd.exe /c node " & Chr(34) & scriptPath & Chr(34) & " >nul 2>nul"
  shell.Run command, 0, True
  WScript.Sleep 2000
Loop
