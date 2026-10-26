# Shared profile picker used by both Usage Viewer Settings implementations.
param([string]$OpenProfileId = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex-account-registry.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$usageHome = if ($env:USAGE_VIEWER_HOME) { $env:USAGE_VIEWER_HOME } else { Join-Path $env:USERPROFILE '.usage-viewer' }
$savedPath = Join-Path $usageHome 'codex-account-profile-ui.json'
$registry = Read-CodexAccountRegistry $savedPath (Join-Path $env:LOCALAPPDATA 'UsageViewer\CodexProfiles')
if ($OpenProfileId) {
  if ($OpenProfileId -notin @($registry.profiles | ForEach-Object { $_.id })) { throw 'Registered Codex account not found.' }
  $registry.selected_id = $OpenProfileId
}
Save-CodexAccountRegistry $savedPath $registry

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
$dialog.Text = 'Codex 帳號設定'
$dialog.ClientSize = New-Object System.Drawing.Size(590, 415)
$dialog.StartPosition = 'CenterScreen'
$dialog.FormBorderStyle = 'FixedDialog'
$dialog.MaximizeBox = $false
$dialog.MinimizeBox = $false
$dialog.TopMost = $true
$dialog.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
$dialog.ForeColor = [System.Drawing.Color]::White
$dialog.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 10)
$title = New-Object System.Windows.Forms.Label
$title.Text = '已註冊的 Codex 帳號'
$title.SetBounds(20, 18, 550, 25)
$dialog.Controls.Add($title)
$accounts = New-Object System.Windows.Forms.ComboBox
$accounts.DropDownStyle = 'DropDownList'
$accounts.DisplayMember = 'name'
$accounts.SetBounds(20, 49, 330, 30)
$dialog.Controls.Add($accounts)
$add = New-Object System.Windows.Forms.Button
$add.Text = '新增帳號'
$add.SetBounds(360, 48, 100, 30)
$dialog.Controls.Add($add)
$name = New-Object System.Windows.Forms.TextBox
$name.SetBounds(20, 94, 450, 28)
$dialog.Controls.Add($name)
$register = New-Object System.Windows.Forms.Button
$register.Text = '儲存註冊'
$register.SetBounds(480, 92, 90, 30)
$dialog.Controls.Add($register)
$folder = New-Object System.Windows.Forms.TextBox
$folder.SetBounds(20, 137, 450, 28)
$dialog.Controls.Add($folder)
$browse = New-Object System.Windows.Forms.Button
$browse.Text = '瀏覽…'
$browse.SetBounds(480, 135, 90, 30)
$dialog.Controls.Add($browse)
$browse.Add_Click({
  $picker = New-Object System.Windows.Forms.FolderBrowserDialog
  $picker.Description = '選擇這個 Codex 視窗專用的資料夾；可建立新資料夾。'
  $picker.ShowNewFolderButton = $true
  if (Test-Path -LiteralPath $folder.Text -PathType Container) { $picker.SelectedPath = $folder.Text }
  try { if ($picker.ShowDialog($dialog) -eq 'OK') { $folder.Text = $picker.SelectedPath } } finally { $picker.Dispose() }
})
$description = New-Object System.Windows.Forms.Label
$description.Text = '上方為帳號名稱，下方為專用資料夾。註冊後直接按「開啟」，不必重選資料夾。登入後自動啟用全寬、快取時間與成本估算。'
$description.SetBounds(20, 183, 550, 48)
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
$status.SetBounds(20, 241, 550, 94)
$dialog.Controls.Add($status)
$open = New-Object System.Windows.Forms.Button
$open.Text = '開啟'
$open.SetBounds(350, 366, 120, 32)
$dialog.Controls.Add($open)
$close = New-Object System.Windows.Forms.Button
$close.Text = '關閉'
$close.SetBounds(480, 366, 90, 32)
$close.Add_Click({ $dialog.Close() })
$dialog.Controls.Add($close)
$dialog.AcceptButton = $open
$script:launchProcess = $null
$script:editingId = ''
function Refresh-Accounts {
  $accounts.Items.Clear()
  foreach ($profile in $registry.profiles) { [void]$accounts.Items.Add($profile) }
  foreach ($profile in $accounts.Items) { if ($profile.id -eq $registry.selected_id) { $accounts.SelectedItem = $profile; break } }
}
$accounts.Add_SelectedIndexChanged({
  if ($accounts.SelectedItem) {
    $script:editingId = $accounts.SelectedItem.id
    $name.Text = $accounts.SelectedItem.name
    $folder.Text = $accounts.SelectedItem.profile_root
    $editable = $script:editingId -ne 'default'
    $name.Enabled = $folder.Enabled = $browse.Enabled = $register.Enabled = $editable
    if (!$editable) { $status.Text = '目前是原本的 Codex 帳號。要註冊另一個帳號，請按「新增帳號」。' }
  }
})
$add.Add_Click({
  $accounts.SelectedIndex = -1
  $script:editingId = ''
  $name.Enabled = $folder.Enabled = $browse.Enabled = $register.Enabled = $true
  $name.Text = "Codex $($registry.profiles.Count)"
  $folder.Text = Join-Path (Join-Path $env:LOCALAPPDATA 'UsageViewer\CodexProfiles') ([Guid]::NewGuid().ToString('N'))
  $status.Text = '填入名稱與資料夾後，按「儲存註冊」。'
  $name.Focus()
})
$register.Add_Click({
  try {
    [void](Register-CodexAccount $registry $name.Text $folder.Text $script:editingId)
    Save-CodexAccountRegistry $savedPath $registry
    Refresh-Accounts
    $status.Text = '已儲存註冊。下次可直接選擇此帳號並按「開啟」。'
  } catch { $status.Text = $_.Exception.Message }
})
Refresh-Accounts
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$open.Add_Click({
  try {
    $selected = $accounts.SelectedItem
    if (!$selected -or $name.Text -ne $selected.name -or $folder.Text -ne $selected.profile_root) { throw '請先儲存註冊，再開啟帳號。' }
    $registry.selected_id = $selected.id
    Save-CodexAccountRegistry $savedPath $registry
    $script:selectedRoot = $selected.profile_root
    $original = $selected.id -eq 'default'
    $launcher = Join-Path $PSScriptRoot $(if ($original) { 'start-codex-native-meter.ps1' } else { 'start-codex-account-profile.ps1' })
    if (!(Test-Path -LiteralPath $launcher)) { throw '找不到 Codex 啟動程式，請更新 Usage Viewer。' }
    $logRoot = Join-Path $usageHome 'profile-launch-logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $attempt = [Guid]::NewGuid().ToString('N')
    $script:stdout = Join-Path $logRoot "$attempt.stdout.log"
    $script:stderr = Join-Path $logRoot "$attempt.stderr.log"
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
    if ($original) { $arguments += ' -SkipReader -AutoPort' }
    else { $port = Select-ProfilePort $script:selectedRoot; $arguments += " -ProfileRoot `"$script:selectedRoot`" -Port $port" }
    $script:launchProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $script:stdout -RedirectStandardError $script:stderr
    $open.Enabled = $browse.Enabled = $folder.Enabled = $close.Enabled = $false
    $accounts.Enabled = $name.Enabled = $register.Enabled = $add.Enabled = $false
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
      $status.Text = if ($script:selectedRoot) { "已開啟 Codex。請在新視窗中選擇帳戶或登入。`r`n資料夾：$script:selectedRoot" } else { '已開啟原本的 Codex 帳號。' }
    } else {
      $detail = (Get-Content -LiteralPath $script:stderr -Tail 8 -ErrorAction SilentlyContinue) -join "`r`n"
      $status.Text = "啟動失敗：$detail`r`n紀錄：$script:stderr"
    }
  } catch { $status.Text = $_.Exception.Message }
  finally {
    $script:launchProcess.Dispose()
    $script:launchProcess = $null
    $open.Enabled = $browse.Enabled = $folder.Enabled = $close.Enabled = $true
    $accounts.Enabled = $name.Enabled = $register.Enabled = $add.Enabled = $true
    if ($accounts.SelectedItem.id -eq 'default') { $name.Enabled = $folder.Enabled = $browse.Enabled = $register.Enabled = $false }
  }
})
$dialog.Add_FormClosing({ param($sender, $eventArgs) if ($script:launchProcess -and !$script:launchProcess.HasExited) { $eventArgs.Cancel = $true } })
if ($OpenProfileId) { $dialog.Add_Shown({ $open.PerformClick() }) }
try { [void]$dialog.ShowDialog() } finally { $timer.Dispose(); $dialog.Dispose() }
