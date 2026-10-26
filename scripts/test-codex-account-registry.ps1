$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex-account-registry.ps1')
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-registry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
  $file = Join-Path $temporaryRoot 'registry.json'
  $profilesRoot = Join-Path $temporaryRoot 'profiles'
  $registry = Read-CodexAccountRegistry $file $profilesRoot
  if ($registry.profiles.Count -ne 1 -or $registry.selected_id -ne 'default' -or $registry.profiles[0].profile_root) { throw 'Initial state must contain only the original account, without a new profile folder.' }
  if ($registry.profiles[0].name -ne 'Codex') { throw 'The initial account name is not neutral.' }
  [void](Register-CodexAccount $registry 'My own label' '' 'default')
  Save-CodexAccountRegistry $file $registry
  $registry = Read-CodexAccountRegistry $file $profilesRoot
  if ($registry.profiles[0].name -ne 'My own label' -or $registry.profiles[0].profile_root) { throw 'Custom original-account name was not retained independently of its login source.' }
  $firstRoot = Join-Path $temporaryRoot 'first account'
  $secondRoot = Join-Path $temporaryRoot 'second account'
  $first = Register-CodexAccount $registry 'Work' $firstRoot
  $second = Register-CodexAccount $registry 'Personal' $secondRoot
  [void](Register-CodexAccount $registry 'Work renamed' $firstRoot $first.id)
  $registry.selected_id = $second.id
  Save-CodexAccountRegistry $file $registry
  $reloaded = Read-CodexAccountRegistry $file $profilesRoot
  if ($reloaded.profiles.Count -ne 3 -or $reloaded.selected_id -ne $second.id) { throw 'Selected account was not retained.' }
  if (@($reloaded.profiles | Where-Object { $_.id -eq $first.id })[0].profile_root -ne $firstRoot) { throw 'First registration was lost.' }
  if (@($reloaded.profiles | Where-Object { $_.id -eq $second.id })[0].profile_root -ne $secondRoot) { throw 'Opening the second account would require choosing its folder again.' }
  foreach ($attempt in @(@('Work renamed', (Join-Path $temporaryRoot 'third')), @('Other', $firstRoot), @('Other', 'relative-folder'))) {
    $rejected = $false
    try { [void](Register-CodexAccount $reloaded $attempt[0] $attempt[1]) } catch { $rejected = $true }
    if (!$rejected) { throw 'Duplicate or invalid registration was accepted.' }
  }
  $legacyFile = Join-Path $temporaryRoot 'legacy.json'
  @{ profile_root = $firstRoot } | ConvertTo-Json | Set-Content -LiteralPath $legacyFile -Encoding UTF8
  $legacy = Read-CodexAccountRegistry $legacyFile $profilesRoot
  if ($legacy.profiles[1].profile_root -ne $firstRoot -or $legacy.profiles.Count -ne 2) { throw 'Previous folder was not migrated.' }
  if ($reloaded.profiles[0].id -ne 'default' -or $reloaded.profiles[1].id -ne $first.id) { throw 'Renaming reordered the saved accounts.' }
  $rejected = $false
  try { [void](Register-CodexAccount $registry 'Replace original' $firstRoot 'default') } catch { $rejected = $true }
  if (!$rejected -or $registry.profiles[0].profile_root) { throw 'Original account was replaced by a new profile.' }
  if ((Test-Path -LiteralPath $firstRoot) -or (Test-Path -LiteralPath $secondRoot)) { throw 'Registering an account should not launch Codex or create credential folders.' }
  Write-Output 'Codex account registry checks passed: original-only initial state, explicit registration, saved selection, rename, duplicate rejection and legacy migration.'
} finally {
  $resolved = [IO.Path]::GetFullPath($temporaryRoot)
  if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
