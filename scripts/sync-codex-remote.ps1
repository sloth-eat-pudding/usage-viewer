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
$Target = "$RemoteUser@$RemoteHost"
New-Item -ItemType Directory -Force -Path $RemoteCacheParent | Out-Null
$sshArguments = @()
if ($SshKeyPath.Trim()) { $sshArguments += @("-i", $SshKeyPath) }
if ($SshPort -ne 22) { $sshArguments += @("-P", "$SshPort") }
Write-Host "Syncing Codex sessions from $Target. Press Ctrl+C to stop."
while ($true) {
    try {
        & scp @sshArguments -r "${Target}:$RemoteSessionsPath" $RemoteCacheParent | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Remote sessions updated"
    } catch { Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] $($_.Exception.Message)" }
    Start-Sleep -Seconds $PollSeconds
}
