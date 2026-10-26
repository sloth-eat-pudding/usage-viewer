# Persistent names and folders only; credentials stay in Codex.
function Read-CodexAccountRegistry([string]$Path, [string]$ProfilesRoot) {
  $saved = $null
  try { $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
  $profiles = @([pscustomobject]@{ id = 'default'; name = 'Codex (original)'; profile_root = '' })
  foreach ($item in @($saved.profiles)) {
    if ($item.id -ne 'default' -and $item.id -match '^[a-zA-Z0-9_-]+$' -and $item.name -and $item.profile_root -and [IO.Path]::IsPathRooted([string]$item.profile_root)) {
      $profiles += [pscustomobject]@{ id = [string]$item.id; name = [string]$item.name; profile_root = [IO.Path]::GetFullPath([string]$item.profile_root) }
    }
  }
  if ($profiles.Count -eq 1 -and $saved.profile_root -and [IO.Path]::IsPathRooted([string]$saved.profile_root)) {
    $profiles += [pscustomobject]@{ id = 'legacy'; name = 'Codex (saved folder)'; profile_root = [string]$saved.profile_root }
  }
  $selected = [string]$saved.selected_id
  if ($selected -notin @($profiles | ForEach-Object { $_.id })) { $selected = $profiles[0].id }
  return [pscustomobject]@{ schema = 2; selected_id = $selected; profiles = @($profiles) }
}
function Save-CodexAccountRegistry([string]$Path, $Registry) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($temporary, ($Registry | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
    for ($attempt = 0; ; $attempt++) {
      try { Move-Item -LiteralPath $temporary -Destination $Path -Force; break }
      catch [IO.IOException] { if ($attempt -ge 9) { throw }; Start-Sleep -Milliseconds 100 }
    }
  } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Register-CodexAccount($Registry, [string]$Name, [string]$Root, [string]$Id = '') {
  if ($Id -eq 'default') { throw 'The original account cannot be changed. Add a new account instead.' }
  $Name = $Name.Trim()
  if (!$Name -or !$Root -or ![IO.Path]::IsPathRooted($Root) -or $Root.Contains('"')) { throw 'A name and an absolute profile folder are required.' }
  $Root = [IO.Path]::GetFullPath($Root)
  if ($Id -and @($Registry.profiles | Where-Object { $_.id -eq $Id }).Count -ne 1) { throw 'Selected account no longer exists.' }
  if (@($Registry.profiles | Where-Object { $_.id -ne $Id -and ($_.name -ieq $Name -or $_.profile_root.TrimEnd('\') -ieq $Root.TrimEnd('\')) }).Count) { throw 'An account with this name or folder is already registered.' }
  if (!$Id) { $Id = [Guid]::NewGuid().ToString('N') }
  $profile = [pscustomobject]@{ id = $Id; name = $Name; profile_root = $Root }
  $profiles = @($Registry.profiles)
  $index = -1
  for ($i = 0; $i -lt $profiles.Count; $i++) { if ($profiles[$i].id -eq $Id) { $index = $i; break } }
  if ($index -ge 0) { $profiles[$index] = $profile } else { $profiles += $profile }
  $Registry.profiles = $profiles
  $Registry.selected_id = $Id
  return $profile
}
