Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
exePath = folder & "\UsageViewer.exe"
publishExePath = folder & "\src\UsageViewer\bin\Release\net7.0-windows\win-x64\publish\UsageViewer.exe"

If fso.FileExists(exePath) Then
  command = Chr(34) & exePath & Chr(34)
ElseIf fso.FileExists(publishExePath) Then
  command = Chr(34) & publishExePath & Chr(34)
Else
  shell.Popup "UsageViewer.exe not found. Run build-exe.cmd first.", 0, "Usage Viewer", 48
  WScript.Quit 1
End If

shell.Run command, 0, False
