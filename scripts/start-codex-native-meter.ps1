param([ValidateRange(1024,65535)][int]$Port = 19335)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$runtimeRoot = Join-Path $projectRoot '.tools'
$profilePath = Join-Path $runtimeRoot 'codex-native-test-profile'
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
$operationLock = [Threading.Mutex]::new($false, "Local\UsageViewerCodexNativeMeter-$Port")
$locked = $false
function Quote-Argument([string]$Value) {
  if ($Value.Contains('"')) { throw 'Double quotes are not allowed in launch arguments.' }
  return '"' + $Value + '"'
}
function Get-VerifiedListener {
  $lines = @(netstat.exe -ano -p tcp | Select-String "^\s*TCP\s+(\S+):$Port\s+\S+\s+LISTENING\s+(\d+)\s*$")
  if (!$lines.Count) { return $null }
  if ($lines.Count -ne 1 -or $lines[0].Matches[0].Groups[1].Value -ne '127.0.0.1') { throw 'CDP port is not exclusive to IPv4 loopback.' }
  $ownerId = [int]$lines[0].Matches[0].Groups[2].Value
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
  if (!$owner -or $owner.ExecutablePath -ine $exe -or
      !$owner.CommandLine.Replace('/', '\').Replace('"','').Contains("--user-data-dir=$profilePath")) {
    throw 'CDP port belongs to a different app/profile. No process was stopped.'
  }
  return $ownerId
}
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
  $arguments = '--remote-debugging-address=127.0.0.1 --remote-debugging-port=' + $Port + ' ' +
    (Quote-Argument "--user-data-dir=$profilePath")
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
  if (!$version) { throw 'Codex did not expose CDP. Close this separate test instance and retry; your normal Codex was not stopped.' }
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
  & $node $driver --port $Port --browser-id $browserId --reinstall
  if ($LASTEXITCODE -ne 0) { throw 'Meter installation failed.' }
  Start-Process -FilePath 'wscript.exe' -ArgumentList (Quote-Argument (Join-Path $PSScriptRoot 'start-codex-reader.vbs')) -WindowStyle Hidden
  $watcher = Start-Process -FilePath $node -ArgumentList ((Quote-Argument $driver) + " --port $Port --browser-id $browserId --watch") `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtimeRoot 'codex-native-meter-watch.log') `
    -RedirectStandardError (Join-Path $runtimeRoot 'codex-native-meter-watch-error.log')
  Start-Sleep -Milliseconds 750
  if ($watcher.HasExited) { throw 'Meter watcher exited. See .tools/codex-native-meter-watch-error.log.' }
  @{ schema = 1; watcher_pid = $watcher.Id; app_pid = $listener; browser_id = $browserId; port = $Port; profile = $profilePath } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeRoot 'codex-native-meter-state.json') -Encoding UTF8
  Write-Output 'Codex full-width meter is running. This launcher shares your existing Codex account.'
} finally {
  if ($locked) { $operationLock.ReleaseMutex() }
  $operationLock.Dispose()
}
