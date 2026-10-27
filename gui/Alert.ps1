# ---------------------------------------------------------------------------------------------
#  Calling a person to the PC: the whole screen (or a frame round it) in a colour, flashing slowly,
#  with the sound again every few minutes until someone answers (settings: src/Alert.ps1).
#  Shown when a run stops with an error, and behind CONFIRM / ASK while they wait.
# ---------------------------------------------------------------------------------------------

# @{ Kind; Style; Forms; Labels (@{ Label; Prefix } with the elapsed time); Since; Flash; Color; Shade; Dark; Timer; SoundTimer; Closing; Test }
$script:Alert = $null

function Test-FujiAlertOpen {
    return ($null -ne $script:Alert -and $script:Alert.Forms.Count -gt 0)
}

# Lines: what to show under the title. Config: settings to use instead of the saved ones (the test button).
function Show-FujiAlert {
    param([ValidateSet('error', 'confirm')][string]$Kind, [string]$Title, [string[]]$Lines = @(), [System.Collections.IDictionary]$Config = $null, [switch]$Test)
    Close-FujiAlert
    $cfg = $Config
    if ($null -eq $cfg) { $cfg = Get-FujiAlertSetting -Settings $script:Settings -Kind $Kind }
    $a = @{
        Kind = $Kind; Style = [string]$cfg.style; Forms = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        Labels = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Since = (Get-Date); Flash = [bool]$cfg.flash
        Color = [string]$cfg.color; Shade = (Get-FujiAlertShade -Color ([string]$cfg.color)); Dark = $false; Timer = $null; SoundTimer = $null; Closing = $false; Test = [bool]$Test
    }
    $script:Alert = $a
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($a.Style -eq 'full') { New-FujiAlertFull -Alert $a -Screen $screen -Title $Title -Lines $Lines }
        if ($a.Style -eq 'border') { New-FujiAlertBorder -Alert $a -Screen $screen -Title $Title }
    }
    foreach ($f in $a.Forms) { $f.Show() }
    if ($a.Forms.Count -gt 0) {
        Update-FujiAlertLook
        $a.Forms[0].Activate()
        $a.Timer = New-Object -TypeName System.Windows.Forms.Timer
        $a.Timer.Interval = 1000
        $a.Timer.Add_Tick({ Invoke-FujiUi { if ($null -ne $script:Alert) { $script:Alert.Dark = $script:Alert.Flash -and -not $script:Alert.Dark; Update-FujiAlertLook } } })
        $a.Timer.Start()
        Write-FujiUiLog -Message (Get-FujiText ('alert.shown' + $a.Style)) -Level 'warn'
    }
    # the error sound follows the run bar's alarm box; the confirm sound is its own setting
    $sound = ($Kind -eq 'confirm' -and [bool]$cfg.sound) -or ($Kind -eq 'error' -and $script:Ui.AlarmCheck.Checked)
    if ($sound) {
        Invoke-FujiAlarm -Force -File ([string]$cfg.file)
        # again until someone answers: only with something on the screen to answer
        if ([bool]$cfg.repeat -and $a.Forms.Count -gt 0) {
            $a.SoundTimer = New-Object -TypeName System.Windows.Forms.Timer
            $a.SoundTimer.Interval = [int]$cfg.minutes * 60000
            $a.SoundTimer.Tag = [string]$cfg.file
            $a.SoundTimer.Add_Tick({ $file = [string]$this.Tag; Invoke-FujiUi { if ($null -ne $script:Alert) { Invoke-FujiAlarm -Force -File $file } } })
            $a.SoundTimer.Start()
        }
    }
}

# Acknowledged: someone answered it (written to the log with how long it waited)
function Close-FujiAlert {
    param([switch]$Acknowledged)
    $a = $script:Alert
    if ($null -eq $a) { return }
    $script:Alert = $null
    $a.Closing = $true
    foreach ($t in @($a.Timer, $a.SoundTimer)) { if ($null -ne $t) { $t.Stop(); $t.Dispose() } }
    if ($null -ne $script:RunCtl.Player) { $script:RunCtl.Player.Stop() }
    foreach ($f in $a.Forms) { if (-not $f.IsDisposed) { $f.Close(); $f.Dispose() } }
    if ($Acknowledged -and -not $a.Test -and $a.Forms.Count -gt 0) {
        Write-FujiUiLog -Message (Get-FujiText 'alert.acknowledged' $a.Since.ToString('HH:mm') (Format-FujiElapsed -Since $a.Since -Now (Get-Date))) -Level 'ok'
        if ($a.Kind -eq 'error') { Save-FujiRunAckUi -Since $a.Since }
    }
}

# Colours and the elapsed time, once a second
function Update-FujiAlertLook {
    $a = $script:Alert
    if ($null -eq $a) { return }
    $back = $a.Color
    if ($a.Dark) { $back = $a.Shade }
    $c = Get-FujiColor $back
    $fore = Get-FujiColor (Get-FujiAlertTextColor -Color $back)
    foreach ($f in $a.Forms) { $f.BackColor = $c; $f.ForeColor = $fore }
    $since = Get-FujiText 'alert.since' $a.Since.ToString('HH:mm') (Format-FujiElapsed -Since $a.Since -Now (Get-Date))
    foreach ($l in $a.Labels) { $l.Label.Text = $l.Prefix + $since }
}

function New-FujiAlertForm {
    param([hashtable]$Alert, [System.Drawing.Rectangle]$Bounds)
    $f = New-Object -TypeName System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.Bounds = $Bounds
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.KeyPreview = $true
    $f.Text = Get-FujiText 'gui.title'
    $f.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Invoke-FujiUi { Close-FujiAlert -Acknowledged } } })
    # Alt+F4 also answers it (after this close, so the form is not closed inside its own closing)
    $f.Add_FormClosing({
            if ($null -eq $script:Alert -or $script:Alert.Closing) { return }
            $_.Cancel = $true
            [void]$script:Ui.Form.BeginInvoke([System.Action] { Invoke-FujiUi { Close-FujiAlert -Acknowledged } })
        })
    $Alert.Forms.Add($f)
    return $f
}

# A font about Share of the screen height tall
function New-FujiAlertFont {
    param([System.Windows.Forms.Screen]$Screen, [double]$Share, [double]$MinPoints, [switch]$Bold)
    $dpi = 96.0 * $script:Ui.Scale / $script:Ui.Zoom
    $points = [Math]::Max($MinPoints * $script:Ui.Zoom, $Screen.Bounds.Height * $Share * 72.0 / $dpi)
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    return (New-Object -TypeName System.Drawing.Font -ArgumentList $script:Ui.Font.FontFamily, ([float]$points), $style)
}

function New-FujiAlertLabel {
    param([string]$Text, $Font, [int]$MaxWidth)
    $l = New-Object -TypeName System.Windows.Forms.Label
    $l.Text = $Text
    $l.Font = $Font
    $l.AutoSize = $true
    $l.UseMnemonic = $false
    $l.MaximumSize = New-Object -TypeName System.Drawing.Size -ArgumentList $MaxWidth, 0
    $l.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $l.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
    return $l
}

# The whole screen: the title, the lines, the time it has waited and the answer button
function New-FujiAlertFull {
    param([hashtable]$Alert, [System.Windows.Forms.Screen]$Screen, [string]$Title, [string[]]$Lines)
    $f = New-FujiAlertForm -Alert $Alert -Bounds $Screen.Bounds
    $width = [int]($Screen.Bounds.Width * 0.85)
    $t = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $t.Dock = [System.Windows.Forms.DockStyle]::Fill
    $t.ColumnCount = 1
    Add-FujiFullColumn -Table $t
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $rows.Add((New-FujiAlertLabel -Text $Title -Font (New-FujiAlertFont -Screen $Screen -Share 0.065 -MinPoints 24 -Bold) -MaxWidth $width))
    $lineFont = New-FujiAlertFont -Screen $Screen -Share 0.032 -MinPoints 14
    foreach ($line in $Lines) { if ($line) { $rows.Add((New-FujiAlertLabel -Text $line -Font $lineFont -MaxWidth $width)) } }
    $since = New-FujiAlertLabel -Text '' -Font (New-FujiAlertFont -Screen $Screen -Share 0.032 -MinPoints 14 -Bold) -MaxWidth $width
    $Alert.Labels.Add(@{ Label = $since; Prefix = '' })
    $rows.Add($since)
    $ok = New-Object -TypeName System.Windows.Forms.Button
    $ok.Text = Get-FujiText 'alert.ok'
    $ok.Font = New-FujiAlertFont -Screen $Screen -Share 0.03 -MinPoints 14 -Bold
    $ok.AutoSize = $true
    $ok.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $ok.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 24), (Get-FujiScaled 8), (Get-FujiScaled 24), (Get-FujiScaled 8)
    $ok.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 24)
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $ok.UseVisualStyleBackColor = $false
    $ok.BackColor = [System.Drawing.Color]::White
    $ok.ForeColor = [System.Drawing.Color]::Black
    $ok.UseMnemonic = $false
    $ok.Add_Click({ Invoke-FujiUi { Close-FujiAlert -Acknowledged } })
    $rows.Add($ok)
    # empty rows above and below share the room, so the text stands in the middle
    $t.RowCount = $rows.Count + 2
    [void]$t.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 50))
    foreach ($r in $rows) { [void]$t.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize))) }
    [void]$t.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 50))
    for ($i = 0; $i -lt $rows.Count; $i++) { $t.Controls.Add($rows[$i], 0, $i + 1) }
    [void]$f.Controls.Add($t)
    $f.AcceptButton = $ok
}

# A frame round the screen: a band at the top with the title (a click answers it) and thin sides
function New-FujiAlertBorder {
    param([hashtable]$Alert, [System.Windows.Forms.Screen]$Screen, [string]$Title)
    $b = $Screen.Bounds
    $font = New-FujiAlertFont -Screen $Screen -Share 0.022 -MinPoints 12 -Bold
    $band = [int][Math]::Ceiling($font.GetHeight() * 2)
    $side = [Math]::Max((Get-FujiScaled 12), [int]($b.Height * 0.012))
    $top = New-FujiAlertForm -Alert $Alert -Bounds (New-Object -TypeName System.Drawing.Rectangle -ArgumentList $b.X, $b.Y, $b.Width, $band)
    $l = New-Object -TypeName System.Windows.Forms.Label
    $l.Dock = [System.Windows.Forms.DockStyle]::Fill
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $l.Font = $font
    $l.UseMnemonic = $false
    $l.AutoEllipsis = $true
    $l.Cursor = [System.Windows.Forms.Cursors]::Hand
    $l.Add_Click({ Invoke-FujiUi { Close-FujiAlert -Acknowledged } })
    [void]$top.Controls.Add($l)
    $Alert.Labels.Add(@{ Label = $l; Prefix = ($Title + (Get-FujiText 'alert.bandClick') + '  ') })
    foreach ($r in @(
            @($b.X, ($b.Y + $band), $side, ($b.Height - $band)),
            @(($b.Right - $side), ($b.Y + $band), $side, ($b.Height - $band)),
            @(($b.X + $side), ($b.Bottom - $side), ($b.Width - 2 * $side), $side))) {
        $f = New-FujiAlertForm -Alert $Alert -Bounds (New-Object -TypeName System.Drawing.Rectangle -ArgumentList $r[0], $r[1], $r[2], $r[3])
        $f.Add_Click({ Invoke-FujiUi { Close-FujiAlert -Acknowledged } })
    }
}

# ----------------------------------------------------------------- from a run
# Error stop: what stopped, where, and since when
function Show-FujiRunAlert {
    param([string]$Message)
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add((Get-FujiText 'alert.macro' (Get-FujiCurrentMacro $script:Ed).name))
    $run = $script:Run
    if ($null -ne $run -and $run.Rows.Count -gt 1) { $lines.Add((Get-FujiText 'alert.row' ($run.RowPos + 1) $run.Rows.Count)) }
    $lines.Add((Format-FujiShort $Message 200))
    Show-FujiAlert -Kind 'error' -Title (Get-FujiText 'alert.errorTitle') -Lines $lines.ToArray()
}

# ----------------------------------------------------------------- settings dialog
# "Alarm 1", "Ring 3" ...
function Get-FujiAlertSoundName {
    param([string]$File)
    $m = [regex]::Match($File, '^(Alarm|Ring)(\d\d)\.wav$')
    if (-not $m.Success) { return $File }
    return (Get-FujiText ('alert.sound' + $m.Groups[1].Value) ([int]$m.Groups[2].Value))
}

function Show-FujiAlertSettingDialog {
    $width = Get-FujiScaled 560
    $f = New-FujiDialogForm -Title (Get-FujiText 'alert.dialogTitle') -Width $width -Height (Get-FujiScaled 300)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.AutoSize = $true
    $f.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.AutoSize = $true
    $layout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $layout.ColumnCount = 1
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    $layout.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList $width, 0
    $script:Ui.AlertEdit = @{}
    foreach ($kind in $script:FujiAlertKinds) {
        $cfg = Get-FujiAlertSetting -Settings $script:Settings -Kind $kind
        $ed = @{ Kind = $kind; Color = $cfg.color }
        $script:Ui.AlertEdit[$kind] = $ed
        $g = New-Object -TypeName System.Windows.Forms.GroupBox
        $g.Text = Get-FujiText ('alert.group' + $kind)
        $g.AutoSize = $true
        $g.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $g.Dock = [System.Windows.Forms.DockStyle]::Fill
        $g.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
        $inner = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
        $inner.AutoSize = $true
        $inner.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $inner.ColumnCount = 1
        $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
        $ed.Style = New-FujiComboBox -Items @((Get-FujiText 'alert.stylefull'), (Get-FujiText 'alert.styleborder'), (Get-FujiText 'alert.stylenone')) -Values $script:FujiAlertStyles -Width (Get-FujiScaled 220)
        $ed.Style.SelectedIndex = [Array]::IndexOf($script:FujiAlertStyles, [string]$cfg.style)
        $ed.ColorButton = New-FujiButton -Text (Get-FujiText 'alert.colorChange') -Tag $kind
        $ed.ColorButton.UseVisualStyleBackColor = $false
        $ed.ColorButton.Add_Click({ $k = [string]$this.Tag; Invoke-FujiUi { Select-FujiAlertColor -Kind $k } })
        $ed.Flash = New-FujiCheck -Text (Get-FujiText 'alert.flash') -Checked ([bool]$cfg.flash)
        $row1 = New-FujiFlow
        foreach ($c in @((New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'alert.style')), $ed.Style)), (New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'alert.color')), $ed.ColorButton)), $ed.Flash)) { [void]$row1.Controls.Add($c) }
        [void]$inner.Controls.Add($row1)
        $soundRow = New-FujiFlow
        if ($kind -eq 'confirm') {
            $ed.Sound = New-FujiCheck -Text (Get-FujiText 'alert.sound') -Checked ([bool]$cfg.sound)
            [void]$soundRow.Controls.Add($ed.Sound)
        } else {
            $ed.Sound = $null
            [void]$soundRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'alert.soundLabel')))
        }
        $names = @($script:FujiAlertSounds | ForEach-Object { Get-FujiAlertSoundName -File $_ })
        $ed.File = New-FujiComboBox -Items $names -Values $script:FujiAlertSounds -Width (Get-FujiScaled 150)
        $ed.File.SelectedIndex = [Array]::IndexOf($script:FujiAlertSounds, [string]$cfg.file)
        $ed.Listen = New-FujiButton -Text (Get-FujiText 'alert.listen') -Tag $kind
        $ed.Listen.Add_Click({ $k = [string]$this.Tag; Invoke-FujiUi { Invoke-FujiAlarm -Force -Once -File (Get-FujiAlertDialogValue -Kind $k).file } })
        [void]$soundRow.Controls.Add((New-FujiGlued @($ed.File, $ed.Listen)))
        if ($kind -eq 'error') { [void]$soundRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'alert.errorSound'))) }
        [void]$inner.Controls.Add($soundRow)
        $row2 = New-FujiFlow
        $ed.Repeat = New-FujiCheck -Text (Get-FujiText 'alert.repeat') -Checked ([bool]$cfg.repeat)
        $ed.Minutes = New-FujiComboBox -Items $script:FujiAlertMinutes -Values $script:FujiAlertMinutes -Width (Get-FujiScaled 60)
        $ed.Minutes.SelectedIndex = [Array]::IndexOf($script:FujiAlertMinutes, [int]$cfg.minutes)
        [void]$row2.Controls.Add((New-FujiGlued @($ed.Repeat, $ed.Minutes, (New-FujiLabel -Text (Get-FujiText 'alert.minutes')))))
        [void]$inner.Controls.Add($row2)
        $test = New-FujiButton -Text (Get-FujiText 'alert.test') -Tag $kind
        $test.Add_Click({ $k = [string]$this.Tag; Invoke-FujiUi { Show-FujiAlertTest -Kind $k } })
        [void]$inner.Controls.Add($test)
        [void]$g.Controls.Add($inner)
        [void]$layout.Controls.Add($g)
        foreach ($c in @($ed.Style, $ed.Repeat, $ed.Sound)) {
            if ($null -eq $c) { continue }
            if ($c -is [System.Windows.Forms.ComboBox]) { $c.Add_SelectedIndexChanged({ Update-FujiAlertDialogState }) } else { $c.Add_CheckedChanged({ Update-FujiAlertDialogState }) }
        }
    }
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'alert.note') -MaxWidth ($width - (Get-FujiScaled 30))))
    $bar = New-FujiButtonBar
    $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-FujiButton -Text (Get-FujiText 'gui.ok')
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    [void]$bar.Controls.Add((New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.alerts')))
    [void]$layout.Controls.Add($bar)
    [void]$f.Controls.Add($layout)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    Update-FujiAlertDialogState
    if ((Show-FujiDialog -Form $f) -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($kind in $script:FujiAlertKinds) { Set-FujiAlertSetting -Settings $script:Settings -Kind $kind -Value (Get-FujiAlertDialogValue -Kind $kind) }
        Save-FujiScheduleSetting
        Write-FujiUiLog -Message (Get-FujiText 'alert.saved') -Level 'ok'
    }
    $f.Dispose()
}

function Get-FujiAlertDialogValue {
    param([string]$Kind)
    $ed = $script:Ui.AlertEdit[$Kind]
    $v = [ordered]@{
        style = $script:FujiAlertStyles[[Math]::Max(0, $ed.Style.SelectedIndex)]; color = $ed.Color; flash = $ed.Flash.Checked
        sound = ($null -ne $ed.Sound -and $ed.Sound.Checked); file = $script:FujiAlertSounds[[Math]::Max(0, $ed.File.SelectedIndex)]; repeat = $ed.Repeat.Checked; minutes = $script:FujiAlertMinutes[[Math]::Max(0, $ed.Minutes.SelectedIndex)]
    }
    return $v
}

# What cannot be used greys out: no colour without anything shown, no repeat without a screen to answer or a sound
function Update-FujiAlertDialogState {
    foreach ($ed in $script:Ui.AlertEdit.Values) {
        $shown = $ed.Style.SelectedIndex -ne 2
        $ed.ColorButton.Enabled = $shown
        $ed.Flash.Enabled = $shown
        $ed.ColorButton.BackColor = Get-FujiColor $ed.Color
        $ed.ColorButton.ForeColor = Get-FujiColor (Get-FujiAlertTextColor -Color $ed.Color)
        $ed.File.Enabled = $null -eq $ed.Sound -or $ed.Sound.Checked
        $ed.Listen.Enabled = $ed.File.Enabled
        $ed.Repeat.Enabled = $shown -and ($null -eq $ed.Sound -or $ed.Sound.Checked)
        $ed.Minutes.Enabled = $ed.Repeat.Enabled -and $ed.Repeat.Checked
    }
}

function Select-FujiAlertColor {
    param([string]$Kind)
    $ed = $script:Ui.AlertEdit[$Kind]
    $d = New-Object -TypeName System.Windows.Forms.ColorDialog
    $d.FullOpen = $true
    $d.Color = Get-FujiColor $ed.Color
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ed.Color = '#{0:X2}{1:X2}{2:X2}' -f $d.Color.R, $d.Color.G, $d.Color.B
        Update-FujiAlertDialogState
    }
    $d.Dispose()
}

# The dialog's choices as they are now, before they are saved
function Show-FujiAlertTest {
    param([string]$Kind)
    $v = Get-FujiAlertDialogValue -Kind $Kind
    if ($v.style -eq 'none') {
        Write-FujiUiLog -Message (Get-FujiText 'alert.testNone') -Level 'warn'
        return
    }
    $title = Get-FujiText ('alert.' + $Kind + 'Title')
    Show-FujiAlert -Kind $Kind -Title $title -Lines @((Get-FujiText 'alert.testLine')) -Config $v -Test
}
