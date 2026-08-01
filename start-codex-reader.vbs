Set shell = CreateObject("WScript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
scriptPath = folder & "\codex-usage-read.js"
command = "cmd.exe /c set CODEX_USAGE_SOURCE=any&& for /l %i in (0,0,0) do @(node " & Chr(34) & scriptPath & Chr(34) & " >nul 2>nul & timeout /t 2 /nobreak >nul)"
shell.Run command, 0, False
