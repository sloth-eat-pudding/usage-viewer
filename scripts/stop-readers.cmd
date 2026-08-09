@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Process | Where-Object { $_.ProcessName -eq 'UsageViewer' -or $_.MainWindowTitle -eq 'Usage Viewer' } | Stop-Process -Force; Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*claude-desktop-usage-read.js*' -or $_.CommandLine -like '*codex-usage-read.js*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
