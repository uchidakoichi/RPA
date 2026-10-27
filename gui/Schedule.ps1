# ---------------------------------------------------------------------------------------------
#  Schedules from the window: the list dialog, the 20-second check while the app is open, Windows
#  scheduled tasks (ScheduledTasks module) that start the app with -AutoRun <id>, and the triggers
#  (a key, a new file, a window) watched every 150 ms while the app is open
# ---------------------------------------------------------------------------------------------

$script:Settings = $null
$script:AutoRunId = ''
$script:AutoClose = @{ Timer = $null; Elapsed = 0; Enabled = $false }

function Initialize-FujiSchedule {
    if ($null -eq $script:Settings) { $script:Settings = Read-FujiSetting -Directory $script:Ed.Directory }
    $t = New-Object -TypeName System.Windows.Forms.Timer
    $t.Interval = 20000
    $t.Add_Tick({ Invoke-FujiUi { Invoke-FujiScheduleCheck } })
    $t.Start()
    $script:Ui.ScheduleTimer = $t
    # triggers: keys are looked at every tick, folders and windows every 3 seconds
    $tt = New-Object -TypeName System.Windows.Forms.Timer
    $tt.Interval = 150
    $tt.Add_Tick({ Invoke-FujiUi { Invoke-FujiTriggerCheck } })
    $tt.Start()
    $script:Ui.TriggerTimer = $tt
    Update-FujiScheduleState
}

# ----------------------------------------------------------------- triggers
$script:TriggerState = @{}
$script:TriggerTick = 0

function Get-FujiTriggerState {
    param([string]$Id)
    if (-not $script:TriggerState.ContainsKey($Id)) {
        $script:TriggerState[$Id] = @{ Started = $false; Down = $false; File = @{ Seen = @{}; Pending = @{} }; Window = @{ Present = $false }; Queue = (New-Object -TypeName 'System.Collections.Generic.List[string]'); Missing = $false }
    }
    return $script:TriggerState[$Id]
}

function Test-FujiHotkeyDown {
    param([hashtable]$Key)
    $native = Get-FujiNativeType
    $down = { param($Vk) (([int]$native::GetAsyncKeyState($Vk)) -band 0x8000) -ne 0 }
    if ($Key.Ctrl -ne (& $down 0x11)) { return $false }
    if ($Key.Alt -ne (& $down 0x12)) { return $false }
    if ($Key.Shift -ne (& $down 0x10)) { return $false }
    return (& $down $Key.Vk)
}

function Invoke-FujiTriggerCheck {
    if ($null -eq $script:Settings) { return }
    $script:TriggerTick++
    $slow = ($script:TriggerTick % 20) -eq 0
    $busy = $script:RunCtl.Running -or $null -ne $script:Rec
    # a copy (not "@(...)" around the List: see Import-FujiEditorCsv)
    foreach ($s in $script:Settings.schedules.ToArray()) {
        $kind = Get-FujiScheduleKind $s
        if ($kind -eq 'TIME' -or -not [bool](Get-FujiScheduleValue $s 'enabled' $false)) { continue }
        $st = Get-FujiTriggerState -Id ([string]$s.id)
        switch ($kind) {
            'HOTKEY' {
                $k = ConvertFrom-FujiHotkeyText -Text ([string](Get-FujiScheduleValue $s 'hotkey'))
                if ($null -eq $k) { continue }
                $down = Test-FujiHotkeyDown -Key $k
                if ($down -and -not $st.Down -and -not $busy) { $st.Queue.Add('') }
                $st.Down = $down
            }
            'FILE' {
                if (-not $slow) { continue }
                $folder = [string](Get-FujiScheduleValue $s 'folder')
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                    if (-not $st.Missing) { Write-FujiUiLog -Message (Get-FujiText 'schedule.folderMissing' $folder) -Level 'warn'; $st.Missing = $true }
                    continue
                }
                $st.Missing = $false
                $files = @(Get-ChildItem -LiteralPath $folder -Filter ([string](Get-FujiScheduleValue $s 'pattern' '*')) -File -ErrorAction SilentlyContinue | ForEach-Object { @{ Name = $_.Name; Length = $_.Length; Ticks = $_.LastWriteTimeUtc.Ticks } })
                foreach ($name in (Update-FujiFileTrigger -State $st.File -Files $files -First (-not $st.Started))) { $st.Queue.Add((Join-Path $folder $name)) }
                $st.Started = $true
            }
            'WINDOW' {
                if (-not $slow) { continue }
                $want = [string](Get-FujiScheduleValue $s 'window')
                $present = $false
                foreach ($w in (Get-FujiTopWindow)) { if ($w.Title.Contains($want)) { $present = $true; break } }
                if (Update-FujiWindowTrigger -State $st.Window -Present $present -First (-not $st.Started)) { $st.Queue.Add($want) }
                $st.Started = $true
            }
        }
        if ($st.Queue.Count -eq 0 -or $busy) { continue }
        if (Test-FujiDialogOpen) {
            if ($slow) { Write-FujiUiLog -Message (Get-FujiWaitDialogText) -Level 'warn' }
            if ($kind -eq 'HOTKEY') { $st.Queue.Clear() }
            continue
        }
        $what = $st.Queue[0]
        $st.Queue.RemoveAt(0)
        [void](Invoke-FujiTrigger -Schedule $s -Kind $kind -What $what)
        # one run per tick; the others wait for the next ticks
        return
    }
}

function Invoke-FujiTrigger {
    param([System.Collections.IDictionary]$Schedule, [string]$Kind, [string]$What)
    $vars = [ordered]@{}
    $csv = ''
    switch ($Kind) {
        'HOTKEY' { Write-FujiUiLog -Message (Get-FujiText 'schedule.firedHotkey' (Get-FujiScheduleValue $Schedule 'hotkey')) -Level 'run' }
        'FILE' {
            $vars[(Get-FujiText 'data.triggerFileVar')] = $What
            Write-FujiUiLog -Message (Get-FujiText 'schedule.firedFile' $What) -Level 'run'
            if ([bool](Get-FujiScheduleValue $Schedule 'useFile' $false) -and ($What -match '\.(csv|txt)$' -or (Test-FujiWorkbookPath -Path $What))) { $csv = $What }
        }
        'WINDOW' {
            $vars[(Get-FujiText 'data.triggerWindowVar')] = $What
            Write-FujiUiLog -Message (Get-FujiText 'schedule.firedWindow' $What) -Level 'run'
        }
    }
    return (Invoke-FujiSchedule -Schedule $Schedule -Vars $vars -CsvOverride $csv)
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

# Why a schedule waits: an alert nobody has answered yet, or a dialog
function Get-FujiWaitDialogText {
    if (Test-FujiAlertOpen) { return (Get-FujiText 'schedule.waitAlert') }
    return (Get-FujiText 'schedule.waitDialog')
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
                Write-FujiUiLog -Message (Get-FujiWaitDialogText) -Level 'warn'
                return
            }
            [void](Invoke-FujiSchedule -Schedule $s)
            return
        }
    }
}

# Runs a schedule now. Returns the run status, or '' when it did not start.
function Invoke-FujiSchedule {
    param([System.Collections.IDictionary]$Schedule, [System.Collections.IDictionary]$Vars = $null, [string]$CsvOverride = '')
    if ((Get-FujiScheduleKind $Schedule) -eq 'TIME') {
        $Schedule['lastRun'] = Format-FujiDate -Date (Get-Date)
        Save-FujiScheduleSetting
    }
    $macro = Get-FujiScheduleMacro -Schedule $Schedule
    if ($null -eq $macro) {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.macroMissing' (Get-FujiScheduleValue $Schedule 'macroName')) -Level 'error'
        return ''
    }
    $script:Ed.MacroIndex = $script:Ed.Data.macros.IndexOf($macro)
    $script:Ed.Selected = -1
    Update-FujiAll
    $csv = [string](Get-FujiScheduleValue $Schedule 'csvPath')
    if ($CsvOverride) { $csv = $CsvOverride }
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
    $how = 'trigger'
    if ((Get-FujiScheduleKind $Schedule) -eq 'TIME') { $how = 'schedule' }
    $status = Start-FujiRunUi -Unattended -Vars $Vars -How $how
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
        Complete-FujiAutoRunStart
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
                    Complete-FujiAutoRunStart
                    return
                }
                $status = Invoke-FujiSchedule -Schedule $sched
                if ($status -eq 'done' -and [bool](Get-FujiScheduleValue $sched 'closeAfter' $false)) { Start-FujiAutoClose } else { Complete-FujiAutoRunStart }
            }
        })
    $t.Start()
}

# After the scheduled run (the window stays open): what the start held back so nobody had to answer
# it first - the last time's unsaved work, and the start notices
function Complete-FujiAutoRunStart {
    if ($script:Ed.TempPending) {
        $ask = (Get-FujiText 'editor.tempAskAfterRun') + "`r`n`r`n" + (Get-FujiText 'editor.tempAsk' $script:FujiFileNames.Macro $script:FujiFileNames.DiscardedTemp)
        $restore = (Show-FujiChoice -Title (Get-FujiText 'gui.tempTitle') -Message $ask -Buttons @((Get-FujiText 'gui.yes'), (Get-FujiText 'gui.no'))) -eq 0
        [void](Resolve-FujiEditorTemp -Editor $script:Ed -Restore $restore)
        Update-FujiAll
    }
    Show-FujiStartNotice
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
                    # someone is at the PC and keeps the window: now the questions held back
                    Invoke-FujiUi { Complete-FujiAutoRunStart }
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
    if ((Get-FujiScheduleKind $Schedule) -ne 'TIME') {
        Write-FujiUiLog -Message (Get-FujiText 'schedule.registerTimeOnly') -Level 'warn'
        return
    }
    # the task starts the app, which reads the saved macros: unsaved changes would not be in the run
    if ($script:Ed.Dirty) {
        $answer = Show-FujiChoice -Title (Get-FujiText 'schedule.saveTitle') -Message (Get-FujiText 'schedule.saveAsk') -Buttons @((Get-FujiText 'schedule.saveAndRegister'), (Get-FujiText 'schedule.registerNoSave'), (Get-FujiText 'gui.cancel'))
        if ($answer -eq 0) {
            Save-FujiUi
            if ($script:Ed.Dirty) { return }
        } elseif ($answer -ne 1) {
            return
        }
    }
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
    $help = New-FujiLabel -Text (Get-FujiText 'schedule.help') -MaxWidth ($f.ClientSize.Width - (Get-FujiScaled 30))
    $help.Dock = [System.Windows.Forms.DockStyle]::Top
    $help.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6)
    $lv = New-Object -TypeName System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.Dock = [System.Windows.Forms.DockStyle]::Top
    # only a few rows when there is nothing yet, so the add form below is in view
    $count = 0
    if ($null -ne $script:Settings.schedules) { $count = $script:Settings.schedules.Count }
    $lv.Height = $script:Ui.Font.Height * 2 + ($script:Ui.Font.Height + (Get-FujiScaled 6)) * [Math]::Min(8, [Math]::Max(3, $count))
    foreach ($c in @(@('schedule.colWhen', 300), @('schedule.colMacro', 220), @('schedule.colCsv', 230), @('schedule.colState', 150))) {
        [void]$lv.Columns.Add((Get-FujiText $c[0]), (Get-FujiScaled $c[1]))
    }
    # buttons for the selected schedule
    $actions = New-FujiFlow -NoWrap
    $actions.Dock = [System.Windows.Forms.DockStyle]::Top
    foreach ($b in @(@('toggle', 'schedule.toggleOff'), @('register', 'schedule.register'), @('unregister', 'schedule.unregister'), @('delete', 'schedule.delete'))) {
        $btn = New-FujiButton -Text (Get-FujiText $b[1]) -Tag $b[0]
        $btn.Add_Click({ $what = [string]$this.Tag; Invoke-FujiUi { Invoke-FujiScheduleAction -Action $what } })
        [void]$actions.Controls.Add($btn)
    }
    # the add form
    $add = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $add.Dock = [System.Windows.Forms.DockStyle]::Top
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
    $csv = New-FujiTextBox -Text ([string]$script:Ed.Csv.Path) -Width (Get-FujiScaled 460)
    $header = New-FujiCheck -Text (Get-FujiText 'schedule.header') -Checked $true
    $kindLabels = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($k in $script:FujiScheduleKinds) { $kindLabels.Add((Get-FujiText ('schedule.kinds.' + $k))) }
    $kind = New-FujiComboBox -Items $kindLabels.ToArray() -Values $script:FujiScheduleKinds -Width (Get-FujiScaled 420)
    $kind.SelectedIndex = 0
    $kind.Add_SelectedIndexChanged({ Invoke-FujiUi { Update-FujiScheduleKindUi } })
    $hotkey = New-FujiTextBox -Width (Get-FujiScaled 200)
    $folder = New-FujiTextBox -Width (Get-FujiScaled 460)
    $pattern = New-FujiTextBox -Text '*.csv' -Width (Get-FujiScaled 160)
    $useFile = New-FujiCheck -Text (Get-FujiText 'schedule.useFile') -Checked $true
    $window = New-FujiTextBox -Width (Get-FujiScaled 360)
    $time = New-FujiTextBox -Width (Get-FujiScaled 90)
    $repLabels = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($r in $script:FujiScheduleRepeats) { $repLabels.Add((Get-FujiScheduleRepeatName $r)) }
    $repeat = New-FujiComboBox -Items $repLabels.ToArray() -Values $script:FujiScheduleRepeats -Width (Get-FujiScaled 200)
    $repeat.SelectedIndex = 0
    $date = New-FujiTextBox -Width (Get-FujiScaled 130)
    $close = New-FujiCheck -Text (Get-FujiText 'schedule.closeAfter') -Checked $false
    $err = New-FujiLabel -Text '' -MaxWidth (Get-FujiScaled 560)
    $err.ForeColor = Get-FujiColor '#c62828'
    $addButton = New-FujiButton -Text (Get-FujiText 'schedule.add')
    $addButton.Font = $script:Ui.BoldFont
    $addButton.Add_Click({ Invoke-FujiUi { Add-FujiScheduleFromDialog } })
    # related boxes share a row, so the form stays short enough for the list above it
    $row = 1
    foreach ($pair in @(@('schedule.kind', @($kind)), @('schedule.macro', @($macro)), @('schedule.csv', @($csv, $header)),
            @('schedule.time', @($time, 'schedule.colRepeat', $repeat, 'schedule.date', $date)), @('', @($close)),
            @('schedule.hotkey', @($hotkey)), @('schedule.folder', @($folder, 'schedule.pattern', $pattern)), @('', @($useFile)),
            @('schedule.window', @($window)), @('', @($addButton, $err)))) {
        if ($pair[0]) { $add.Controls.Add((New-FujiLabel -Text (Get-FujiText $pair[0])), 0, $row) }
        $cell = New-FujiFlow -NoWrap
        foreach ($c in $pair[1]) {
            if ($c -is [string]) { $c = New-FujiLabel -Text (Get-FujiText $c) }
            [void]$cell.Controls.Add($c)
        }
        $add.Controls.Add($cell, 1, $row)
        $row++
    }
    $bar = New-FujiButtonBar
    $closeButton = New-FujiButton -Text (Get-FujiText 'gui.close')
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void]$bar.Controls.Add($closeButton)
    [void]$bar.Controls.Add((New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.schedule')))
    $f.CancelButton = $closeButton
    # the last added is docked first: help, list, its buttons and the add form stack from the top
    [void]$f.Controls.Add($add)
    [void]$f.Controls.Add($actions)
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($help)
    [void]$f.Controls.Add($bar)
    # height that fits every part; on a small screen the dialog scrolls instead of overlapping
    $inner = $f.ClientSize.Width
    $needW = [Math]::Max($inner, $add.GetPreferredSize([System.Drawing.Size]::Empty).Width)
    $needH = $lv.Height
    foreach ($c in @($help, $actions, $add, $bar)) { $needH += $c.GetPreferredSize((New-Object -TypeName System.Drawing.Size -ArgumentList $needW, 0)).Height }
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.ClientSize = New-Object -TypeName System.Drawing.Size -ArgumentList ([Math]::Min($needW, [int]($area.Width * 0.95))), ([Math]::Min($needH, [int]($area.Height * 0.9)))
    $f.AutoScroll = $true
    $f.AutoScrollMinSize = New-Object -TypeName System.Drawing.Size -ArgumentList $needW, $needH
    $script:Ui.SchedDlg = @{ List = $lv; Macro = $macro; Csv = $csv; Header = $header; Time = $time; Repeat = $repeat; Date = $date; Close = $close; Error = $err; Toggle = $actions.Controls[0]
        Kind = $kind; Hotkey = $hotkey; Folder = $folder; Pattern = $pattern; UseFile = $useFile; Window = $window }
    Update-FujiScheduleKindUi
    $f.Add_Shown({ $native = Get-FujiNativeType; [void]$native::SendMessage($script:Ui.SchedDlg.Time.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.timeCue')); [void]$native::SendMessage($script:Ui.SchedDlg.Date.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.dateCue')); [void]$native::SendMessage($script:Ui.SchedDlg.Hotkey.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.hotkeyCue')); [void]$native::SendMessage($script:Ui.SchedDlg.Folder.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.folderCue')); [void]$native::SendMessage($script:Ui.SchedDlg.Window.Handle, $script:EmSetCueBanner, [IntPtr]1, (Get-FujiText 'schedule.windowCue')) })
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
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList (Get-FujiScheduleWhenText -Schedule $s)
        foreach ($sub in @($macroText, $csv, $state)) { [void]$item.SubItems.Add([string]$sub) }
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
    $kind = [string]([object[]]$d.Kind.Tag)[$d.Kind.SelectedIndex]
    $r = New-FujiSchedule -MacroId $macroId -MacroName ([string]$d.Macro.SelectedItem) -CsvPath $d.Csv.Text -Header $d.Header.Checked -Time $d.Time.Text -Repeat $repeat -DateText $d.Date.Text -CloseAfter $d.Close.Checked `
        -Kind $kind -Hotkey $d.Hotkey.Text -Folder $d.Folder.Text -Pattern $d.Pattern.Text -Window $d.Window.Text -UseFile $d.UseFile.Checked
    if ($r.ContainsKey('Error')) { $d.Error.Text = $r.Error; return }
    $d.Error.Text = ''
    $script:Settings.schedules.Add($r.Schedule)
    Save-FujiScheduleSetting
    Write-FujiUiLog -Message (Get-FujiText 'schedule.added2' (Get-FujiScheduleWhenText -Schedule $r.Schedule) $r.Schedule.macroName) -Level 'ok'
    if ($kind -ne 'TIME') { Write-FujiUiLog -Message (Get-FujiText 'schedule.triggerNote') }
    Update-FujiScheduleList
}

# Only the boxes of the chosen kind can be typed in
function Update-FujiScheduleKindUi {
    $d = $script:Ui.SchedDlg
    if ($null -eq $d) { return }
    $kind = [string]([object[]]$d.Kind.Tag)[$d.Kind.SelectedIndex]
    foreach ($c in @($d.Time, $d.Repeat, $d.Date, $d.Close)) { $c.Enabled = ($kind -eq 'TIME') }
    $d.Hotkey.Enabled = ($kind -eq 'HOTKEY')
    foreach ($c in @($d.Folder, $d.Pattern, $d.UseFile)) { $c.Enabled = ($kind -eq 'FILE') }
    $d.Window.Enabled = ($kind -eq 'WINDOW')
}
