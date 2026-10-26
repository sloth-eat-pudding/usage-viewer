param(
  [string]$DotNetPath = 'dotnet',
  [string]$NuGetConfig = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$restoreArguments = @()
if ($NuGetConfig) { $restoreArguments = @("-p:RestoreConfigFile=$NuGetConfig") }

Push-Location $projectRoot
try {
  $scriptFiles = @(Get-ChildItem scripts -Filter '*.ps1') + @(Get-ChildItem src/overlay -Filter '*.ps1')
  foreach ($file in $scriptFiles) {
    $parseErrors = $null
    $tokens = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
  }
  foreach ($file in Get-ChildItem src/readers -Filter '*.js') {
    & node --check $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax failed: $($file.Name)" }
  }

  & node --test tests/claude-usage-contract.test.js tests/claude-profile-discovery.test.js tests/claude-subagent-usage.test.js tests/codex-native-meter.test.js tests/codex-profile-metrics.test.js tests/codex-desktop-usage.test.js
  if ($LASTEXITCODE -ne 0) { throw 'JavaScript contract tests failed' }

  & node --check src/desktop-addon/claude-session-meter.js
  if ($LASTEXITCODE -ne 0) { throw 'Desktop session meter syntax failed' }
  & node --check src/desktop-addon/codex-native-meter.js
  if ($LASTEXITCODE -ne 0) { throw 'Codex native meter syntax failed' }
  & node --check scripts/codex-native-meter.cjs
  if ($LASTEXITCODE -ne 0) { throw 'Codex native driver syntax failed' }
  & node --test tests/claude-session-meter.test.js
  if ($LASTEXITCODE -ne 0) { throw 'Desktop session meter tests failed' }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-claude-usage.ps1
  if ($LASTEXITCODE -ne 0) { throw 'Claude injector and HTTP bridge tests failed' }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-codex-account-registry.ps1
  if ($LASTEXITCODE -ne 0) { throw 'Codex account registration tests failed' }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-overlay-columns.ps1
  if ($LASTEXITCODE -ne 0) { throw 'Overlay column layout tests failed' }

  & $DotNetPath run --project tests/UsageViewer.RegressionTests/UsageViewer.RegressionTests.csproj -c Release @restoreArguments
  if ($LASTEXITCODE -ne 0) { throw 'C# regression tests failed' }

  & $DotNetPath build src/UsageViewer/UsageViewer.csproj -c Release @restoreArguments
  if ($LASTEXITCODE -ne 0) { throw 'WPF build failed' }

  Write-Output 'Usage Viewer checks passed.'
} finally {
  Pop-Location
}
