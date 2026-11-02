param([ValidateRange(1024,65535)][int]$Port = 19335, [switch]$SkipReader, [switch]$AutoPort)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$runtimeRoot = Join-Path $projectRoot '.tools'
$driver = Join-Path $PSScriptRoot 'codex-native-meter.cjs'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (!$package -or $package.SignatureKind -ne 'Store' -or $package.IsDevelopmentMode) { throw 'Official Codex Store package required.' }
$exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
$manifest = Get-AppxPackageManifest -Package $package
$apps = @($manifest.Package.Applications.Application | Where-Object { "$($_.Executable)".Replace('/', '\') -ieq 'app\ChatGPT.exe' })
if ($apps.Count -ne 1) { throw 'Cannot identify the official Codex application.' }
$identity = "$($package.PackageFamilyName)!$($apps[0].Id)"
if ($identity -cnotmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') { throw 'Unexpected app identity.' }
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
$locked = $false
function Quote-Argument([string]$Value) {
  if ($Value.Contains('"')) { throw 'Double quotes are not allowed in launch arguments.' }
  return '"' + $Value + '"'
}
function Test-OriginalCodexProcess($Process) {
  if (!$Process -or !$Process.CommandLine) { return $false }
  $command = $Process.CommandLine
  return $command -notmatch '(?:^|\s)--type=' -and
    $command -notmatch '(?:^|\s)"?--user-data-dir='
}
function Get-VerifiedListener {
  $lines = @(netstat.exe -ano -p tcp | Select-String "^\s*TCP\s+(\S+):$Port\s+\S+\s+LISTENING\s+(\d+)\s*$")
  if (!$lines.Count) { return $null }
  if ($lines.Count -ne 1 -or $lines[0].Matches[0].Groups[1].Value -ne '127.0.0.1') { throw 'CDP port is not exclusive to IPv4 loopback.' }
  $ownerId = [int]$lines[0].Matches[0].Groups[2].Value
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
  if (!$owner -or $owner.ExecutablePath -ine $exe -or !(Test-OriginalCodexProcess $owner) -or
      $owner.CommandLine -notmatch ( '(?:^|\s)--remote-debugging-port=' + $Port + '(?=\s|$)' )) {
    throw 'CDP port belongs to a different app/profile. No process was stopped.'
  }
  return $ownerId
}
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" | Where-Object {
  $_.ExecutablePath -ieq $exe -and (Test-OriginalCodexProcess $_)
})
if ($running.Count -gt 1) { throw 'Multiple original Codex processes found. Fully quit Codex and reopen using Start-Codex-Session-Meter.cmd.' }
if ($running.Count) {
  if ($running[0].CommandLine -notmatch '(?:^|\s)--remote-debugging-port=(\d+)(?=\s|$)') {
    throw 'The original Codex is running without layout support. Fully quit the original Codex (including its tray process), then run Start-Codex-Session-Meter.cmd or Settings > Codex account windows > Open. No Codex process was stopped.'
  }
  $Port = [int]$Matches[1]
  if ($Port -lt 1024 -or $Port -gt 65535) { throw 'The original Codex debugging port is invalid.' }
  if ((Get-VerifiedListener) -ne $running[0].ProcessId) { throw 'The original Codex is not listening on its debugging port. Fully quit it and retry this launcher.' }
}
if ($AutoPort) {
  try { [void](Get-VerifiedListener) }
  catch {
    $occupied = @(netstat.exe -ano -p tcp | Select-String '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+\d+\s*$' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
    $available = @(19335..19435 | Where-Object { $_ -notin $occupied })
    if (!$available.Count) { throw 'No free Codex meter port is available.' }
    $Port = $available[0]
  }
}
$operationLock = [Threading.Mutex]::new($false, "Local\UsageViewerCodexNativeMeter-$Port")
try {
  try { $locked = $operationLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (!$locked) { throw 'Another meter launcher is already running.' }
  $listener = Get-VerifiedListener
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport,Guid("2e941141-7f97-4756-ba1d-9decde894a3d"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUsageViewerActivation {
  [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)]string id,[MarshalAs(UnmanagedType.LPWStr)]string args,uint options,out uint pid);
}
[ComImport,Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]class UsageViewerActivation {}
public static class UsageViewerCodexLauncher {
  public static uint Launch(string id,string args) {
    var manager=(IUsageViewerActivation)new UsageViewerActivation();
    try { uint pid; Marshal.ThrowExceptionForHR(manager.ActivateApplication(id,args,0,out pid)); return pid; }
    finally { Marshal.FinalReleaseComObject(manager); }
  }
}
'@
  # Omit --user-data-dir so Store activation uses the real original desktop,
  # including its existing settings and windows, rather than a test profile.
  $arguments = '--remote-debugging-address=127.0.0.1 --remote-debugging-port=' + $Port
  [void][UsageViewerCodexLauncher]::Launch($identity, $arguments)
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  $version = $null
  do {
    $listener = Get-VerifiedListener
    if ($listener) {
      try { $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 } catch { $version = $null }
    }
    if (!$version) { Start-Sleep -Milliseconds 500 }
  } while (!$version -and [DateTime]::UtcNow -lt $deadline)
  if (!$version) { throw 'Codex did not expose CDP. Fully quit the original Codex, then retry this launcher. No process was stopped.' }
  $socket = [Uri]$version.webSocketDebuggerUrl
  if ($socket.Scheme -ne 'ws' -or $socket.Host -ne '127.0.0.1' -or $socket.Port -ne $Port -or
      $socket.UserInfo -or $socket.Query -or $socket.Fragment -or
      $socket.AbsolutePath -notmatch '^/devtools/browser/([a-fA-F0-9-]{36})$') { throw 'Unexpected CDP endpoint.' }
  $browserId = $Matches[1]
  # Replace only watchers for this exact driver and verified browser, never readers or app processes.
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
    $_.ExecutablePath -ieq $node -and $_.CommandLine -and
    $_.CommandLine.Replace('/', '\').Contains($driver) -and
    $_.CommandLine.Contains($browserId) -and $_.CommandLine -match '(?:^|\s)--watch(?:\s|$)'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  $usage = Join-Path $env:USERPROFILE '.usage-viewer'
  & $node $driver --port $Port --browser-id $browserId --usage-home $usage --reinstall
  if ($LASTEXITCODE -ne 0) { throw 'Meter installation failed.' }
  if (!$SkipReader) { Start-Process -FilePath 'wscript.exe' -ArgumentList (Quote-Argument (Join-Path $PSScriptRoot 'start-codex-reader.vbs')) -WindowStyle Hidden }
  $watcher = Start-Process -FilePath $node -ArgumentList ((Quote-Argument $driver) + " --port $Port --browser-id $browserId --usage-home " + (Quote-Argument $usage) + ' --watch') `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtimeRoot 'codex-native-meter-watch.log') `
    -RedirectStandardError (Join-Path $runtimeRoot 'codex-native-meter-watch-error.log')
  Start-Sleep -Milliseconds 750
  if ($watcher.HasExited) { throw 'Meter watcher exited. See .tools/codex-native-meter-watch-error.log.' }
  @{ schema = 2; watcher_pid = $watcher.Id; app_pid = $listener; browser_id = $browserId; port = $Port; profile = 'default' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeRoot 'codex-native-meter-state.json') -Encoding UTF8
  Write-Output 'Codex full-width meter is running. This launcher shares your existing Codex account.'
} finally {
  if ($locked) { $operationLock.ReleaseMutex() }
  $operationLock.Dispose()
}
