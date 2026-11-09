param([switch]$Once)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usage-source-policy.ps1')
$usageHome = Join-Path $env:USERPROFILE '.usage-viewer'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$driver = Join-Path $PSScriptRoot 'codex-desktop-usage.cjs'
$mutex = [Threading.Mutex]::new($false, 'Local\UsageViewerCodexDesktopUsage')
$locked = $false
function Test-OfficialDesktopExecutable([string]$Path, $Packages) {
  if (!$Path) { return $false }
  foreach ($package in $Packages) {
    $current = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if ($Path -ieq $current) { return $true }
    # Store updates leave already-open account windows on the previous version.
    # Accept only the protected package family and the same valid publisher.
    $parent = [regex]::Escape((Split-Path -Parent $package.InstallLocation))
    $name = [regex]::Escape($package.Name)
    $family = [regex]::Escape(($package.PackageFamilyName -split '_', 2)[1])
    if ($Path -notmatch ('^' + $parent + '\\' + $name + '_\d+\.\d+\.\d+\.\d+_(?:x64|arm64)__' + $family + '\\app\\ChatGPT\.exe$')) { continue }
    try {
      $currentSignature = Get-AuthenticodeSignature -LiteralPath $current -ErrorAction Stop
      $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
      if ($currentSignature.Status -eq 'Valid' -and $signature.Status -eq 'Valid' -and
          $signature.SignerCertificate.Subject -eq $currentSignature.SignerCertificate.Subject) { return $true }
    } catch { }
  }
  return $false
}
function Get-DesktopSources {
  param([switch]$IncludeHidden)
  $packages = @(Get-AppxPackage -Name OpenAI.Codex | Where-Object { $_.SignatureKind -eq 'Store' -and !$_.IsDevelopmentMode })
  $profiles = @()
  try { $profiles = @((Get-Content -LiteralPath (Join-Path $usageHome 'codex-account-profile-ui.json') -Raw | ConvertFrom-Json).profiles) } catch { }
  $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" | Where-Object {
    $_.CommandLine -notmatch '--type=' -and $_.CommandLine -match '--remote-debugging-port=\d+' -and
    (Test-OfficialDesktopExecutable $_.ExecutablePath $packages)
  })
  $listeners = @(netstat.exe -ano -p tcp)
  $sources = @()
  foreach ($process in $processes) {
    $command = $process.CommandLine
    if ($command -notmatch '--remote-debugging-port=(\d+)(?:\s|$)') { continue }
    $port = [int]$Matches[1]
    if ($port -lt 1024 -or $port -gt 65535) { continue }
    $bound = @($listeners | Select-String "^\s*TCP\s+(\S+):$port\s+\S+\s+LISTENING\s+(\d+)\s*$")
    if ($bound.Count -ne 1 -or $bound[0].Matches[0].Groups[1].Value -ne '127.0.0.1' -or [int]$bound[0].Matches[0].Groups[2].Value -ne $process.ProcessId) { continue }
    $desktopPath = $null
    if ($command -match '(?:"--user-data-dir=([^"]+)"|--user-data-dir="([^"]+)"|--user-data-dir=([^\s"]+))') {
      $desktopPath = @($Matches[1], $Matches[2], $Matches[3] | Where-Object { $_ })[0]
      $desktopPath = [IO.Path]::GetFullPath($desktopPath).TrimEnd('\')
    }
    $profile = @($profiles | Where-Object { $_.id -ne 'default' -and $_.profile_root -and (Join-Path $_.profile_root 'desktop').TrimEnd('\') -ieq $desktopPath })
    $id = $null; $name = $null; $output = $null
    if ($profile.Count -eq 1 -and $profile[0].id -match '^[a-zA-Z0-9_-]+$') {
      $id = [string]$profile[0].id; $name = [string]$profile[0].name
      $output = Join-Path $profile[0].profile_root 'usage'
      $codexHome = Join-Path $profile[0].profile_root 'codex'
    } elseif (!$desktopPath) {
      $id = 'default'; $name = 'Codex'; $output = $usageHome
      $codexHome = Join-Path $env:USERPROFILE '.codex'
    } else {
      # Unregistered test instances are deliberately excluded.
      continue
    }
    if (!$IncludeHidden -and $id -eq 'default' -and -not (Test-UsageSourceEnabled $usageHome 'codex_desktop_group')) { continue }
    try {
      $version = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 3
      $socket = [Uri]$version.webSocketDebuggerUrl
      if ($socket.Scheme -ne 'ws' -or $socket.Host -ne '127.0.0.1' -or $socket.Port -ne $port -or $socket.UserInfo -or $socket.Query -or $socket.Fragment -or $socket.AbsolutePath -notmatch '^/devtools/browser/([a-fA-F0-9-]{36})$') { continue }
      $sources += [pscustomobject]@{ id = $id; name = $name; port = $port; browser_id = $Matches[1]; output = $output; home = $usageHome; codex_home = $codexHome }
    } catch { }
  }
  # An ambiguous profile never borrows another process's result.
  return @($sources | Group-Object id | Where-Object { $_.Count -eq 1 } | ForEach-Object { $_.Group[0] })
}
try {
  try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (!$locked) { return }
  if (!$Once) {
    $reapply = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'UsageViewer.CodexNativeMeterReapply.v1')
  }
  do {
    try {
      $sources = @(Get-DesktopSources)
      ConvertTo-Json -InputObject $sources -Depth 5 -Compress | & $node $driver
    } catch { Write-Warning 'Codex desktop discovery unavailable; retrying next poll.' }
    if (!$Once -and $reapply.WaitOne(30000)) {
      try {
        $meterDriver = Join-Path $PSScriptRoot 'codex-native-meter.cjs'
        foreach ($source in @(Get-DesktopSources -IncludeHidden)) {
          & $node $meterDriver --port $source.port --browser-id $source.browser_id --codex-home $source.codex_home --usage-home $source.output --reinstall
          if ($LASTEXITCODE -ne 0) { Write-Warning "Could not reapply the Codex meter for profile $($source.id)." }
        }
      } catch { Write-Warning 'Codex desktop discovery unavailable; try reapplying again.' }
    }
  } while (!$Once)
} finally {
  if ($reapply) { $reapply.Dispose() }
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
