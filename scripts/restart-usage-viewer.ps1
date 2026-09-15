$ErrorActionPreference = 'Stop'
$patterns = @(
  '*UsageOverlay.ps1*',
  '*sync-codex-remote.ps1*',
  '*codex-usage-read.js*',
  '*claude-desktop-usage-read.js*',
  '*claude-desktop-usage-bridge.js*',
  '*watch-claude-desktop-usage-bridge.ps1*',
  '*claude-desktop-usage-injector.ps1*',
  '*start-usage-viewer.vbs*',
  '*UsageViewer.exe*'
)

# Process command-line inspection can be denied for packaged desktop apps.
# Stop the process that actually owns our loopback bridge port so an older
# bridge cannot survive the restart and prevent the updated one from binding.
$bridgeProcessIds = netstat.exe -ano -p tcp |
  Select-String '^\s*TCP\s+127\.0\.0\.1:8765\s+\S+\s+LISTENING\s+(\d+)\s*$' |
  ForEach-Object { [int]$_.Matches[0].Groups[1].Value } |
  Sort-Object -Unique

$bridgeProcessIds |
  Where-Object { $_ -ne $PID } |
  ForEach-Object { Stop-Process -Id $_ -Force }

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
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$PSScriptRoot\watch-claude-desktop-usage-bridge.ps1" -WindowStyle Hidden
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$PSScriptRoot\claude-desktop-usage-injector.ps1" -WindowStyle Hidden
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"$PSScriptRoot\sync-codex-remote.ps1" -WindowStyle Hidden
