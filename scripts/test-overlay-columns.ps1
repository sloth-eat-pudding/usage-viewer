$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot '../src/overlay/UsageOverlay.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -in @('Resize-OverlayToContent', 'Resize-UsageColumns', 'Measure-TextWidth', 'Measure-MultilineTextSize')
}, $false)) { Invoke-Expression $function.Extent.Text }

function Assert-True { param($Value, $Message) if (-not $Value) { throw $Message } }
$combinedMode = $true
$script:DisplayLayout = 'columns'
$script:IsPinned = $false
$script:usageColumnControls = @()
$mouseDown = {}; $mouseMove = {}; $mouseUp = {}
$form = New-Object System.Windows.Forms.Form
$form.MinimumSize = [System.Drawing.Size]::new(180, 56)
$main = New-Object System.Windows.Forms.Label
$detail = New-Object System.Windows.Forms.Label
$main.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$detail.Font = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Regular)
$form.Controls.Add($main)
$form.Controls.Add($detail)
$form.ShowInTaskbar = $false
$form.Opacity = 0
$form.Show()
try {
  $main.Text = (@('A  5h 10%  7d 20% (D)', 'A  5h 30%  7d 40% (S)', 'O  5h 50%  7d 60% (D+C)', 'O  5h 70%  7d 80% (R)') -join "`n")
  $detail.Text = ((1..4 | ForEach-Object { "Reset in 4h / 6d | now (source $_)" }) -join "`n")
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  Assert-True ($script:usageColumnControls.Count -eq 4) 'Every group must retain its own column'
  $height = $form.ClientSize.Height
  $previousRight = 0
  foreach ($column in $script:usageColumnControls) {
    Assert-True ($column.Main.Top -eq 4) 'Usage must stay on the first row'
    Assert-True ($column.Detail.Top -gt $column.Main.Bottom) 'Details must stay below usage'
    Assert-True ($column.Main.Left -eq $column.Detail.Left) 'Usage and details must align within each column'
    Assert-True ($column.Main.Left -ge $previousRight) 'Columns must not overlap'
    $previousRight = $column.Main.Right
  }
  Assert-True ($form.ClientSize.Width -ge $previousRight + 66) 'Controls must not cover the last column'
  # Refresh the same groups across digit boundaries in both layouts and pin
  # states. Verify geometry, not just the text measurement helper.
  foreach ($layout in @('columns', 'stacked')) {
    $script:DisplayLayout = $layout
    foreach ($pinned in @($false, $true)) {
      $script:IsPinned = $pinned
      $expectedSize = $null
      $expectedBounds = $null
      foreach ($value in @(9, 10, 99, 100, 1, 11, 0)) {
        $main.Text = (@("A  5h $value%  7d $value% (D)", 'O  5h 50%  7d 60% (D+C)') -join "`n")
        $detail.Text = (@("Reset in ${value}h / ${value}d | ${value}m ago (source 1)", 'Reset in 4h / 6d | now (source 2)') -join "`n")
        Resize-OverlayToContent -Form $form -Main $main -Detail $detail
        $bounds = @($script:usageColumnControls | ForEach-Object { "$($_.Main.Bounds)|$($_.Detail.Bounds)" }) -join ';'
        if ($null -eq $expectedSize) {
          $expectedSize = $form.ClientSize
          $expectedBounds = $bounds
        }
        Assert-True ($form.ClientSize -eq $expectedSize -and $bounds -eq $expectedBounds) "Numeric refresh must preserve $layout geometry (pinned=$pinned, value=$value)"
        Assert-True ($main.Text.Contains("$value%")) 'Reserved space must not change displayed values'
        foreach ($column in $script:usageColumnControls) {
          foreach ($label in @($column.Main, $column.Detail)) {
            $actualWidth = [System.Windows.Forms.TextRenderer]::MeasureText($label.Text, $label.Font).Width
            Assert-True ($label.Width -ge $actualWidth) 'Reserved columns must not clip text'
          }
        }
      }
    }
  }
  $script:IsPinned = $false
  $script:DisplayLayout = 'columns'
  $main.Text = (@('A  5h 10%  7d 20% (D)', 'A  5h 30%  7d 40% (S)', 'O  5h 50%  7d 60% (D+C)', 'O  5h 70%  7d 80% (R)') -join "`n")
  $detail.Text = ((1..4 | ForEach-Object { "Reset in 4h / 6d | now (source $_)" }) -join "`n")
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  $script:DisplayLayout = 'stacked'
  $oldColumn = $script:usageColumnControls[0].Main
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  Assert-True ($form.ClientSize.Height -gt $height) 'Stacked mode must display all groups vertically'
  Assert-True ($main.Visible -and $detail.Visible -and $oldColumn.IsDisposed) 'Switching to stacked mode must restore the text labels and dispose column controls'
  $script:DisplayLayout = 'columns'
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  Assert-True ($form.ClientSize.Height -eq $height -and $script:usageColumnControls.Count -eq 4) 'Switching back must restore two rows and all groups'
  $removed = $script:usageColumnControls[-1].Main
  $main.Text = 'Waiting for Claude / Codex usage...'
  $detail.Text = ''
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  Assert-True ($script:usageColumnControls.Count -eq 1 -and $removed.IsDisposed) 'Removed groups must release their controls'
  Assert-True ($form.ClientSize.Height -eq $height) 'Adding groups must not increase the row count or height'
  $script:IsPinned = $true
  Resize-OverlayToContent -Form $form -Main $main -Detail $detail
  Assert-True ($form.ClientSize.Width -ge $script:usageColumnControls[0].Main.Right + 26) 'Pinned mode must reserve the unlock button'
  Write-Output 'Overlay column layout checks passed.'
} finally { $form.Dispose() }
