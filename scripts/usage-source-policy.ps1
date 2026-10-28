# Reload display settings for each poll so Hide/Show takes effect without restart.
function Test-UsageSourceEnabled {
  param([string]$HomePath, [string]$GroupKey, [string]$SourcePath = '')
  try {
    $settings = Get-Content -LiteralPath (Join-Path $HomePath 'display-settings.json') -Raw | ConvertFrom-Json
    $sourcesKey = $GroupKey -replace '_group$', '_sources'
    $source = @($settings.$sourcesKey | Where-Object { $SourcePath -and $_.path -ieq $SourcePath } | Select-Object -First 1)
    $group = if ($source.Count) { $source[0].group } else { $settings.$GroupKey }
    return ([string]$group).Trim() -ine 'Hidden'
  } catch { return $true }
}
