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
