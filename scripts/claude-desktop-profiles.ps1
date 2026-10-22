# Claude 3.16+ migrates packaged profiles out of Packages into Claude-Data.
# Keep the package family as the identity so a migration retains the group/name.
function Get-ClaudeDesktopProfiles {
  param([string]$AppData = $env:APPDATA, [string]$LocalAppData = $env:LOCALAPPDATA)
  $regular = Join-Path $AppData 'Claude\plan-usage-history.json'
  if (Test-Path -LiteralPath $regular) {
    [pscustomobject]@{ name = 'Claude Desktop (AppData)'; path = $regular; legacy_path = $regular; group = '1' }
  }
  $families = @{}
  $dataRoot = Join-Path $LocalAppData 'Claude-Data'
  if (Test-Path -LiteralPath $dataRoot) {
    Get-ChildItem -LiteralPath $dataRoot -Directory -Filter 'claude_*' | ForEach-Object {
      $history = Join-Path $_.FullName 'plan-usage-history.json'
      if (Test-Path -LiteralPath $history) { $families[$_.Name] = $history }
    }
  }
  $packages = Join-Path $LocalAppData 'Packages'
  if (Test-Path -LiteralPath $packages) {
    Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*' | ForEach-Object {
      $history = Join-Path $_.FullName 'LocalCache\Roaming\Claude\plan-usage-history.json'
      if (-not $families.ContainsKey($_.Name) -and (Test-Path -LiteralPath $history)) { $families[$_.Name] = $history }
    }
  }
  $index = 0
  foreach ($family in @($families.Keys | Sort-Object)) {
    $index++
    [pscustomobject]@{
      name = "Claude Desktop (MSIX $index)"; path = $families[$family]; group = [string]($index + 1)
      legacy_path = Join-Path $packages "$family\LocalCache\Roaming\Claude\plan-usage-history.json"
    }
  }
}

function Resolve-ClaudeDesktopHistoryPath {
  param([string]$Path)
  foreach ($profile in @(Get-ClaudeDesktopProfiles)) {
    if ($Path -ieq $profile.path -or $Path -ieq $profile.legacy_path) { return $profile.path }
  }
  return $Path
}
