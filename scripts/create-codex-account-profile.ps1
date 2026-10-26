# Shared profile picker used by both Usage Viewer Settings implementations.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$usageHome = if ($env:USAGE_VIEWER_HOME) { $env:USAGE_VIEWER_HOME } else { Join-Path $env:USERPROFILE '.usage-viewer' }
$savedPath = Join-Path $usageHome 'codex-account-profile-ui.json'
$lastRoot = Join-Path $env:LOCALAPPDATA 'UsageViewer\CodexProfiles\account-1'
try {
  $saved = Get-Content -LiteralPath $savedPath -Raw | ConvertFrom-Json
  if ($saved.profile_root) { $lastRoot = [string]$saved.profile_root }
} catch { }

function Select-ProfilePort([string]$Root) {
  try {
    $state = Get-Content -LiteralPath (Join-Path $Root 'runtime\state.json') -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$state.profile_root) -ieq $Root -and
        [int]$state.port -ge 1024 -and [int]$state.port -le 65535) { return [int]$state.port }
  } catch { }
  $occupied = @(netstat.exe -ano -p tcp | Select-String '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+\d+\s*$' |
    ForEach-Object { [int]$_.Matches[0].Groups[1].Value })
  foreach ($candidate in 19336..19435) { if ($occupied -notcontains $candidate) { return $candidate } }
  throw 'No free Codex profile port is available. Close an unused Codex profile and retry.'
}

$dialog = New-Object System.Windows.Forms.Form
$dialog.Text = '建立／開啟 Codex 視窗'
$dialog.ClientSize = New-Object System.Drawing.Size(590, 290)
$dialog.StartPosition = 'CenterScreen'
$dialog.FormBorderStyle = 'FixedDialog'
$dialog.MaximizeBox = $false
$dialog.MinimizeBox = $false
$dialog.TopMost = $true
$dialog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
$dialog.ForeColor = [System.Drawing.Color]::White
$dialog.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 10)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Codex 視窗資料夾'
$title.SetBounds(20, 18, 550, 25)
$dialog.Controls.Add($title)
$folder = New-Object System.Windows.Forms.TextBox
$folder.Text = $lastRoot
$folder.SetBounds(20, 51, 450, 28)
$dialog.Controls.Add($folder)
$browse = New-Object System.Windows.Forms.Button
$browse.Text = '瀏覽…'
$browse.SetBounds(480, 49, 90, 30)
$dialog.Controls.Add($browse)
$browse.Add_Click({
  $picker = New-Object System.Windows.Forms.FolderBrowserDialog
  $picker.Description = '選擇這個 Codex 視窗專用的資料夾；可建立新資料夾。'
  $picker.ShowNewFolderButton = $true
  if (Test-Path -LiteralPath $folder.Text -PathType Container) { $picker.SelectedPath = $folder.Text }
  try { if ($picker.ShowDialog($dialog) -eq 'OK') { $folder.Text = $picker.SelectedPath } } finally { $picker.Dispose() }
})
$description = New-Object System.Windows.Forms.Label
$description.Text = '新資料夾會開啟登入畫面。登入後自動啟用全寬、快取時間與成本估算；尚無此視窗的用量紀錄時顯示未知。'
$description.SetBounds(20, 94, 550, 48)
$description.ForeColor = [System.Drawing.Color]::LightGray
$dialog.Controls.Add($description)
$status = New-Object System.Windows.Forms.TextBox
$status.Multiline = $true
$status.ReadOnly = $true
$status.BorderStyle = 'None'
$status.ScrollBars = 'Vertical'
$status.BackColor = $dialog.BackColor
$status.ForeColor = [System.Drawing.Color]::LightGray
$status.TabStop = $false
$status.SetBounds(20, 151, 550, 70)
$dialog.Controls.Add($status)
$open = New-Object System.Windows.Forms.Button
$open.Text = '建立／開啟'
$open.SetBounds(350, 241, 120, 32)
$dialog.Controls.Add($open)
$close = New-Object System.Windows.Forms.Button
$close.Text = '關閉'
$close.SetBounds(480, 241, 90, 32)
$close.Add_Click({ $dialog.Close() })
$dialog.Controls.Add($close)
$dialog.AcceptButton = $open
$script:launchProcess = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$open.Add_Click({
  try {
    $value = $folder.Text.Trim()
    if (!$value -or ![IO.Path]::IsPathRooted($value) -or $value.Contains('"')) { throw '請指定有效的完整資料夾路徑。' }
    $script:selectedRoot = [IO.Path]::GetFullPath($value)
    $port = Select-ProfilePort $script:selectedRoot
    $launcher = Join-Path $PSScriptRoot 'start-codex-account-profile.ps1'
    if (!(Test-Path -LiteralPath $launcher)) { throw '找不到 Codex 啟動程式，請更新 Usage Viewer。' }
    $logRoot = Join-Path $usageHome 'profile-launch-logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $attempt = [Guid]::NewGuid().ToString('N')
    $script:stdout = Join-Path $logRoot "$attempt.stdout.log"
    $script:stderr = Join-Path $logRoot "$attempt.stderr.log"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`" -ProfileRoot `"$script:selectedRoot`" -Port $port"
    $script:launchProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $script:stdout -RedirectStandardError $script:stderr
    $open.Enabled = $browse.Enabled = $folder.Enabled = $close.Enabled = $false
    $status.Text = '正在開啟 Codex，首次啟動可能需要一段時間…'
    $timer.Start()
  } catch { $status.Text = $_.Exception.Message }
})
$timer.Add_Tick({
  if (!$script:launchProcess -or !$script:launchProcess.HasExited) { return }
  $timer.Stop()
  try {
    $script:launchProcess.WaitForExit()
    if ($script:launchProcess.ExitCode -eq 0) {
      @{ profile_root = $script:selectedRoot } | ConvertTo-Json | Set-Content -LiteralPath $savedPath -Encoding UTF8
      $status.Text = "已開啟 Codex。請在新視窗中選擇帳戶或登入。`r`n資料夾：$script:selectedRoot"
    } else {
      $detail = (Get-Content -LiteralPath $script:stderr -Tail 8 -ErrorAction SilentlyContinue) -join "`r`n"
      $status.Text = "啟動失敗：$detail`r`n紀錄：$script:stderr"
    }
  } catch { $status.Text = $_.Exception.Message }
  finally {
    $script:launchProcess.Dispose()
    $script:launchProcess = $null
    $open.Enabled = $browse.Enabled = $folder.Enabled = $close.Enabled = $true
  }
})
$dialog.Add_FormClosing({ param($sender, $eventArgs) if ($script:launchProcess -and !$script:launchProcess.HasExited) { $eventArgs.Cancel = $true } })
try { [void]$dialog.ShowDialog() } finally { $timer.Dispose(); $dialog.Dispose() }
