# ---------------------------------------------------------------------------------------------
#  Running from the window: run controls, and the Windows side (Io) of Runner.ps1
#  The run is one loop inside the Run button's handler; while it waits, Wait-FujiUiRun keeps the
#  window responsive (DoEvents), so Pause, Stop and Esc work. Editing is locked during a run.
# ---------------------------------------------------------------------------------------------

$script:Run = $null
$script:RunCtl = @{ Running = $false; Paused = $false; StopReason = ''; EscSince = $null; Excel = $null; Highlight = -1; Player = $null; AlarmTimer = $null; InBreak = $false; BreakChoice = 'run' }
$script:EscHoldMs = 1000
$script:FujiSelfElevated = $null

# ----------------------------------------------------------------- run controls
function New-FujiRunBar {
    $row = New-FujiFlow
    $row.SuspendLayout()
    $run = New-FujiButton -Text (Get-FujiText 'gui.run')
    $run.Font = $script:Ui.BoldFont
    $run.BackColor = Get-FujiColor '#c8f0cf'
    $run.Add_Click({ Invoke-FujiUi { [void](Start-FujiRunUi) } })
    $pause = New-FujiButton -Text (Get-FujiText 'gui.pause')
    $pause.Enabled = $false
    $pause.Add_Click({ Invoke-FujiUi { Switch-FujiRunPause } })
    $stop = New-FujiButton -Text (Get-FujiText 'gui.stop') -Tip (Get-FujiText 'gui.stopTip')
    $stop.Enabled = $false
    $stop.BackColor = Get-FujiColor '#ffd6dc'
    $stop.Add_Click({ $script:RunCtl.StopReason = Get-FujiText 'run.stopButtonReason' })
    # debugging: start stopping before every step / go one step on while stopped
    $stepRun = New-FujiButton -Text (Get-FujiText 'gui.stepRun') -Tip (Get-FujiText 'gui.stepRunTip')
    $stepRun.Add_Click({ Invoke-FujiUi { [void](Start-FujiRunUi -Stepping) } })
    $next = New-FujiButton -Text (Get-FujiText 'gui.stepNext') -Tip (Get-FujiText 'gui.stepNextTip')
    $next.Enabled = $false
    $next.Add_Click({ Invoke-FujiUi { Step-FujiRunUi } })
    $script:Ui.RunButton = $run
    $script:Ui.PauseButton = $pause
    $script:Ui.StopButton = $stop
    $script:Ui.StepRunButton = $stepRun
    $script:Ui.NextButton = $next
    foreach ($c in @($run, $stepRun, $pause, $next, $stop)) { [void]$row.Controls.Add($c) }
    $script:Ui.StartRow = New-FujiTextBox -Text '1' -Width (Get-FujiScaled 50)
    $script:Ui.EndRow = New-FujiTextBox -Text '' -Width (Get-FujiScaled 50)
    $script:Ui.ToolTip.SetToolTip($script:Ui.EndRow, (Get-FujiText 'gui.endRowAll'))
    $script:Ui.Interval = New-FujiTextBox -Text '300' -Width (Get-FujiScaled 55)
    # a label and its box never wrap apart
    [void]$row.Controls.Add((New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'gui.startRow')), $script:Ui.StartRow)))
    [void]$row.Controls.Add((New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'gui.endRow')), $script:Ui.EndRow)))
    [void]$row.Controls.Add((New-FujiGlued @((New-FujiLabel -Text (Get-FujiText 'gui.interval')), $script:Ui.Interval, (New-FujiLabel -Text (Get-FujiText 'gui.ms')))))
    $script:Ui.AlarmCheck = New-FujiCheck -Text (Get-FujiText 'gui.alarm') -Checked $true
    [void]$row.Controls.Add($script:Ui.AlarmCheck)
    $bell = New-FujiButton -Text (Get-FujiText 'gui.alarmTest') -Tip (Get-FujiText 'gui.alarmTestTip')
    $bell.Add_Click({ Invoke-FujiUi { Invoke-FujiAlarm -Force } })
    [void]$row.Controls.Add($bell)
    $alerts = New-FujiButton -Text (Get-FujiText 'gui.alertSettings') -Tip (Get-FujiText 'gui.alertSettingsTip')
    $alerts.Add_Click({ Invoke-FujiUi { Show-FujiAlertSettingDialog } })
    [void]$row.Controls.Add($alerts)
    $script:Ui.SafeCheck = New-FujiCheck -Text (Get-FujiText 'gui.safeMode') -Checked $false -Tip (Get-FujiText 'gui.safeModeTip')
    $script:Ui.NotifyCheck = New-FujiCheck -Text (Get-FujiText 'gui.notify') -Checked $true -Tip (Get-FujiText 'gui.notifyTip')
    [void]$row.Controls.Add($script:Ui.SafeCheck)
    [void]$row.Controls.Add($script:Ui.NotifyCheck)
    $watch = New-FujiButton -Text (Get-FujiText 'gui.watch') -Tip (Get-FujiText 'gui.watchTip')
    $watch.Add_Click({ Invoke-FujiUi { $script:Ui.Watch.Visible = -not $script:Ui.Watch.Visible; Update-FujiWatchPanel } })
    [void]$row.Controls.Add($watch)
    $times = New-FujiButton -Text (Get-FujiText 'gui.stepTimes') -Tip (Get-FujiText 'gui.stepTimesTip')
    $times.Add_Click({ Invoke-FujiUi { Show-FujiStepTimeDialog } })
    [void]$row.Controls.Add($times)
    $script:Ui.ExportResults = New-FujiButton -Text (Get-FujiText 'gui.exportResults' 0) -Tip (Get-FujiText 'gui.exportResultsTip')
    $script:Ui.ExportResults.Add_Click({ Invoke-FujiUi { Export-FujiRunCsvUi -Kind 'results' } })
    $script:Ui.ExportErrors = New-FujiButton -Text (Get-FujiText 'gui.exportErrors' 0)
    $script:Ui.ExportErrors.Add_Click({ Invoke-FujiUi { Export-FujiRunCsvUi -Kind 'errors' } })
    [void]$row.Controls.Add($script:Ui.ExportResults)
    [void]$row.Controls.Add($script:Ui.ExportErrors)
    $progress = New-FujiLabel -Text (Get-FujiText 'gui.idle')
    $progress.Font = $script:Ui.BoldFont
    $progress.ForeColor = Get-FujiColor '#ad1457'
    $script:Ui.Progress = $progress
    [void]$row.Controls.Add($progress)
    $row.ResumeLayout($false)
    $row.Dock = [System.Windows.Forms.DockStyle]::Top
    return $row
}

# Controls kept on one line inside a wrapping row
function New-FujiGlued {
    param([object[]]$Controls)
    $g = New-FujiFlow -NoWrap
    $g.Dock = [System.Windows.Forms.DockStyle]::None
    foreach ($c in $Controls) { [void]$g.Controls.Add($c) }
    return $g
}

function New-FujiCheck {
    param([string]$Text, [bool]$Checked, [string]$Tip = '')
    $c = New-Object -TypeName System.Windows.Forms.CheckBox
    $c.Text = $Text
    $c.AutoSize = $true
    # drawn by Windows: measuring the Windows Forms drawn box made labels with an emoji measured
    # afterwards too narrow (their text was cut off, e.g. the image hint of the step dialog)
    $c.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $c.Checked = $Checked
    $c.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 6), (Get-FujiScaled 6), (Get-FujiScaled 2), 0
    if ($Tip) { $script:Ui.ToolTip.SetToolTip($c, $Tip) }
    return $c
}

# Toolbars and editing locked while a run is going
function Set-FujiRunUi {
    param([bool]$Running)
    foreach ($bar in $script:Ui.Toolbars) { $bar.Enabled = -not $Running }
    $script:Ui.RunButton.Enabled = -not $Running
    $script:Ui.StepRunButton.Enabled = -not $Running
    $script:Ui.NextButton.Enabled = $false
    $script:Ui.PauseButton.Enabled = $Running
    $script:Ui.StopButton.Enabled = $Running
    $script:Ui.PauseButton.Text = Get-FujiText 'gui.pause'
    foreach ($c in @($script:Ui.StartRow, $script:Ui.EndRow, $script:Ui.Interval)) { $c.Enabled = -not $Running }
}

function Test-FujiEditLocked {
    if (-not $script:RunCtl.Running) { return $false }
    Write-FujiUiLog -Message (Get-FujiText 'run.editLocked') -Level 'warn'
    return $true
}

function Update-FujiRunButton {
    $results = 0
    $errors = 0
    if ($null -ne $script:Run) { $results = $script:Run.ResultRows.Count; $errors = $script:Run.ErrorRows.Count }
    $script:Ui.ExportResults.Text = Get-FujiText 'gui.exportResults' $results
    $script:Ui.ExportErrors.Text = Get-FujiText 'gui.exportErrors' $errors
}

function Switch-FujiRunPause {
    $c = $script:RunCtl
    if (-not $c.Running) { return }
    $c.Paused = -not $c.Paused
    if ($c.Paused) {
        $script:Ui.PauseButton.Text = Get-FujiText 'gui.resume'
        $script:Ui.NextButton.Enabled = $true
        $script:Ui.Progress.Text = (Get-FujiText 'run.paused') + $script:Ui.Progress.Text
        Write-FujiUiLog -Message (Get-FujiText 'run.pause') -Level 'warn'
    } else {
        # resumed: run on to the end (or the next breakpoint)
        $c.BreakChoice = 'run'
        $script:Ui.PauseButton.Text = Get-FujiText 'gui.pause'
        $script:Ui.NextButton.Enabled = $false
    }
}

# "Next" while stopped: run one step, then stop again before the following one
function Step-FujiRunUi {
    $c = $script:RunCtl
    if (-not $c.Running -or -not $c.Paused) { return }
    $c.BreakChoice = 'step'
    if ($null -ne $script:Run) { $script:Run.Stepping = $true }
    $c.Paused = $false
    $script:Ui.PauseButton.Text = Get-FujiText 'gui.pause'
    $script:Ui.NextButton.Enabled = $false
}

# Io.Break: the run stops before a step (breakpoint or stepping) until Next, Resume or Stop.
# Returns 'step' or 'run'; a stop throws like any wait.
function Invoke-FujiUiBreak {
    param([string]$Message)
    $c = $script:RunCtl
    $c.BreakChoice = 'run'
    $c.Paused = $true
    $script:Ui.PauseButton.Text = Get-FujiText 'gui.resume'
    $script:Ui.NextButton.Enabled = $true
    $script:Ui.Progress.Text = $Message
    # the window comes to the front, so the variables and the highlighted step can be looked at
    [void](Invoke-FujiWindowActivate -Handle $script:Ui.Form.Handle)
    if ($script:Ui.Watch.Visible) { Update-FujiWatchPanel }
    $c.InBreak = $true
    try {
        while ($c.Paused -and -not $c.StopReason) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
    } finally {
        $c.InBreak = $false
    }
    if ($c.StopReason) { throw (New-FujiStopException $c.StopReason) }
    return $c.BreakChoice
}

# ----------------------------------------------------------------- starting a run
# Unattended: started by a schedule, so nothing is asked before the run. Returns the run status
# ('done', 'stopped', 'error') or '' when it did not start.
# Stepping: stop before the first step. Partial 'from' / 'only': start at the selected step ('only':
# just it, for one CSV row). Vars: values handed over by a trigger. How: what started it, for the
# run record (schedule / trigger; otherwise manual, or test for a partial or stepping run).
function Start-FujiRunUi {
    param([switch]$Unattended, [switch]$Stepping, [ValidateSet('', 'from', 'only')][string]$Partial = '', [System.Collections.IDictionary]$Vars = $null,
        [ValidateSet('', 'schedule', 'trigger')][string]$How = '')
    if ($script:RunCtl.Running) { return '' }
    if ($null -ne $script:Rec) {
        Write-FujiUiLog -Message (Get-FujiText 'rec.busy') -Level 'warn'
        return ''
    }
    # a frame alert leaves the window usable: running again answers it
    Close-FujiAlert -Acknowledged
    $macro = Get-FujiCurrentMacro $script:Ed
    $steps = $macro.steps
    $range = @{ StartAt = -1; EndAt = -1 }
    if ($Partial) {
        $range = Get-FujiPartialRun -Editor $script:Ed -Mode $Partial
        if ($range.ContainsKey('Error')) {
            Write-FujiUiLog -Message $range.Error -Level 'warn'
            return ''
        }
    }
    $executable = 0
    $usesCsv = $false
    foreach ($s in $steps) {
        if (Test-FujiExecutableStep -Step $s) { $executable++ }
        if ($s.cmd -eq 'CSV') { $usesCsv = $true }
    }
    if ($executable -eq 0) {
        Write-FujiUiLog -Message (Get-FujiText 'run.noSteps') -Level 'warn'
        return ''
    }
    if (-not (Test-FujiBlockBalanced -Steps $steps)) {
        Show-FujiMessage -Title (Get-FujiText 'run.unbalancedTitle') -Message (Get-FujiText 'run.unbalanced')
        return ''
    }
    $csvRows = $script:Ed.Csv.Rows
    if ($csvRows.Count -eq 0 -and $usesCsv) {
        if ($Unattended) {
            Write-FujiUiLog -Message (Get-FujiText 'run.noCsvUnattended') -Level 'error'
            return ''
        }
        $answer = Show-FujiChoice -Title (Get-FujiText 'gui.run') -Message (Get-FujiText 'run.noCsvAsk') -Buttons @((Get-FujiText 'gui.yes'), (Get-FujiText 'gui.no'))
        if ($answer -ne 0) { return '' }
    }
    $rr = Get-FujiRunRow -CsvRows $csvRows -Header $script:Ed.Csv.Header -StartText $script:Ui.StartRow.Text -EndText $script:Ui.EndRow.Text
    foreach ($l in $rr.Logs) { Write-FujiUiLog -Message $l[0] -Level $l[1] }
    if ($rr.Error) {
        Show-FujiMessage -Title (Get-FujiText 'run.rangeTitle') -Message $rr.Error
        return ''
    }
    if ($rr.Rows.Count -eq 0) { return '' }
    $rows = $rr.Rows
    if ($Partial -eq 'only' -and $rows.Count -gt 1) {
        # trying one step: the first row of the range only
        $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $rows.Add($rr.Rows[0])
    }
    $interval = [Math]::Max(0, (Get-FujiInt -Text $script:Ui.Interval.Text -Default 300))
    $script:Run = New-FujiRun -Macro $macro -Macros $script:Ed.Data.macros -Rows $rows -Header $script:Ed.Csv.Header -Io (New-FujiWinIo) `
        -Interval $interval -SafeMode $script:Ui.SafeCheck.Checked -Directory $script:Ed.Directory `
        -ResolvePath { param($Path) Resolve-FujiEditorPath -Editor $script:Ed -Path $Path } `
        -StartAt $range.StartAt -EndAt $range.EndAt -Breaks (-not $Unattended) -Stepping $Stepping.IsPresent -Vars $Vars
    $c = $script:RunCtl
    $c.Running = $true
    $c.Paused = $false
    $c.StopReason = ''
    $c.EscSince = $null
    $c.Highlight = -1
    Set-FujiRunUi -Running $true
    Update-FujiRunButton
    Write-FujiUiLog -Message (Get-FujiText 'run.start' $macro.name $rows.Count $rr.Range $interval) -Level 'run'
    if ($Partial -eq 'only') { Write-FujiUiLog -Message (Get-FujiText 'run.onlyThis' ($range.StartAt + 1) ($range.EndAt + 1)) -Level 'run' }
    if ($Stepping) { Write-FujiUiLog -Message (Get-FujiText 'run.steppingStart') -Level 'run' }
    $status = ''
    try {
        $status = Invoke-FujiRun -Run $script:Run
    } finally {
        $c.Running = $false
        $c.Paused = $false
        $c.Highlight = -1
        Set-FujiRunUi -Running $false
        $script:Ui.Progress.Text = [string][char]0x25A0 + ' ' + $script:Run.Summary
        $origin = $How
        if (-not $origin) { if ($Partial -or $Stepping) { $origin = 'test' } elseif ($Unattended) { $origin = 'schedule' } else { $origin = 'manual' } }
        Save-FujiRunRecordUi -Run $script:Run -How $origin
        Update-FujiRunButton
        Update-FujiWatchPanel
        $script:Ui.List.Invalidate()
    }
    return $status
}

# ----------------------------------------------------------------- waiting (keeps the window alive)
function Wait-FujiUiRun {
    param([int]$Ms)
    $c = $script:RunCtl
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Test-FujiEscHeld
        if ($c.StopReason) { throw (New-FujiStopException $c.StopReason) }
        if ($c.Paused) {
            while ($c.Paused -and -not $c.StopReason) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 30
            }
            if ($c.StopReason) { throw (New-FujiStopException $c.StopReason) }
            return $true
        }
        $left = $Ms - $sw.ElapsedMilliseconds
        if ($left -le 0) { return $false }
        Start-Sleep -Milliseconds ([Math]::Max(1, [Math]::Min(15, $left)))
    }
}

# Esc held for about a second stops the run from any window (a macro's own {ESC} is one short press)
function Test-FujiEscHeld {
    $c = $script:RunCtl
    $native = Get-FujiNativeType
    if (([int]$native::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
        if ($null -eq $c.EscSince) { $c.EscSince = [DateTime]::UtcNow }
        elseif (([DateTime]::UtcNow - $c.EscSince).TotalMilliseconds -ge $script:EscHoldMs) { $c.StopReason = Get-FujiText 'run.stopEscHeld' }
    } else {
        $c.EscSince = $null
    }
}

# ----------------------------------------------------------------- the Io for Runner.ps1
function New-FujiWinIo {
    return @{
        Log = { param($Message, $Level) Write-FujiUiLog -Message $Message -Level $Level }
        Wait = { param($Ms) Wait-FujiUiRun -Ms $Ms }
        Activate = { param($Title) Invoke-FujiActivateTitle -Title $Title }
        WindowExists = { param($Title) return ($null -ne (Select-FujiWindow -Windows (Get-FujiTopWindow) -Title $Title)) }
        SelfHasFocus = { Test-FujiSelfForeground }
        InputBlocked = { param($Title) $w = Select-FujiWindow -Windows (Get-FujiTopWindow) -Title $Title; return ($null -ne $w -and (Test-FujiWindowElevated -Handle $w.Handle)) }
        FocusSelf = { [void](Invoke-FujiWindowActivate -Handle $script:Ui.Form.Handle) }
        SendKeys = { param($Keys) [System.Windows.Forms.SendKeys]::SendWait($Keys) }
        SetClipboard = { param($Text) Set-FujiClipboard -Text $Text }
        GetClipboard = { Get-FujiClipboard }
        ClipboardSeq = { (Get-FujiNativeType)::GetClipboardSequenceNumber() }
        ClipboardReady = { param($Seq) Test-FujiClipboardReady -Seq $Seq }
        Start = { param($CommandLine) Start-FujiCommandLine -CommandLine $CommandLine }
        ClickAt = { param($X, $Y, $Kind) Invoke-FujiMouseClick -X $X -Y $Y -Kind $Kind }
        Screenshot = { param($Path, $Full) Save-FujiScreenshot -Path $Path -Full $Full }
        ClickName = { param($Name, $WindowTitle) Invoke-FujiNameClick -Name $Name -WindowTitle $WindowTitle }
        ClickImage = { param($Path, $Threshold) Invoke-FujiImageClick -Path $Path -Threshold $Threshold }
        Ocr = { param($Settings, $Find, $Nth) Invoke-FujiOcr -Settings $Settings -Find $Find -Nth $Nth }
        Excel = { param($Request) Invoke-FujiExcelRequest -Request $Request }
        Outlook = { param($Mail) Send-FujiOutlookMail -Mail $Mail }
        OpenUrl = { param($Url) Start-Process -FilePath $Url }
        FileExists = { param($Path) return ([bool]$Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) }
        Now = { Get-Date }
        Confirm = { param($Caption, $Message) Show-FujiRunConfirm -Caption $Caption -Message $Message }
        Ask = { param($Caption, $Message, $Default) Show-FujiRunAsk -Caption $Caption -Message $Message -Default $Default }
        Progress = { param($Text) $script:Ui.Progress.Text = $Text }
        Highlight = { param($StepIndex) Set-FujiRunHighlight -Index $StepIndex }
        Watch = { Update-FujiWatchPanel }
        Alarm = { param($Message) Show-FujiRunAlert -Message $Message }
        Notify = { Invoke-FujiNotify }
        EndRun = { Close-FujiRunExcel; Clear-FujiBackground }
        Break = { param($Message) Invoke-FujiUiBreak -Message $Message }
        SetField = { param($Request) Set-FujiUiaField -Request $Request }
        GetField = { param($Request) Get-FujiUiaField -Request $Request }
        ReadTable = { param($Request) Read-FujiUiaTable -Request $Request }
        SaveText = { param($Path, $Text) Save-FujiRunText -Path $Path -Text $Text }
        GetSecret = { param($Target) Read-FujiCredential -Target $Target }
        TypeSecret = { param($Text) [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-FujiSendKeyLiteral $Text)) }
        ForegroundWindow = { Get-FujiForegroundWindowInfo }
        FocusIsPassword = { [bool](Invoke-FujiUia -Mode 'ISPASSWORD') }
        FileOp = { param($Request) Invoke-FujiFileOperation -Op $Request.Op -Source $Request.Source -Dest $Request.Dest -Overwrite $Request.Overwrite -AppDirectory $Request.AppDirectory }
    }
}

# ----------------------------------------------------------------- windows
# Visible top-level windows with a title, this app's own windows left out
function Get-FujiTopWindow {
    $native = Get-FujiNativeType
    $own = @{}
    foreach ($f in [System.Windows.Forms.Application]::OpenForms) { $own[$f.Handle.ToInt64()] = $true }
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 10000; $i++) {
        $h = $native::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, [NullString]::Value)
        if ($h -eq [IntPtr]::Zero) { break }
        if ($own.ContainsKey($h.ToInt64()) -or -not $native::IsWindowVisible($h)) { continue }
        $len = $native::GetWindowTextLength($h)
        if ($len -le 0) { continue }
        $sb = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($len + 1)
        [void]$native::GetWindowText($h, $sb, $sb.Capacity)
        $list.Add(@{ Handle = $h; Title = $sb.ToString() })
    }
    return , $list.ToArray()
}

# @{ Title; Program } of the window in front (Program: the full path of its .exe), $null if none
function Get-FujiForegroundWindowInfo {
    $native = Get-FujiNativeType
    $h = $native::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    $len = $native::GetWindowTextLength($h)
    $title = ''
    if ($len -gt 0) {
        $sb = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($len + 1)
        [void]$native::GetWindowText($h, $sb, $sb.Capacity)
        $title = $sb.ToString()
    }
    # GetWindowThreadProcessId writes the process id where its second argument points
    $mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, 0)
        [void]$native::GetWindowThreadProcessId($h, $mem)
        $processId = [System.Runtime.InteropServices.Marshal]::ReadInt32($mem)
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mem)
    }
    $program = ''
    if ($processId -gt 0) {
        $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
        # Path is empty for a process this user may not look into (e.g. one run as administrator):
        # then nothing matches and no password is typed
        if ($null -ne $p) { try { $program = [string]$p.Path } catch { $program = '' } }
    }
    return @{ Title = $title; Program = $program }
}

function Test-FujiSelfForeground {
    $fg = (Get-FujiNativeType)::GetForegroundWindow()
    foreach ($f in [System.Windows.Forms.Application]::OpenForms) { if ($f.Handle -eq $fg) { return $true } }
    return $false
}

function Invoke-FujiActivateTitle {
    param([string]$Title)
    $w = Select-FujiWindow -Windows (Get-FujiTopWindow) -Title $Title
    if ($null -eq $w) { return $false }
    return (Invoke-FujiWindowActivate -Handle $w.Handle)
}

# Brings a window to the front. Windows only lets the process the user is working with do that,
# so when the plain call is refused: join the input of the window in front, then a key press
# (the same steps the pre-check tool tried)
function Invoke-FujiWindowActivate {
    param([IntPtr]$Handle)
    $native = Get-FujiNativeType
    if ($native::IsIconic($Handle)) { [void]$native::ShowWindow($Handle, 9) }
    if ($native::GetForegroundWindow() -eq $Handle) { return $true }
    [void]$native::SetForegroundWindow($Handle)
    if ($native::GetForegroundWindow() -eq $Handle) { return $true }
    $fgThread = $native::GetWindowThreadProcessId($native::GetForegroundWindow(), [IntPtr]::Zero)
    $me = $native::GetCurrentThreadId()
    if ($fgThread -ne 0 -and $fgThread -ne $me) {
        [void]$native::AttachThreadInput($me, $fgThread, $true)
        try {
            [void]$native::BringWindowToTop($Handle)
            [void]$native::SetForegroundWindow($Handle)
        } finally {
            [void]$native::AttachThreadInput($me, $fgThread, $false)
        }
        if ($native::GetForegroundWindow() -eq $Handle) { return $true }
    }
    # a key press counts as input of this process, which lifts the foreground lock. Not Alt: its key up
    # reached the window brought to the front, opened its menu and the next keys went there (VM probe:
    # 0 of 18 keys arrived). 0xE8 is an unassigned key code: nothing reacts to it (25 of 25 arrived).
    $native::keybd_event(0xE8, 0, 0, [UIntPtr]::Zero)
    $native::keybd_event(0xE8, 0, 2, [UIntPtr]::Zero)
    [void]$native::SetForegroundWindow($Handle)
    return ($native::GetForegroundWindow() -eq $Handle)
}

# ----------------------------------------------------------------- clipboard, programs, mouse, screen
# $true when the window belongs to a program run as administrator and this app is not: Windows then
# drops the keys and pastes sent to it without any error (User Interface Privilege Isolation)
function Test-FujiWindowElevated {
    param([IntPtr]$Handle)
    if ($null -eq $script:FujiSelfElevated) {
        $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
        $script:FujiSelfElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if ($script:FujiSelfElevated) { return $false }
    $native = Get-FujiNativeType
    $marshal = [System.Runtime.InteropServices.Marshal]
    # 16 bytes: the process id, then the token handle, then TokenElevation and its length
    $mem = $marshal::AllocHGlobal(16)
    try {
        $marshal::WriteInt32($mem, 0)
        [void]$native::GetWindowThreadProcessId($Handle, $mem)
        $processId = $marshal::ReadInt32($mem)
        if ($processId -le 0) { return $false }
        # PROCESS_QUERY_LIMITED_INFORMATION, TOKEN_QUERY, TokenElevation (20)
        $process = $native::OpenProcess([uint32]0x1000, $false, [uint32]$processId)
        if ($process -eq [IntPtr]::Zero) { return $false }
        try {
            $marshal::WriteIntPtr($mem, [IntPtr]::Zero)
            if (-not $native::OpenProcessToken($process, [uint32]8, $mem)) { return $false }
            $token = $marshal::ReadIntPtr($mem)
            try {
                if (-not $native::GetTokenInformation($token, 20, $mem, 4, [IntPtr]::Add($mem, 8))) { return $false }
                return ($marshal::ReadInt32($mem) -ne 0)
            } finally { [void]$native::CloseHandle($token) }
        } finally { [void]$native::CloseHandle($process) }
    } finally {
        $marshal::FreeHGlobal($mem)
    }
}

function Set-FujiClipboard {
    param([AllowEmptyString()][string]$Text)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ($Text -eq '') { [System.Windows.Forms.Clipboard]::Clear() } else { [System.Windows.Forms.Clipboard]::SetText($Text) }
            return $true
        } catch {
            # another program has the clipboard open for a moment
            Start-Sleep -Milliseconds 60
        }
    }
    return $false
}

# The clipboard changed since Seq and the program that wrote it has closed it with text on it
# (CF_UNICODETEXT 13). The number goes up when the clipboard is emptied too, before the data is there.
function Test-FujiClipboardReady {
    param([uint32]$Seq)
    $native = Get-FujiNativeType
    if ($native::GetClipboardSequenceNumber() -eq $Seq) { return $false }
    if ($native::GetOpenClipboardWindow() -ne [IntPtr]::Zero) { return $false }
    return $native::IsClipboardFormatAvailable(13)
}

function Get-FujiClipboard {
    for ($i = 0; $i -lt 5; $i++) {
        try { return [System.Windows.Forms.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 60 }
    }
    return ''
}

# "program arguments" or "\"C:\path with spaces\prog.exe\" arguments"; documents and URLs open
# with their app. Environment variables (%USERPROFILE% ...) are expanded like WScript's Run did.
function Start-FujiCommandLine {
    param([string]$CommandLine)
    $cmd = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $m = [regex]::Match($cmd, '^"([^"]*)"\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { $m = [regex]::Match($cmd, '^(\S+)\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline) }
    $file = $m.Groups[1].Value
    $arguments = $m.Groups[2].Value
    if ($arguments) { Start-Process -FilePath $file -ArgumentList $arguments } else { Start-Process -FilePath $file }
    return ''
}

function Invoke-FujiMouseClick {
    param([int]$X, [int]$Y, [string]$Kind)
    $native = Get-FujiNativeType
    $down = [uint32]0x0002
    $up = [uint32]0x0004
    if ($Kind -eq 'RIGHT') { $down = [uint32]0x0008; $up = [uint32]0x0010 }
    [void]$native::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 80
    $native::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    $native::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
    if ($Kind -eq 'DOUBLE') {
        Start-Sleep -Milliseconds 60
        $native::mouse_event([uint32]0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        $native::mouse_event([uint32]0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
}

# Full: every screen; otherwise the window in front. Returns "width x height".
function Save-FujiScreenshot {
    param([string]$Path, [bool]$Full)
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder) }
    $r = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if (-not $Full) {
        $native = Get-FujiNativeType
        $a = New-Object -TypeName 'int[]' -ArgumentList 4
        if ($native::GetWindowRect($native::GetForegroundWindow(), $a) -and $a[2] -gt $a[0] -and $a[3] -gt $a[1]) {
            $r = New-Object -TypeName System.Drawing.Rectangle -ArgumentList $a[0], $a[1], ($a[2] - $a[0]), ($a[3] - $a[1])
        }
    }
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $r.Width, $r.Height
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { $g.CopyFromScreen($r.X, $r.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
    return ('{0}x{1}' -f $r.Width, $r.Height)
}

# A CSV a step writes (a table read from the screen): with a BOM, so Excel opens it as UTF-8
function Save-FujiRunText {
    param([string]$Path, [string]$Text)
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder) }
    Write-FujiTextFile -Path $Path -Text $Text -Bom
}

# ----------------------------------------------------------------- Excel and Outlook (COM)
# An Excel book as the data of a run: the first sheet saved by Excel as a CSV (UTF-8), which keeps
# what the cells show (dates and numbers as displayed). The book is opened read-only and its macros
# never run. Returns the CSV text.
function Read-FujiWorkbookCsv {
    param([Parameter(Mandatory)][string]$Path)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_book_' + [guid]::NewGuid().ToString('N') + '.csv')
    $app = New-Object -ComObject Excel.Application
    try {
        $app.Visible = $false
        $app.DisplayAlerts = $false
        $app.AutomationSecurity = 3
        $wb = $app.Workbooks.Open($Path, 0, $true)
        try {
            # Copy() without a place puts the sheet into a new book of its own
            $wb.Worksheets.Item(1).Copy()
            $copy = $app.ActiveWorkbook
            try { $copy.SaveAs($tmp, 62) } finally { $copy.Close($false) }   # 62 = xlCSVUTF8
        } finally {
            $wb.Close($false)
        }
    } finally {
        $app.Quit()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    }
    try {
        return (Read-FujiCsvText -Path $tmp -Encoding 'auto').Text
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FujiExcelRequest {
    param([hashtable]$Request)
    $c = $script:RunCtl
    if ($null -eq $c.Excel) {
        $app = New-Object -ComObject Excel.Application
        $app.Visible = $false
        $app.DisplayAlerts = $false
        # Workbooks opened by automation run their macros by default: never run them (3 = force disable)
        $app.AutomationSecurity = 3
        $c.Excel = @{ App = $app; Books = @{} }
    }
    $path = $Request.Path
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (Get-FujiText 'run.excelNoBook' $path) }
    $key = $path.ToLowerInvariant()
    $wb = $c.Excel.Books[$key]
    if ($null -eq $wb) {
        $wb = $c.Excel.App.Workbooks.Open($path, 0, $false)
        $c.Excel.Books[$key] = $wb
    }
    if ($Request.Write -and $wb.ReadOnly) { throw (Get-FujiText 'run.excelReadOnly' $path) }
    $s = (ConvertTo-FujiHalfWidthDigit -Text ([string]$Request.Sheet)).Trim()
    if ($s -eq '') { $s = '1' }
    if ($s -match '^[0-9]+$') { $sheet = $wb.Worksheets.Item([int]$s) } else { $sheet = $wb.Worksheets.Item($s) }
    $range = $sheet.Range($Request.Cell)
    if ($Request.Write) {
        $range.Value2 = $Request.Value
        $wb.Save()
        return ''
    }
    return [string]$range.Text
}

function Close-FujiRunExcel {
    $c = $script:RunCtl
    if ($null -eq $c.Excel) { return }
    try {
        foreach ($wb in $c.Excel.Books.Values) { try { $wb.Close($false) } catch { $null = $_ } }
        $c.Excel.App.Quit()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($c.Excel.App)
    } catch {
        $null = $_
    }
    $c.Excel = $null
}

function Send-FujiOutlookMail {
    param([hashtable]$Mail)
    $ol = New-Object -ComObject Outlook.Application
    $item = $ol.CreateItem(0)
    $item.To = $Mail.To
    $item.CC = $Mail.Cc
    $item.Subject = $Mail.Subject
    $item.Body = $Mail.Body
    foreach ($a in $Mail.Attachments) { [void]$item.Attachments.Add($a) }
    switch ($Mail.Mode) {
        'SEND' { $item.Send() }
        'DISPLAY' { $item.Display($false) }
        default { $item.Save() }
    }
    return $Mail.Mode
}

# ----------------------------------------------------------------- dialogs during a run
function Show-FujiRunConfirm {
    param([string]$Caption, [string]$Message)
    [void](Invoke-FujiWindowActivate -Handle $script:Ui.Form.Handle)
    Show-FujiAlert -Kind 'confirm' -Title (Get-FujiText 'alert.confirmTitle') -Lines @($Caption, (Format-FujiShort $Message 200))
    try {
        $answer = Show-FujiChoice -Title $Caption -Message $Message -Buttons @((Get-FujiText 'run.continueButton'), (Get-FujiText 'run.skipButton'), (Get-FujiText 'run.stopButton'))
    } finally {
        Close-FujiAlert
    }
    switch ($answer) {
        0 { return 'continue' }
        1 { return 'skip' }
    }
    return 'stop'
}

function Show-FujiRunAsk {
    param([string]$Caption, [string]$Message, [string]$Default)
    [void](Invoke-FujiWindowActivate -Handle $script:Ui.Form.Handle)
    $width = Get-FujiScaled 480
    $f = New-FujiDialogForm -Title $Caption -Width $width -Height (Get-FujiScaled 200)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    [void]$layout.Controls.Add((New-FujiLabel -Text $Message -MaxWidth ($width - (Get-FujiScaled 30))))
    $box = New-FujiTextBox -Text $Default -Width ($width - (Get-FujiScaled 30))
    [void]$layout.Controls.Add($box)
    $bar = New-FujiButtonBar
    $script:Ui.AskDialog = @{ Choice = 'stop'; Value = '' }
    # RightToLeft bar: added in reverse order
    foreach ($b in @(@('stop', 'run.stopButton'), @('skip', 'run.skipButton'), @('continue', 'run.continueButton'))) {
        $btn = New-FujiButton -Text (Get-FujiText $b[1]) -Tag $b[0]
        $btn.Add_Click({ $script:Ui.AskDialog.Choice = [string]$this.Tag; $this.FindForm().Close() })
        [void]$bar.Controls.Add($btn)
        if ($b[0] -eq 'continue') { $f.AcceptButton = $btn }
    }
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $script:Ui.AskDialog.Box = $box
    $f.Add_Shown({ $script:Ui.AskDialog.Box.SelectAll(); $script:Ui.AskDialog.Box.Focus() })
    $f.Add_FormClosing({ $script:Ui.AskDialog.Value = $script:Ui.AskDialog.Box.Text })
    Show-FujiAlert -Kind 'confirm' -Title (Get-FujiText 'alert.confirmTitle') -Lines @($Caption, (Format-FujiShort $Message 200))
    try {
        [void](Show-FujiDialog -Form $f)
    } finally {
        Close-FujiAlert
    }
    $f.Dispose()
    return @{ Choice = $script:Ui.AskDialog.Choice; Value = $script:Ui.AskDialog.Value }
}

# ----------------------------------------------------------------- what the window shows during a run
function Set-FujiRunHighlight {
    param([int]$Index)
    $script:RunCtl.Highlight = $Index
    if ($null -eq $script:Run -or -not [object]::ReferenceEquals((Get-FujiCurrentMacro $script:Ed), $script:Run.Macro)) { return }
    $lb = $script:Ui.List
    for ($i = 0; $i -lt $script:Rows.Count; $i++) {
        if ($script:Rows[$i].Index -eq $Index) {
            $visible = [Math]::Max(1, [int]($lb.ClientSize.Height / $lb.ItemHeight))
            if ($i -lt $lb.TopIndex -or $i -ge $lb.TopIndex + $visible) { $lb.TopIndex = [Math]::Max(0, $i - [int]($visible / 3)) }
            break
        }
    }
    $lb.Invalidate()
}

function Test-FujiRunHighlight {
    param([int]$StepIndex)
    return ($script:RunCtl.Running -and $script:RunCtl.Highlight -eq $StepIndex -and $null -ne $script:Run -and [object]::ReferenceEquals((Get-FujiCurrentMacro $script:Ed), $script:Run.Macro))
}

function Update-FujiWatchPanel {
    $box = $script:Ui.Watch
    if (-not $box.Visible) { return }
    if ($null -eq $script:Run) {
        $box.Text = Get-FujiText 'run.watchIdle'
        return
    }
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($section in (Get-FujiRunWatch -Run $script:Run)) {
        $lines.Add('[' + $section[0] + ']')
        if ($section[1].Count -eq 0) { $lines.Add('  ' + (Get-FujiText 'run.watchNone')) }
        foreach ($pair in $section[1]) { $lines.Add('  ' + $pair[0] + ' = ' + (Format-FujiShort ([string]$pair[1]) 60)) }
        $lines.Add('')
    }
    $box.Text = [string]::Join("`r`n", $lines.ToArray())
}

# File: a sound of %SystemRoot%\Media ('' = the one chosen for errors). Once: play it one time (to listen to it)
function Invoke-FujiAlarm {
    param([switch]$Force, [string]$File = '', [switch]$Once)
    if (-not $Force -and -not $script:Ui.AlarmCheck.Checked) { return }
    if (-not $File) { $File = (Get-FujiAlertSetting -Settings $script:Settings -Kind 'error').file }
    if (-not $Once) { Write-FujiUiLog -Message (Get-FujiText 'run.alarm') -Level 'warn' }
    try {
        $c = $script:RunCtl
        if ($null -ne $c.Player) { $c.Player.Stop() }
        $c.Player = New-Object -TypeName System.Media.SoundPlayer -ArgumentList (Join-Path $env:SystemRoot ('Media\' + $File))
        $c.Player.Load()
        if ($Once) {
            $c.Player.Play()
            return
        }
        $c.Player.PlayLooping()
        # about three times
        if ($null -eq $c.AlarmTimer) {
            $c.AlarmTimer = New-Object -TypeName System.Windows.Forms.Timer
            $c.AlarmTimer.Interval = 12000
            $c.AlarmTimer.Add_Tick({ $this.Stop(); if ($null -ne $script:RunCtl.Player) { $script:RunCtl.Player.Stop() } })
        }
        $c.AlarmTimer.Stop()
        $c.AlarmTimer.Start()
    } catch {
        [System.Media.SystemSounds]::Exclamation.Play()
        Write-FujiUiLog -Message (Get-FujiText 'run.alarmFailed' $_.Exception.Message) -Level 'warn'
    }
}

function Invoke-FujiNotify {
    if (-not $script:Ui.NotifyCheck.Checked) { return }
    try {
        $p = New-Object -TypeName System.Media.SoundPlayer -ArgumentList (Join-Path $env:SystemRoot 'Media\tada.wav')
        $p.Play()
        $script:RunCtl.Player = $p
    } catch {
        # the finishing sound is a nicety; silence is fine
        $null = $_
    }
}

# ----------------------------------------------------------------- result and error-row CSVs
function Export-FujiRunCsvUi {
    param([ValidateSet('results', 'errors')][string]$Kind)
    $run = $script:Run
    if ($Kind -eq 'results') {
        $title = Get-FujiText 'run.resultsTitle'
        if ($null -eq $run -or $run.ResultRows.Count -eq 0) { Show-FujiMessage -Title $title -Message (Get-FujiText 'run.resultsNone'); return }
        $path = Get-FujiEditorPath $script:Ed 'fujikyun_result.csv'
        $text = ConvertTo-FujiResultCsv -Run $run
        $count = $run.ResultRows.Count
        $savedKey = 'run.resultsSaved'
        $doneKey = 'run.resultsDone'
    } else {
        $title = Get-FujiText 'run.errorRowsTitle'
        if ($null -eq $run -or $run.ErrorRows.Count -eq 0) { Show-FujiMessage -Title $title -Message (Get-FujiText 'run.errorRowsNone'); return }
        $path = Get-FujiEditorPath $script:Ed 'fujikyun_error_list.csv'
        $text = ConvertTo-FujiErrorCsv -Run $run
        $count = $run.ErrorRows.Count
        $savedKey = 'run.errorRowsSaved'
        $doneKey = 'run.errorRowsDone'
    }
    try {
        # With a BOM: Excel opens it as UTF-8
        Write-FujiTextFile -Path $path -Text $text -Bom
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'run.saveFailed' $_.Exception.Message) -Level 'error'
        return
    }
    Write-FujiUiLog -Message (Get-FujiText $savedKey $count $path) -Level 'ok'
    $answer = Show-FujiChoice -Title $title -Message (Get-FujiText $doneKey $path) -Buttons @((Get-FujiText 'gui.openFolder'), (Get-FujiText 'gui.close'))
    if ($answer -eq 0) { Open-FujiFolder -Path $path }
}
