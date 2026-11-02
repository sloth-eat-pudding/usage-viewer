$ErrorActionPreference = 'Stop'
# Load only the real launcher's functions; tests must not start desktop apps.
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'start-codex-account-profile.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$desktop = 'C:\Profiles\my account\desktop'
foreach ($argument in @('"--user-data-dir=' + $desktop + '"', '--user-data-dir="' + $desktop + '"')) {
  $process = [pscustomobject]@{ CommandLine = '"C:\App\ChatGPT.exe" ' + $argument + ' --remote-debugging-port=19336' }
  if (!(Test-ProfileProcess $process $desktop)) { throw 'Quoted profile folder was not recognized.' }
  $process.CommandLine += ' --type=renderer'
  if (Test-ProfileProcess $process $desktop) { throw 'Renderer was mistaken for the account main process.' }
}
foreach ($wrong in @('C:\Profiles\my account\desktop-other', 'C:\Profiles\another\desktop')) {
  if (Test-ProfileProcess ([pscustomobject]@{ CommandLine = 'ChatGPT.exe "--user-data-dir=' + $wrong + '"' }) $desktop) { throw 'A different profile was accepted.' }
}
if (Test-ProfileProcess $null $desktop) { throw 'Missing process accepted.' }
if ((Select-AvailableProfilePort 19339 @(19336)) -ne 19339) { throw 'Free saved port was not retained.' }
if ((Select-AvailableProfilePort 19339 @(19336,19339)) -ne 19337) { throw 'Occupied saved port was not avoided.' }
$rejected = $false
try { Select-AvailableProfilePort 19339 (19336..19435) } catch { $rejected = $true }
if (!$rejected) { throw 'Port exhaustion was not detected.' }
$package = [pscustomobject]@{ InstallLocation = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1027.3384.0_x64__family'; Name = 'OpenAI.Codex'; PackageFamilyName = 'OpenAI.Codex_family' }
$exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
$oldExe = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1021.2667.0_x64__family\app\ChatGPT.exe'
$script:oldStatus = 'Valid'
$script:oldSubject = 'CN=Official publisher'
function Get-AuthenticodeSignature([string]$LiteralPath) {
  if ($LiteralPath -eq $exe) { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Official publisher' } } }
  return [pscustomobject]@{ Status = $script:oldStatus; SignerCertificate = @{ Subject = $script:oldSubject } }
}
if (!(Test-OfficialProfileExecutable $oldExe)) { throw 'Valid official previous version was rejected.' }
foreach ($path in @('C:\Downloads\OpenAI.Codex_26.1021.2667.0_x64__family\app\ChatGPT.exe', $oldExe.Replace('__family', '__other'), $oldExe.Replace('ChatGPT.exe', 'other.exe'))) {
  if (Test-OfficialProfileExecutable $path) { throw 'A nonofficial package path was accepted.' }
}
$script:oldStatus = 'HashMismatch'
if (Test-OfficialProfileExecutable $oldExe) { throw 'Modified executable was accepted.' }
$script:oldStatus = 'Valid'
$script:oldSubject = 'CN=Different publisher'
if (Test-OfficialProfileExecutable $oldExe) { throw 'Different publisher was accepted.' }
$script:oldSubject = 'CN=Official publisher'
$script:owner = [pscustomobject]@{ ExecutablePath = $oldExe; CommandLine = 'ChatGPT.exe "--user-data-dir=' + $desktop + '"' }
$script:windowHandle = 0
$script:killed = $false
function Get-CimInstance { return $script:owner }
function Get-Process {
  $process = [pscustomobject]@{ MainWindowHandle = $script:windowHandle }
  $process | Add-Member ScriptMethod WaitForExit { param($Timeout) return $true }
  return $process
}
function taskkill.exe { $script:killed = $true; $global:LASTEXITCODE = 0 }
Stop-StaleProfileProcess 123
if (!$script:killed) { throw 'The verified hidden outdated account was not retired.' }
foreach ($case in @('visible', 'current', 'other-profile', 'unsigned')) {
  $script:killed = $false
  $script:windowHandle = 0
  $script:owner.ExecutablePath = $oldExe
  $script:owner.CommandLine = 'ChatGPT.exe "--user-data-dir=' + $desktop + '"'
  $script:oldStatus = 'Valid'
  switch ($case) {
    'visible' { $script:windowHandle = 1 }
    'current' { $script:owner.ExecutablePath = $exe }
    'other-profile' { $script:owner.CommandLine += '-other' }
    'unsigned' { $script:oldStatus = 'HashMismatch' }
  }
  $rejected = $false
  try { Stop-StaleProfileProcess 123 } catch { $rejected = $true }
  if (!$rejected -or $script:killed) { throw "Unsafe retirement accepted: $case" }
}
Write-Output 'Codex account launcher checks passed: exact profile identity, previous official version, signature rejection and occupied port recovery.'

$nativeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'start-codex-native-meter.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$originalDefinition = $nativeAst.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-OriginalCodexProcess'
}, $true)
. ([scriptblock]::Create($originalDefinition.Extent.Text))
foreach ($command in @('"C:\App\ChatGPT.exe"', 'ChatGPT.exe --remote-debugging-port=19335')) {
  if (!(Test-OriginalCodexProcess ([pscustomobject]@{ CommandLine = $command }))) { throw 'Original desktop was not recognized.' }
}
foreach ($command in @('ChatGPT.exe --type=renderer', 'ChatGPT.exe "--user-data-dir=C:\Profiles\self\desktop"',
    'ChatGPT.exe --user-data-dir="C:\Profiles\self\desktop"', 'ChatGPT.exe --user-data-dir=C:\Profiles\self\desktop')) {
  if (Test-OriginalCodexProcess ([pscustomobject]@{ CommandLine = $command })) { throw 'A child or separate profile was mistaken for the original desktop.' }
}
if (Test-OriginalCodexProcess $null) { throw 'Missing original process accepted.' }
Write-Output 'Original Codex layout launcher identity checks passed.'

$discoveryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'watch-codex-desktop-usage.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$discoveryDefinition = $discoveryAst.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DesktopSources'
}, $true)
. ([scriptblock]::Create($discoveryDefinition.Extent.Text))
$usageHome = 'C:\Usage'
$script:discoveryProcesses = @(
  [pscustomobject]@{ ProcessId = 101; ExecutablePath = $exe; CommandLine = 'ChatGPT.exe --remote-debugging-port=19335' },
  [pscustomobject]@{ ProcessId = 102; ExecutablePath = $exe; CommandLine = 'ChatGPT.exe --remote-debugging-port=19336 "--user-data-dir=C:\Profiles\self\desktop"' },
  [pscustomobject]@{ ProcessId = 103; ExecutablePath = $exe; CommandLine = 'ChatGPT.exe --remote-debugging-port=19337 "--user-data-dir=C:\Usage\.tools\codex-native-test-profile"' }
)
function Get-AppxPackage { return [pscustomobject]@{ InstallLocation = $package.InstallLocation; SignatureKind = 'Store'; IsDevelopmentMode = $false } }
function Get-CimInstance { return $script:discoveryProcesses }
function Get-Content { return '{"profiles":[{"id":"self","name":"Self","profile_root":"C:\\Profiles\\self"}]}' }
function netstat.exe {
  return @('  TCP  127.0.0.1:19335  0.0.0.0:0  LISTENING  101',
    '  TCP  127.0.0.1:19336  0.0.0.0:0  LISTENING  102',
    '  TCP  127.0.0.1:19337  0.0.0.0:0  LISTENING  103')
}
function Test-UsageSourceEnabled { return $true }
function Invoke-RestMethod { param($Uri)
  $port = ([Uri]$Uri).Port
  return @{ webSocketDebuggerUrl = "ws://127.0.0.1:$port/devtools/browser/11111111-2222-3333-4444-555555555555" }
}
$sources = @(Get-DesktopSources)
if ($sources.Count -ne 2) { throw 'Expected the original and Self sources, excluding the legacy test desktop.' }
$original = @($sources | Where-Object { $_.id -eq 'default' })
$self = @($sources | Where-Object { $_.id -eq 'self' })
if ($original.Count -ne 1 -or $original[0].port -ne 19335 -or $original[0].output -ne $usageHome) { throw 'Original desktop quota was not paired with the shared usage home.' }
if ($self.Count -ne 1 -or $self[0].port -ne 19336 -or $self[0].output -ne 'C:\Profiles\self\usage') { throw 'Self desktop quota lost its profile isolation.' }
Write-Output 'Original and Self desktop discovery checks passed.'
