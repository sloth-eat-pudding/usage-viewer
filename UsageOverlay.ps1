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

  [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
  public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

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
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowIconPath = Join-Path $scriptDirectory "assets\usage-viewer.ico"
$claudeUsageFile = Join-Path $usageHome "claude-latest.json"
$codexUsageFile = Join-Path $usageHome "codex-latest.json"
$overlayErrorLog = Join-Path $usageHome "overlay-error.log"
$defaultWindowSize = New-Object System.Drawing.Size(440, 112)

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
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(24, 48)
$form.Size = $defaultWindowSize
$form.MinimumSize = New-Object System.Drawing.Size(360, 104)
$form.TopMost = $true
$form.ShowIcon = $true
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
$title.Location = New-Object System.Drawing.Point(0, 0)
$title.Size = New-Object System.Drawing.Size(1, 1)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(235, 241, 247)
$title.Text = ""
$title.Visible = $false
$panel.Controls.Add($title)

$main = New-Object System.Windows.Forms.Label
$main.AutoSize = $false
$main.Location = New-Object System.Drawing.Point(14, 12)
$main.Size = New-Object System.Drawing.Size(392, 48)
$main.Font = New-Object System.Drawing.Font("Cascadia Mono", 15, [System.Drawing.FontStyle]::Bold)
$main.ForeColor = [System.Drawing.Color]::FromArgb(126, 231, 180)
$main.Text = "Waiting for usage..."
$panel.Controls.Add($main)

$detail = New-Object System.Windows.Forms.Label
$detail.AutoSize = $false
$detail.Location = New-Object System.Drawing.Point(14, 62)
$detail.Size = New-Object System.Drawing.Size(392, 36)
$detail.Font = New-Object System.Drawing.Font("Cascadia Mono", 9, [System.Drawing.FontStyle]::Regular)
$detail.ForeColor = [System.Drawing.Color]::White
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
  $width = [Math]::Max(80, $panel.ClientSize.Width - 28)
  $main.Width = $width
  $detail.Width = $width
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

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(250, $RefreshMs)
$timer.Add_Tick({
  try {
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
    $Detail.Text = "Claude $age reset $reset"
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

  $claude = Read-UsageJson $ClaudeUsageFile
  $codex = Read-UsageJson $CodexUsageFile

  if ($null -eq $claude -and $null -eq $codex) {
    $Title.Text = ""
    $Main.Text = "Waiting for Claude / Codex usage..."
    $Detail.Text = ""
    $CostToggle.Text = ""
    return
  }

  $Title.Text = ""

  $claudeLine = if ($null -eq $claude) {
    "Claude ?% ?%"
  } else {
    Format-ClaudeUsageLine $claude
  }

  $codexLine = if ($null -eq $codex) {
    "Codex ?%"
  } else {
    $codexLimit = Format-Percent $codex.percentages.seven_day_used 2
    if ($codexLimit -eq "?") {
      $codexLimit = Format-Percent $codex.percentages.primary_limit_used 2
    }

    "Codex $codexLimit"
  }

  $Main.Text = "$codexLine`r`n$claudeLine"

  $codexTimeLine = if ($null -eq $codex) {
    "Codex ? reset ?"
  } else {
    "Codex $(Format-Age (Get-UsageTimestamp $codex)) - $(Format-ResetSummary $codex)"
  }

  $claudeTimeLine = if ($null -eq $claude) {
    "Claude ? reset ?"
  } else {
    "Claude $(Format-Age (Get-UsageTimestamp $claude)) - $(Format-ResetSummary $claude)"
  }

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

  $Detail.Text = "$codexTimeLine`r`n$claudeTimeLine"
  $CostToggle.Text = ""
}

function Resize-OverlayToContent {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Windows.Forms.Label]$Title,
    [System.Windows.Forms.Label]$Main,
    [System.Windows.Forms.Label]$Detail
  )

  $mainWidth = Measure-MultilineTextWidth -Text $Main.Text -Font $Main.Font
  $detailWidth = Measure-MultilineTextWidth -Text $Detail.Text -Font $Detail.Font

  $desiredWidth = [Math]::Max(
    $Form.MinimumSize.Width,
    ([Math]::Max($mainWidth, $detailWidth) + 34)
  )

  $desiredWidth = [Math]::Min(760, $desiredWidth)

  if ([Math]::Abs($Form.Width - $desiredWidth) -gt 8) {
    $Form.Width = $desiredWidth
  }

  $desiredHeight = [Math]::Max($Form.MinimumSize.Height, 112)

  if ([Math]::Abs($Form.Height - $desiredHeight) -gt 6) {
    $Form.Height = $desiredHeight
  }
}

function Measure-MultilineTextWidth {
  param(
    [string]$Text,
    [System.Drawing.Font]$Font
  )

  $maxWidth = 0

  foreach ($line in ([string]$Text -split "`r?`n")) {
    $maxWidth = [Math]::Max(
      $maxWidth,
      (Measure-TextWidth -Text $line -Font $Font)
    )
  }

  return $maxWidth
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

  $week = Format-Percent $Claude.percentages.seven_day_used 2
  $fiveHour = Format-Percent $Claude.percentages.five_hour_used 2

  if ($week -ne "?" -or $fiveHour -ne "?") {
    return "Claude $week $fiveHour"
  }

  return "Claude in $(Format-CompactCount $Claude.tokens.total_input) out $(Format-CompactCount $Claude.tokens.output)"
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

  if ($week -ne "?") {
    if ($fiveHour -ne "?") {
      return "$week / 5h $fiveHour"
    }
    return $week
  }

  if ($fiveHour -ne "?") {
    return "5h $fiveHour"
  }

  return Format-Reset (Get-ResetEpoch $Json)
}

function Format-ResetTime {
  param($EpochSeconds)

  if ($null -eq $EpochSeconds) {
    return "?"
  }

  try {
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$EpochSeconds).ToLocalTime().ToString("HH:mm")
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
    $weekPrefix = [string][char]0x9031
    $weekdayNames = @(
      "$weekPrefix$([char]0x65E5)",
      "$weekPrefix$([char]0x4E00)",
      "$weekPrefix$([char]0x4E8C)",
      "$weekPrefix$([char]0x4E09)",
      "$weekPrefix$([char]0x56DB)",
      "$weekPrefix$([char]0x4E94)",
      "$weekPrefix$([char]0x516D)"
    )
    $weekday = $weekdayNames[[int]$local.DayOfWeek]
    $weekPrefix = [string][char]0x9031
    $weekdayNames = @(
      "$weekPrefix$([char]0x65E5)",
      "$weekPrefix$([char]0x4E00)",
      "$weekPrefix$([char]0x4E8C)",
      "$weekPrefix$([char]0x4E09)",
      "$weekPrefix$([char]0x56DB)",
      "$weekPrefix$([char]0x4E94)",
      "$weekPrefix$([char]0x516D)"
    )
    $weekday = $weekdayNames[[int]$local.DayOfWeek]
    return "$weekday $($local.ToString("HH:mm"))"
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
[void][System.Windows.Forms.Application]::Run($form)
