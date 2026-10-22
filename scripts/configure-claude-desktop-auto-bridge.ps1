param([switch]$Disable)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claude-desktop-profiles.ps1')
$usageHome = if ([string]::IsNullOrWhiteSpace($env:USAGE_VIEWER_HOME)) {
  Join-Path $env:USERPROFILE '.usage-viewer'
} else {
  $env:USAGE_VIEWER_HOME
}
$ownershipMarker = Join-Path $usageHome 'claude-devtools-env-owned'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class UsageViewerEnvironmentBroadcast
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    public static void Send()
    {
        IntPtr result;
        SendMessageTimeout(new IntPtr(0xffff), 0x001A, IntPtr.Zero, "Environment", 0x0002, 5000, out result);
    }
}
'@

if ($Disable) {
  if (Test-Path -LiteralPath $ownershipMarker) {
    $current = [Environment]::GetEnvironmentVariable('CLAUDE_DEV_TOOLS', 'User')
    if ($current -eq 'undocked') {
      [Environment]::SetEnvironmentVariable('CLAUDE_DEV_TOOLS', $null, 'User')
      [UsageViewerEnvironmentBroadcast]::Send()
    }
    Remove-Item -LiteralPath $ownershipMarker -Force
  }
  Write-Output 'Claude Desktop automatic usage injection has been disabled. Restart Claude Desktop to apply the change.'
  exit 0
}

$developerModeEnabled = $false
$settingsFiles = @((Join-Path $env:APPDATA 'Claude\developer_settings.json'))
$packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path -LiteralPath $packagesRoot) {
  $settingsFiles += @(Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter 'Claude_*' |
    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\developer_settings.json' })
}
$settingsFiles += @(Get-ClaudeDesktopProfiles | ForEach-Object { Join-Path (Split-Path -Parent $_.path) 'developer_settings.json' })
foreach ($settingsFile in $settingsFiles) {
  try {
    if ((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).allowDevTools -eq $true) {
      $developerModeEnabled = $true
      break
    }
  } catch {}
}
if (-not $developerModeEnabled) {
  throw 'Enable Claude Desktop Developer Mode before configuring automatic usage injection.'
}

$currentValue = [Environment]::GetEnvironmentVariable('CLAUDE_DEV_TOOLS', 'User')
if ([string]::IsNullOrWhiteSpace($currentValue)) {
  [Environment]::SetEnvironmentVariable('CLAUDE_DEV_TOOLS', 'undocked', 'User')
  New-Item -ItemType Directory -Path $usageHome -Force | Out-Null
  Set-Content -LiteralPath $ownershipMarker -Value 'undocked' -Encoding ASCII
  [UsageViewerEnvironmentBroadcast]::Send()
  Write-Output 'Configured CLAUDE_DEV_TOOLS=undocked for the current user.'
} else {
  Write-Output "CLAUDE_DEV_TOOLS is already set to '$currentValue'; it was left unchanged."
}
Write-Output 'Restart Claude Desktop once. Usage Viewer will then inject the local usage bridge automatically.'
