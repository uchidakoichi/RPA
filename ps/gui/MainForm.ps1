# ---------------------------------------------------------------------------------------------
#  Main window: macro and CSV toolbars, command palette, step list, log
#  The step list is an owner-drawn ListBox; $script:Rows maps its rows to step indexes
#  (blocks inside a collapsed block have no row). Every change: editor function, then Update-FujiAll.
# ---------------------------------------------------------------------------------------------

$script:Rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:Refreshing = $false
$script:DropRow = -1
$script:DragRow = -1
$script:DragFrom = $null
$script:ToggleClicked = $false
$script:TextFlags = $null   # set by Show-FujiMainForm (needs Windows Forms loaded)

function Show-FujiMainForm {
    $script:TextFlags = [System.Windows.Forms.TextFormatFlags]'NoPrefix, SingleLine, VerticalCenter, EndEllipsis'
    $form = New-Object -TypeName System.Windows.Forms.Form
    $form.Text = Get-FujiText 'gui.title'
    $form.Font = $script:Ui.Font
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object -TypeName System.Drawing.Size -ArgumentList ([Math]::Min((Get-FujiScaled 1280), $area.Width)), ([Math]::Min((Get-FujiScaled 900), $area.Height))
    $form.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList (Get-FujiScaled 640), (Get-FujiScaled 480)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.KeyPreview = $true
    $form.BackColor = Get-FujiColor '#fdf7fb'
    $script:Ui.Form = $form

    # Docking, not a TableLayoutPanel: a docked FlowLayoutPanel gets its height from wrapping at the
    # real window width (an auto-sized table row measured the toolbars far too tall)
    # No layout while the controls are added (each addition would lay out the window again)
    $form.SuspendLayout()
    $bottom = New-FujiBottomPanel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = Get-FujiScaled 250
    [void]$form.Controls.Add((New-FujiStepListPanel))
    [void]$form.Controls.Add($bottom)
    $toolbars = @(New-FujiTopPanel)
    $script:Ui.Toolbars = $toolbars
    # The last added docks first: add from the bottom row up so the first row is at the top
    for ($i = $toolbars.Count - 1; $i -ge 0; $i--) { [void]$form.Controls.Add($toolbars[$i]) }
    $form.ResumeLayout($true)
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)

    $form.Add_KeyDown({ $e = $_; Invoke-FujiUi { Invoke-FujiShortcut -KeyEvent $e } })
    $form.Add_FormClosing({ $e = $_; Invoke-FujiUi { Confirm-FujiClose -CloseEvent $e } })
    $form.Add_Shown({
            Invoke-FujiUi {
                foreach ($entry in $script:LogBuffer) { Add-FujiLogLine -Box $script:Ui.Log -Line $entry[0] -Level $entry[1] }
                $script:LogBuffer.Clear()
                Write-FujiUiLog -Message (Get-FujiText 'gui.welcome') -Level 'ok'
                Write-FujiStartupTime
                Start-FujiAutoRun
                if ($script:Ed.Notices.Count -gt 0) { Show-FujiMessage -Title (Get-FujiText 'gui.noticeTitle') -Message ($script:Ed.Notices -join "`r`n`r`n") }
                $script:Ui.List.Focus()
            }
        })
    Update-FujiAll
    Initialize-FujiSchedule
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    [System.Windows.Forms.Application]::Run($form)
}

# How long the start took: from the PowerShell process start (includes reading this script),
# and the parts measured inside the script (StartMarks: texts and commands, window setup, data)
function Write-FujiStartupTime {
    $total = ((Get-Date) - (Get-Process -Id $PID).StartTime).TotalSeconds
    $m = $script:StartMarks
    $w = $script:StartWatch.Elapsed.TotalSeconds
    if ($m.Count -lt 5) { return }
    $f = '0.0'
    $before = $total - $w
    Write-FujiUiLog -Message (Get-FujiText 'gui.startupTime' $total.ToString($f) $before.ToString($f) $m[0].ToString($f) ($m[1] - $m[0]).ToString($f) ($m[2] - $m[1]).ToString($f) ($m[3] - $m[2]).ToString($f) ($m[4] - $m[3]).ToString($f) ($w - $m[4]).ToString($f))
}

# ----------------------------------------------------------------- top panel
function New-FujiRowLabel {
    param([string]$Text)
    $l = New-FujiLabel -Text $Text
    $l.Font = $script:Ui.BoldFont
    $l.ForeColor = Get-FujiColor '#ad1457'
    return $l
}

function New-FujiTopPanel {
    $top = New-Object -TypeName 'System.Collections.Generic.List[object]'

    # save
    $row = New-FujiFlow
    $row.SuspendLayout()
    $save = New-FujiButton -Text (Get-FujiText 'gui.save') -Tip (Get-FujiText 'gui.saveTip')
    $save.Font = $script:Ui.BoldFont
    $save.Add_Click({ Invoke-FujiUi { Save-FujiUi } })
    $state = New-FujiLabel -Text ''
    $state.Font = $script:Ui.BoldFont
    $script:Ui.SaveState = $state
    $sched = New-FujiButton -Text (Get-FujiText 'gui.schedule') -Tip (Get-FujiText 'gui.scheduleTip')
    $sched.Add_Click({ Invoke-FujiUi { Show-FujiScheduleDialog } })
    $next = New-FujiLabel -Text ''
    $next.ForeColor = Get-FujiColor '#6a1b9a'
    $script:Ui.ScheduleState = $next
    $diag = New-FujiButton -Text (Get-FujiText 'gui.diagnostics') -Tip (Get-FujiText 'gui.diagnosticsTip')
    $diag.Add_Click({ Invoke-FujiUi { Show-FujiDiagnostic } })
    foreach ($c in @($save, $state, $sched, $diag, $next)) { [void]$row.Controls.Add($c) }
    $top.Add((Set-FujiToolbarRow $row))

    # macro
    $row = New-FujiFlow
    $row.SuspendLayout()
    [void]$row.Controls.Add((New-FujiRowLabel (Get-FujiText 'gui.macro')))
    $combo = New-FujiComboBox -Width (Get-FujiScaled 320)
    $combo.Add_SelectedIndexChanged({ Invoke-FujiUi { Select-FujiMacroUi } })
    $script:Ui.MacroCombo = $combo
    [void]$row.Controls.Add($combo)
    foreach ($b in @(
            @('gui.newMacro', '', { Invoke-FujiUi { Add-FujiMacroUi } }),
            @('gui.rename', '', { Invoke-FujiUi { Rename-FujiMacroUi } }),
            @('gui.duplicateMacro', '', { Invoke-FujiUi { Copy-FujiCurrentMacro -Editor $script:Ed; Update-FujiAll } }),
            @('gui.deleteMacro', '', { Invoke-FujiUi { Remove-FujiMacroUi } }),
            @('gui.template', 'gui.templateTip', { Invoke-FujiUi { New-FujiMacroFromTemplateUi } }),
            @('gui.export', 'gui.exportTip', { Invoke-FujiUi { Export-FujiMacroUi } }),
            @('gui.import', 'gui.importTip', { Invoke-FujiUi { Import-FujiMacroUi } })
        )) {
        $tip = ''
        if ($b[1]) { $tip = Get-FujiText $b[1] }
        $btn = New-FujiButton -Text (Get-FujiText $b[0]) -Tip $tip
        $btn.Add_Click($b[2])
        [void]$row.Controls.Add($btn)
    }
    [void]$row.Controls.Add((New-FujiRowLabel (Get-FujiText 'gui.target')))
    $target = New-FujiTextBox -Width (Get-FujiScaled 220)
    $script:Ui.ToolTip.SetToolTip($target, (Get-FujiText 'gui.targetTip'))
    $target.Add_Leave({ Invoke-FujiUi { Set-FujiTargetWindowUi } })
    $target.Add_KeyDown({
            $e = $_
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Invoke-FujiUi { Set-FujiTargetWindowUi } }
        })
    $script:Ui.Target = $target
    [void]$row.Controls.Add($target)
    $wl = New-FujiButton -Text (Get-FujiText 'gui.windowList') -Tip (Get-FujiText 'gui.windowListTip')
    $wl.Add_Click({ Invoke-FujiUi { Select-FujiWindowUi } })
    [void]$row.Controls.Add($wl)
    $top.Add((Set-FujiToolbarRow $row))

    # CSV
    $row = New-FujiFlow
    $row.SuspendLayout()
    [void]$row.Controls.Add((New-FujiRowLabel (Get-FujiText 'gui.csv')))
    $path = New-FujiTextBox -Width (Get-FujiScaled 380)
    $path.Add_KeyDown({
            $e = $_
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Invoke-FujiUi { Import-FujiCsvUi } }
        })
    $script:Ui.CsvPath = $path
    [void]$row.Controls.Add($path)
    $browse = New-FujiButton -Text (Get-FujiText 'gui.csvBrowse')
    $browse.Add_Click({ Invoke-FujiUi { Select-FujiCsvFileUi } })
    $load = New-FujiButton -Text (Get-FujiText 'gui.csvLoad')
    $load.Add_Click({ Invoke-FujiUi { Import-FujiCsvUi } })
    $header = New-Object -TypeName System.Windows.Forms.CheckBox
    $header.Text = Get-FujiText 'gui.csvHeader'
    $header.AutoSize = $true
    $header.Checked = $true
    $header.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6), (Get-FujiScaled 6), (Get-FujiScaled 2), 0
    $header.Add_CheckedChanged({ Invoke-FujiUi { Set-FujiCsvHeaderUi } })
    $script:Ui.CsvHeader = $header
    $encLabels = @()
    $encValues = @()
    foreach ($p in (Get-FujiText 'gui.csvEncodings')) { $encValues += [string]$p[0]; $encLabels += [string]$p[1] }
    $enc = New-FujiComboBox -Items $encLabels -Values $encValues -Width (Get-FujiScaled 170)
    $enc.SelectedIndex = 0
    $enc.Add_SelectedIndexChanged({ Invoke-FujiUi { if (-not $script:Refreshing -and $script:Ed.Csv.Path) { Import-FujiCsvUi } } })
    $script:Ui.CsvEncoding = $enc
    $info = New-FujiLabel -Text (Get-FujiText 'editor.csv.none')
    $info.ForeColor = Get-FujiColor '#5e5368'
    $script:Ui.CsvInfo = $info
    foreach ($c in @($browse, $load, $header, $enc, $info)) { [void]$row.Controls.Add($c) }
    $top.Add((Set-FujiToolbarRow $row))

    # palette
    $row = New-FujiFlow
    $row.SuspendLayout()
    [void]$row.Controls.Add((New-FujiRowLabel (Get-FujiText 'gui.add')))
    foreach ($group in $script:FujiCommands['palette']) {
        $gl = New-FujiLabel -Text ([string]$group['label'])
        $gl.ForeColor = Get-FujiColor '#7a6f84'
        $gl.Font = $script:Ui.SmallFont
        $gl.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8), (Get-FujiScaled 8), 0, 0
        [void]$row.Controls.Add($gl)
        $color = Get-FujiColor $script:CategoryColors[[string]$group['category']]
        foreach ($cmd in $group['cmds']) {
            $def = Get-FujiCommandDef ([string]$cmd)
            $btn = New-FujiButton -Text ([string]$def['icon'] + ' ' + [string]$def['title']) -Tip ([string]$cmd + ': ' + [string]$def['help']) -Tag ([string]$cmd)
            $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $btn.FlatAppearance.BorderColor = $color
            $btn.BackColor = Get-FujiTint -Color $color -Amount 0.88
            $btn.Add_Click({ $cmdName = [string]$this.Tag; Invoke-FujiUi { Add-FujiStepUi -Cmd $cmdName } })
            [void]$row.Controls.Add($btn)
        }
    }
    $top.Add((Set-FujiToolbarRow $row))

    # edit
    $row = New-FujiFlow
    $row.SuspendLayout()
    [void]$row.Controls.Add((New-FujiRowLabel (Get-FujiText 'gui.edit')))
    $undo = New-FujiButton -Text (Get-FujiText 'gui.undo') -Tip (Get-FujiText 'gui.undoTip')
    $undo.Add_Click({ Invoke-FujiUi { if (Undo-FujiEditorChange -Editor $script:Ed) { Update-FujiAll } } })
    $redo = New-FujiButton -Text (Get-FujiText 'gui.redo') -Tip (Get-FujiText 'gui.redoTip')
    $redo.Add_Click({ Invoke-FujiUi { if (Redo-FujiEditorChange -Editor $script:Ed) { Update-FujiAll } } })
    $script:Ui.Undo = $undo
    $script:Ui.Redo = $redo
    $hist = New-FujiComboBox -Width (Get-FujiScaled 300)
    $script:Ui.ToolTip.SetToolTip($hist, (Get-FujiText 'gui.historyTip'))
    $hist.Add_SelectedIndexChanged({ Invoke-FujiUi { Restore-FujiHistoryUi } })
    $script:Ui.History = $hist
    foreach ($c in @($undo, $redo, $hist)) { [void]$row.Controls.Add($c) }
    foreach ($b in @(
            @('gui.moveUp', 'gui.moveUpTip', { Invoke-FujiUi { Move-FujiStepUi -Direction -1 } }),
            @('gui.moveDown', 'gui.moveDownTip', { Invoke-FujiUi { Move-FujiStepUi -Direction 1 } }),
            @('gui.editStep', 'gui.editStepTip', { Invoke-FujiUi { Edit-FujiStepUi } }),
            @('gui.deleteStep', 'gui.deleteStepTip', { Invoke-FujiUi { Remove-FujiStepUi } }),
            @('gui.duplicate', 'gui.duplicateTip', { Invoke-FujiUi { if (Copy-FujiEditorStep -Editor $script:Ed) { Update-FujiAll } } }),
            @('gui.disable', 'gui.disableTip', { Invoke-FujiUi { if (Switch-FujiEditorStepDisabled -Editor $script:Ed) { Update-FujiAll } } }),
            @('gui.expandAll', '', { Invoke-FujiUi { Set-FujiAllCollapsed -Editor $script:Ed -Collapsed $false; Update-FujiStepList } }),
            @('gui.collapseAll', '', { Invoke-FujiUi { Set-FujiAllCollapsed -Editor $script:Ed -Collapsed $true; Update-FujiStepList; Update-FujiInsertHint } })
        )) {
        $tip = ''
        if ($b[1]) { $tip = Get-FujiText $b[1] }
        $btn = New-FujiButton -Text (Get-FujiText $b[0]) -Tip $tip
        $btn.Add_Click($b[2])
        [void]$row.Controls.Add($btn)
    }
    $recBtn = New-FujiButton -Text (Get-FujiText 'rec.button') -Tip (Get-FujiText 'rec.buttonTip')
    $recBtn.Add_Click({ Invoke-FujiUi { Switch-FujiRecording } })
    $script:Ui.RecordButton = $recBtn
    [void]$row.Controls.Add($recBtn)
    $hint = New-FujiLabel -Text ''
    $hint.ForeColor = Get-FujiColor '#5e5368'
    $script:Ui.InsertHint = $hint
    [void]$row.Controls.Add($hint)
    $top.Add((Set-FujiToolbarRow $row))
    return $top.ToArray()
}

function Set-FujiToolbarRow {
    param([Parameter(Mandatory)]$Row)
    $Row.ResumeLayout($false)
    $Row.Dock = [System.Windows.Forms.DockStyle]::Top
    $Row.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6), (Get-FujiScaled 1), (Get-FujiScaled 6), (Get-FujiScaled 1)
    return $Row
}

# Color mixed with white (Amount 0 = the colour, 1 = white)
function Get-FujiTint {
    param([System.Drawing.Color]$Color, [double]$Amount)
    $r = [int]($Color.R + (255 - $Color.R) * $Amount)
    $g = [int]($Color.G + (255 - $Color.G) * $Amount)
    $b = [int]($Color.B + (255 - $Color.B) * $Amount)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

# ----------------------------------------------------------------- step list
function New-FujiStepListPanel {
    $listHost = New-Object -TypeName System.Windows.Forms.Panel
    $listHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listHost.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6), (Get-FujiScaled 2), (Get-FujiScaled 6), (Get-FujiScaled 2)
    $lb = New-Object -TypeName System.Windows.Forms.ListBox
    $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lb.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $lb.ItemHeight = [Math]::Min(255, [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $script:Ui.Font).Height + (Get-FujiScaled 12))
    $lb.IntegralHeight = $false
    $lb.AllowDrop = $true
    $lb.BackColor = [System.Drawing.Color]::White
    $lb.Add_DrawItem({ $e = $_; Invoke-FujiUi { Show-FujiStepRow -DrawEvent $e } })
    $lb.Add_SelectedIndexChanged({ Invoke-FujiUi { Select-FujiStepUi } })
    $lb.Add_MouseDown({ $e = $_; Invoke-FujiUi { Start-FujiListMouse -MouseEvent $e } })
    $lb.Add_MouseMove({ $e = $_; Invoke-FujiUi { Move-FujiListMouse -MouseEvent $e } })
    $lb.Add_MouseUp({ $script:DragFrom = $null })
    # a double click on the fold mark only folds and unfolds
    $lb.Add_DoubleClick({ Invoke-FujiUi { if (-not $script:ToggleClicked -and -not (Test-FujiEditLocked)) { Edit-FujiStepUi } } })
    $lb.Add_DragOver({ $e = $_; Invoke-FujiUi { Update-FujiDropTarget -DragEvent $e } })
    $lb.Add_DragDrop({ Invoke-FujiUi { Complete-FujiDrop } })
    $lb.Add_DragLeave({ $script:DropRow = -1; $script:Ui.List.Invalidate() })
    $lb.Add_Resize({ $this.Invalidate() })
    $script:Ui.List = $lb
    $empty = New-FujiLabel -Text ((Get-FujiText 'gui.empty') + "`r`n" + (Get-FujiText 'gui.emptyHint'))
    $empty.Dock = [System.Windows.Forms.DockStyle]::Top
    $empty.AutoSize = $false
    $empty.Height = Get-FujiScaled 70
    $empty.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $empty.ForeColor = Get-FujiColor '#7a6f84'
    $empty.BackColor = [System.Drawing.Color]::White
    $empty.Visible = $false
    $script:Ui.Empty = $empty
    [void]$listHost.Controls.Add($lb)
    [void]$listHost.Controls.Add($empty)
    return $listHost
}

# Left edge of a row's contents and its fold mark (same numbers for drawing and clicking)
function Get-FujiRowLayout {
    param([int]$Depth, [int]$Left)
    $x = $Left + (Get-FujiScaled 4) + $Depth * (Get-FujiScaled 22)
    return @{ Bar = $x; Toggle = $x + (Get-FujiScaled 8); ToggleEnd = $x + (Get-FujiScaled 26) }
}

function Write-FujiRowText {
    param($Graphics, [string]$Text, $Font, [System.Drawing.Color]$Color, [int]$X, [System.Drawing.Rectangle]$Bounds, [System.Drawing.Color]$Back = [System.Drawing.Color]::Empty)
    if ($X -ge $Bounds.Right -or $Text -eq '') { return $X }
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($Graphics, $Text, $Font, $Bounds.Size, $script:TextFlags)
    $pad = 0
    if (-not $Back.IsEmpty) { $pad = Get-FujiScaled 4 }
    $w = [Math]::Min($size.Width + $pad * 2, $Bounds.Right - $X)
    $rect = New-Object -TypeName System.Drawing.Rectangle -ArgumentList $X, $Bounds.Y, $w, $Bounds.Height
    if (-not $Back.IsEmpty) {
        $h = $size.Height + (Get-FujiScaled 2)
        $tag = New-Object -TypeName System.Drawing.Rectangle -ArgumentList $X, ($Bounds.Y + [int](($Bounds.Height - $h) / 2)), $w, $h
        $brush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList $Back
        try { $Graphics.FillRectangle($brush, $tag) } finally { $brush.Dispose() }
        $rect = $tag
    }
    $flags = $script:TextFlags
    if ($pad -gt 0) { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Text, $Font, $rect, $Color, $flags)
    return ($X + $w + (Get-FujiScaled 6))
}

function Show-FujiStepRow {
    param([Parameter(Mandatory)]$DrawEvent)
    $e = $DrawEvent
    $i = $e.Index
    if ($i -lt 0 -or $i -ge $script:Rows.Count) { return }
    $row = $script:Rows[$i]
    $steps = Get-FujiCurrentStepList $script:Ed
    if ($row.Index -ge $steps.Count) { return }
    $step = $steps[$row.Index]
    $def = Get-FujiCommandDef $step.cmd
    if ($null -eq $def) { $def = Get-FujiCommandDef 'COMMENT' }
    $cat = [string]$def['category']
    $catColor = Get-FujiColor $script:CategoryColors[$cat]
    $g = $e.Graphics
    $b = $e.Bounds
    $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $disabled = $step.Contains('disabled') -and $step['disabled']
    $collapsed = $step.Contains('collapsed') -and $step['collapsed']
    $back = [System.Drawing.Color]::White
    if ($script:CategoryBack.ContainsKey($cat)) { $back = Get-FujiColor $script:CategoryBack[$cat] }
    if ($selected) { $back = Get-FujiColor '#dcecfd' }
    $running = Test-FujiRunHighlight -StepIndex $row.Index
    if ($running) { $back = Get-FujiColor '#fff3c4' }
    $brush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList $back
    try { $g.FillRectangle($brush, $b) } finally { $brush.Dispose() }
    if ($selected -or $running) {
        $edge = '#2196f3'
        if ($running) { $edge = '#fb8c00' }
        $pen = New-Object -TypeName System.Drawing.Pen -ArgumentList (Get-FujiColor $edge), 1
        try { $g.DrawRectangle($pen, $b.X, $b.Y, $b.Width - 1, $b.Height - 1) } finally { $pen.Dispose() }
    }
    $lay = Get-FujiRowLayout -Depth $row.Depth -Left $b.X
    $brush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList $catColor
    try { $g.FillRectangle($brush, $lay.Bar, $b.Y + 2, (Get-FujiScaled 4), $b.Height - 4) } finally { $brush.Dispose() }
    $grey = Get-FujiColor '#8a7f94'
    if (Test-FujiBlockStart $step.cmd) {
        $glyph = [string][char]0x25BC
        if ($collapsed) { $glyph = [string][char]0x25B6 }
        [void](Write-FujiRowText -Graphics $g -Text $glyph -Font $script:Ui.SmallFont -Color $grey -X $lay.Toggle -Bounds $b)
    }
    $x = $lay.ToggleEnd
    $no = New-Object -TypeName System.Drawing.Rectangle -ArgumentList $x, $b.Y, (Get-FujiScaled 36), $b.Height
    [System.Windows.Forms.TextRenderer]::DrawText($g, [string]($row.Index + 1), $script:Ui.SmallFont, $no, $grey, ($script:TextFlags -bor [System.Windows.Forms.TextFormatFlags]::Right))
    $x += Get-FujiScaled 44
    $badgeColor = $catColor
    if ($disabled) { $badgeColor = Get-FujiColor '#9e9e9e' }
    $x = Write-FujiRowText -Graphics $g -Text ([string]$def['icon'] + ' ' + $step.cmd) -Font $script:Ui.SmallFont -Color ([System.Drawing.Color]::White) -X $x -Bounds $b -Back $badgeColor
    $font = $script:Ui.Font
    $color = Get-FujiColor '#2b2430'
    if ($disabled) {
        $x = Write-FujiRowText -Graphics $g -Text (Get-FujiText 'gui.off') -Font $script:Ui.SmallFont -Color ([System.Drawing.Color]::White) -X $x -Bounds $b -Back (Get-FujiColor '#757575')
        $font = $script:Ui.StrikeFont
        $color = Get-FujiColor '#9e9e9e'
    }
    $label = [string]$step.label
    if (-not $label) { $label = Get-FujiStepLabel -Cmd $step.cmd -Value $step.val }
    $more = ''
    if ($collapsed) { $more = Get-FujiText 'gui.collapsedCount' $row.HiddenCount }
    if ($step.cmd -eq 'COMMENT') {
        $c = Get-FujiColor '#2e7d32'
        if ($disabled) { $c = $color }
        [void](Write-FujiRowText -Graphics $g -Text ((Get-FujiText 'gui.commentPrefix') + (Format-FujiShort $step.val 120)) -Font $font -Color $c -X $x -Bounds $b)
    } elseif ($step.cmd -eq 'GROUP_START') {
        $bold = $script:Ui.BoldFont
        if ($disabled) { $bold = $font }
        $x = Write-FujiRowText -Graphics $g -Text ([string]$def['icon'] + ' ' + $step.val) -Font $bold -Color $color -X $x -Bounds $b
        $when = ''
        if ($step.Contains('when')) { if ($step['when'] -eq 'first') { $when = Get-FujiText 'gui.whenFirst' } elseif ($step['when'] -eq 'last') { $when = Get-FujiText 'gui.whenLast' } }
        if ($when) { $x = Write-FujiRowText -Graphics $g -Text $when -Font $script:Ui.SmallFont -Color ([System.Drawing.Color]::White) -X $x -Bounds $b -Back (Get-FujiColor '#7e57c2') }
        [void](Write-FujiRowText -Graphics $g -Text $more -Font $script:Ui.SmallFont -Color $grey -X $x -Bounds $b)
    } elseif (Test-FujiBlockEnd $step.cmd) {
        [void](Write-FujiRowText -Graphics $g -Text ((Get-FujiText 'gui.blockEndPrefix') + [string]$def['title']) -Font $font -Color (Get-FujiColor '#8d6e63') -X $x -Bounds $b)
    } elseif (Test-FujiBlockMiddle $step.cmd) {
        [void](Write-FujiRowText -Graphics $g -Text ([string]$def['icon'] + ' ' + [string]$def['title']) -Font $script:Ui.BoldFont -Color $color -X $x -Bounds $b)
    } elseif ((Test-FujiBlockStart $step.cmd) -or ($def.Contains('hideVal') -and $def['hideVal'])) {
        $x = Write-FujiRowText -Graphics $g -Text $label -Font $font -Color $color -X $x -Bounds $b
        [void](Write-FujiRowText -Graphics $g -Text $more -Font $script:Ui.SmallFont -Color $grey -X $x -Bounds $b)
    } else {
        $x = Write-FujiRowText -Graphics $g -Text $label -Font $font -Color $color -X $x -Bounds $b
        [void](Write-FujiRowText -Graphics $g -Text (Format-FujiShort $step.val 60) -Font $script:Ui.SmallFont -Color $grey -X ($x + (Get-FujiScaled 6)) -Bounds $b)
    }
    # where a dragged step would land
    if ($script:DropRow -ge 0) {
        $y = -1
        if ($script:DropRow -eq $i) { $y = $b.Top + 1 }
        elseif ($script:DropRow -eq $script:Rows.Count -and $i -eq $script:Rows.Count - 1) { $y = $b.Bottom - 2 }
        if ($y -ge 0) {
            $pen = New-Object -TypeName System.Drawing.Pen -ArgumentList (Get-FujiColor '#e91e63'), (Get-FujiScaled 3)
            try { $g.DrawLine($pen, $b.Left, $y, $b.Right, $y) } finally { $pen.Dispose() }
        }
    }
}

function Select-FujiStepUi {
    if ($script:Refreshing) { return }
    $i = $script:Ui.List.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:Rows.Count) { $script:Ed.Selected = $script:Rows[$i].Index } else { $script:Ed.Selected = -1 }
    Update-FujiInsertHint
}

function Start-FujiListMouse {
    param([Parameter(Mandatory)]$MouseEvent)
    $lb = $script:Ui.List
    $script:DragFrom = $null
    $script:ToggleClicked = $false
    $i = $lb.IndexFromPoint($MouseEvent.Location)
    if ($i -lt 0 -or $i -ge $script:Rows.Count) {
        $lb.ClearSelected()
        $script:Ed.Selected = -1
        Update-FujiInsertHint
        return
    }
    if ($MouseEvent.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $row = $script:Rows[$i]
    $steps = Get-FujiCurrentStepList $script:Ed
    $lay = Get-FujiRowLayout -Depth $row.Depth -Left $lb.GetItemRectangle($i).X
    if ((Test-FujiBlockStart $steps[$row.Index].cmd) -and $MouseEvent.X -ge $lay.Toggle - (Get-FujiScaled 4) -and $MouseEvent.X -lt $lay.ToggleEnd) {
        $script:ToggleClicked = $true
        Switch-FujiBlockCollapsed -Editor $script:Ed -Index $row.Index
        Update-FujiStepList
        Update-FujiInsertHint
        return
    }
    $script:DragFrom = @{ Row = $i; X = $MouseEvent.X; Y = $MouseEvent.Y }
}

function Move-FujiListMouse {
    param([Parameter(Mandatory)]$MouseEvent)
    $from = $script:DragFrom
    if ($null -eq $from -or $MouseEvent.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $script:RunCtl.Running) { return }
    $drag = [System.Windows.Forms.SystemInformation]::DragSize
    if ([Math]::Abs($MouseEvent.X - $from.X) -lt $drag.Width -and [Math]::Abs($MouseEvent.Y - $from.Y) -lt $drag.Height) { return }
    $script:DragFrom = $null
    $script:DragRow = $from.Row
    try {
        [void]$script:Ui.List.DoDragDrop('fujikyun-step', [System.Windows.Forms.DragDropEffects]::Move)
    } finally {
        $script:DragRow = -1
        if ($script:DropRow -ge 0) { $script:DropRow = -1; $script:Ui.List.Invalidate() }
    }
}

function Update-FujiDropTarget {
    param([Parameter(Mandatory)]$DragEvent)
    if ($script:DragRow -lt 0) { $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::None; return }
    $lb = $script:Ui.List
    $pt = $lb.PointToClient((New-Object -TypeName System.Drawing.Point -ArgumentList $DragEvent.X, $DragEvent.Y))
    # scroll near the edges
    $edge = $lb.ItemHeight
    if ($pt.Y -lt $edge -and $lb.TopIndex -gt 0) { $lb.TopIndex-- }
    elseif ($pt.Y -gt $lb.ClientSize.Height - $edge -and $lb.TopIndex -lt $lb.Items.Count - 1) { $lb.TopIndex++ }
    $i = $lb.IndexFromPoint($pt)
    if ($i -lt 0 -or $i -ge $script:Rows.Count) {
        $target = $script:Rows.Count
    } else {
        $r = $lb.GetItemRectangle($i)
        $target = $i
        if ($pt.Y -gt $r.Top + $r.Height / 2) { $target = $i + 1 }
    }
    if ($target -ne $script:DropRow) {
        $script:DropRow = $target
        $lb.Invalidate()
    }
    $DragEvent.Effect = [System.Windows.Forms.DragDropEffects]::Move
}

function Complete-FujiDrop {
    $target = $script:DropRow
    $fromRow = $script:DragRow
    $script:DropRow = -1
    if ($fromRow -lt 0 -or $target -lt 0) { $script:Ui.List.Invalidate(); return }
    $steps = Get-FujiCurrentStepList $script:Ed
    $range = Get-FujiBlockRange -Steps $steps -Index $script:Rows[$fromRow].Index
    $insertAt = $steps.Count
    if ($target -lt $script:Rows.Count) { $insertAt = $script:Rows[$target].Index }
    [void](Move-FujiEditorRange -Editor $script:Ed -From $range.From -To $range.To -InsertAt $insertAt -DescriptionKey 'move')
    Update-FujiAll
}

# ----------------------------------------------------------------- bottom panel
# Run controls on top, then the log with the variable panel on its right (hidden until asked)
function New-FujiBottomPanel {
    $panel = New-Object -TypeName System.Windows.Forms.Panel
    $panel.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6), 0, (Get-FujiScaled 6), (Get-FujiScaled 6)
    $log = New-Object -TypeName System.Windows.Forms.RichTextBox
    $log.Dock = [System.Windows.Forms.DockStyle]::Fill
    $log.ReadOnly = $true
    $log.BackColor = Get-FujiColor '#2d2733'
    $log.ForeColor = Get-FujiColor '#ece6f0'
    $log.Font = $script:Ui.LogFont
    $log.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $log.DetectUrls = $false
    $log.HideSelection = $false
    $script:Ui.Log = $log
    $watch = New-Object -TypeName System.Windows.Forms.TextBox
    $watch.Multiline = $true
    $watch.ReadOnly = $true
    $watch.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $watch.Dock = [System.Windows.Forms.DockStyle]::Right
    $watch.Width = Get-FujiScaled 340
    $watch.BackColor = [System.Drawing.Color]::White
    $watch.Font = $script:Ui.LogFont
    $watch.Visible = $false
    $script:Ui.Watch = $watch
    # fill first, then the docked parts (the last added docks first)
    [void]$panel.Controls.Add($log)
    [void]$panel.Controls.Add($watch)
    [void]$panel.Controls.Add((New-FujiRunBar))
    return $panel
}

# ----------------------------------------------------------------- refresh
function Update-FujiAll {
    Update-FujiMacroSelect
    Update-FujiStepList
    Update-FujiHistoryUi
    Update-FujiSaveState
    Update-FujiInsertHint
}

function Update-FujiMacroSelect {
    $script:Refreshing = $true
    try {
        $c = $script:Ui.MacroCombo
        $c.BeginUpdate()
        $c.Items.Clear()
        for ($i = 0; $i -lt $script:Ed.Data.macros.Count; $i++) {
            $m = $script:Ed.Data.macros[$i]
            [void]$c.Items.Add((Get-FujiText 'gui.macroItem' ($i + 1) $m.name $m.steps.Count))
        }
        $c.EndUpdate()
        $c.SelectedIndex = $script:Ed.MacroIndex
        $m = Get-FujiCurrentMacro $script:Ed
        $script:Ui.Target.Text = [string]$m.targetWindow
    } finally {
        $script:Refreshing = $false
    }
}

function Update-FujiStepList {
    $script:Refreshing = $true
    try {
        $lb = $script:Ui.List
        $script:Rows = Get-FujiStepRow -Editor $script:Ed
        $top = $lb.TopIndex
        $lb.BeginUpdate()
        $lb.Items.Clear()
        $sel = -1
        for ($i = 0; $i -lt $script:Rows.Count; $i++) {
            [void]$lb.Items.Add($i)
            if ($script:Rows[$i].Index -eq $script:Ed.Selected) { $sel = $i }
        }
        if ($lb.Items.Count -gt 0) { $lb.TopIndex = [Math]::Min($top, $lb.Items.Count - 1) }
        $lb.SelectedIndex = $sel
        $lb.EndUpdate()
        if ($sel -ge 0) {
            $visible = [Math]::Max(1, [int]($lb.ClientSize.Height / $lb.ItemHeight))
            if ($sel -lt $lb.TopIndex -or $sel -ge $lb.TopIndex + $visible) { $lb.TopIndex = [Math]::Max(0, $sel - [int]($visible / 3)) }
        }
        $script:Ui.Empty.Visible = ($script:Rows.Count -eq 0)
    } finally {
        $script:Refreshing = $false
    }
}

function Update-FujiHistoryUi {
    $script:Refreshing = $true
    try {
        $c = $script:Ui.History
        $h = $script:Ed.History
        $c.BeginUpdate()
        $c.Items.Clear()
        $positions = @()
        for ($i = $h.Count - 1; $i -ge 0; $i--) {
            $mark = Get-FujiText 'gui.historyNoMark'
            if ($i -eq $script:Ed.HistoryPos) { $mark = Get-FujiText 'gui.historyMark' }
            [void]$c.Items.Add((Get-FujiText 'gui.historyItem' $mark ($i + 1) $h[$i].Time $h[$i].Desc))
            $positions += $i
        }
        $c.Tag = $positions
        $c.EndUpdate()
        $c.SelectedIndex = [Array]::IndexOf([object[]]$positions, [object]$script:Ed.HistoryPos)
        $script:Ui.Undo.Enabled = $script:Ed.HistoryPos -gt 0
        $script:Ui.Redo.Enabled = $script:Ed.HistoryPos -lt $h.Count - 1
    } finally {
        $script:Refreshing = $false
    }
}

function Update-FujiSaveState {
    $l = $script:Ui.SaveState
    if ($script:Ed.Dirty) {
        $l.Text = Get-FujiText 'gui.dirtyState'
        $l.ForeColor = Get-FujiColor '#c62828'
    } else {
        $l.Text = Get-FujiText 'gui.savedState'
        $l.ForeColor = Get-FujiColor '#2e7d32'
    }
}

function Update-FujiInsertHint {
    $steps = Get-FujiCurrentStepList $script:Ed
    if ($script:Ed.Selected -ge 0 -and $script:Ed.Selected -lt $steps.Count) {
        $script:Ui.InsertHint.Text = Get-FujiText 'gui.insertAfter' (Get-FujiInsertionIndex $script:Ed)
    } else {
        $script:Ui.InsertHint.Text = Get-FujiText 'gui.insertEnd'
    }
}

function Update-FujiCsvInfo {
    $script:Ui.CsvInfo.Text = Get-FujiCsvInfoText -Editor $script:Ed
    $script:Ui.ToolTip.SetToolTip($script:Ui.CsvInfo, [string]$script:Ed.Csv.Path)
}

# ----------------------------------------------------------------- macros
function Select-FujiMacroUi {
    if ($script:Refreshing) { return }
    $script:Ed.MacroIndex = $script:Ui.MacroCombo.SelectedIndex
    $script:Ed.Selected = -1
    Update-FujiAll
    if ($script:Ui.List.Items.Count -gt 0) { $script:Ui.List.TopIndex = 0 }
}

function Add-FujiMacroUi {
    $name = Show-FujiInput -Title (Get-FujiText 'gui.newMacroTitle') -Label (Get-FujiText 'gui.macroNameLabel') -Default (Get-FujiText 'editor.newMacro')
    if (-not $name) { return }
    Add-FujiMacro -Editor $script:Ed -Name $name
    Update-FujiAll
}

function Rename-FujiMacroUi {
    $m = Get-FujiCurrentMacro $script:Ed
    $name = Show-FujiInput -Title (Get-FujiText 'gui.renameTitle') -Label (Get-FujiText 'gui.renameLabel') -Default $m.name
    if (-not $name) { return }
    Rename-FujiMacro -Editor $script:Ed -Name $name
    Update-FujiAll
}

function Remove-FujiMacroUi {
    $m = Get-FujiCurrentMacro $script:Ed
    $answer = Show-FujiChoice -Title (Get-FujiText 'gui.deleteMacroTitle') -Message (Get-FujiText 'gui.deleteMacroText' $m.name $m.steps.Count) -Buttons @((Get-FujiText 'gui.deleteMacroButton'), (Get-FujiText 'gui.cancel'))
    if ($answer -ne 0) { return }
    Remove-FujiCurrentMacro -Editor $script:Ed
    Update-FujiAll
}

function Set-FujiTargetWindowUi {
    if ($script:Refreshing) { return }
    $m = Get-FujiCurrentMacro $script:Ed
    if ($null -eq $m -or $m.targetWindow -ceq $script:Ui.Target.Text.Trim()) { return }
    Set-FujiTargetWindow -Editor $script:Ed -Title $script:Ui.Target.Text
    Update-FujiAll
}

function Export-FujiMacroUi {
    try {
        $path = Export-FujiCurrentMacro -Editor $script:Ed
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'editor.exportFailed' $_.Exception.Message) -Level 'error'
        return
    }
    $answer = Show-FujiChoice -Title (Get-FujiText 'gui.exportDoneTitle') -Message (Get-FujiText 'gui.exportDone' $path) -Buttons @((Get-FujiText 'gui.openFolder'), (Get-FujiText 'gui.close'))
    if ($answer -eq 0) { Open-FujiFolder -Path $path }
}

function Import-FujiMacroUi {
    $dlg = New-Object -TypeName System.Windows.Forms.OpenFileDialog
    $dlg.Filter = Get-FujiText 'gui.jsonFilter'
    $folder = Get-FujiEditorPath $script:Ed $script:FujiFileNames.Export
    if (Test-Path -LiteralPath $folder) { $dlg.InitialDirectory = $folder } else { $dlg.InitialDirectory = $script:Ed.Directory }
    try {
        if ($dlg.ShowDialog($script:Ui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $message = Import-FujiMacroFile -Editor $script:Ed -Path $dlg.FileName
    } finally {
        $dlg.Dispose()
    }
    if ($message) { Show-FujiMessage -Title (Get-FujiText 'gui.importFailedTitle') -Message $message }
    Update-FujiAll
}

function Select-FujiWindowUi {
    $titles = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle } | Sort-Object -Unique)
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.windowListTitle') -Width (Get-FujiScaled 600) -Height (Get-FujiScaled 440)
    $help = New-FujiLabel -Text (Get-FujiText 'gui.windowListHelp') -MaxWidth (Get-FujiScaled 580)
    $help.Dock = [System.Windows.Forms.DockStyle]::Top
    $lb = New-Object -TypeName System.Windows.Forms.ListBox
    $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lb.IntegralHeight = $false
    foreach ($t in $titles) { [void]$lb.Items.Add($t) }
    $bar = New-FujiButtonBar
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-FujiButton -Text (Get-FujiText 'gui.ok')
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    if ($titles.Count -eq 0) { [void]$lb.Items.Add((Get-FujiText 'gui.windowNone')); $lb.Enabled = $false; $ok.Enabled = $false } else { $lb.SelectedIndex = 0 }
    $lb.Add_DoubleClick({ if ($this.SelectedIndex -ge 0) { $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK } })
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    [void]$f.Controls.Add($lb)
    [void]$f.Controls.Add($help)
    [void]$f.Controls.Add($bar)
    $result = Show-FujiDialog -Form $f
    $title = ''
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $titles.Count -gt 0 -and $lb.SelectedIndex -ge 0) { $title = [string]$lb.SelectedItem }
    $f.Dispose()
    if (-not $title) { return }
    $script:Ui.Target.Text = $title
    Set-FujiTargetWindowUi
}

# ----------------------------------------------------------------- templates
# Read on first use (a 200 KB file: reading it at start made the window slow to open)
$script:Templates = $null
function Get-FujiTemplateData {
    if ($null -eq $script:Templates) {
        $script:Templates = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path (Join-Path $script:Ed.Directory 'fujikyun_templates.json'))
    }
    return $script:Templates
}

function Show-FujiTemplateGallery {
    $all = (Get-FujiTemplateData)['templates']
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.templateTitle' $all.Count) -Width (Get-FujiScaled 1000) -Height (Get-FujiScaled 640)
    $f.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList (Get-FujiScaled 600), (Get-FujiScaled 400)
    $topRow = New-FujiFlow
    $topRow.Dock = [System.Windows.Forms.DockStyle]::Top
    $topRow.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6)
    [void]$topRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.templateHelp') -MaxWidth (Get-FujiScaled 960)))
    [void]$topRow.SetFlowBreak($topRow.Controls[0], $true)
    [void]$topRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.category')))
    $cats = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $cats.Add((Get-FujiText 'gui.allCategories'))
    foreach ($c in (Get-FujiTemplateData)['categories']) { $cats.Add([string]$c) }
    $combo = New-FujiComboBox -Items $cats.ToArray() -Values $cats.ToArray() -Width (Get-FujiScaled 280)
    [void]$topRow.Controls.Add($combo)
    $split = New-Object -TypeName System.Windows.Forms.SplitContainer
    # A new SplitContainer is 150 px wide: size it before placing the splitter
    $split.Size = $f.ClientSize
    $split.SplitterDistance = Get-FujiScaled 420
    $split.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lb = New-Object -TypeName System.Windows.Forms.ListBox
    $lb.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lb.IntegralHeight = $false
    $details = New-Object -TypeName System.Windows.Forms.TextBox
    $details.Dock = [System.Windows.Forms.DockStyle]::Fill
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $details.BackColor = [System.Drawing.Color]::White
    [void]$split.Panel1.Controls.Add($lb)
    [void]$split.Panel2.Controls.Add($details)
    $bar = New-FujiButtonBar
    $close = New-FujiButton -Text (Get-FujiText 'gui.close')
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $create = New-FujiButton -Text (Get-FujiText 'gui.create')
    $create.Font = $script:Ui.BoldFont
    $create.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$bar.Controls.Add($close)
    [void]$bar.Controls.Add($create)
    $f.AcceptButton = $create
    $f.CancelButton = $close
    [void]$f.Controls.Add($split)
    [void]$f.Controls.Add($topRow)
    [void]$f.Controls.Add($bar)
    $script:Ui.Gallery = @{ List = $lb; Details = $details; Shown = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Combo = $combo }
    $combo.Add_SelectedIndexChanged({ Invoke-FujiUi { Update-FujiTemplateList } })
    $lb.Add_SelectedIndexChanged({ Invoke-FujiUi { Update-FujiTemplateDetail } })
    $lb.Add_DoubleClick({ if ($this.SelectedIndex -ge 0) { $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK } })
    $combo.SelectedIndex = 0
    $result = Show-FujiDialog -Form $f
    $chosen = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $lb.SelectedIndex -ge 0) { $chosen = $script:Ui.Gallery.Shown[$lb.SelectedIndex] }
    $f.Dispose()
    $script:Ui.Gallery = $null
    return $chosen
}

function Update-FujiTemplateList {
    $gal = $script:Ui.Gallery
    $cat = ''
    if ($gal.Combo.SelectedIndex -gt 0) { $cat = [string]$gal.Combo.SelectedItem }
    $gal.Shown.Clear()
    $gal.List.BeginUpdate()
    $gal.List.Items.Clear()
    foreach ($t in (Get-FujiTemplateData)['templates']) {
        if ($cat -and $t['category'] -ne $cat) { continue }
        $gal.Shown.Add($t)
        [void]$gal.List.Items.Add((Get-FujiText 'gui.templateItem' (Get-FujiText ('gui.levels.' + $t['level'])) $t['name']))
    }
    $gal.List.EndUpdate()
    if ($gal.List.Items.Count -gt 0) { $gal.List.SelectedIndex = 0 } else { $gal.Details.Text = '' }
}

function Update-FujiTemplateDetail {
    $gal = $script:Ui.Gallery
    $i = $gal.List.SelectedIndex
    if ($i -lt 0) { $gal.Details.Text = ''; return }
    $t = $gal.Shown[$i]
    $target = [string]$t['targetWindow']
    if (-not $target) { $target = Get-FujiText 'gui.tplNoTarget' }
    $level = Get-FujiText ('gui.levels.' + $t['level'])
    $prepare = Join-FujiTextList -Items $t['prepare'] -Separator (Get-FujiText 'gui.tplJoin')
    $customize = Join-FujiTextList -Items $t['customize'] -Separator (Get-FujiText 'gui.tplLines')
    $steps = $t['steps']
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add((Get-FujiText 'gui.templateItem' $level $t['name']))
    $lines.Add('')
    $lines.Add([string]$t['summary'])
    $lines.Add('')
    $lines.Add((Get-FujiText 'gui.tplUseCase' $t['useCase']))
    $lines.Add('')
    $lines.Add((Get-FujiText 'gui.tplPrepare' $prepare))
    $lines.Add('')
    $lines.Add((Get-FujiText 'gui.tplCustomize' $customize))
    $lines.Add('')
    $lines.Add((Get-FujiText 'gui.tplMeta' $target $t['csvFile'] $steps.Count))
    $gal.Details.Text = [string]::Join("`r`n", $lines.ToArray())
}

# Items of a list from a JSON file joined into one text. A plain loop on purpose: "@(...)" around
# such a list failed on Windows PowerShell 5.1 with "argument types do not match"
function Join-FujiTextList {
    param($Items, [string]$Separator)
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($x in $Items) { $parts.Add([string]$x) }
    return [string]::Join($Separator, $parts.ToArray())
}

function New-FujiMacroFromTemplateUi {
    $tpl = Show-FujiTemplateGallery
    if ($null -eq $tpl) { return }
    $name = New-FujiMacroFromTemplate -Editor $script:Ed -Template $tpl
    Update-FujiAll
    try {
        $csvPath = Write-FujiTemplateCsv -Editor $script:Ed -Template $tpl
        if ($csvPath) {
            $script:Refreshing = $true
            try {
                $script:Ui.CsvPath.Text = $csvPath
                $script:Ui.CsvHeader.Checked = $true
                $script:Ui.CsvEncoding.SelectedIndex = 0
            } finally {
                $script:Refreshing = $false
            }
            Import-FujiCsvUi
            Write-FujiUiLog -Message (Get-FujiText 'editor.templateCsvOptions')
        }
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'editor.templateCsvFailed' $_.Exception.Message) -Level 'warn'
    }
    $lines = Get-FujiText 'gui.tplLines'
    Show-FujiMessage -Title (Get-FujiText 'gui.templateDoneTitle') -Message (Get-FujiText 'editor.templateDone' $name (Join-FujiTextList -Items $tpl['prepare'] -Separator $lines) (Join-FujiTextList -Items $tpl['customize'] -Separator $lines))
}

# ----------------------------------------------------------------- CSV
function Select-FujiCsvFileUi {
    $dlg = New-Object -TypeName System.Windows.Forms.OpenFileDialog
    $dlg.Filter = Get-FujiText 'gui.csvFilter'
    $current = $script:Ui.CsvPath.Text.Trim().Trim('"')
    if ($current -and (Test-Path -LiteralPath $current -PathType Leaf)) { $dlg.InitialDirectory = Split-Path -Path $current -Parent } else { $dlg.InitialDirectory = $script:Ed.Directory }
    try {
        if ($dlg.ShowDialog($script:Ui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:Ui.CsvPath.Text = $dlg.FileName
    } finally {
        $dlg.Dispose()
    }
    Import-FujiCsvUi
}

function Import-FujiCsvUi {
    $enc = [string]([object[]]$script:Ui.CsvEncoding.Tag)[$script:Ui.CsvEncoding.SelectedIndex]
    $res = Import-FujiEditorCsv -Editor $script:Ed -Path $script:Ui.CsvPath.Text -Encoding $enc -HasHeader $script:Ui.CsvHeader.Checked
    if ($res.HeaderForced) {
        $script:Refreshing = $true
        try { $script:Ui.CsvHeader.Checked = $true } finally { $script:Refreshing = $false }
    }
    Update-FujiCsvInfo
}

function Set-FujiCsvHeaderUi {
    if ($script:Refreshing -or @($script:Ed.Csv.Records).Count -eq 0) { return }
    Set-FujiCsvHeader -Editor $script:Ed -HasHeader $script:Ui.CsvHeader.Checked
    Write-FujiUiLog -Message (Get-FujiText 'editor.csv.headerToggled' (@($script:Ed.Csv.Rows).Count))
    Update-FujiCsvInfo
}

# ----------------------------------------------------------------- steps
function Add-FujiStepUi {
    param([Parameter(Mandatory)][string]$Cmd)
    $step = Show-FujiStepDialog -Cmd $Cmd
    if ($null -eq $step) { return }
    [void](Add-FujiEditorStep -Editor $script:Ed -Step $step)
    Update-FujiAll
}

function Edit-FujiStepUi {
    $steps = Get-FujiCurrentStepList $script:Ed
    $i = $script:Ed.Selected
    if ($i -lt 0 -or $i -ge $steps.Count) { return }
    $step = $steps[$i]
    $def = Get-FujiCommandDef $step.cmd
    if ($def['format'] -eq 'none') {
        $text = Get-FujiText 'gui.markerText'
        if ((Test-FujiBlockEnd $step.cmd) -or (Test-FujiBlockMiddle $step.cmd)) { $text += Get-FujiText 'gui.markerChild' }
        Show-FujiMessage -Title ([string]$def['icon'] + ' ' + [string]$def['title']) -Message $text
        return
    }
    $updated = Show-FujiStepDialog -Cmd $step.cmd -Step $step
    if ($null -eq $updated) { return }
    Set-FujiEditorStep -Editor $script:Ed -Index $i -Updated $updated
    Update-FujiAll
}

function Remove-FujiStepUi {
    $i = $script:Ed.Selected
    if ($i -lt 0 -or $i -ge (Get-FujiCurrentStepList $script:Ed).Count) { return }
    $block = Get-FujiEditorBlock -Editor $script:Ed -Index $i
    if ($null -eq $block) {
        Remove-FujiEditorStep -Editor $script:Ed -Index $i -Mode 'Step'
    } else {
        $answer = Show-FujiChoice -Title (Get-FujiText 'gui.deleteBlockTitle' $block.Kind) -Message (Get-FujiText 'gui.deleteBlockText' $block.Kind $block.Name) -Buttons @((Get-FujiText 'gui.deleteAll'), (Get-FujiText 'gui.unwrap'), (Get-FujiText 'gui.cancel'))
        if ($answer -eq 0) { Remove-FujiEditorStep -Editor $script:Ed -Index $i -Mode 'All' }
        elseif ($answer -eq 1) { Remove-FujiEditorStep -Editor $script:Ed -Index $i -Mode 'Frame' }
        else { return }
    }
    Update-FujiAll
}

function Move-FujiStepUi {
    param([int]$Direction)
    if (Move-FujiEditorStep -Editor $script:Ed -Direction $Direction) { Update-FujiAll }
}

function Restore-FujiHistoryUi {
    if ($script:Refreshing) { return }
    $c = $script:Ui.History
    if ($c.SelectedIndex -lt 0) { return }
    $pos = [int]([object[]]$c.Tag)[$c.SelectedIndex]
    if (Restore-FujiHistory -Editor $script:Ed -Position $pos) { Update-FujiAll }
}

# ----------------------------------------------------------------- save, close, keys
function Save-FujiUi {
    if ($script:Ed.SaveBlockReason) {
        $answer = Show-FujiChoice -Title (Get-FujiText 'gui.saveConfirmTitle') -Message (Get-FujiText 'gui.saveConfirm' $script:Ed.SaveBlockReason) -Buttons @((Get-FujiText 'gui.cancel'), (Get-FujiText 'gui.overwrite'))
        if ($answer -ne 1) { return }
        $script:Ed.SaveBlockReason = ''
    }
    $err = Save-FujiEditorData -Editor $script:Ed
    if ($err) { Show-FujiMessage -Title (Get-FujiText 'gui.saveErrorTitle') -Message (Get-FujiText 'gui.saveError' $err) }
    Update-FujiSaveState
}

function Confirm-FujiClose {
    param([Parameter(Mandatory)]$CloseEvent)
    if ($script:RunCtl.Running) {
        $CloseEvent.Cancel = $true
        Write-FujiUiLog -Message (Get-FujiText 'gui.closeRunning') -Level 'warn'
        return
    }
    if ($null -ne $script:Rec) { [FujiRecorder]::StopRequested = $true }
    if (-not $script:Ed.Dirty) { return }
    $answer = Show-FujiChoice -Title (Get-FujiText 'gui.closeDirtyTitle') -Message (Get-FujiText 'gui.closeDirty') -Buttons @((Get-FujiText 'gui.yes'), (Get-FujiText 'gui.no'))
    if ($answer -ne 0) { $CloseEvent.Cancel = $true }
}

function Invoke-FujiShortcut {
    param([Parameter(Mandatory)]$KeyEvent)
    $k = $KeyEvent.KeyCode
    $keys = [System.Windows.Forms.Keys]
    if ($KeyEvent.Control -and $k -eq $keys::S -and -not $script:RunCtl.Running) {
        $KeyEvent.SuppressKeyPress = $true
        Save-FujiUi
        return
    }
    if ($script:RunCtl.Running) {
        if ($k -eq $keys::Escape) {
            $script:RunCtl.StopReason = Get-FujiText 'run.stopEsc'
            $KeyEvent.SuppressKeyPress = $true
        }
        return
    }
    $active = $script:Ui.Form.ActiveControl
    if ($active -is [System.Windows.Forms.TextBoxBase] -or $active -is [System.Windows.Forms.ComboBox]) { return }
    $handled = $true
    if ($KeyEvent.Control -and $k -eq $keys::Z) { if (Undo-FujiEditorChange -Editor $script:Ed) { Update-FujiAll } }
    elseif ($KeyEvent.Control -and $k -eq $keys::Y) { if (Redo-FujiEditorChange -Editor $script:Ed) { Update-FujiAll } }
    elseif ($KeyEvent.Control -and $k -eq $keys::D) { if (Copy-FujiEditorStep -Editor $script:Ed) { Update-FujiAll } }
    elseif ($KeyEvent.Control -and ($k -eq $keys::OemQuestion -or $k -eq $keys::Divide)) { if (Switch-FujiEditorStepDisabled -Editor $script:Ed) { Update-FujiAll } }
    elseif ($KeyEvent.Alt -and $k -eq $keys::Up) { Move-FujiStepUi -Direction -1 }
    elseif ($KeyEvent.Alt -and $k -eq $keys::Down) { Move-FujiStepUi -Direction 1 }
    elseif ($k -eq $keys::Delete -and $script:Ed.Selected -ge 0) { Remove-FujiStepUi }
    elseif ($k -eq $keys::Enter -and $script:Ed.Selected -ge 0 -and $active -isnot [System.Windows.Forms.ButtonBase]) { Edit-FujiStepUi }
    elseif ($k -eq $keys::Escape) {
        $script:Ui.List.ClearSelected()
        $script:Ed.Selected = -1
        Update-FujiInsertHint
    } else { $handled = $false }
    if ($handled) { $KeyEvent.SuppressKeyPress = $true; $KeyEvent.Handled = $true }
}
