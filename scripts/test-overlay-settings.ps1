$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot '../src/overlay/UsageOverlay.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$script:overlayRoot = Join-Path $PSScriptRoot '../src/overlay'
foreach ($function in $ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -in @('Convert-GroupCode', 'Set-SourceDisplayGroup', 'Show-SharedDisplaySettings')
}, $false)) { Invoke-Expression ($function.Extent.Text.Replace('$PSScriptRoot', '$script:overlayRoot')) }
function Assert-True { param($Value, $Message) if (-not $Value) { throw $Message } }

$sources = @([pscustomobject]@{ group = '2' }, [pscustomobject]@{ group = '3' })
Set-SourceDisplayGroup $sources '2' '2'
Assert-True ($sources[1].group -eq '3') 'Unchanged selectors must preserve individual groups'
Set-SourceDisplayGroup $sources '2' 'Hidden'
Assert-True (@($sources | Where-Object group -ne 'Hidden').Count -eq 0) 'Hiding SSH/custom sources must update the rendered source groups'
Set-SourceDisplayGroup $sources 'Hidden' 'Group 1'
Assert-True (@($sources | Where-Object group -ne '1').Count -eq 0) 'Restoring sources must normalize and update each group'
Set-SourceDisplayGroup @() '1' 'Hidden'

# Exercise settings reload without launching an external settings window.
function Start-Process { [pscustomobject]@{ ExitCode = $script:exitCode } }
function Update-UsageView { }
function Resize-OverlayToContent { }
function Write-OverlayError { param($ErrorRecord) $script:loggedError = $ErrorRecord }
$testHome = Join-Path $PSScriptRoot ('../.tmp-overlay-settings-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testHome | Out-Null
try {
  $displaySettingsFile = Join-Path $testHome 'display-settings.json'
  # The mock launcher still requires an existing executable path.
  function Test-Path {
    param([string]$LiteralPath)
    if ($LiteralPath -like '*UsageViewer.exe') { return $true }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
  }
  $script:exitCode = 0
  $script:ClaudeCustomSources = @([pscustomobject]@{ group = '1'; path = 'old' })
  $script:CodexSshSources = @([pscustomobject]@{ group = '2' })
  '{"claude_custom_sources":[],"codex_ssh_sources":[],"codex_cli_group":"Hidden","codex_desktop_group":"2"}' |
    Set-Content -LiteralPath $displaySettingsFile -Encoding UTF8
  Assert-True (Show-SharedDisplaySettings) 'Shared settings reload should succeed'
  Assert-True ($script:ClaudeCustomSources.Count -eq 0 -and $script:CodexSshSources.Count -eq 0) 'Empty source arrays must remove previous sources'
  Assert-True ($script:CodexCliGroup -eq 'Hidden' -and $script:CodexDesktopGroup -eq '2') 'Desktop and CLI selections must reload'
  $script:exitCode = 1; $script:loggedError = $null
  Assert-True (-not (Show-SharedDisplaySettings)) 'Failed settings processes must enable the fallback dialog'
  Assert-True ($null -ne $script:loggedError) 'Settings process failures must be logged'
  Write-Output 'Overlay settings checks passed.'
} finally {
  Remove-Item -LiteralPath $displaySettingsFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testHome -Force
}
