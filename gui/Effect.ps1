# ---------------------------------------------------------------------------------------------
#  Effect (rules: src/Effect.ps1): the record written after every run, the "effect" dialog (hand
#  work taken over per macro and month), and the step times of the last run
# ---------------------------------------------------------------------------------------------

# The record of the last run, until its error alert is answered: @{ Start; MacroId; Acked }
$script:LastRunRecord = $null

# After a run: one line in fujikyun_runs.csv. A file that cannot be written only gets a log line.
function Save-FujiRunRecordUi {
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$How)
    $rec = New-FujiRunRecord -Run $Run -How $How
    try {
        Add-FujiRunRecord -Directory $script:Ed.Directory -Record $rec
        $script:LastRunRecord = @{ Start = $rec.start; MacroId = $rec.macroId; Acked = ($Run.Status -ne 'error') }
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'effect.recordFailed' $_.Exception.Message) -Level 'warn'
    }
}

# The error alert of the last run was answered: how long the stop waited goes into its record
function Save-FujiRunAckUi {
    param([datetime]$Since)
    $r = $script:LastRunRecord
    if ($null -eq $r -or $r.Acked) { return }
    $r.Acked = $true
    try {
        [void](Set-FujiRunRecordAck -Directory $script:Ed.Directory -Start $r.Start -MacroId $r.MacroId -Seconds ([int][Math]::Round(((Get-Date) - $Since).TotalSeconds)))
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'effect.recordFailed' $_.Exception.Message) -Level 'warn'
    }
}

# The editing time counted so far into fujikyun_edits.csv (on save, on close, before the dialog)
function Save-FujiEditTimeUi {
    try { Save-FujiEditTime -Editor $script:Ed } catch { Write-FujiUiLog -Message (Get-FujiText 'effect.recordFailed' $_.Exception.Message) -Level 'warn' }
}

# ----------------------------------------------------------------- step times of the last run
function Show-FujiStepTimeDialog {
    $title = Get-FujiText 'steptime.title'
    if ($null -eq $script:Run -or $script:Run.StepTimes.Count -eq 0) { Show-FujiMessage -Title $title -Message (Get-FujiText 'steptime.none'); return }
    $rows = Get-FujiStepTimeRow -Run $script:Run
    $f = New-FujiDialogForm -Title $title -Width (Get-FujiScaled 900) -Height (Get-FujiScaled 520)
    $f.MaximizeBox = $true
    $lv = New-FujiListView -Headings (Get-FujiText 'steptime.head') -Widths @(160, 50, 330, 60, 80, 80, 80, 60) -LeftColumns @(0, 2)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($r in $rows) {
        $avg = 0.0
        if ($r.Count -gt 0) { $avg = $r.TotalMs / $r.Count }
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList ([string]$r.Macro)
        foreach ($v in @([string]($r.Index + 1), [string]$r.Label, [string]$r.Count, ($r.TotalMs / 1000.0).ToString('0.00', $inv), ($avg / 1000.0).ToString('0.00', $inv), ($r.MaxMs / 1000.0).ToString('0.00', $inv), $r.Share.ToString('0.0', $inv))) { [void]$item.SubItems.Add($v) }
        $item.Tag = @($r.MacroId, $r.Index)
        [void]$lv.Items.Add($item)
    }
    Resize-FujiListColumn -List $lv
    $lv.Add_DoubleClick({ $at = $this.SelectedItems[0].Tag; Invoke-FujiUi { [void](Select-FujiStepAt -MacroId ([string]$at[0]) -Index ([int]$at[1])) } })
    $note = New-FujiLabel -Text (Get-FujiText 'steptime.note' (Format-FujiShort ([string]$script:Run.Macro.name) 40) $script:Run.Summary) -MaxWidth (Get-FujiScaled 860)
    $note.Dock = [System.Windows.Forms.DockStyle]::Top
    $bar = New-FujiButtonBar
    $close = New-FujiButton -Text (Get-FujiText 'gui.close')
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void]$bar.Controls.Add($close)
    $copy = New-FujiButton -Text (Get-FujiText 'steptime.copy') -Tip (Get-FujiText 'steptime.copyTip') -Tag (ConvertTo-FujiStepTimeText -Rows $rows)
    $copy.Add_Click({ $t = [string]$this.Tag; Invoke-FujiUi { Copy-FujiTextUi -Text $t } })
    [void]$bar.Controls.Add($copy)
    [void]$bar.Controls.Add((New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.stepTime')))
    $f.CancelButton = $close
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($note)
    [void]$f.Controls.Add($bar)
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
}

# LeftColumns: columns of text (the others hold numbers and are right-aligned)
function New-FujiListView {
    param([object[]]$Headings, [int[]]$Widths, [int[]]$LeftColumns = @(0))
    $lv = New-Object -TypeName System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.MultiSelect = $false
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    for ($i = 0; $i -lt $Headings.Count; $i++) {
        $w = 90
        if ($i -lt $Widths.Count) { $w = $Widths[$i] }
        $align = [System.Windows.Forms.HorizontalAlignment]::Right
        if ($LeftColumns -contains $i) { $align = [System.Windows.Forms.HorizontalAlignment]::Left }
        [void]$lv.Columns.Add([string]$Headings[$i], (Get-FujiScaled $w), $align)
    }
    $lv.Tag = [int[]]@($lv.Columns | ForEach-Object { $_.Width })
    return $lv
}

# Every column as wide as its heading or its widest value, whichever is wider (headings never cut
# off), and at least the width it was made with: text with an emoji is measured too narrow
function Resize-FujiListColumn {
    param([Parameter(Mandatory)][System.Windows.Forms.ListView]$List)
    $least = [int[]]$List.Tag
    $List.AutoResizeColumns([System.Windows.Forms.ColumnHeaderAutoResizeStyle]::ColumnContent)
    $content = @($List.Columns | ForEach-Object { $_.Width })
    $List.AutoResizeColumns([System.Windows.Forms.ColumnHeaderAutoResizeStyle]::HeaderSize)
    for ($i = 0; $i -lt $List.Columns.Count; $i++) {
        $List.Columns[$i].Width = [Math]::Max([Math]::Max($content[$i], $List.Columns[$i].Width) + (Get-FujiScaled 8), $least[$i])
    }
}

function Copy-FujiTextUi {
    param([string]$Text)
    if (Set-FujiClipboard -Text $Text) { Write-FujiUiLog -Message (Get-FujiText 'effect.copied') -Level 'ok' } else { Write-FujiUiLog -Message (Get-FujiText 'diag.copyFailed') -Level 'warn' }
}

# ----------------------------------------------------------------- the effect dialog
function Show-FujiEffectDialog {
    Save-FujiEditTimeUi
    try {
        $runs = Read-FujiRunRecord -Directory $script:Ed.Directory
        $edits = Read-FujiEditRecord -Directory $script:Ed.Directory
    } catch {
        Show-FujiMessage -Title (Get-FujiText 'effect.title') -Message (Get-FujiText 'effect.readFailed' $_.Exception.Message)
        return
    }
    $f = New-FujiDialogForm -Title (Get-FujiText 'effect.title') -Width (Get-FujiScaled 1100) -Height (Get-FujiScaled 600)
    $f.MaximizeBox = $true
    $top = New-FujiFlow
    $top.Dock = [System.Windows.Forms.DockStyle]::Top
    $months = Get-FujiEffectMonth -Runs $runs
    $labels = @((Get-FujiText 'effect.allMonths')) + @($months | ForEach-Object { Get-FujiText 'effect.month' $_ })
    $values = @('') + @($months)
    $period = New-FujiComboBox -Items $labels -Values $values -Width (Get-FujiScaled 160)
    $period.SelectedIndex = 0
    if ($months.Count -gt 0) { $period.SelectedIndex = 1 }
    $effect = Get-FujiEffectSetting -Settings $script:Settings
    $hourlyText = ''
    if ($null -ne $effect.Hourly) { $hourlyText = $effect.Hourly.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    $hourly = New-FujiTextBox -Text $hourlyText -Width (Get-FujiScaled 90)
    $script:Ui.ToolTip.SetToolTip($hourly, (Get-FujiText 'effect.hourlyTip'))
    foreach ($c in @((New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'effect.period')), $period)), (New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'effect.hourly')), $hourly, (New-FujiLabel -Text (Get-FujiText 'effect.yen')))))) { [void]$top.Controls.Add($c) }
    $lv = New-FujiListView -Headings (Get-FujiText 'effect.head') -Widths @(200, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40)
    $edit = New-FujiFlow
    $edit.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $manual = New-FujiTextBox -Width (Get-FujiScaled 70)
    $set = New-FujiButton -Text (Get-FujiText 'effect.setManual')
    $selected = New-FujiLabel -Text (Get-FujiText 'effect.pickMacro')
    $selected.Font = $script:Ui.BoldFont
    foreach ($c in @($selected, (New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'effect.manual')), $manual, (New-FujiLabel -Text (Get-FujiText 'effect.minutes')), $set)))) { [void]$edit.Controls.Add($c) }
    $note = New-FujiLabel -Text (Get-FujiText 'effect.note' $script:FujiEditGapSeconds) -MaxWidth (Get-FujiScaled 1060)
    $note.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $note.ForeColor = Get-FujiColor '#5e5368'
    $bar = New-FujiButtonBar
    $close = New-FujiButton -Text (Get-FujiText 'gui.close')
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $copy = New-FujiButton -Text (Get-FujiText 'effect.copy') -Tip (Get-FujiText 'effect.copyTip')
    $save = New-FujiButton -Text (Get-FujiText 'effect.save') -Tip (Get-FujiText 'effect.saveTip')
    foreach ($c in @($close, $copy, $save, (New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.effect')))) { [void]$bar.Controls.Add($c) }
    $script:Ui.EffectDialog = @{ Runs = $runs; Edits = $edits; Period = $period; Hourly = $hourly; List = $lv; Manual = $manual; Selected = $selected; Table = $null; PickedId = '' }
    $period.Add_SelectedIndexChanged({ Invoke-FujiUi { Update-FujiEffectList } })
    $hourly.Add_Leave({ Invoke-FujiUi { Set-FujiEffectHourlyUi } })
    $hourly.Add_KeyDown({ $e = $_; if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Invoke-FujiUi { Set-FujiEffectHourlyUi } } })
    $lv.Add_SelectedIndexChanged({ Invoke-FujiUi { Select-FujiEffectMacroUi } })
    $set.Add_Click({ Invoke-FujiUi { Set-FujiEffectManualUi } })
    $manual.Add_KeyDown({ $e = $_; if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Invoke-FujiUi { Set-FujiEffectManualUi } } })
    $copy.Add_Click({ Invoke-FujiUi { Copy-FujiTextUi -Text (ConvertTo-FujiTabText -Rows $script:Ui.EffectDialog.Table) } })
    $save.Add_Click({ Invoke-FujiUi { Save-FujiEffectCsvUi } })
    $f.CancelButton = $close
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($top)
    [void]$f.Controls.Add($edit)
    [void]$f.Controls.Add($note)
    [void]$f.Controls.Add($bar)
    Update-FujiEffectList
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
    $script:Ui.EffectDialog = $null
}

function Get-FujiEffectMonthChoice {
    $p = $script:Ui.EffectDialog.Period
    if ($p.SelectedIndex -lt 0) { return '' }
    return [string]([object[]]$p.Tag)[$p.SelectedIndex]
}

function Update-FujiEffectList {
    $d = $script:Ui.EffectDialog
    $summary = Get-FujiEffectSummary -Runs $d.Runs -Edits $d.Edits -Macros $script:Ed.Data.macros -Effect (Get-FujiEffectSetting -Settings $script:Settings) -Month (Get-FujiEffectMonthChoice)
    $d.Table = ConvertTo-FujiEffectTable -Summary $summary
    $ids = @($summary.Rows | ForEach-Object { [string]$_.id }) + @('')
    $lv = $d.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    for ($r = 1; $r -lt $d.Table.Count; $r++) {
        $cells = $d.Table[$r]
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList $cells[0]
        for ($c = 1; $c -lt $cells.Count; $c++) { [void]$item.SubItems.Add($cells[$c]) }
        $item.Tag = $ids[$r - 1]
        if ($r -eq $d.Table.Count - 1) { $item.Font = $script:Ui.BoldFont; $item.BackColor = Get-FujiColor '#f3e5f5' }
        elseif ($cells[8] -eq '') { $item.ForeColor = Get-FujiColor '#8a7f94' }
        [void]$lv.Items.Add($item)
        if ($d.PickedId -and $item.Tag -eq $d.PickedId) { $item.Selected = $true }
    }
    Resize-FujiListColumn -List $lv
    $lv.EndUpdate()
}

function Select-FujiEffectMacroUi {
    $d = $script:Ui.EffectDialog
    if ($null -eq $d -or $d.List.SelectedItems.Count -eq 0) { return }
    $id = [string]$d.List.SelectedItems[0].Tag
    if (-not $id) { return }
    $d.PickedId = $id
    $d.Selected.Text = Get-FujiText 'effect.picked' (Format-FujiShort $d.List.SelectedItems[0].Text 30)
    $m = (Get-FujiEffectSetting -Settings $script:Settings).Manual
    if ($m.ContainsKey($id)) { $d.Manual.Text = $m[$id].ToString([System.Globalization.CultureInfo]::InvariantCulture) } else { $d.Manual.Text = '' }
}

function Set-FujiEffectManualUi {
    $d = $script:Ui.EffectDialog
    if (-not $d.PickedId) { Write-FujiUiLog -Message (Get-FujiText 'effect.pickMacro') -Level 'warn'; return }
    $text = $d.Manual.Text.Trim()
    if ($text -ne '' -and $null -eq (ConvertTo-FujiEffectNumber $text)) { Show-FujiMessage -Title (Get-FujiText 'effect.title') -Message (Get-FujiText 'effect.badNumber' $text); return }
    $value = ''
    if ($text -ne '') { $value = (ConvertTo-FujiEffectNumber $text).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    Set-FujiEffectSetting -Settings $script:Settings -Key 'manual' -MacroId $d.PickedId -Value $value
    if (Save-FujiEffectSettingUi) { Update-FujiEffectList }
}

function Set-FujiEffectHourlyUi {
    $d = $script:Ui.EffectDialog
    $text = $d.Hourly.Text.Trim()
    if ($text -ne '' -and $null -eq (ConvertTo-FujiEffectNumber $text)) { Show-FujiMessage -Title (Get-FujiText 'effect.title') -Message (Get-FujiText 'effect.badNumber' $text); return }
    $value = ''
    if ($text -ne '') { $value = (ConvertTo-FujiEffectNumber $text).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    $now = Get-FujiEffectSetting -Settings $script:Settings
    $old = ''
    if ($null -ne $now.Hourly) { $old = $now.Hourly.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    if ($old -eq $value) { return }
    Set-FujiEffectSetting -Settings $script:Settings -Key 'hourly' -Value $value
    if (Save-FujiEffectSettingUi) { Update-FujiEffectList }
}

function Save-FujiEffectSettingUi {
    try {
        Save-FujiSetting -Directory $script:Ed.Directory -Settings $script:Settings
        return $true
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'editor.saveFailed' $_.Exception.Message) -Level 'error'
        return $false
    }
}

# Rows of text -> tab-separated lines (pasted into Excel as a table)
function ConvertTo-FujiTabText {
    param([object[]]$Rows)
    return ((@($Rows | ForEach-Object { (@($_) | ForEach-Object { ([string]$_) -replace '[\t\r\n]+', ' ' }) -join "`t" }) -join "`r`n") + "`r`n")
}

function Save-FujiEffectCsvUi {
    $d = $script:Ui.EffectDialog
    $month = Get-FujiEffectMonthChoice
    $suffix = 'all'
    if ($month) { $suffix = $month.Replace('/', '') }
    $path = Get-FujiEditorPath $script:Ed ('fujikyun_effect_' + $suffix + '.csv')
    try {
        Write-FujiTextFile -Path $path -Text (ConvertTo-FujiCsvText -Rows $d.Table) -Bom
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'run.saveFailed' $_.Exception.Message) -Level 'error'
        return
    }
    Write-FujiUiLog -Message (Get-FujiText 'effect.saved' $path) -Level 'ok'
    $answer = Show-FujiChoice -Title (Get-FujiText 'effect.title') -Message (Get-FujiText 'effect.savedAsk' $path) -Buttons @((Get-FujiText 'gui.openFolder'), (Get-FujiText 'gui.close'))
    if ($answer -eq 0) { Open-FujiFolder -Path $path }
}
