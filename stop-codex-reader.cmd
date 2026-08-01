@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*codex-usage-read.js*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
