Set shell = CreateObject("WScript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
readerPath = folder & "\start-claude-desktop-reader.vbs"
overlayPath = folder & "\start-overlay-powershell.vbs"
shell.Run "wscript.exe " & Chr(34) & readerPath & Chr(34), 0, False
WScript.Sleep 500
shell.Run "wscript.exe " & Chr(34) & overlayPath & Chr(34), 0, False
