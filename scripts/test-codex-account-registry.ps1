$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex-account-registry.ps1')
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-registry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
  $file = Join-Path $temporaryRoot 'registry.json'
  $profilesRoot = Join-Path $temporaryRoot 'profiles'
  $registry = Read-CodexAccountRegistry $file $profilesRoot
  if ($registry.profiles.Count -ne 2 -or $registry.selected_id -ne 'account-1') { throw 'Two default accounts were not supplied.' }
  if ($registry.profiles[0].profile_root -eq $registry.profiles[1].profile_root) { throw 'Default accounts share a folder.' }
  $firstRoot = Join-Path $temporaryRoot 'first account'
  $secondRoot = Join-Path $temporaryRoot 'second account'
  [void](Register-CodexAccount $registry 'Work' $firstRoot 'account-1')
  [void](Register-CodexAccount $registry 'Personal' $secondRoot 'account-2')
  Save-CodexAccountRegistry $file $registry
  $reloaded = Read-CodexAccountRegistry $file $profilesRoot
  if ($reloaded.profiles.Count -ne 2 -or $reloaded.selected_id -ne 'account-2') { throw 'Selected account was not retained.' }
  if (@($reloaded.profiles | Where-Object { $_.id -eq 'account-1' })[0].profile_root -ne $firstRoot) { throw 'First registration was lost.' }
  if (@($reloaded.profiles | Where-Object { $_.id -eq 'account-2' })[0].profile_root -ne $secondRoot) { throw 'Opening the second account would require choosing its folder again.' }
  foreach ($attempt in @(@('Work', (Join-Path $temporaryRoot 'third')), @('Other', $firstRoot), @('Other', 'relative-folder'))) {
    $rejected = $false
    try { [void](Register-CodexAccount $reloaded $attempt[0] $attempt[1]) } catch { $rejected = $true }
    if (!$rejected) { throw 'Duplicate or invalid registration was accepted.' }
  }
  $legacyFile = Join-Path $temporaryRoot 'legacy.json'
  @{ profile_root = $firstRoot } | ConvertTo-Json | Set-Content -LiteralPath $legacyFile -Encoding UTF8
  $legacy = Read-CodexAccountRegistry $legacyFile $profilesRoot
  if ($legacy.profiles[0].profile_root -ne $firstRoot -or $legacy.profiles.Count -ne 2) { throw 'Previous folder was not migrated.' }
  if ($reloaded.profiles[0].id -ne 'account-1') { throw 'Renaming reordered the saved accounts.' }
  @{ profile_root = (Join-Path $profilesRoot 'account-2') } | ConvertTo-Json | Set-Content -LiteralPath $legacyFile -Encoding UTF8
  $collision = Read-CodexAccountRegistry $legacyFile $profilesRoot
  if ($collision.profiles[0].profile_root -eq $collision.profiles[1].profile_root) { throw 'Migrated accounts share a folder.' }
  if ((Test-Path -LiteralPath $firstRoot) -or (Test-Path -LiteralPath $secondRoot)) { throw 'Registering an account should not launch Codex or create credential folders.' }
  Write-Output 'Codex account registry checks passed: two accounts, saved folders and selection, rename, duplicate rejection and legacy migration.'
} finally {
  $resolved = [IO.Path]::GetFullPath($temporaryRoot)
  if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
