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
$driver = Join-Path $PSScriptRoot 'codex-native-meter.cjs'
$node = (Get-Command node.exe -ErrorAction Stop).Source
if (!(Test-Path -LiteralPath $driver) -or !(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'codex-profile-metrics.cjs'))) { throw 'Codex meter files are missing. Update Usage Viewer.' }
if ((& $node -p 'typeof WebSocket') -ne 'function') { throw 'Codex meter requires Node.js 22 or later with WebSocket support.' }
$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (!$package -or $package.SignatureKind -ne 'Store' -or $package.IsDevelopmentMode) { throw 'Official Codex Store package required.' }
$exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Official executable not found.' }
function Test-ProfileProcess($Process, [string]$DesktopPath) {
  if (!$Process -or !$Process.CommandLine) { return $false }
  # Match a whole argument, never a folder prefix or a renderer child.
  $command = $Process.CommandLine.Replace('/', '\')
  if ($command -match '(?:^|\s)--type=') { return $false }
  $folder = [regex]::Escape($DesktopPath.TrimEnd('\'))
  return $command -match ('(?:^|\s)(?:"--user-data-dir=' + $folder + '"|--user-data-dir="' + $folder + '"|--user-data-dir=' + $folder + ')(?=\s|$)')
}
function Test-OfficialProfileExecutable([string]$Path) {
  if ($Path -ieq $exe) { return $true }
  # Store updates can leave a previous version running. Require the same
  # package family, protected installation parent, and a valid publisher.
  $installParent = Split-Path -Parent $package.InstallLocation
  $packageName = [regex]::Escape($package.Name)
  $familySuffix = [regex]::Escape(($package.PackageFamilyName -split '_', 2)[1])
  $pattern = '^' + [regex]::Escape($installParent) + '\\' + $packageName + '_\d+\.\d+\.\d+\.\d+_(?:x64|arm64)__' + $familySuffix + '\\app\\ChatGPT\.exe$'
  if (!$Path -or $Path -notmatch $pattern) { return $false }
  # Load the inbox module for this PowerShell host, even if another version
  # of PowerShell added its modules to the inherited PSModulePath.
  Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
  $currentSignature = Get-AuthenticodeSignature -LiteralPath $exe
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  return $currentSignature.Status -eq 'Valid' -and $signature.Status -eq 'Valid' -and
    $signature.SignerCertificate.Subject -eq $currentSignature.SignerCertificate.Subject
}
function Select-AvailableProfilePort([int]$Preferred, [int[]]$Occupied) {
  if ($Occupied -notcontains $Preferred) { return $Preferred }
  foreach ($candidate in 19336..19435) {
    if ($Occupied -notcontains $candidate) { return $candidate }
  }
  throw 'No free Codex profile port is available.'
}
function Stop-StaleProfileProcess([int]$OwnerId) {
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $OwnerId"
  if (!$owner) { return }
  if (!(Test-ProfileProcess $owner $desktop) -or $owner.ExecutablePath -ieq $exe -or
      !(Test-OfficialProfileExecutable $owner.ExecutablePath)) { throw 'Refusing to stop an unverified or current-version process.' }
  $nativeProcess = Get-Process -Id $OwnerId -ErrorAction Stop
  if ($nativeProcess.MainWindowHandle -ne 0) { throw 'The old account still has an open window. Close that window and retry.' }
  # Browser.close can leave the Electron tray process and its children alive.
  # Only retire the verified, outdated account tree after normal close timed out.
  & taskkill.exe /PID $OwnerId /T /F | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not retire the previous account process.' }
  if (!$nativeProcess.WaitForExit(10000)) { throw 'The previous account process did not exit.' }
}
function Get-ProfileListener {
  $lines = @(netstat.exe -ano -p tcp | Select-String "^\s*TCP\s+(\S+):$Port\s+\S+\s+LISTENING\s+(\d+)\s*$")
  if (!$lines.Count) { return $null }
  if ($lines.Count -ne 1 -or $lines[0].Matches[0].Groups[1].Value -ne '127.0.0.1') { throw 'Port is not exclusive to IPv4 loopback.' }
  $ownerId = [int]$lines[0].Matches[0].Groups[2].Value
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
  if (!(Test-ProfileProcess $owner $desktop) -or !(Test-OfficialProfileExecutable $owner.ExecutablePath)) {
    throw 'Port belongs to a different app/profile. Choose another port; no process was stopped.'
  }
  return $ownerId
}
# Serialize by folder even when a stale state file suggests another port.
$hasher = [Security.Cryptography.SHA256]::Create()
try { $profileKey = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($desktop.ToLowerInvariant()))).Replace('-', '') }
finally { $hasher.Dispose() }
$lock = [Threading.Mutex]::new($false, "Local\UsageViewerAccountProfile-$profileKey")
$locked = $false
try {
  try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (!$locked) { throw 'Another launcher is opening this account profile.' }
  # The live process is authoritative; runtime/state.json may predate an update
  # or an interrupted launch. Do not create a second instance of this folder.
  $running = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" | Where-Object {
    Test-ProfileProcess $_ $desktop
  })
  if ($running.Count -gt 1) { throw 'Multiple Codex processes use this profile. Close this account and retry.' }
  $launchExe = $exe
  if ($running.Count) {
    if (!(Test-OfficialProfileExecutable $running[0].ExecutablePath)) { throw 'The existing profile executable could not be verified. No process was stopped.' }
    if ($running[0].CommandLine -notmatch '(?:^|\s)--remote-debugging-port=(\d+)(?=\s|$)') { throw 'The existing profile has no debugging port. Close this account and retry.' }
    $Port = [int]$Matches[1]
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'The existing profile has an invalid debugging port.' }
    $launchExe = $running[0].ExecutablePath
  } else {
    $occupied = @(netstat.exe -ano -p tcp | Select-String '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+\d+\s*$' |
      ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
    $Port = Select-AvailableProfilePort $Port $occupied
  }
  $listener = Get-ProfileListener
  if ($running.Count -and $listener -ne $running[0].ProcessId) { throw 'The existing profile is not listening on its debugging port. Close this account and retry.' }
  foreach ($directory in @($desktop,$codex,$usage,$runtime)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
  $configPath = Join-Path $codex 'config.toml'
  if (!(Test-Path -LiteralPath $configPath)) {
    # Never copy existing auth/config or use the shared operating-system keyring.
    [IO.File]::WriteAllText($configPath, "cli_auth_credentials_store = `"file`"`n", [Text.UTF8Encoding]::new($false))
  } elseif ((Get-Content -LiteralPath $configPath -Raw) -notmatch '(?m)^\s*cli_auth_credentials_store\s*=\s*"file"\s*(?:#.*)?$') {
    throw 'This profile must explicitly use cli_auth_credentials_store = "file". Existing config was not changed.'
  }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $launchExe
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
  try { [void][Diagnostics.Process]::Start($start) }
  catch [ComponentModel.Win32Exception] {
    if ($launchExe -ieq $exe -or !$listener) { throw }
    if ((Get-Process -Id $listener -ErrorAction Stop).MainWindowHandle -ne 0) {
      throw 'The previous version still has an open account window. Close that window and retry to use the update.'
    }
    # Windows may keep an old process alive while its Store activation context
    # has already been removed. Ask only this verified browser to quit normally.
    Write-Output 'The previous Store version cannot reopen. Restarting this account with the installed version.'
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2
    $socket = [Uri]$version.webSocketDebuggerUrl
    if ($socket.Scheme -ne 'ws' -or $socket.Host -ne '127.0.0.1' -or $socket.Port -ne $Port -or
        $socket.UserInfo -or $socket.Query -or $socket.Fragment -or
        $socket.AbsolutePath -notmatch '^/devtools/browser/([a-fA-F0-9-]{36})$') { throw 'Unexpected CDP endpoint.' }
    $closingBrowserId = $Matches[1]
    if ((Get-ProfileListener) -ne $listener) { throw 'Profile ownership changed before restart.' }
    & $node $driver --port $Port --browser-id $closingBrowserId --close
    if ($LASTEXITCODE -ne 0) { throw 'The old account could not close normally. No process was forcibly stopped.' }
    $closeDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
      $oldProcess = Get-Process -Id $listener -ErrorAction SilentlyContinue
      if (!$oldProcess) { break }
      Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $closeDeadline)
    if ($oldProcess) { Stop-StaleProfileProcess $listener }
    if (Get-ProfileListener) { throw 'The profile port is still in use after closing.' }
    $launchExe = $exe
    $start.FileName = $exe
    [void][Diagnostics.Process]::Start($start)
  }
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
    profile_root = $root; desktop = $desktop; codex_home = $codex; usage_home = $usage;
    package_version = [regex]::Match($launchExe, 'OpenAI\.Codex_([\d.]+)_').Groups[1].Value;
    installed_package_version = "$($package.Version)" }
  $browserId = $state.browser_id
  # Replace only the watcher attached to this verified browser and driver.
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
    $_.ExecutablePath -ieq $node -and $_.CommandLine -and
    $_.CommandLine.Replace('/', '\').Contains($driver) -and
    $_.CommandLine.Contains($browserId) -and $_.CommandLine -match '(?:^|\s)--watch(?:\s|$)'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  & $node $driver --port $Port --browser-id $browserId --codex-home $codex --usage-home $usage --reinstall
  if ($LASTEXITCODE -ne 0) { throw 'Codex meter installation failed.' }
  $watcher = Start-Process -FilePath $node -ArgumentList "`"$driver`" --port $Port --browser-id $browserId --codex-home `"$codex`" --usage-home `"$usage`" --watch" `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime 'meter.stdout.log') `
    -RedirectStandardError (Join-Path $runtime 'meter.stderr.log')
  Start-Sleep -Milliseconds 750
  if ($watcher.HasExited) { throw 'Codex meter watcher exited. See runtime/meter.stderr.log.' }
  $state.watcher_pid = $watcher.Id
  $statePath = Join-Path $runtime 'state.json'
  $temporaryState = Join-Path $runtime ([Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($temporaryState, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    for ($attempt = 0; ; $attempt++) {
      try { Move-Item -LiteralPath $temporaryState -Destination $statePath -Force; break }
      catch [IO.IOException] { if ($attempt -ge 9) { throw }; Start-Sleep -Milliseconds 200 }
    }
  } finally { if (Test-Path -LiteralPath $temporaryState) { Remove-Item -LiteralPath $temporaryState -Force } }
  Write-Output "Separate Codex profile is open. Profile root: $root"
  Write-Output 'Full-width and session metrics are enabled. Metrics appear after sign-in and local usage events; no shared account snapshot is used.'
} finally {
  if ($locked) { $lock.ReleaseMutex() }
  $lock.Dispose()
}
