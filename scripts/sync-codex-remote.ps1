# Codex remote session synchronizer. The remote host only needs SSH/SCP access.
$UsageHome = Join-Path $env:USERPROFILE ".usage-viewer"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RepoRoot "config\remote.env"
$RemoteUser = "jerry"
$RemoteHost = "192.168.2.57"
$PollSeconds = 10
$SshKeyPath = ""
$SshPort = 22
$RemoteSessionsPath = "~/.codex/sessions"

$RemoteSourcesFile = Join-Path $UsageHome "remote-sources.json"

if (Test-Path -LiteralPath $EnvFile) {
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim().Trim('"').Trim("'")
        switch ($name) {
            'REMOTE_USER' { $RemoteUser = $value }
            'REMOTE_HOST' { $RemoteHost = $value }
            'POLL_SECONDS' { $PollSeconds = [int]$value }
            'SSH_KEY_PATH' { $SshKeyPath = $value }
            'SSH_PORT' { $SshPort = [int]$value }
            'REMOTE_SESSIONS_PATH' { $RemoteSessionsPath = $value }
        }
    }
}

$RemoteCacheParent = Join-Path $UsageHome "remote-codex"
$sources = @()
if (Test-Path -LiteralPath $RemoteSourcesFile) {
    try {
        $configured = Get-Content -LiteralPath $RemoteSourcesFile -Raw | ConvertFrom-Json
        if ($configured.sources) { $sources = @($configured.sources) }
    } catch { Write-Warning "Cannot read ${RemoteSourcesFile}: $($_.Exception.Message)" }
}
if ($sources.Count -eq 0) {
    $sources = @([pscustomobject]@{ name = "SSH 1"; user = $RemoteUser; host = $RemoteHost; port = $SshPort; key_path = $SshKeyPath; sessions_path = $RemoteSessionsPath })
}
New-Item -ItemType Directory -Force -Path $RemoteCacheParent | Out-Null
Write-Host "Syncing $($sources.Count) Codex SSH source(s). Press Ctrl+C to stop."
while ($true) {
    if (Test-Path -LiteralPath $RemoteSourcesFile) {
        try {
            $configured = Get-Content -LiteralPath $RemoteSourcesFile -Raw | ConvertFrom-Json
            if ($configured.sources) { $sources = @($configured.sources) }
        } catch { }
    }
    for ($index = 0; $index -lt $sources.Count; $index++) {
        $source = $sources[$index]
        $user = if ($source.user) { [string]$source.user } else { $RemoteUser }
        $hostName = if ($source.host) { [string]$source.host } else { $RemoteHost }
        $port = if ($source.port) { [int]$source.port } else { $SshPort }
        $key = if ($source.key_path) { [string]$source.key_path } else { $SshKeyPath }
        $sessions = if ($source.sessions_path) { [string]$source.sessions_path } else { $RemoteSessionsPath }
        $target = "$user@$hostName"
        $cache = Join-Path $RemoteCacheParent $index
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $sshArguments = @()
        if ($key.Trim()) { $sshArguments += @("-i", $key) }
        if ($port -ne 22) { $sshArguments += @("-P", "$port") }
        try {
            & scp @sshArguments -r "${target}:$sessions" (Join-Path $cache "sessions") | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Remote source $($index + 1) updated: $target"
        } catch { Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Remote source $($index + 1) failed ($target): $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds $PollSeconds
}
