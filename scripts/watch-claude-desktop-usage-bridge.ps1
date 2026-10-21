$ErrorActionPreference = 'Stop'
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'UsageViewer.ClaudeDesktopUsageBridgeWatch.v1', [ref]$createdNew)
if (-not $createdNew) {
  # Stop-Process and Windows handle cleanup can overlap a restart. Wait for
  # the previous watchdog to release its mutex instead of silently exiting.
  try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { $mutex.Dispose(); exit 0 }
}

$usageDirectory = if ($env:USAGE_VIEWER_HOME) { $env:USAGE_VIEWER_HOME } else { Join-Path $env:USERPROFILE '.usage-viewer' }
$bridgeScript = Join-Path $PSScriptRoot '..\src\readers\claude-desktop-usage-bridge.js'
$bridgePort = if ($env:CLAUDE_DESKTOP_USAGE_BRIDGE_PORT) { [int]$env:CLAUDE_DESKTOP_USAGE_BRIDGE_PORT } else { 8765 }
$bridgeProcess = $null
try {
  New-Item -ItemType Directory -Path $usageDirectory -Force | Out-Null
  while ($true) {
    $healthy = $false
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$bridgePort/health" -TimeoutSec 3
      $healthy = $health.status -eq 'ok'
    } catch {}
    if (-not $healthy) {
      if ($bridgeProcess -and -not $bridgeProcess.HasExited) {
        $bridgeProcess.Kill()
        $bridgeProcess.WaitForExit()
      }
      try {
        $bridgeProcess = Start-Process -FilePath 'node.exe' -ArgumentList "`"$bridgeScript`"" -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput (Join-Path $usageDirectory 'claude-desktop-usage-bridge.stdout.log') `
          -RedirectStandardError (Join-Path $usageDirectory 'claude-desktop-usage-bridge.stderr.log')
        Add-Content -LiteralPath (Join-Path $usageDirectory 'claude-desktop-usage-bridge-watch.log') -Value "$([DateTimeOffset]::UtcNow.ToString('O')) started bridge process=$($bridgeProcess.Id)"
      } catch {
        Add-Content -LiteralPath (Join-Path $usageDirectory 'claude-desktop-usage-bridge-watch.log') -Value "$([DateTimeOffset]::UtcNow.ToString('O')) bridge launch failed: $($_.Exception.Message)"
      }
    }
    Start-Sleep -Seconds 15
  }
} finally {
  if ($bridgeProcess -and -not $bridgeProcess.HasExited) { $bridgeProcess.Kill() }
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
