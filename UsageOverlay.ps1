param(
  [string]$UsageFile = "",
  [int]$RefreshMs = 1000
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class ResizableOverlayForm : Form
{
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
  public static extern bool ReleaseCapture();

  [System.Runtime.InteropServices.DllImport("user32.dll")]
  public static extern IntPtr SendMessage(
    IntPtr hWnd,
    int msg,
    int wParam,
    int lParam
  );
}
"@

$usageHome = $env:USAGE_VIEWER_HOME
if ([string]::IsNullOrWhiteSpace($usageHome)) {
  $usageHome = Join-Path $env:USERPROFILE ".usage-viewer"
}

$combinedMode = [string]::IsNullOrWhiteSpace($UsageFile)
$claudeUsageFile = Join-Path $usageHome "claude-latest.json"
$codexUsageFile = Join-Path $usageHome "codex-latest.json"
$defaultWindowSize = New-Object System.Drawing.Size(560, 188)

if (-not $combinedMode) {
  $claudeUsageFile = $UsageFile
}

$form = New-Object ResizableOverlayForm
$form.Text = "Usage Viewer"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(24, 48)
$form.Size = $defaultWindowSize
$form.MinimumSize = New-Object System.Drawing.Size(440, 160)
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(1, 2, 3)
$form.TransparencyKey = $form.BackColor
$form.Opacity = 0.92

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$panel.BackColor = [System.Drawing.Color]::FromArgb(28, 32, 38)
$form.Controls.Add($panel)

$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$resetButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$resetButton.FlatAppearance.BorderSize = 0
$resetButton.BackColor = [System.Drawing.Color]::FromArgb(28, 32, 38)
$resetButton.ForeColor = [System.Drawing.Color]::FromArgb(174, 185, 196)
$resetButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$resetButton.Location = New-Object System.Drawing.Point(394, 6)
$resetButton.Size = New-Object System.Drawing.Size(28, 24)
$resetButton.Text = "R"
$resetButton.TabStop = $false
$resetButton.Add_Click({
  $form.Size = $defaultWindowSize
  $script:showCost = $false
  $script:heightBeforeCostExpand = $null
  Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
})
$panel.Controls.Add($resetButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.Color]::FromArgb(28, 32, 38)
$closeButton.ForeColor = [System.Drawing.Color]::FromArgb(220, 226, 232)
$closeButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$closeButton.Location = New-Object System.Drawing.Point(426, 6)
$closeButton.Size = New-Object System.Drawing.Size(28, 24)
$closeButton.Text = "X"
$closeButton.TabStop = $false
$closeButton.Add_Click({ $form.Close() })
$panel.Controls.Add($closeButton)

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.Location = New-Object System.Drawing.Point(14, 10)
$title.Size = New-Object System.Drawing.Size(400, 22)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(235, 241, 247)
$title.Text = "Usage"
$panel.Controls.Add($title)

$main = New-Object System.Windows.Forms.Label
$main.AutoSize = $false
$main.Location = New-Object System.Drawing.Point(14, 34)
$main.Size = New-Object System.Drawing.Size(532, 76)
$main.Font = New-Object System.Drawing.Font("Cascadia Mono", 15, [System.Drawing.FontStyle]::Bold)
$main.ForeColor = [System.Drawing.Color]::FromArgb(126, 231, 180)
$main.Text = "Waiting for usage..."
$panel.Controls.Add($main)

$detail = New-Object System.Windows.Forms.Label
$detail.AutoSize = $false
$detail.Location = New-Object System.Drawing.Point(14, 112)
$detail.Size = New-Object System.Drawing.Size(532, 44)
$detail.Font = New-Object System.Drawing.Font("Cascadia Mono", 9, [System.Drawing.FontStyle]::Regular)
$detail.ForeColor = [System.Drawing.Color]::FromArgb(174, 185, 196)
$detail.Text = $UsageFile
$panel.Controls.Add($detail)

$costToggle = New-Object System.Windows.Forms.Label
$costToggle.AutoSize = $false
$costToggle.Location = New-Object System.Drawing.Point(14, 158)
$costToggle.Size = New-Object System.Drawing.Size(532, 20)
$costToggle.Font = New-Object System.Drawing.Font("Cascadia Mono", 9, [System.Drawing.FontStyle]::Regular)
$costToggle.ForeColor = [System.Drawing.Color]::FromArgb(174, 185, 196)
$costToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
$costToggle.Text = "> cost hidden"
$panel.Controls.Add($costToggle)

$script:showCost = $false
$script:heightBeforeCostExpand = $null

$layoutOverlay = {
  $width = [Math]::Max(80, $panel.ClientSize.Width - 28)
  $titleWidth = [Math]::Max(80, $panel.ClientSize.Width - 88)
  $costHeight = Get-CostToggleHeight -Label $costToggle -Width $width
  $detailHeight = [Math]::Max(
    32,
    $panel.ClientSize.Height - $detail.Top - $costHeight - 14
  )

  $title.Width = $titleWidth
  $main.Width = $width
  $detail.Width = $width
  $detail.Height = $detailHeight
  $costToggle.Top = $detail.Top + $detail.Height + 2
  $costToggle.Width = $width
  $costToggle.Height = $costHeight
  $resetButton.Left = $panel.ClientSize.Width - 66
  $closeButton.Left = $panel.ClientSize.Width - 34
}

$form.Add_Resize($layoutOverlay)

$dragging = $false
$dragStart = New-Object System.Drawing.Point(0, 0)

$mouseDown = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
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

$toggleCost = {
  $script:showCost = -not $script:showCost

  if ($script:showCost) {
    $script:heightBeforeCostExpand = $form.Height
  } else {
    if ($script:heightBeforeCostExpand -ne $null) {
      $form.Height = [Math]::Max($form.MinimumSize.Height, [int]$script:heightBeforeCostExpand)
      $script:heightBeforeCostExpand = $null
    }
  }

  Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
  Ensure-CostToggleFits -Form $form -Panel $panel -CostToggle $costToggle
  & $layoutOverlay
}
$costToggle.Add_Click($toggleCost)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$closeItem = New-Object System.Windows.Forms.ToolStripMenuItem
$closeItem.Text = "Close"
$closeItem.Add_Click({ $form.Close() })
[void]$menu.Items.Add($closeItem)
$form.ContextMenuStrip = $menu
$panel.ContextMenuStrip = $menu

function Get-ResizeHitTest {
  param([System.Windows.Forms.Form]$Form)

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

function Get-CostToggleHeight {
  param(
    [System.Windows.Forms.Label]$Label,
    [int]$Width
  )

  $minimumHeight = if ($script:showCost) { 20 } else { 20 }
  $text = [string]$Label.Text

  if ([string]::IsNullOrWhiteSpace($text)) {
    return $minimumHeight
  }

  $proposedSize = New-Object System.Drawing.Size(
    [Math]::Max(40, $Width),
    1000
  )

  $flags =
    [System.Windows.Forms.TextFormatFlags]::WordBreak -bor
    [System.Windows.Forms.TextFormatFlags]::TextBoxControl

  $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
    $text,
    $Label.Font,
    $proposedSize,
    $flags
  )

  return [Math]::Max($minimumHeight, $measured.Height + 6)
}

function Ensure-CostToggleFits {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Windows.Forms.Panel]$Panel,
    [System.Windows.Forms.Label]$CostToggle
  )

  if (-not $script:showCost) {
    return
  }

  $width = [Math]::Max(80, $Panel.ClientSize.Width - 28)
  $costHeight = Get-CostToggleHeight -Label $CostToggle -Width $width
  $requiredClientHeight = $detail.Top + 32 + 2 + $costHeight + 12

  if ($Panel.ClientSize.Height -lt $requiredClientHeight) {
    $Form.Height += $requiredClientHeight - $Panel.ClientSize.Height
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(250, $RefreshMs)
$timer.Add_Tick({
  Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
})

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
    $Title.Text = "Usage"
    $Main.Text = "Waiting for usage..."
    $Detail.Text = $UsageFile
    $CostToggle.Text = "> cost hidden"
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
    $age = Format-Age $json.generated_at

    $Title.Text = "$model  |  updated $age"
    $Main.Text = "5h $fiveHour   week $week"
    $Detail.Text = "ctx $ctx  |  in $(Format-Count $tokens.total_input)  out $(Format-Count $tokens.output)`r`nnew $(Format-Count $tokens.new_input)  cached $cached"

    if ($script:showCost) {
      $CostToggle.Text = "v cost $$(Format-Usd $cost.session_usd)`r`n  turn $$(Format-Usd $cost.turn_usd)"
    } else {
      $CostToggle.Text = "> cost hidden"
    }
  } catch {
    $Title.Text = "Usage"
    $Main.Text = "Read error"
    $Detail.Text = $_.Exception.Message
    $CostToggle.Text = "> cost hidden"
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

  $claude = Read-UsageJson $ClaudeUsageFile
  $codex = Read-UsageJson $CodexUsageFile

  if ($null -eq $claude -and $null -eq $codex) {
    $Title.Text = "Usage"
    $Main.Text = "Waiting for Claude / Codex usage..."
    $Detail.Text = "$ClaudeUsageFile`r`n$CodexUsageFile"
    $CostToggle.Text = "> cost hidden"
    return
  }

  $claudeAge = if ($null -eq $claude) { "missing" } else { Format-Age $claude.generated_at }
  $codexAge = if ($null -eq $codex) { "missing" } else { Format-Age $codex.generated_at }
  $Title.Text = "Claude $claudeAge  |  Codex $codexAge"

  $claudeLine = if ($null -eq $claude) {
    "Claude 5h ?      week ?"
  } else {
    "Claude 5h $(Format-Percent $claude.percentages.five_hour_used 2)   week $(Format-Percent $claude.percentages.seven_day_used 2)"
  }

  $codexLine = if ($null -eq $codex) {
    "Codex  limit ?"
  } else {
    $codexLimit = Format-Percent $codex.percentages.seven_day_used 2
    if ($codexLimit -eq "?") {
      $codexLimit = Format-Percent $codex.percentages.primary_limit_used 2
    }

    "Codex  week $codexLimit"
  }

  $Main.Text = "$claudeLine`r`n$codexLine"

  $claudeDetail = if ($null -eq $claude) {
    "Claude waiting"
  } else {
    "Claude ctx $(Format-Percent $claude.percentages.context_used 1) in $(Format-Count $claude.tokens.total_input) out $(Format-Count $claude.tokens.output)"
  }

  $codexDetail = if ($null -eq $codex) {
    "Codex waiting"
  } else {
    "Codex  ctx $(Format-Percent $codex.percentages.context_used 1) in $(Format-Count $codex.tokens.total_input) out $(Format-Count $codex.tokens.output)"
  }

  $Detail.Text = "$claudeDetail`r`n$codexDetail"

  if ($script:showCost) {
    if ($null -eq $claude) {
      $CostToggle.Text = "v Claude cost unavailable"
    } else {
      $CostToggle.Text = "v Claude cost $$(Format-Usd $claude.cost.session_usd)`r`n  turn $$(Format-Usd $claude.cost.turn_usd)"
    }
  } else {
    $CostToggle.Text = "> cost hidden"
  }
}

function Read-UsageJson {
  param([string]$Filename)

  if (-not (Test-Path -LiteralPath $Filename)) {
    return $null
  }

  try {
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

Update-UsageView -CombinedMode $combinedMode -UsageFile $claudeUsageFile -ClaudeUsageFile $claudeUsageFile -CodexUsageFile $codexUsageFile -Title $title -Main $main -Detail $detail -CostToggle $costToggle
$timer.Start()
[void][System.Windows.Forms.Application]::Run($form)
