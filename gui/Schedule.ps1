# ---------------------------------------------------------------------------------------------
#  Schedules from the window: the list dialog, the 20-second check while the app is open, Windows
#  scheduled tasks (ScheduledTasks module) that start the app with -AutoRun <id>
# ---------------------------------------------------------------------------------------------

$script:Settings = $null
$script:AutoRunId = ''
$script:AutoClose = @{ Timer = $null; Elapsed = 0; Enabled = $false }

function Initialize-FujiSchedule {
    $script:Settings = Read-FujiSetting -Directory $script:Ed.Directory
    $t = New-Object -TypeName System.Windows.Forms.Timer
    $t.Interval = 20000
    $t.Add_Tick({ Invoke-FujiUi { Invoke-FujiScheduleCheck } })
    $t.Start()
    $script:Ui.ScheduleTimer = $t
    Update-FujiScheduleState
}

function Save-FujiScheduleSetting {
    try {
        Save-FujiSetting -Directory $script:Ed.Directory -Settings $script:Settings
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'editor.saveFailed' $_.Exception.Message) -Level 'error'
    }
    Update-FujiScheduleState
}

function Get-FujiScheduleMacro {
    param([System.Collections.IDictionary]$Schedule)
    foreach ($m in $script:Ed.Data.macros) { if ($m.id -eq [string](Get-FujiScheduleValue $Schedule 'macroId')) { return $m } }
    foreach ($m in $script:Ed.Data.macros) { if ($m.name -eq [string](Get-FujiScheduleValue $Schedule 'macroName')) { return $m } }
    return $null
}

function Update-FujiScheduleState {
    $label = $script:Ui['ScheduleState']
    if ($null -eq $label -or $null -eq $script:Settings) { return }
    $now = Get-Date
    $next = Get-FujiNextSchedule -Schedules $script:Settings.schedules -Now $now
    if ($null -eq $next) { $label.Text = ''; return }
    $day = Get-FujiText 'schedule.today'
    if ($next.Day.Date -ne $now.Date) { $day = Get-FujiText 'schedule.dayFormat' $next.Day.Month $next.Day.Day }
    $m = Get-FujiScheduleMacro -Schedule $next.Schedule
    $name = [string](Get-FujiScheduleValue $next.Schedule 'macroName')
    if ($null -ne $m) { $name = $m.name }
    $label.Text = Get-FujiText 'schedule.next' $day $next.Schedule.time (Format-FujiShort $name 16)
}

function Test-FujiDialogOpen {
    return ([System.Windows.Forms.Application]::OpenForms.Count -gt 1)
}

function Invoke-FujiScheduleCheck {
    Update-FujiScheduleState
    if ($script:RunCtl.Running -or $null -ne $script:Rec) { return }
    $now = Get-Date
    foreach ($s in $script:Settings.schedules) {
        if (Test-FujiScheduleDue -Schedule $s -Now $now) {
            if (Test-FujiDialogOpen) {
                Write-FujiUiLog -Message (Get-FujiText 'schedule.waitDialog') -Level 'warn'
                return
            }
            [void](Invoke-FujiSchedule -Schedule $s)
            return
        }
    }
}

# Runs a schedule now. Returns the run status, or '' when it did not start.
function Invoke-FujiSchedule {
    param([System.Collections.IDictionary]$Schedule)
    $Schedule['lastRun'] = Format-FujiDate -Date (Get-Date)
    Save-FujiScheduleSetting
    $macro = Get-FujiScheduleMacro -Schedule $Schedule
    if ($null -eq $macro) {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.macroMissing' (Get-FujiScheduleValue $Schedule 'macroName')) -Level 'error'
        return ''
    }
    $script:Ed.MacroIndex = $script:Ed.Data.macros.IndexOf($macro)
    $script:Ed.Selected = -1
    Update-FujiAll
    $csv = [string](Get-FujiScheduleValue $Schedule 'csvPath')
    if ($csv.Trim()) {
        $script:Refreshing = $true
        try {
            $script:Ui.CsvPath.Text = $csv
            $script:Ui.CsvHeader.Checked = [bool](Get-FujiScheduleValue $Schedule 'header' $true)
        } finally {
            $script:Refreshing = $false
        }
        Import-FujiCsvUi
        if ($script:Ed.Csv.Path -ne $csv.Trim().Trim('"')) {
            Write-FujiUiLog -Message (Get-FujiText 'schedule.csvFailed' $csv) -Level 'error'
            return ''
        }
    } else {
        $script:Ed.Csv = New-FujiCsvState
        Update-FujiCsvInfo
    }
    $script:Ui.StartRow.Text = '1'
    $script:Ui.EndRow.Text = ''
    Write-FujiUiLog -Message (Get-FujiText 'schedule.starting' $macro.name) -Level 'run'
    $status = Start-FujiRunUi -Unattended
    Update-FujiScheduleState
    return $status
}

# ----------------------------------------------------------------- started by a Windows task
function Start-FujiAutoRun {
    if (-not $script:AutoRunId) { return }
    $s = $null
    foreach ($x in $script:Settings.schedules) { if ($x.id -eq $script:AutoRunId) { $s = $x } }
    if ($null -eq $s) {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.autoMissing' $script:AutoRunId) -Level 'warn'
        return
    }
    Write-FujiUiLog -Message (Get-FujiText 'schedule.autoStart') -Level 'run'
    $t = New-Object -TypeName System.Windows.Forms.Timer
    $t.Interval = 5000
    $t.Tag = $s
    $t.Add_Tick({
            $this.Stop()
            $sched = $this.Tag
            Invoke-FujiUi {
                if ($script:RunCtl.Running -or (Test-FujiDialogOpen)) {
                    Write-FujiUiLog -Message (Get-FujiText 'schedule.autoBusy') -Level 'warn'
                    return
                }
                $status = Invoke-FujiSchedule -Schedule $sched
                if ($status -eq 'done' -and [bool](Get-FujiScheduleValue $sched 'closeAfter' $false)) { Start-FujiAutoClose }
            }
        })
    $t.Start()
}

# Closes the app 10 seconds after a scheduled run finished, unless someone clicks meanwhile
function Start-FujiAutoClose {
    Write-FujiUiLog -Message (Get-FujiText 'schedule.autoClose') -Level 'warn'
    $c = $script:AutoClose
    $c.Elapsed = 0
    $c.Enabled = $true
    if ($null -eq $c.Timer) {
        $c.Timer = New-Object -TypeName System.Windows.Forms.Timer
        $c.Timer.Interval = 250
        $c.Timer.Add_Tick({
                $a = $script:AutoClose
                if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) {
                    $a.Enabled = $false
                    $this.Stop()
                    return
                }
                $a.Elapsed += 250
                if ($a.Elapsed -ge 10000) {
                    $this.Stop()
                    if (-not $script:RunCtl.Running -and -not $script:Ed.Dirty) { $script:Ui.Form.Close() }
                }
            })
    }
    $c.Timer.Start()
}

# ----------------------------------------------------------------- Windows scheduled tasks
function Get-FujiTaskName {
    param([System.Collections.IDictionary]$Schedule)
    return ('FujikyunRPA_PS_' + $Schedule.id)
}

function Register-FujiScheduleTask {
    param([System.Collections.IDictionary]$Schedule)
    $name = Get-FujiTaskName -Schedule $Schedule
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AutoRun {1}' -f $script:AppScriptPath, $Schedule.id
        $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $script:Ed.Directory
        $mins = Get-FujiScheduleMinute $Schedule
        $at = [datetime]::Today.AddMinutes($mins)
        switch ([string](Get-FujiScheduleValue $Schedule 'repeat')) {
            'WEEKDAYS' { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $at }
            'ONCE' { $trigger = New-ScheduledTaskTrigger -Once -At ((ConvertFrom-FujiDateText -Text ([string](Get-FujiScheduleValue $Schedule 'date'))).AddMinutes($mins)) }
            default { $trigger = New-ScheduledTaskTrigger -Daily -At $at }
        }
        # A task of the signed-in user: it runs only while that user is signed in (the robot needs the screen)
        [void](Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Description (Get-FujiText 'schedule.taskDescription') -Force -ErrorAction Stop)
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.registerFailed' $_.Exception.Message) -Level 'error'
        return
    }
    $Schedule['taskName'] = $name
    Save-FujiScheduleSetting
    Write-FujiUiLog -Message (Get-FujiText 'schedule.registered2' $name) -Level 'ok'
}

function Unregister-FujiScheduleTask {
    param([System.Collections.IDictionary]$Schedule)
    $name = [string](Get-FujiScheduleValue $Schedule 'taskName')
    if (-not $name) { return }
    try {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-FujiUiLog -Message (Get-FujiText 'schedule.unregistered') -Level 'ok'
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.unregisterFailed' $_.Exception.Message) -Level 'warn'
    }
    $Schedule.Remove('taskName')
    Save-FujiScheduleSetting
}

# ----------------------------------------------------------------- the dialog
function Show-FujiScheduleDialog {
    $width = Get-FujiScaled 940
    $f = New-FujiDialogForm -Title (Get-FujiText 'schedule.title') -Width $width -Height (Get-FujiScaled 640)
    $f.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList (Get-FujiScaled 640), (Get-FujiScaled 480)
    $help = New-FujiLabel -Text (Get-FujiText 'schedule.help') -MaxWidth ($width - (Get-FujiScaled 30))
    $help.Dock = [System.Windows.Forms.DockStyle]::Top
    $help.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6)
    $lv = New-Object -TypeName System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    foreach ($c in @(@('schedule.colTime', 70), @('schedule.colRepeat', 150), @('schedule.colMacro', 240), @('schedule.colCsv', 260), @('schedule.colState', 170))) {
        [void]$lv.Columns.Add((Get-FujiText $c[0]), (Get-FujiScaled $c[1]))
    }
    # buttons for the selected schedule
    $actions = New-FujiFlow
    $actions.Dock = [System.Windows.Forms.DockStyle]::Bottom
    foreach ($b in @(@('toggle', 'schedule.toggleOff'), @('register', 'schedule.register'), @('unregister', 'schedule.unregister'), @('delete', 'schedule.delete'))) {
        $btn = New-FujiButton -Text (Get-FujiText $b[1]) -Tag $b[0]
        $btn.Add_Click({ $what = [string]$this.Tag; Invoke-FujiUi { Invoke-FujiScheduleAction -Action $what } })
        [void]$actions.Controls.Add($btn)
    }
    # the add form
    $add = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $add.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $add.AutoSize = $true
    $add.ColumnCount = 2
    $add.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
    $title = New-FujiLabel -Text (Get-FujiText 'schedule.addTitle')
    $title.Font = $script:Ui.BoldFont
    $add.Controls.Add($title, 0, 0)
    $add.SetColumnSpan($title, 2)
    $labels = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $values = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($m in $script:Ed.Data.macros) { $labels.Add([string]$m.name); $values.Add([string]$m.id) }
    $macro = New-FujiComboBox -Items $labels.ToArray() -Values $values.ToArray() -Width (Get-FujiScaled 420)
    if ($macro.Items.Count -gt 0) { $macro.SelectedIndex = [Math]::Max(0, $script:Ed.MacroIndex) }
    $csv = New-FujiTextBox -Text ([string]$script:Ed.Csv.Path) -Width (Get-FujiScaled 560)
    $header = New-FujiCheck -Text (Get-FujiText 'schedule.header') -Checked $true
    $time = New-FujiTextBox -Width (Get-FujiScaled 90)
    $repLabels = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($r in $script:FujiScheduleRepeats) { $repLabels.Add((Get-FujiScheduleRepeatName $r)) }
    $repeat = New-FujiComboBox -Items $repLabels.ToArray() -Values $script:FujiScheduleRepeats -Width (Get-FujiScaled 200)
    $repeat.SelectedIndex = 0
    $date = New-FujiTextBox -Width (Get-FujiScaled 130)
    $close = New-FujiCheck -Text (Get-FujiText 'schedule.closeAfter') -Checked $false
    $err = New-FujiLabel -Text ''
    $err.ForeColor = Get-FujiColor '#c62828'
    $row = 1
    foreach ($pair in @(@('schedule.macro', $macro), @('schedule.csv', $csv), @('', $header), @('schedule.time', $time), @('schedule.colRepeat', $repeat), @('schedule.date', $date), @('', $close), @('', $err))) {
        if ($pair[0]) { $add.Controls.Add((New-FujiLabel -Text (Get-FujiText $pair[0])), 0, $row) }
        $add.Controls.Add($pair[1], 1, $row)
        $row++
    }
    $addButton = New-FujiButton -Text (Get-FujiText 'schedule.add')
    $addButton.Font = $script:Ui.BoldFont
    $addButton.Add_Click({ Invoke-FujiUi { Add-FujiScheduleFromDialog } })
    $add.Controls.Add($addButton, 1, $row)
    $bar = New-FujiButtonBar
    $closeButton = New-FujiButton -Text (Get-FujiText 'gui.close')
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void]$bar.Controls.Add($closeButton)
    $f.CancelButton = $closeButton
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($help)
    [void]$f.Controls.Add($actions)
    [void]$f.Controls.Add($add)
    [void]$f.Controls.Add($bar)
    $script:Ui.SchedDlg = @{ List = $lv; Macro = $macro; Csv = $csv; Header = $header; Time = $time; Repeat = $repeat; Date = $date; Close = $close; Error = $err; Toggle = $actions.Controls[0] }
    $f.Add_Shown({ $native = Get-FujiNativeType; [void]$native::SendMessage($script:Ui.SchedDlg.Time.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.timeCue')); [void]$native::SendMessage($script:Ui.SchedDlg.Date.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.dateCue')) })
    $lv.Add_SelectedIndexChanged({ Invoke-FujiUi { Update-FujiScheduleToggleText } })
    Update-FujiScheduleList
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
    $script:Ui.SchedDlg = $null
}

function Update-FujiScheduleList {
    $d = $script:Ui.SchedDlg
    $lv = $d.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($s in $script:Settings.schedules) {
        $m = Get-FujiScheduleMacro -Schedule $s
        $macroText = Get-FujiText 'schedule.missingMacro' (Get-FujiScheduleValue $s 'macroName')
        if ($null -ne $m) { $macroText = $m.name }
        $csv = [string](Get-FujiScheduleValue $s 'csvPath')
        if (-not $csv) { $csv = Get-FujiText 'schedule.noCsv' }
        $state = Get-FujiText 'schedule.disabled'
        if (Get-FujiScheduleValue $s 'enabled' $false) { $state = Get-FujiText 'schedule.enabled' }
        if (Get-FujiScheduleValue $s 'taskName') { $state += Get-FujiText 'schedule.registered' }
        $repeat = Get-FujiScheduleRepeatName ([string](Get-FujiScheduleValue $s 'repeat'))
        if (Get-FujiScheduleValue $s 'date') { $repeat += ' ' + $s.date }
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList ([string]$s.time)
        foreach ($sub in @($repeat, $macroText, $csv, $state)) { [void]$item.SubItems.Add([string]$sub) }
        $item.Tag = $s
        [void]$lv.Items.Add($item)
    }
    $lv.EndUpdate()
    if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
    Update-FujiScheduleToggleText
}

function Get-FujiSelectedSchedule {
    $lv = $script:Ui.SchedDlg.List
    if ($lv.SelectedItems.Count -eq 0) { return $null }
    return $lv.SelectedItems[0].Tag
}

function Update-FujiScheduleToggleText {
    $s = Get-FujiSelectedSchedule
    $key = 'schedule.toggleOff'
    if ($null -ne $s -and -not (Get-FujiScheduleValue $s 'enabled' $false)) { $key = 'schedule.toggleOn' }
    $script:Ui.SchedDlg.Toggle.Text = Get-FujiText $key
}

function Invoke-FujiScheduleAction {
    param([string]$Action)
    $s = Get-FujiSelectedSchedule
    if ($null -eq $s) { return }
    switch ($Action) {
        'toggle' { $s['enabled'] = -not [bool](Get-FujiScheduleValue $s 'enabled' $false); Save-FujiScheduleSetting }
        'register' { Register-FujiScheduleTask -Schedule $s }
        'unregister' { Unregister-FujiScheduleTask -Schedule $s }
        'delete' {
            Unregister-FujiScheduleTask -Schedule $s
            [void]$script:Settings.schedules.Remove($s)
            Save-FujiScheduleSetting
        }
    }
    Update-FujiScheduleList
}

function Add-FujiScheduleFromDialog {
    $d = $script:Ui.SchedDlg
    if ($d.Macro.SelectedIndex -lt 0) { return }
    $macroId = [string]([object[]]$d.Macro.Tag)[$d.Macro.SelectedIndex]
    $repeat = [string]([object[]]$d.Repeat.Tag)[$d.Repeat.SelectedIndex]
    $r = New-FujiSchedule -MacroId $macroId -MacroName ([string]$d.Macro.SelectedItem) -CsvPath $d.Csv.Text -Header $d.Header.Checked -Time $d.Time.Text -Repeat $repeat -DateText $d.Date.Text -CloseAfter $d.Close.Checked
    if ($r.ContainsKey('Error')) { $d.Error.Text = $r.Error; return }
    $d.Error.Text = ''
    $script:Settings.schedules.Add($r.Schedule)
    Save-FujiScheduleSetting
    Write-FujiUiLog -Message (Get-FujiText 'schedule.added' (Get-FujiScheduleRepeatName $repeat) $r.Schedule.time $r.Schedule.macroName) -Level 'ok'
    Update-FujiScheduleList
}
