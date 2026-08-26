$ErrorActionPreference = 'SilentlyContinue'
$patterns = @(
  '*UsageOverlay.ps1*',
  '*sync-codex-remote.ps1*',
  '*codex-usage-read.js*',
  '*claude-desktop-usage-read.js*',
  '*start-usage-viewer.vbs*',
  '*UsageViewer.exe*'
)

Get-CimInstance Win32_Process |
  Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    ($patterns | Where-Object { $process.CommandLine -like $_ } | Select-Object -First 1)
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Start-Sleep -Milliseconds 500
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$PSScriptRoot\..\src\overlay\UsageOverlay.ps1",'-DisplayMode','combined' -WindowStyle Hidden
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$PSScriptRoot\start-codex-reader.vbs`"" -WindowStyle Hidden
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$PSScriptRoot\start-claude-desktop-reader.vbs`"" -WindowStyle Hidden
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$PSScriptRoot\sync-codex-remote.ps1" -WindowStyle Hidden
