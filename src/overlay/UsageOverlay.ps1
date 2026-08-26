param(
  [string]$UsageFile = "",
  [int]$RefreshMs = 1000,
  [ValidateSet("combined", "separate")][string]$DisplayMode = "combined"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$createdNew = $false
$overlayMutex = New-Object System.Threading.Mutex($true, "UsageViewer.PowerShellOverlay.v2", [ref]$createdNew)
if (-not $createdNew) {
  $overlayMutex.Dispose()
  exit 0
}

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class ResizableOverlayForm : Form
{
  public static bool ClickThrough { get; set; }
  public static Rectangle UnlockButtonBounds { get; set; }
  private const int WM_NCHITTEST = 0x84;
  private const int HTCLIENT = 1;
  private const int HTLEFT = 10;
  private const int HTRIGHT = 11;
  private const int HTTOP = 12;
  private const int HTTOPLEFT = 13;
  private const int HTTOPRIGHT = 14;
  private const int HTBOTTOM = 15;
  private const int HTBOTTOMLEFT = 16;
  private const int HTBOTTOMRIGHT = 17;
  private const int GripSize = 8;

  protected override void WndProc(ref Message message)
  {
    if (ClickThrough && message.Msg == WM_NCHITTEST)
    {
      if (!UnlockButtonBounds.Contains(Cursor.Position))
      {
        message.Result = (IntPtr)(-1);
        return;
      }
    }
    base.WndProc(ref message);

    if (message.Msg != WM_NCHITTEST || (int)message.Result != HTCLIENT)
    {
      return;
    }

    Point cursor = PointToClient(Cursor.Position);
    bool left = cursor.X <= GripSize;
    bool right = cursor.X >= ClientSize.Width - GripSize;
    bool top = cursor.Y <= GripSize;
    bool bottom = cursor.Y >= ClientSize.Height - GripSize;

    if (left && top) message.Result = (IntPtr)HTTOPLEFT;
    else if (right && top) message.Result = (IntPtr)HTTOPRIGHT;
    else if (left && bottom) message.Result = (IntPtr)HTBOTTOMLEFT;
    else if (right && bottom) message.Result = (IntPtr)HTBOTTOMRIGHT;
    else if (left) message.Result = (IntPtr)HTLEFT;
    else if (right) message.Result = (IntPtr)HTRIGHT;
    else if (top) message.Result = (IntPtr)HTTOP;
    else if (bottom) message.Result = (IntPtr)HTBOTTOM;
  }
}

public static class OverlayWindowInterop
{
  public const int WM_NCLBUTTONDOWN = 0xA1;
  [System.Runtime.InteropServices.DllImport("user32.dll")]
  public static extern short GetAsyncKeyState(int key);

  [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
  public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

  [System.Runtime.InteropServices.DllImport("user32.dll")]
  public static extern bool ReleaseCapture();

  [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
  public static extern bool SetWindowPos(
    IntPtr hWnd,
    IntPtr hWndInsertAfter,
    int x,
    int y,
    int cx,
    int cy,
    uint flags
  );

  [System.Runtime.InteropServices.DllImport("user32.dll")]
  public static extern IntPtr SendMessage(
    IntPtr hWnd,
    int msg,
    int wParam,
    int lParam
  );
}
"@

$HWND_TOPMOST = [IntPtr](-1)
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002

$usageHome = $env:USAGE_VIEWER_HOME
if ([string]::IsNullOrWhiteSpace($usageHome)) {
  $usageHome = Join-Path $env:USERPROFILE ".usage-viewer"
}

$combinedMode = [string]::IsNullOrWhiteSpace($UsageFile)
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowIconPath = Join-Path $scriptDirectory "..\..\assets\usage-viewer.ico"
$claudeUsageFile = Join-Path $usageHome "claude-app-latest.json"
$claudeDesktopUsageFile = Join-Path $usageHome "claude-desktop-latest.json"
$claudeCliUsageFile = Join-Path $usageHome "claude-statusline-latest.json"
$codexUsageFile = Join-Path $usageHome "codex-app-latest.json"
$codexDesktopUsageFile = Join-Path $usageHome "codex-desktop-latest.json"
$codexCliUsageFile = Join-Path $usageHome "codex-cli-latest.json"
$codexRemoteUsageFile = Join-Path $usageHome "codex-remote-latest.json"
$displaySettingsFile = Join-Path $usageHome "display-settings.json"
$script:ShowClaudeDesktop = $true
$script:ShowClaudeCli = $true
$script:MergeClaude = $true
$script:ShowCodexDesktop = $true
$script:ShowCodexCli = $true
$script:ShowSsh = $true
$script:MergeCodex = $false
$script:ClaudeDesktopGroup = "Group 1"
$script:ClaudeCliGroup = "Group 1"
$script:CodexDesktopGroup = "Group 1"
$script:CodexCliGroup = "Group 1"
$script:CodexSshGroup = "Group 2"
$script:ClaudeUserEnvironment = "default"
if (Test-Path -LiteralPath $displaySettingsFile) {
  try {
    $savedSettings = Get-Content -LiteralPath $displaySettingsFile -Raw | ConvertFrom-Json
    if ($null -ne $savedSettings.show_claude_desktop) { $script:ShowClaudeDesktop = [bool]$savedSettings.show_claude_desktop }
    if ($null -ne $savedSettings.show_claude_cli) { $script:ShowClaudeCli = [bool]$savedSettings.show_claude_cli }
    if ($null -ne $savedSettings.merge_claude) { $script:MergeClaude = [bool]$savedSettings.merge_claude }
    if ($null -ne $savedSettings.show_codex_desktop) { $script:ShowCodexDesktop = [bool]$savedSettings.show_codex_desktop }
    if ($null -ne $savedSettings.show_codex_cli) { $script:ShowCodexCli = [bool]$savedSettings.show_codex_cli }
    if ($null -ne $savedSettings.show_ssh) { $script:ShowSsh = [bool]$savedSettings.show_ssh }
    if ($null -ne $savedSettings.merge_codex) { $script:MergeCodex = [bool]$savedSettings.merge_codex }
    if ($savedSettings.claude_desktop_group) { $script:ClaudeDesktopGroup = [string]$savedSettings.claude_desktop_group }
    if ($savedSettings.claude_cli_group) { $script:ClaudeCliGroup = [string]$savedSettings.claude_cli_group }
    if ($savedSettings.codex_desktop_group) { $script:CodexDesktopGroup = [string]$savedSettings.codex_desktop_group }
    if ($savedSettings.codex_cli_group) { $script:CodexCliGroup = [string]$savedSettings.codex_cli_group }
    if ($savedSettings.codex_ssh_group) { $script:CodexSshGroup = [string]$savedSettings.codex_ssh_group }
    if ($savedSettings.claude_user_environment -in @("default", "self")) { $script:ClaudeUserEnvironment = [string]$savedSettings.claude_user_environment }
  } catch { }
}
$overlayErrorLog = Join-Path $usageHome "overlay-error.log"
$defaultWindowSize = New-Object System.Drawing.Size(340, 96)

[OverlayWindowInterop]::SetCurrentProcessExplicitAppUserModelID("SlothEatPudding.UsageViewer") | Out-Null

if (-not $combinedMode) {
  $claudeUsageFile = $UsageFile
}

$form = New-Object ResizableOverlayForm
$form.Text = "Usage Viewer"
if (Test-Path -LiteralPath $windowIconPath) {
  try {
    $form.Icon = New-Object System.Drawing.Icon($windowIconPath)
  } catch {
    Write-Verbose "Unable to load window icon: $($_.Exception.Message)"
  }
}
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(24, 48)
$form.Size = $defaultWindowSize
$form.MinimumSize = New-Object System.Drawing.Size(180, 56)
$form.TopMost = $true
$form.ShowIcon = $true
$form.ShowInTaskbar = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(1, 2, 3)
$form.TransparencyKey = $form.BackColor
$form.Opacity = 0.91

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$panel.BackColor = [System.Drawing.Color]::FromArgb(23, 23, 23)
$form.Controls.Add($panel)

$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$resetButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$resetButton.FlatAppearance.BorderSize = 0
$resetButton.BackColor = [System.Drawing.Color]::FromArgb(23, 23, 23)
$resetButton.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
$resetButton.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$resetButton.Location = New-Object System.Drawing.Point(286, 2)
$resetButton.Size = New-Object System.Drawing.Size(20, 20)
$resetButton.Text = "R"
$resetButton.TabStop = $false
$resetButton.Add_Click({
  $form.Size = $defaultWindowSize
  $script:showCost = $false
  $script:heightBeforeCostExpand = $null
  Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
  Resize-OverlayToContent -Form $form -Title $title -Main $main -Detail $detail
})
$panel.Controls.Add($resetButton)

$script:IsPinned = $false
$script:pinHotkeyWasDown = $false
$normalPanelColor = [System.Drawing.Color]::FromArgb(23, 23, 23)

$pinButton = New-Object System.Windows.Forms.Button
$pinButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$pinButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pinButton.FlatAppearance.BorderSize = 0
$pinButton.BackColor = $normalPanelColor
$pinButton.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
$pinButton.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$pinButton.Location = New-Object System.Drawing.Point(212, 2)
$pinButton.Size = New-Object System.Drawing.Size(20, 20)
$pinButton.Text = "P"
$pinButton.TabStop = $false
$panel.Controls.Add($pinButton)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$settingsButton.FlatAppearance.BorderSize = 0
$settingsButton.BackColor = [System.Drawing.Color]::FromArgb(23, 23, 23)
$settingsButton.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
$settingsButton.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$settingsButton.Location = New-Object System.Drawing.Point(234, 2)
$settingsButton.Size = New-Object System.Drawing.Size(50, 20)
$settingsButton.Text = "Settings"
$settingsButton.TabStop = $false
$settingsButton.Add_Click({ Show-DisplaySettings })
$panel.Controls.Add($settingsButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.Color]::FromArgb(23, 23, 23)
$closeButton.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
$closeButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$closeButton.Location = New-Object System.Drawing.Point(308, 2)
$closeButton.Size = New-Object System.Drawing.Size(20, 20)
$closeButton.Text = "X"
$closeButton.TabStop = $false
$closeButton.Add_Click({ $form.Close() })
$panel.Controls.Add($closeButton)

$applyPinState = {
  # Keep P available so the overlay can always be unlocked with a second click.
  # Other controls and window manipulation are disabled while pinned.
  [ResizableOverlayForm]::ClickThrough = $script:IsPinned
  $form.TopMost = $true
  if ($script:IsPinned) {
    [OverlayWindowInterop]::SetWindowPos($form.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOSIZE -bor $SWP_NOMOVE) | Out-Null
  }
  $pinButton.Visible = $true
  $pinButton.Text = if ($script:IsPinned) { "U" } else { "P" }
  $pinButton.BackColor = if ($script:IsPinned) { [System.Drawing.Color]::FromArgb(45, 75, 45) } else { $normalPanelColor }
  $settingsButton.Visible = -not $script:IsPinned
  $resetButton.Visible = -not $script:IsPinned
  $closeButton.Visible = -not $script:IsPinned
  $costToggle.Enabled = -not $script:IsPinned
  # U mode keeps the background click-through while the unlock button remains
  # visibly rendered and retains its complete hit area.
  $panel.BackColor = if ($script:IsPinned) { $form.TransparencyKey } else { $normalPanelColor }
  $form.BackColor = $form.TransparencyKey
  Resize-OverlayToContent -Form $form -Title $title -Main $main -Detail $detail
  $unlockBounds = $pinButton.RectangleToScreen($pinButton.ClientRectangle)
  $unlockBounds.Inflate(2, 2)
  [ResizableOverlayForm]::UnlockButtonBounds = $unlockBounds
}
$pinButton.Add_Click({
  $script:IsPinned = -not $script:IsPinned
  & $applyPinState
})

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.Location = New-Object System.Drawing.Point(0, 0)
$title.Size = New-Object System.Drawing.Size(1, 1)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(235, 241, 247)
$title.Text = ""
$title.Visible = $false
$panel.Controls.Add($title)

$main = New-Object System.Windows.Forms.Label
$main.AutoSize = $false
$main.Location = New-Object System.Drawing.Point(7, 4)
$main.Size = New-Object System.Drawing.Size(246, 34)
$main.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
$main.ForeColor = [System.Drawing.Color]::White
$main.Text = "Waiting for usage..."
$panel.Controls.Add($main)

$detail = New-Object System.Windows.Forms.Label
$detail.AutoSize = $false
$detail.Location = New-Object System.Drawing.Point(7, 39)
$detail.Size = New-Object System.Drawing.Size(246, 25)
$detail.Font = New-Object System.Drawing.Font("Segoe UI", 8.25, [System.Drawing.FontStyle]::Regular)
$detail.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
$detail.Text = $UsageFile
$detail.Visible = $true
$panel.Controls.Add($detail)

$costToggle = New-Object System.Windows.Forms.Label
$costToggle.AutoSize = $false
$costToggle.Location = New-Object System.Drawing.Point(0, 0)
$costToggle.Size = New-Object System.Drawing.Size(1, 1)
$costToggle.Font = New-Object System.Drawing.Font("Cascadia Mono", 9, [System.Drawing.FontStyle]::Regular)
$costToggle.ForeColor = [System.Drawing.Color]::FromArgb(174, 185, 196)
$costToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
$costToggle.Text = "> cost hidden"
$costToggle.Visible = $false
$panel.Controls.Add($costToggle)

$script:showCost = $false
$script:heightBeforeCostExpand = $null

$layoutOverlay = {
  $width = [Math]::Max(80, $panel.ClientSize.Width - 13)
  $main.Width = $width
  $detail.Width = $width
  $pinButton.Left = if ($script:IsPinned) { $panel.ClientSize.Width - 26 } else { $panel.ClientSize.Width - 128 }
  $resetButton.Left = $panel.ClientSize.Width - 44
  $closeButton.Left = $panel.ClientSize.Width - 22
}

$form.Add_Resize($layoutOverlay)

$dragging = $false
$dragStart = New-Object System.Drawing.Point(0, 0)

$mouseDown = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    if ($script:IsPinned) {
      return
    }
    $hitTest = Get-ResizeHitTest -Form $form

    if ($hitTest -ne 0) {
      [OverlayWindowInterop]::ReleaseCapture() | Out-Null
      [OverlayWindowInterop]::SendMessage(
        $form.Handle,
        [OverlayWindowInterop]::WM_NCLBUTTONDOWN,
        $hitTest,
        0
      ) | Out-Null
      return
    }

    $script:dragging = $true
    $script:dragStart = $_.Location
  }
}

$mouseMove = {
  if ($script:dragging) {
    $form.Left += $_.X - $script:dragStart.X
    $form.Top += $_.Y - $script:dragStart.Y
  }
}

$mouseUp = {
  $script:dragging = $false
}

foreach ($control in @($form, $panel, $title, $main, $detail, $costToggle)) {
  $control.Add_MouseDown($mouseDown)
  $control.Add_MouseMove($mouseMove)
  $control.Add_MouseUp($mouseUp)
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Add_Opening({ $_.Cancel = $script:IsPinned })
$closeItem = New-Object System.Windows.Forms.ToolStripMenuItem
$closeItem.Text = "Close"
$closeItem.Add_Click({ $form.Close() })
[void]$menu.Items.Add($closeItem)
$form.ContextMenuStrip = $menu
$panel.ContextMenuStrip = $menu

function Get-ResizeHitTest {
  param([System.Windows.Forms.Form]$Form)

  if ($script:IsPinned) {
    return 0
  }

  $grip = 10
  $cursor = $Form.PointToClient([System.Windows.Forms.Cursor]::Position)
  $left = $cursor.X -le $grip
  $right = $cursor.X -ge ($Form.ClientSize.Width - $grip)
  $top = $cursor.Y -le $grip
  $bottom = $cursor.Y -ge ($Form.ClientSize.Height - $grip)

  if ($left -and $top) {
    return 13
  }

  if ($right -and $top) {
    return 14
  }

  if ($left -and $bottom) {
    return 16
  }

  if ($right -and $bottom) {
    return 17
  }

  if ($left) {
    return 10
  }

  if ($right) {
    return 11
  }

  if ($top) {
    return 12
  }

  if ($bottom) {
    return 15
  }

  return 0
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(250, $RefreshMs)
$form.Add_Shown({
  if ($script:IsPinned) {
    [OverlayWindowInterop]::SetWindowPos($form.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOSIZE -bor $SWP_NOMOVE) | Out-Null
  }
})
$timer.Add_Tick({
  try {
    if ($script:IsPinned -and -not $form.TopMost) {
      $form.TopMost = $true
    }
    if ($script:IsPinned) {
      [OverlayWindowInterop]::SetWindowPos($form.Handle, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOSIZE -bor $SWP_NOMOVE) | Out-Null
    }
    $pinHotkeyDown = (([OverlayWindowInterop]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0) -and
      (([OverlayWindowInterop]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0) -and
      (([OverlayWindowInterop]::GetAsyncKeyState(0x50) -band 0x8000) -ne 0)
    if ($pinHotkeyDown -and -not $script:pinHotkeyWasDown) {
      $script:IsPinned = -not $script:IsPinned
      & $applyPinState
    }
    $script:pinHotkeyWasDown = $pinHotkeyDown
    Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
    Resize-OverlayToContent -Form $form -Title $title -Main $main -Detail $detail
  } catch {
    Write-OverlayError $_
    $title.Text = ""
    $main.Text = "Overlay error"
    $detail.Text = $_.Exception.Message
    $costToggle.Text = ""
  }
})

function Write-OverlayError {
  param($ErrorRecord)

  try {
    $message = @(
      "[$([DateTimeOffset]::Now.ToString("o"))]",
      [string]$ErrorRecord.Exception.GetType().FullName,
      [string]$ErrorRecord.Exception.Message,
      [string]$ErrorRecord.ScriptStackTrace,
      ""
    ) -join [Environment]::NewLine

    Add-Content -LiteralPath $script:overlayErrorLog -Value $message -Encoding UTF8
  } catch {
    # Keep the overlay alive even if logging fails.
  }
}

function Update-UsageView {
  param(
    [bool]$CombinedMode,
    [string]$UsageFile,
    [string]$ClaudeUsageFile,
    [string]$CodexUsageFile,
    [System.Windows.Forms.Label]$Title,
    [System.Windows.Forms.Label]$Main,
    [System.Windows.Forms.Label]$Detail,
    [System.Windows.Forms.Label]$CostToggle
  )

  if ($CombinedMode) {
    Update-CombinedUsageView -ClaudeUsageFile $ClaudeUsageFile -CodexUsageFile $CodexUsageFile -Title $Title -Main $Main -Detail $Detail -CostToggle $CostToggle
    return
  }

  if (-not (Test-Path -LiteralPath $UsageFile)) {
    $Title.Text = ""
    $Main.Text = "Waiting for usage..."
    $Detail.Text = ""
    $CostToggle.Text = ""
    return
  }

  try {
    $json = Get-Content -LiteralPath $UsageFile -Raw | ConvertFrom-Json
    $tokens = $json.tokens
    $pct = $json.percentages
    $cost = $json.cost

    $model = First-Text @($json.model.name, $json.model.id, "unknown")
    $ctx = Format-Percent $pct.context_used 1
    $fiveHour = Format-Percent $pct.five_hour_used 2
    $week = Format-Percent $pct.seven_day_used 2
    $cached = Format-Percent $pct.cached_input 1
    $age = Format-Age (Get-UsageTimestamp $json)
    $reset = Format-ResetSummary $json

    $Title.Text = ""
    $Main.Text = Format-ClaudeUsageLine $json
    $Detail.Text = "Claude  $reset | $age"
    $CostToggle.Text = ""
  } catch {
    $Title.Text = ""
    $Main.Text = "Read error"
    $Detail.Text = ""
    $CostToggle.Text = ""
  }
}

function Update-CombinedUsageView {
  param(
    [string]$ClaudeUsageFile,
    [string]$CodexUsageFile,
    [System.Windows.Forms.Label]$Title,
    [System.Windows.Forms.Label]$Main,
    [System.Windows.Forms.Label]$Detail,
    [System.Windows.Forms.Label]$CostToggle
  )

  $claudeSources = @()
  if ($script:ClaudeDesktopGroup -ne "Hidden") { $claudeSources += @{ Label = "D"; Group = $script:ClaudeDesktopGroup; Data = (Read-UsageJson $claudeDesktopUsageFile) } }
  if ($script:ClaudeCliGroup -ne "Hidden") { $claudeSources += @{ Label = "C"; Group = $script:ClaudeCliGroup; Data = (Read-UsageJson $claudeCliUsageFile) } }
  $claudeSources = @($claudeSources | Where-Object { $null -ne $_.Data })

  $codexSources = @()
  if ($script:CodexDesktopGroup -ne "Hidden") { $codexSources += @{ Label = "D"; Group = $script:CodexDesktopGroup; Data = (Read-UsageJson $codexDesktopUsageFile) } }
  if ($script:CodexCliGroup -ne "Hidden") { $codexSources += @{ Label = "C"; Group = $script:CodexCliGroup; Data = (Read-UsageJson $codexCliUsageFile) } }
  if ($script:CodexSshGroup -ne "Hidden") { $codexSources += @{ Label = "SSH"; Group = $script:CodexSshGroup; Data = (Read-UsageJson $codexRemoteUsageFile) } }
  $codexSources = @($codexSources | Where-Object { $null -ne $_.Data })

  if ($claudeSources.Count -eq 0 -and $codexSources.Count -eq 0) {
    $Title.Text = ""
    $Main.Text = "Waiting for Claude / Codex usage..."
    $Detail.Text = ""
    $CostToggle.Text = ""
    return
  }

  $Title.Text = ""

  $mainLines = @()
  $detailLines = @()

  $claudeGroupNames = @($claudeSources | ForEach-Object { [string]$_.Group } | Sort-Object -Unique)
  foreach ($groupName in $claudeGroupNames) {
    $groupItems = @($claudeSources | Where-Object { [string]$_.Group -eq $groupName })
    $item = $groupItems | Sort-Object { Get-UsageTimestamp $_.Data } -Descending | Select-Object -First 1
    $labels = ($groupItems | ForEach-Object { $_.Label }) -join "+"
    $suffix = "  ($labels)"
    $mainLines += "$(Format-ClaudeUsageLine $item.Data)$suffix"
    $detailLines += "Claude  $(Format-ResetSummary $item.Data) | $(Format-Age (Get-UsageTimestamp $item.Data))$suffix"
  }

  $codexGroupNames = @($codexSources | ForEach-Object { [string]$_.Group } | Sort-Object -Unique)
  foreach ($groupName in $codexGroupNames) {
    $groupItems = @($codexSources | Where-Object { [string]$_.Group -eq $groupName })
    $item = $groupItems | Sort-Object { Get-UsageTimestamp $_.Data } -Descending | Select-Object -First 1
    $labels = ($groupItems | ForEach-Object { $_.Label }) -join "+"
    $suffix = "  ($labels)"
    $mainLines += "$(Format-CodexUsageLine $item.Data)$suffix"
    $detailLines += "Codex   $(Format-ResetSummary $item.Data) | $(Format-Age (Get-UsageTimestamp $item.Data))$suffix"
  }

  $Main.Text = $mainLines -join "`r`n"
  $Detail.Text = $detailLines -join "`r`n"
  try {
    @{
      generated_at = [DateTimeOffset]::Now.ToString("O")
      main_lines = @($mainLines)
      detail_lines = @($detailLines)
      claude_groups = @($claudeSources | ForEach-Object { @{ label = $_.Label; group = $_.Group } })
      codex_groups = @($codexSources | ForEach-Object { @{ label = $_.Label; group = $_.Group } })
      main_text = $Main.Text
      detail_text = $Detail.Text
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $usageHome "display-render-state.json") -Encoding UTF8
  } catch { }
  $CostToggle.Text = ""
}

function Resize-OverlayToContent {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Windows.Forms.Label]$Title,
    [System.Windows.Forms.Label]$Main,
    [System.Windows.Forms.Label]$Detail
  )

  $mainSize = Measure-MultilineTextSize -Text $Main.Text -Font $Main.Font
  $detailSize = Measure-MultilineTextSize -Text $Detail.Text -Font $Detail.Font
  $left = 7
  $top = 4
  $gap = 1
  $right = 6
  $bottom = 7
  $buttonArea = if ($script:IsPinned) { 26 } else { 78 }
  $mainVerticalPadding = 2
  $detailVerticalPadding = 5

  $contentWidth = [Math]::Max($mainSize.Width + $buttonArea, $detailSize.Width)
  $minimumWidth = if ($script:IsPinned) { 180 } else { 340 }
  $desiredWidth = [Math]::Min(900, [Math]::Max($minimumWidth, $left + $contentWidth + $right))
  $mainHeight = $mainSize.Height + $mainVerticalPadding
  $detailHeight = $detailSize.Height + $detailVerticalPadding
  $desiredHeight = [Math]::Max($Form.MinimumSize.Height, $top + $mainHeight + $gap + $detailHeight + $bottom)

  $Form.ClientSize = [System.Drawing.Size]::new([int]$desiredWidth, [int]$desiredHeight)
  $Main.Location = [System.Drawing.Point]::new($left, $top)
  $Main.Size = [System.Drawing.Size]::new($desiredWidth - $left - $right, $mainHeight)
  $Detail.Location = [System.Drawing.Point]::new($left, $top + $mainHeight + $gap)
  $Detail.Size = [System.Drawing.Size]::new($desiredWidth - $left - $right, $detailHeight)
}

function Measure-MultilineTextSize {
  param(
    [string]$Text,
    [System.Drawing.Font]$Font
  )

  if ([string]::IsNullOrEmpty([string]$Text)) {
    return [System.Drawing.Size]::Empty
  }

  $lines = @([string]$Text -split "`r?`n")
  $maxWidth = 0

  foreach ($line in $lines) {
    $maxWidth = [Math]::Max(
      $maxWidth,
      (Measure-TextWidth -Text $line -Font $Font)
    )
  }

  $lineHeight = [System.Windows.Forms.TextRenderer]::MeasureText("Ag", $Font).Height
  return [System.Drawing.Size]::new([int]$maxWidth, [int]($lineHeight * $lines.Count))
}

function Measure-TextWidth {
  param(
    [string]$Text,
    [System.Drawing.Font]$Font
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return 0
  }

  return [System.Windows.Forms.TextRenderer]::MeasureText(
    $Text,
    $Font
  ).Width
}

function Read-UsageJson {
  param([string]$Filename)

  try {
    if (-not (Test-Path -LiteralPath $Filename)) {
      return $null
    }

    return Get-Content -LiteralPath $Filename -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function First-Text {
  param([object[]]$Values)

  foreach ($value in $Values) {
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
      return [string]$value
    }
  }

  return ""
}

function Format-Count {
  param($Value)

  if ($null -eq $Value) {
    return "?"
  }

  return ([double]$Value).ToString("N0")
}

function Format-Percent {
  param($Value, [int]$Digits)

  if ($null -eq $Value) {
    return "?"
  }

  return "$(([double]$Value).ToString("N$Digits"))%"
}

function Format-CompactCount {
  param($Value)

  if ($null -eq $Value) {
    return "?"
  }

  $number = [double]$Value

  if ($number -ge 1000000) {
    return "$(($number / 1000000).ToString("N1"))m"
  }

  if ($number -ge 1000) {
    return "$(($number / 1000).ToString("N1"))k"
  }

  return $number.ToString("N0")
}

function Format-ClaudeUsageLine {
  param($Claude)

  $week = Format-UsagePercent $Claude.percentages.seven_day_used
  $fiveHour = Format-UsagePercent $Claude.percentages.five_hour_used

  return "Claude  7d $week  |  5h $fiveHour"
}

function Read-LatestClaudeUsage {
  param([string]$AppUsageFile)

  $directory = Split-Path -Parent $AppUsageFile
  $candidates = @(
    $AppUsageFile,
    (Join-Path $directory "claude-desktop-latest.json"),
    (Join-Path $directory "claude-statusline-latest.json")
  )
  $latest = $null
  $latestTimestamp = [DateTimeOffset]::MinValue

  foreach ($file in $candidates) {
    $candidate = Read-UsageJson $file
    if ($null -eq $candidate) { continue }

    $timestamp = Get-ClaudeUsageTimestamp $candidate
    if ($null -eq $latest -or $timestamp -gt $latestTimestamp) {
      $latest = $candidate
      $latestTimestamp = $timestamp
    }
  }

  return $latest
}

function Get-ClaudeUsageTimestamp {
  param($Json)

  $values = @()
  if ($Json.plan_usage -and $Json.plan_usage.observed_at) {
    $values += $Json.plan_usage.observed_at
  }
  if ($Json.source -eq "claude-code-statusline" -and $Json.generated_at) {
    $values += $Json.generated_at
  }
  $values += @($Json.observed_at, $Json.generated_at)

  foreach ($value in $values) {
    try {
      if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
        return [DateTimeOffset]::Parse([string]$value)
      }
    } catch { }
  }

  return [DateTimeOffset]::MinValue
}

function Format-CodexUsageLine {
  param($Codex)

  $parts = @()
  $week = Format-UsagePercent $Codex.percentages.seven_day_used
  $fiveHour = Format-UsagePercent $Codex.percentages.five_hour_used
  if ($week -eq "?") { $week = "-" }
  if ($fiveHour -eq "?") { $fiveHour = "-" }
  return "Codex   7d $week  |  5h $fiveHour"
}

function Get-CodexSourceSuffix {
  param($Codex)

  if ($Codex.source_mode -eq "cli") { return "(C)" }
  if ($Codex.source_mode -eq "desktop") { return "(D)" }
  return ""
}

function Get-ClaudeSourceSuffix {
  param($Claude)

  if ($Claude.source_mode -eq "cli") { return "(C)" }
  if ($Claude.source_mode -eq "desktop") { return "(D)" }
  if ($Claude.source -eq "claude-code-statusline") { return "(C)" }
  if ($Claude.source) { return "(D)" }
  return ""
}

function Format-UsagePercent {
  param($Value)

  if ($null -eq $Value) { return "?" }
  return "$(([double]$Value).ToString("0.##", [Globalization.CultureInfo]::InvariantCulture))%"
}

function Format-Usd {
  param($Value)

  if ($null -eq $Value) {
    return "?"
  }

  return ([double]$Value).ToString("N3")
}

function Format-Age {
  param($Iso)

  try {
    $timestamp = [DateTimeOffset]::Parse([string]$Iso)
    $age = [DateTimeOffset]::Now - $timestamp

    if ($age.TotalSeconds -lt 60) {
      return "$([Math]::Max(0, [int]$age.TotalSeconds))s ago"
    }

    if ($age.TotalMinutes -lt 60) {
      return "$([int]$age.TotalMinutes)m ago"
    }

    return "$([int]$age.TotalHours)h ago"
  } catch {
    return ""
  }
}

function Get-UsageTimestamp {
  param($Json)

  if ($Json.observed_at) {
    return $Json.observed_at
  }

  return $Json.generated_at
}

function Get-ResetEpoch {
  param($Json)

  if ($Json.resets_at -and $null -ne $Json.resets_at.seven_day_epoch_seconds) {
    return $Json.resets_at.seven_day_epoch_seconds
  }

  if ($Json.rate_limits -and $Json.rate_limits.primary -and $null -ne $Json.rate_limits.primary.resets_at_epoch_seconds) {
    return $Json.rate_limits.primary.resets_at_epoch_seconds
  }

  return $null
}

function Get-ResetEpochByName {
  param($Json, [string]$Name)

  if ($Json.resets_at) {
    $property = "${Name}_epoch_seconds"

    if ($Json.resets_at.PSObject.Properties.Name -contains $property) {
      $value = $Json.resets_at.$property

      if ($null -ne $value) {
        return $value
      }
    }
  }

  return $null
}

function Format-ResetSummary {
  param($Json)

  $fiveHour = Format-ResetTime (Get-ResetEpochByName $Json "five_hour")
  $week = Format-ResetWeekdayTime (Get-ResetEpochByName $Json "seven_day")
  $parts = @()
  if ($week -ne "?") { $parts += $week }
  if ($fiveHour -ne "?") { $parts += $fiveHour }
  if ($parts.Count -gt 0) { return $parts -join " | " }
  return "?"
}

function Show-DisplaySettings {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "Usage Viewer Settings"
  $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.ShowInTaskbar = $false
  $dialog.TopMost = $true
  $dialog.BackColor = [System.Drawing.Color]::FromArgb(23, 23, 23)
  $dialog.ForeColor = [System.Drawing.Color]::White
  $dialog.Opacity = 0.96
  $dialog.ClientSize = New-Object System.Drawing.Size(350, 365)

  $dialogTitle = New-Object System.Windows.Forms.Label
  $dialogTitle.Text = "Display settings"
  $dialogTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
  $dialogTitle.ForeColor = [System.Drawing.Color]::White
  $dialogTitle.Location = New-Object System.Drawing.Point(12, 8)
  $dialogTitle.AutoSize = $true
  $dialog.Controls.Add($dialogTitle)
  $dragSettings = {
    [OverlayWindowInterop]::ReleaseCapture() | Out-Null
    [OverlayWindowInterop]::SendMessage($dialog.Handle, [OverlayWindowInterop]::WM_NCLBUTTONDOWN, 2, 0) | Out-Null
  }
  $dialogTitle.Add_MouseDown($dragSettings)

  $dialogClose = New-Object System.Windows.Forms.Button
  $dialogClose.Text = "X"
  $dialogClose.Location = New-Object System.Drawing.Point(322, 4)
  $dialogClose.Size = New-Object System.Drawing.Size(22, 22)
  $dialogClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $dialogClose.FlatAppearance.BorderSize = 0
  $dialogClose.BackColor = $dialog.BackColor
  $dialogClose.ForeColor = [System.Drawing.Color]::FromArgb(187, 187, 187)
  $dialogClose.Add_Click({ $dialog.Close() })
  $dialog.Controls.Add($dialogClose)

  $claudeLabel = New-Object System.Windows.Forms.Label
  $claudeLabel.Text = "Claude sources"
  $claudeLabel.Location = New-Object System.Drawing.Point(15, 42)
  $claudeLabel.AutoSize = $true
  $dialog.Controls.Add($claudeLabel)

  $claudeDesktopLabel = New-Object System.Windows.Forms.Label
  $claudeDesktopLabel.Text = "Desktop"
  $claudeDesktopLabel.Location = New-Object System.Drawing.Point(20, 70)
  $claudeDesktopLabel.AutoSize = $true
  $dialog.Controls.Add($claudeDesktopLabel)
  $claudeDesktop = New-Object System.Windows.Forms.ComboBox
  $claudeDesktop.Location = New-Object System.Drawing.Point(20, 67)
  $claudeDesktop.Location = New-Object System.Drawing.Point(170, 64)
  $claudeDesktop.Size = New-Object System.Drawing.Size(150, 24)
  $claudeDesktop.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  [void]$claudeDesktop.Items.AddRange(@("Group 1", "Group 2", "Group 3", "Hidden"))
  $claudeDesktop.SelectedIndex = [Math]::Max(0, $claudeDesktop.Items.IndexOf($script:ClaudeDesktopGroup))
  $dialog.Controls.Add($claudeDesktop)

  $claudeCliLabel = New-Object System.Windows.Forms.Label
  $claudeCliLabel.Text = "CLI"
  $claudeCliLabel.Location = New-Object System.Drawing.Point(20, 98)
  $claudeCliLabel.AutoSize = $true
  $dialog.Controls.Add($claudeCliLabel)
  $claudeCli = New-Object System.Windows.Forms.ComboBox
  $claudeCli.Location = New-Object System.Drawing.Point(170, 92)
  $claudeCli.Size = New-Object System.Drawing.Size(150, 24)
  $claudeCli.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  [void]$claudeCli.Items.AddRange(@("Group 1", "Group 2", "Group 3", "Hidden"))
  $claudeCli.SelectedIndex = [Math]::Max(0, $claudeCli.Items.IndexOf($script:ClaudeCliGroup))
  $dialog.Controls.Add($claudeCli)

  $codexLabel = New-Object System.Windows.Forms.Label
  $codexLabel.Text = "Codex sources"
  $codexLabel.Location = New-Object System.Drawing.Point(15, 132)
  $codexLabel.AutoSize = $true
  $dialog.Controls.Add($codexLabel)

  $codexDesktopLabel = New-Object System.Windows.Forms.Label
  $codexDesktopLabel.Text = "Desktop"
  $codexDesktopLabel.Location = New-Object System.Drawing.Point(20, 160)
  $codexDesktopLabel.AutoSize = $true
  $dialog.Controls.Add($codexDesktopLabel)
  $codexDesktop = New-Object System.Windows.Forms.ComboBox
  $codexDesktop.Location = New-Object System.Drawing.Point(170, 154)
  $codexDesktop.Size = New-Object System.Drawing.Size(150, 24)
  $codexDesktop.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  [void]$codexDesktop.Items.AddRange(@("Group 1", "Group 2", "Group 3", "Hidden"))
  $codexDesktop.SelectedIndex = [Math]::Max(0, $codexDesktop.Items.IndexOf($script:CodexDesktopGroup))
  $dialog.Controls.Add($codexDesktop)

  $codexCliLabel = New-Object System.Windows.Forms.Label
  $codexCliLabel.Text = "CLI"
  $codexCliLabel.Location = New-Object System.Drawing.Point(20, 188)
  $codexCliLabel.AutoSize = $true
  $dialog.Controls.Add($codexCliLabel)
  $codexCli = New-Object System.Windows.Forms.ComboBox
  $codexCli.Location = New-Object System.Drawing.Point(170, 182)
  $codexCli.Size = New-Object System.Drawing.Size(150, 24)
  $codexCli.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  [void]$codexCli.Items.AddRange(@("Group 1", "Group 2", "Group 3", "Hidden"))
  $codexCli.SelectedIndex = [Math]::Max(0, $codexCli.Items.IndexOf($script:CodexCliGroup))
  $dialog.Controls.Add($codexCli)

  $sshLabel = New-Object System.Windows.Forms.Label
  $sshLabel.Text = "Remote (SSH)"
  $sshLabel.Location = New-Object System.Drawing.Point(20, 216)
  $sshLabel.AutoSize = $true
  $dialog.Controls.Add($sshLabel)
  $ssh = New-Object System.Windows.Forms.ComboBox
  $ssh.Location = New-Object System.Drawing.Point(170, 210)
  $ssh.Size = New-Object System.Drawing.Size(150, 24)
  $ssh.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  [void]$ssh.Items.AddRange(@("Group 1", "Group 2", "Group 3", "Hidden"))
  $ssh.SelectedIndex = [Math]::Max(0, $ssh.Items.IndexOf($script:CodexSshGroup))
  $dialog.Controls.Add($ssh)

  $accountLabel = New-Object System.Windows.Forms.Label
  $accountLabel.Text = "Claude user environment"
  $accountLabel.Location = New-Object System.Drawing.Point(15, 248)
  $accountLabel.AutoSize = $true
  $dialog.Controls.Add($accountLabel)

  $defaultAccount = New-Object System.Windows.Forms.Button
  $defaultAccount.Text = "Open Default"
  $defaultAccount.Location = New-Object System.Drawing.Point(20, 275)
  $defaultAccount.Size = New-Object System.Drawing.Size(145, 28)
  $defaultAccount.Add_Click({ Start-ClaudeUserEnvironment -EnvironmentName "default" -StatusLabel $accountStatus })
  $dialog.Controls.Add($defaultAccount)

  $selfAccount = New-Object System.Windows.Forms.Button
  $selfAccount.Text = "Open Self"
  $selfAccount.Location = New-Object System.Drawing.Point(175, 275)
  $selfAccount.Size = New-Object System.Drawing.Size(145, 28)
  $selfAccount.Add_Click({ Start-ClaudeUserEnvironment -EnvironmentName "self" -StatusLabel $accountStatus })
  $dialog.Controls.Add($selfAccount)

  $accountStatus = New-Object System.Windows.Forms.Label
  $currentEnvironmentLabel = if ($script:ClaudeUserEnvironment -eq "self") { "Self account" } else { "Default account" }
  $currentEnvironmentFolder = if ($script:ClaudeUserEnvironment -eq "self") { "Claude-Self" } else { "Claude" }
  $accountStatus.Text = "Current: $currentEnvironmentLabel  |  Folder: $currentEnvironmentFolder"
  $accountStatus.Location = New-Object System.Drawing.Point(20, 309)
  $accountStatus.Size = New-Object System.Drawing.Size(305, 20)
  $accountStatus.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
  $dialog.Controls.Add($accountStatus)

  $save = New-Object System.Windows.Forms.Button
  $save.Text = "Save"
  $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $save.Location = New-Object System.Drawing.Point(255, 334)
  $save.Size = New-Object System.Drawing.Size(75, 25)
  $dialog.AcceptButton = $save
  $dialog.Controls.Add($save)

  foreach ($control in $dialog.Controls) {
    if ($control -is [System.Windows.Forms.CheckBox] -or $control -is [System.Windows.Forms.Label] -or $control -is [System.Windows.Forms.ComboBox]) {
      $control.BackColor = $dialog.BackColor
      $control.ForeColor = if ($control -eq $claudeLabel -or $control -eq $codexLabel -or $control -eq $dialogTitle) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(210, 210, 210) }
    }
  }
  $save.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $save.FlatAppearance.BorderSize = 0
  $save.BackColor = [System.Drawing.Color]::FromArgb(45, 75, 105)
  $save.ForeColor = [System.Drawing.Color]::White
  foreach ($button in @($defaultAccount, $selfAccount)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $button.ForeColor = [System.Drawing.Color]::White
  }

  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $script:ClaudeDesktopGroup = [string]$claudeDesktop.SelectedItem
    $script:ClaudeCliGroup = [string]$claudeCli.SelectedItem
    $script:CodexDesktopGroup = [string]$codexDesktop.SelectedItem
    $script:CodexCliGroup = [string]$codexCli.SelectedItem
    $script:CodexSshGroup = [string]$ssh.SelectedItem
    New-Item -ItemType Directory -Force -Path $usageHome | Out-Null
    @{
      claude_desktop_group = $script:ClaudeDesktopGroup
      claude_cli_group = $script:ClaudeCliGroup
      codex_desktop_group = $script:CodexDesktopGroup
      codex_cli_group = $script:CodexCliGroup
      codex_ssh_group = $script:CodexSshGroup
      claude_user_environment = $script:ClaudeUserEnvironment
    } |
      ConvertTo-Json | Set-Content -LiteralPath $displaySettingsFile -Encoding UTF8
    Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
    Resize-OverlayToContent -Form $form -Title $title -Main $main -Detail $detail
  }
  $dialog.Dispose()
}

function Get-ClaudeDesktopExecutable {
  try {
    $package = Get-AppxPackage -Name "Claude" -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $package) {
      $candidate = Join-Path $package.InstallLocation "app\Claude.exe"
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  } catch { }

  foreach ($candidate in @(
    (Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Claude\Claude.exe"),
    (Join-Path $env:LOCALAPPDATA "Claude\Claude.exe")
  )) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $null
}

function Start-ClaudeUserEnvironment {
  param(
    [ValidateSet("default", "self")][string]$EnvironmentName,
    [System.Windows.Forms.Label]$StatusLabel
  )

  try {
    $script:ClaudeUserEnvironment = $EnvironmentName
    $environmentLabel = if ($EnvironmentName -eq "default") { "Default" } else { "Self" }
    if ($EnvironmentName -eq "default") {
      $app = Get-StartApps | Where-Object { $_.Name -eq "Claude" } | Select-Object -First 1
      if ($null -eq $app) { throw "Claude Start Menu app was not found." }
      Start-Process -FilePath "explorer.exe" -ArgumentList "shell:AppsFolder\$($app.AppID)"
      $StatusLabel.Text = "Current: $environmentLabel — opened Claude Default."
      return
    }

    $executable = Get-ClaudeDesktopExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { throw "Claude.exe was not found." }
    $profileDirectory = Join-Path $env:LOCALAPPDATA "Claude-Self"
    New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
    Start-Process -FilePath $executable -ArgumentList "--user-data-dir=`"$profileDirectory`""
    $StatusLabel.Text = "Current: $environmentLabel — opened Claude Self. Sign in once to save this session."
  } catch {
    $StatusLabel.Text = "Unable to open Claude: $($_.Exception.Message)"
  }
}

function Format-ResetTime {
  param($EpochSeconds)

  if ($null -eq $EpochSeconds) {
    return "?"
  }

  try {
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).ToLocalTime().ToString("HH:mm", [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return "?"
  }
}

function Format-ResetWeekdayTime {
  param($EpochSeconds)

  if ($null -eq $EpochSeconds) {
    return "?"
  }

  try {
    $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).ToLocalTime()
    return $local.ToString("ddd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return "?"
  }
}

function Format-ResetRelative {
  param($EpochSeconds)

  if ($null -eq $EpochSeconds) {
    return "?"
  }

  try {
    $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).ToLocalTime()
    $remaining = $reset - [DateTimeOffset]::Now

    if ($remaining.TotalSeconds -le 0) {
      return "now"
    }

    if ($remaining.TotalHours -ge 1) {
      return "$([int]$remaining.TotalHours)h $($remaining.Minutes)m"
    }

    return "$([Math]::Max(0, [int]$remaining.TotalMinutes))m"
  } catch {
    return "?"
  }
}

function Format-Reset {
  param($EpochSeconds)

  if ($null -eq $EpochSeconds) {
    return "?"
  }

  try {
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).ToLocalTime().ToString("M/d HH:mm")
  } catch {
    return "?"
  }
}

try {
  Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
  Resize-OverlayToContent -Form $form -Title $title -Main $main -Detail $detail
} catch {
  Write-OverlayError $_
  $main.Text = "Overlay error"
  $detail.Text = $_.Exception.Message
}
$timer.Start()
try {
  [void][System.Windows.Forms.Application]::Run($form)
} finally {
  $timer.Stop()
  $overlayMutex.ReleaseMutex()
  $overlayMutex.Dispose()
}
