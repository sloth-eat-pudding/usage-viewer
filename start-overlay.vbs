Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
exePath = folder & "\UsageViewer.exe"
publishExePath = folder & "\src\UsageViewer\bin\Release\net7.0-windows\win-x64\publish\UsageViewer.exe"
scriptPath = folder & "\UsageOverlay.ps1"

If fso.FileExists(exePath) Then
  command = Chr(34) & exePath & Chr(34)
ElseIf fso.FileExists(publishExePath) Then
  command = Chr(34) & publishExePath & Chr(34)
Else
  command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
End If

shell.Run command, 0, False
