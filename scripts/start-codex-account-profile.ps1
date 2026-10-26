param(
  [Parameter(Mandatory = $true)][string]$ProfileRoot,
  [ValidateRange(1024,65535)][int]$Port = 19336
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ProfileRoot)
if ($root.Contains('"')) { throw 'Profile path cannot contain a double quote.' }
$desktop = Join-Path $root 'desktop'
$codex = Join-Path $root 'codex'
$usage = Join-Path $root 'usage'
$runtime = Join-Path $root 'runtime'
$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (!$package -or $package.SignatureKind -ne 'Store' -or $package.IsDevelopmentMode) { throw 'Official Codex Store package required.' }
$exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Official executable not found.' }
function Get-ProfileListener {
  $lines = @(netstat.exe -ano -p tcp | Select-String "^\s*TCP\s+(\S+):$Port\s+\S+\s+LISTENING\s+(\d+)\s*$")
  if (!$lines.Count) { return $null }
  if ($lines.Count -ne 1 -or $lines[0].Matches[0].Groups[1].Value -ne '127.0.0.1') { throw 'Port is not exclusive to IPv4 loopback.' }
  $ownerId = [int]$lines[0].Matches[0].Groups[2].Value
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
  if (!$owner -or $owner.ExecutablePath -ine $exe -or
      !$owner.CommandLine.Replace('/', '\').Replace('"','').Contains("--user-data-dir=$desktop")) {
    throw 'Port belongs to a different app/profile. Choose another port; no process was stopped.'
  }
  return $ownerId
}
$lock = [Threading.Mutex]::new($false, "Local\UsageViewerAccountProfile-$Port")
$locked = $false
try {
  try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (!$locked) { throw 'Another profile launcher is running on this port.' }
  $listener = Get-ProfileListener
  foreach ($directory in @($desktop,$codex,$usage,$runtime)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
  $configPath = Join-Path $codex 'config.toml'
  if (!(Test-Path -LiteralPath $configPath)) {
    # Never copy existing auth/config or use the shared operating-system keyring.
    [IO.File]::WriteAllText($configPath, "cli_auth_credentials_store = `"file`"`n", [Text.UTF8Encoding]::new($false))
  } elseif ((Get-Content -LiteralPath $configPath -Raw) -notmatch '(?m)^\s*cli_auth_credentials_store\s*=\s*"file"\s*(?:#.*)?$') {
    throw 'This profile must explicitly use cli_auth_credentials_store = "file". Existing config was not changed.'
  }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $exe
  $start.UseShellExecute = $false
  $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
  $start.Arguments = "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$Port `"--user-data-dir=$desktop`""
  $start.EnvironmentVariables['CODEX_HOME'] = $codex
  $start.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $desktop
  $start.EnvironmentVariables['USAGE_VIEWER_HOME'] = $usage
  foreach ($name in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_EXECUTOR_API_KEY','OPENAI_IDENTITY_TOKEN_FILE')) {
    $start.EnvironmentVariables.Remove($name)
  }
  # Environment changes apply only to this new process, never the user's session.
  [void][Diagnostics.Process]::Start($start)
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  $version = $null
  do {
    $listener = Get-ProfileListener
    if ($listener) {
      try { $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 } catch { $version = $null }
    }
    if (!$version) { Start-Sleep -Milliseconds 500 }
  } while (!$version -and [DateTime]::UtcNow -lt $deadline)
  if (!$version) { throw 'The separate Codex profile did not expose CDP. Your existing Codex was not closed.' }
  $socket = [Uri]$version.webSocketDebuggerUrl
  if ($socket.Scheme -ne 'ws' -or $socket.Host -ne '127.0.0.1' -or $socket.Port -ne $Port -or
      $socket.UserInfo -or $socket.Query -or $socket.Fragment -or
      $socket.AbsolutePath -notmatch '^/devtools/browser/([a-fA-F0-9-]{36})$') { throw 'Unexpected CDP endpoint.' }
  $state = @{ schema = 1; app_pid = $listener; browser_id = $Matches[1]; port = $Port;
    profile_root = $root; desktop = $desktop; codex_home = $codex; usage_home = $usage; package_version = "$($package.Version)" }
  $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'state.json') -Encoding UTF8
  Write-Output "Separate Codex profile is open. Profile root: $root"
  Write-Output 'Login-screen experiment only: no shared reader or usage snapshot is attached. Stop at sign-in when testing.'
} finally {
  if ($locked) { $lock.ReleaseMutex() }
  $lock.Dispose()
}
