$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claude-desktop-profiles.ps1')
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
  # Reproduce the packaged app's profile migration, with both locations present.
  $fixtureAppData = Join-Path $usageHome 'roaming'
  $fixtureLocalData = Join-Path $usageHome 'local'
  $oldHistory = Join-Path $fixtureLocalData 'Packages\Claude_test\LocalCache\Roaming\Claude\plan-usage-history.json'
  $newHistory = Join-Path $fixtureLocalData 'Claude-Data\claude_test\plan-usage-history.json'
  $regularHistory = Join-Path $fixtureAppData 'Claude\plan-usage-history.json'
  foreach ($historyPath in @($oldHistory, $newHistory, $regularHistory)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $historyPath) -Force | Out-Null
    [IO.File]::WriteAllText($historyPath, '{"samples":[]}')
  }
  $profiles = @(Get-ClaudeDesktopProfiles $fixtureAppData $fixtureLocalData)
  Assert-True ($profiles.Count -eq 2) 'Migrated and legacy copies of one family must not create duplicate sources'
  Assert-True ($profiles[1].path -ieq (Get-Item -LiteralPath $newHistory).FullName) 'Claude-Data must take precedence over Packages'
  Assert-True ($profiles[1].legacy_path -ieq $oldHistory) 'Migration must preserve the old path identity for saved groups'
  Remove-Item -LiteralPath $newHistory
  $profiles = @(Get-ClaudeDesktopProfiles $fixtureAppData $fixtureLocalData)
  Assert-True ($profiles[1].path -ieq (Get-Item -LiteralPath $oldHistory).FullName) 'Older installations must still be discovered'
  Remove-Item -LiteralPath $oldHistory
  $profiles = @(Get-ClaudeDesktopProfiles $fixtureAppData $fixtureLocalData)
  Assert-True ($profiles.Count -eq 1) 'Missing packaged profiles must not replace the regular installation'
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
  Assert-True ((Get-RetryDelaySeconds 1000) -eq 120) 'Recovery must retry before another five-minute display expiry'
  $retryStates = @{}
  $firstWindow = [pscustomobject]@{ ProcessId = 1; Handle = 100 }
  $retryState = Get-ClaudeRetryState $retryStates 'profile|organization' $firstWindow
  $retryState.Failures = 4; $retryState.NextAttempt = [DateTimeOffset]::UtcNow.AddMinutes(2)
  Assert-True ((Get-ClaudeRetryState $retryStates 'profile|organization' $firstWindow).Failures -eq 4) 'The same window must retain its backoff'
  Assert-True ((Get-ClaudeRetryState $retryStates 'profile|organization' $null).Failures -eq 4) 'A temporarily missing window must not spin retries'
  $restartedWindow = [pscustomobject]@{ ProcessId = 2; Handle = 200 }
  $retryState = Get-ClaudeRetryState $retryStates 'profile|organization' $restartedWindow
  Assert-True ($retryState.Failures -eq 0 -and $retryState.NextAttempt -eq [DateTimeOffset]::MinValue) 'Restarted Claude must recover immediately without inheriting the old cooldown'
  $tools = @(
    [pscustomobject]@{ ProcessId = 1; Handle = 101; Cloaked = $false; Title = 'DevTools - file:///main_window/index.html' },
    [pscustomobject]@{ ProcessId = 1; Handle = 102; Cloaked = $false; Title = 'Developer Tools - https://claude.ai/epitaxy?coldLaunch=1' },
    [pscustomobject]@{ ProcessId = 2; Handle = 201; Cloaked = $false; Title = 'Developer Tools - https://claude.ai/epitaxy' }
  )
  Assert-True ((Get-ClaudeWebDevTools $firstWindow $tools).Handle -eq 102) 'Reuse the existing Claude web DevTools, excluding the wrapper and the other account'
  Assert-True ($null -eq (Get-ClaudeWebDevTools $firstWindow @($tools[0], $tools[2]))) 'Another renderer is not a matching web console'
  $tools[1].Cloaked = $true
  Assert-True ($null -eq (Get-ClaudeWebDevTools $firstWindow $tools)) 'A cloaked console must not receive keyboard input'
  $tools[1].Cloaked = $false
  $ambiguousRejected = $false
  try { Get-ClaudeWebDevTools $firstWindow @($tools[1], $tools[1]) | Out-Null } catch { $ambiguousRejected = $true }
  Assert-True $ambiguousRejected 'Multiple web DevTools must not select an arbitrary renderer'
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
  $heartbeat = @{ source = 'claude-session-meter'; instance = '2-1002'; version = '1.3.0'; refresh_id = $refreshId; observed_at = [DateTimeOffset]::UtcNow.ToString('O') }
  Write-TestSnapshot $heartbeat
  Assert-True (Test-SessionMeterHeartbeat '2-1002' $refreshId) 'A matching current window heartbeat must be fresh'
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1003')) 'One window heartbeat cannot acknowledge another window'
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002' ([guid]::NewGuid().ToString()))) 'An older injection cannot acknowledge a new worker'
  $heartbeat.version = '1.0.0'; Write-TestSnapshot $heartbeat
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002')) 'Old meter versions must be upgraded'
  $heartbeat.version = '1.3.0'; $heartbeat.observed_at = [DateTimeOffset]::UtcNow.AddSeconds(-90).ToString('O'); Write-TestSnapshot $heartbeat
  Assert-True (-not (Test-SessionMeterHeartbeat '2-1002')) 'A reloaded page stops heartbeats and must be reinjected'
  # Compile the actual Win32 helper without calling its input methods.
  $source = Get-Content $scriptPath -Raw
  $native = [regex]::Match($source, "(?s)Add-Type -ReferencedAssemblies \u0024nativeReferences @'\r?\n(.*?)\r?\n'@").Groups[1].Value
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
  $nativeReferences = @('System.dll', 'System.Core.dll',
    [Windows.Automation.AutomationElement].Assembly.Location,
    [Windows.Automation.AutomationPattern].Assembly.Location,
    [Windows.DependencyObject].Assembly.Location)
  Add-Type -ReferencedAssemblies $nativeReferences $native
  Assert-True ([ClaudeUsageInjectorNative]::IsEmptyConsoleText("`r`n")) 'A blank Console prompt may be reused'
  Assert-True (-not [ClaudeUsageInjectorNative]::IsEmptyConsoleText('user draft')) 'Existing console input must be preserved'
  Assert-True (-not [ClaudeUsageInjectorNative]::IsEmptyConsoleText([NullString]::Value)) 'An unreadable Console prompt must not be treated as empty'
  Assert-True (Test-ConsoleScriptText "line1`r`nline2`r`n" "line1`nline2") 'Clipboard verification must compare the entire multiline script across Windows newline formats'
  Assert-True (-not (Test-ConsoleScriptText 'line2' "line1`nline2")) 'Visible CodeMirror lines alone must not acknowledge the whole script'
  Assert-True (-not (Test-ConsoleScriptText 'UsageViewer-copy-sentinel' 'script')) 'A failed clipboard copy must not validate the previous paste'
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
