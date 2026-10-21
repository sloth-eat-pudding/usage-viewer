$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'claude-desktop-usage-injector.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load only pure functions; never start the desktop automation in a unit test.
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
function Assert-True { param($Value, [string]$Message) if (-not $Value) { throw $Message } }
function Write-TestSnapshot {
  param([object]$Value, [switch]$Raw)
  $json = if ($Raw) { [string]$Value } else { $Value | ConvertTo-Json }
  # File scanners may briefly lock a newly written fixture on Windows.
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try { [IO.File]::WriteAllText($path, $json); return } catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
  }
  throw 'Fixture remained locked for one second'
}
$usageHome = Join-Path $env:TEMP ('usage-viewer-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $usageHome | Out-Null
$organization = '11111111-1111-1111-1111-111111111111'
$path = Join-Path $usageHome "claude-desktop-api-$organization-latest.json"
try {
  Assert-True ($null -eq (Read-BridgeObservation $organization)) 'Missing snapshot must be stale'
  $snapshot = @{
    source = 'claude-desktop-api-bridge'; organization_id = $organization
    observed_at = [DateTimeOffset]::UtcNow.ToString('O')
    percentages = @{ five_hour_used = 0; seven_day_used = 78 }
  }
  Write-TestSnapshot $snapshot
  Assert-True (@(Get-StaleClaudeOrganizations @($organization)).Count -eq 0) 'Valid zero usage must be fresh'
  $refreshId = [guid]::NewGuid().ToString()
  Assert-True ($null -eq (Read-BridgeObservation $organization $refreshId)) 'Old timer must not acknowledge a new operation'
  $snapshot.refresh_id = $refreshId
  Write-TestSnapshot $snapshot
  Assert-True ($null -ne (Read-BridgeObservation $organization $refreshId)) 'Matching refresh ID must acknowledge the operation'
  $snapshot.observed_at = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('O')
  Write-TestSnapshot $snapshot
  Assert-True (@(Get-StaleClaudeOrganizations @($organization)).Count -eq 1) 'New file mtime must not hide an old observation'
  $snapshot.observed_at = [DateTimeOffset]::UtcNow.AddDays(1).ToString('O')
  Write-TestSnapshot $snapshot
  Assert-True ($null -eq (Read-BridgeObservation $organization)) 'Future observation must be rejected'
  $snapshot.observed_at = [DateTimeOffset]::UtcNow.ToString('O')
  $snapshot.organization_id = '22222222-2222-2222-2222-222222222222'
  Write-TestSnapshot $snapshot
  Assert-True ($null -eq (Read-BridgeObservation $organization)) 'Wrong account must be rejected'
  $snapshot.organization_id = $organization
  foreach ($invalid in @($null, '78', 101, -1)) {
    $snapshot.percentages = @{ five_hour_used = $invalid; seven_day_used = $null }
    Write-TestSnapshot $snapshot
    Assert-True ($null -eq (Read-BridgeObservation $organization)) "Invalid utilization must be rejected: $invalid"
  }
  Write-TestSnapshot '{broken' -Raw
  Assert-True ($null -eq (Read-BridgeObservation $organization)) 'Malformed JSON must be rejected'
  $target = [pscustomobject]@{ Profile = 'C:\profiles\Self'; IsDefault = $false }
  $processes = @(
    [pscustomobject]@{ ProcessId = 1; CommandLine = 'Claude.exe' },
    [pscustomobject]@{ ProcessId = 2; CommandLine = 'Claude.exe --user-data-dir="C:\profiles\Self"' },
    [pscustomobject]@{ ProcessId = 3; CommandLine = 'Claude.exe --user-data-dir="C:\profiles\Self-other"' },
    [pscustomobject]@{ ProcessId = 4; CommandLine = 'Claude.exe --type=renderer --user-data-dir="C:\profiles\Self"' }
  )
  $windows = @(1..4 | ForEach-Object { [pscustomobject]@{ ProcessId = $_; Cloaked = $false; Title = 'Claude'; Area = 100 * $_ } })
  Assert-True ((Get-TargetWindow $target $processes $windows).ProcessId -eq 2) 'Profile must match exactly, excluding renderer processes'
  $target.IsDefault = $true; $target.Profile = 'C:\default'
  Assert-True ((Get-TargetWindow $target $processes $windows).ProcessId -eq 1) 'Default account must not target Self'
  Assert-True ((Get-RetryDelaySeconds 1) -eq 30) 'First retry must be prompt'
  Assert-True ((Get-RetryDelaySeconds 1000) -eq 600) 'Recovery must keep retrying with a bounded delay'
  $meterWindows = @(
    [pscustomobject]@{ Handle = 1001; ProcessId = 1; Cloaked = $false; Title = 'Claude'; Area = 900000 },
    [pscustomobject]@{ Handle = 1002; ProcessId = 2; Cloaked = $false; Title = 'Claude'; Area = 800000 },
    [pscustomobject]@{ Handle = 1003; ProcessId = 2; Cloaked = $false; Title = 'Claude'; Area = 700000 },
    [pscustomobject]@{ Handle = 1004; ProcessId = 4; Cloaked = $false; Title = 'Renderer'; Area = 600000 },
    [pscustomobject]@{ Handle = 1005; ProcessId = 3; Cloaked = $true; Title = 'Claude'; Area = 600000 }
  )
  $discoveredWindows = @(Get-SessionMeterWindows $processes $meterWindows)
  Assert-True ($discoveredWindows.Count -eq 3) 'Discover both profiles and multiple windows from one process, excluding renderers and cloaked windows'
  Assert-True (@($discoveredWindows | Where-Object { $_.ProcessId -eq 2 }).Count -eq 2) 'A second window in the same profile must not be lost'
  $path = Join-Path $usageHome 'claude-session-meter-2-1002-latest.json'
  $heartbeat = @{ source = 'claude-session-meter'; instance = '2-1002'; version = '1.1.0'; refresh_id = $refreshId; observed_at = [DateTimeOffset]::UtcNow.ToString('O') }
  Write-TestSnapshot $heartbeat
  Assert-True (Test-SessionMeterHeartbeat '2-1002' $refreshId) 'A matching current window heartbeat must be fresh'
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1003')) 'One window heartbeat cannot acknowledge another window'
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002' ([guid]::NewGuid().ToString()))) 'An older injection cannot acknowledge a new worker'
  $heartbeat.version = '1.0.0'; Write-TestSnapshot $heartbeat
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002')) 'Old meter versions must be upgraded'
  $heartbeat.version = '1.1.0'; $heartbeat.observed_at = [DateTimeOffset]::UtcNow.AddSeconds(-90).ToString('O'); Write-TestSnapshot $heartbeat
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002')) 'A reloaded page stops heartbeats and must be reinjected'
  # Compile the actual Win32 helper without calling its input methods.
  $source = Get-Content $scriptPath -Raw
  $native = [regex]::Match($source, "(?s)Add-Type @'\r?\n(.*?)\r?\n'@").Groups[1].Value
  Add-Type $native
  $meterPath = Join-Path $PSScriptRoot '..\src\desktop-addon\claude-session-meter.js'
  $injection = New-InjectionScript @($organization) -SessionMeterPath $meterPath
  Assert-True ($injection.Contains('__usageViewerSessionMeter')) 'The Desktop session meter must be bundled with the bridge payload'
  $meterOnly = New-InjectionScript @() -SessionMeterPath $meterPath -RefreshId $refreshId -WindowKey '2-1002' -MeterOnly
  Assert-True ($meterOnly.Contains('"instance":"2-1002"')) 'The payload must identify its exact target window'
  Assert-True (-not $meterOnly.Contains('__usageViewerBridgeV3')) 'Installing a meter must not clear existing account usage timers'
  $injection | Set-Content (Join-Path $usageHome 'injection.js') -Encoding UTF8
  & node --check (Join-Path $usageHome 'injection.js')
  if ($LASTEXITCODE -ne 0) { throw 'Generated JavaScript syntax failed' }
  & node (Join-Path $PSScriptRoot 'test-claude-usage.js') (Join-Path $usageHome 'injection.js')
  if ($LASTEXITCODE -ne 0) { throw 'JavaScript behavior tests failed' }
  Write-Output 'Claude usage tests passed: observation validation, profile isolation, recovery delays, native helper, JavaScript behavior.'
} finally {
  # This path is a newly created, unique test directory under TEMP.
  Remove-Item -LiteralPath $usageHome -Recurse -Force
}
