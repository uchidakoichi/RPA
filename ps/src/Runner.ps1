# ---------------------------------------------------------------------------------------------
#  Runner: runs a macro over the CSV rows (the HTA's runner, same rules)
#  Runs as one plain loop. Everything that touches Windows goes through Io (a hashtable of
#  script blocks), so the rules are tested with a fake Io and the window supplies the real one:
#
#    Log {Message, Level}      Wait {Ms} -> $true when the run was paused and resumed meanwhile;
#                              throws OperationCanceledException(reason) when the run is stopped
#    Activate {Title} -> bool  (exact, then prefix, then suffix title match; never this app)
#    WindowExists {Title} -> bool   SelfHasFocus {} -> bool   FocusSelf {}
#    SendKeys {Keys}   SetClipboard {Text} -> bool   GetClipboard {} -> string
#    Start {CommandLine} -> note   ClickAt {X, Y, Kind}   Screenshot {Path, Full} -> note
#    ClickName {Name, WindowTitle} -> note   ClickImage {Path, Threshold} -> @{ X; Y; Score }
#    Ocr {Settings, Find, Nth} -> text read, or a note of the click
#    Excel {Request} -> cell text   Outlook {Mail} -> 'SEND'|'DISPLAY'|'DRAFT'   OpenUrl {Url}
#    FileExists {Path} -> bool   Now {} -> datetime
#    Confirm {Caption, Message} -> 'continue'|'skip'|'stop'
#    Ask {Caption, Message, Default} -> @{ Choice = 'continue'|'skip'|'stop'; Value }
#    Progress {Text}   Highlight {StepIndex}   Watch {}   Alarm {}   Notify {}   EndRun {}
#
#  Each step returns @{ Action = 'next'|'skipRow'|'error'; Delay; Message; RecordRow; Uncatchable }.
# ---------------------------------------------------------------------------------------------

$script:FujiRunLimits = @{
    PasteSettleMs = 250; CopyWaitMs = 400; WindowRetryMax = 3; WindowRetryMs = 1000; CallDepthMax = 10
}
$script:FujiEvidenceFolder = 'evidence'

function New-FujiStopException {
    param([string]$Reason)
    return (New-Object -TypeName System.OperationCanceledException -ArgumentList $Reason)
}

# ----------------------------------------------------------------- before a run
# The rows to run: @{ Rows; Logs = @(@(message, level)); Error (message for a dialog); Range }.
# No CSV: one test row (No 0). Rows are 1-based; blank rows are skipped; a results / error CSV's
# original row number column keeps {{ROW}} pointing at the original rows.
function Get-FujiRunRow {
    param([AllowEmptyCollection()][object[]]$CsvRows = @(), [string[]]$Header = $null, [AllowEmptyString()][string]$StartText = '', [AllowEmptyString()][string]$EndText = '')
    $logs = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($CsvRows.Count -eq 0) {
        $list.Add(@{ No = 0; Data = [string[]]@() })
        return @{ Rows = $list; Logs = $logs; Error = ''; Range = '' }
    }
    $s = (ConvertTo-FujiHalfWidthDigit -Text ([string]$StartText)).Trim()
    $e = (ConvertTo-FujiHalfWidthDigit -Text ([string]$EndText)).Trim()
    if (($s -ne '' -and $s -notmatch '^[0-9]+$') -or ($e -ne '' -and $e -notmatch '^[0-9]+$')) {
        # Never fall back to "all rows" on a typo: that would enter rows twice
        return @{ Rows = $list; Logs = $logs; Error = (Get-FujiText 'run.rangeBad' $StartText $EndText); Range = '' }
    }
    $start = 1
    if ($s -ne '') { $start = [Math]::Max(1, [int]$s) }
    $end = $CsvRows.Count
    if ($e -ne '') { $end = [Math]::Min($CsvRows.Count, [int]$e) }
    if ($start -gt $end) {
        $logs.Add(@((Get-FujiText 'run.rangeOrder' $start $end), 'warn'))
        return @{ Rows = $list; Logs = $logs; Error = ''; Range = '' }
    }
    $origCol = -1
    if ($null -ne $Header) {
        $marker = Get-FujiText 'editor.csv.resultHeaderName'
        for ($i = 0; $i -lt $Header.Length; $i++) { if ($Header[$i].Trim() -ceq $marker) { $origCol = $i; break } }
    }
    $origUsed = 0
    $blank = 0
    for ($r = $start; $r -le $end; $r++) {
        $data = [string[]]$CsvRows[$r - 1]
        if (Test-FujiBlankRow -Row $data) { $blank++; continue }
        $no = $r
        if ($origCol -ge 0 -and $origCol -lt $data.Length) {
            $t = $data[$origCol].Trim()
            if ($t -match '^[1-9][0-9]*$') { $no = [int]$t; $origUsed++ }
        }
        $list.Add(@{ No = $no; Data = $data })
    }
    if ($origUsed -gt 0) { $logs.Add(@((Get-FujiText 'run.origRowNo'), 'info')) }
    if ($blank -gt 0) { $logs.Add(@((Get-FujiText 'run.blankSkipped' $blank), 'info')) }
    if ($list.Count -eq 0) { $logs.Add(@((Get-FujiText 'run.noRows'), 'warn')) }
    return @{ Rows = $list; Logs = $logs; Error = ''; Range = (Get-FujiText 'run.range' $start $end) }
}

# A run state. Macros: the list CALL_MACRO looks in. Options: Interval (ms), SafeMode.
function New-FujiRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Macro,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Macros,
        [Parameter(Mandatory)][System.Collections.IList]$Rows,
        [string[]]$Header = $null,
        [Parameter(Mandatory)][hashtable]$Io,
        [int]$Interval = 300,
        [bool]$SafeMode = $false,
        [string]$Directory = '',
        [scriptblock]$ResolvePath = $null
    )
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $Macro.steps) { $steps.Add((Copy-FujiStep -Step $s)) }
    return @{
        Io = $Io; Directory = $Directory; ResolvePath = $ResolvePath; Macro = $Macro; Macros = $Macros; Header = $Header; Rows = $Rows
        Steps = $steps; RootSteps = $steps; CallStack = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        TargetWindow = [string]$Macro.targetWindow; ActiveTitle = [string]$Macro.targetWindow
        RowPos = 0; StepIndex = 0; Interval = [Math]::Max(0, $Interval); SafeMode = $SafeMode
        DoneRows = 0; SkippedRows = 0; Vars = [ordered]@{}
        LoopStack = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        TryStack = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        FinalOnly = $false; FinalGroupEnd = -1
        CurrentResult = $null; ErrorRows = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        ResultRows = (New-Object -TypeName 'System.Collections.Generic.List[object]'); ResultColumns = (New-Object -TypeName 'System.Collections.Generic.List[string]')
        Running = $false; Status = ''; StartTime = (Get-Date); Summary = ''
    }
}

# ----------------------------------------------------------------- small helpers
function Write-FujiRunLog {
    param([hashtable]$Run, [string]$Message, [string]$Level = 'info')
    & $Run.Io.Log $Message $Level
}

function Wait-FujiRun {
    param([hashtable]$Run, [int]$Ms)
    $resumed = & $Run.Io.Wait ([Math]::Max(0, $Ms))
    if ($resumed -eq $true) { Resume-FujiRunTarget -Run $Run }
}

# After a pause the user may have clicked elsewhere: give the input target the focus again
function Resume-FujiRunTarget {
    param([hashtable]$Run)
    Write-FujiRunLog $Run (Get-FujiText 'run.resume') 'run'
    if ($Run.ActiveTitle) {
        if (-not (Invoke-FujiActivate -Run $Run -Title $Run.ActiveTitle)) {
            throw (New-FujiRunFailure (Get-FujiText 'run.resumeFailed' $Run.ActiveTitle))
        }
        Wait-FujiRun -Run $Run -Ms 300
    } else {
        Write-FujiRunLog $Run (Get-FujiText 'run.noTargetResume') 'warn'
        Wait-FujiRun -Run $Run -Ms 1500
    }
}

# An error raised from a helper (activation inside a wait ...): turned into a step error
function New-FujiRunFailure {
    param([string]$Message)
    $ex = New-Object -TypeName System.InvalidOperationException -ArgumentList $Message
    $ex.Data['FujiRunFailure'] = $true
    return $ex
}

function Get-FujiRunNext {
    param($Delay = $null)
    return @{ Action = 'next'; Delay = $Delay }
}

function Get-FujiRunError {
    param([string]$Message, [bool]$RecordRow = $true, [bool]$Uncatchable = $false)
    return @{ Action = 'error'; Message = $Message; RecordRow = $RecordRow; Uncatchable = $Uncatchable }
}

function Get-FujiRunRowCaption {
    param([hashtable]$Row)
    if ($Row.No -gt 0) { return (Get-FujiText 'run.rowCaption' $Row.No) }
    return (Get-FujiText 'run.testRun')
}

function Get-FujiRunCurrentRow {
    param([hashtable]$Run)
    if ($Run.RowPos -lt $Run.Rows.Count) { return $Run.Rows[$Run.RowPos] }
    return @{ No = 0; Data = [string[]]@() }
}

function Get-FujiRunContext {
    param([hashtable]$Run)
    return @{
        Row = (Get-FujiRunCurrentRow $Run); Header = $Run.Header; Vars = $Run.Vars; Log = $Run.Io.Log
        FileExists = $Run.Io.FileExists; WindowExists = $Run.Io.WindowExists
    }
}

function Expand-FujiRunText {
    param([hashtable]$Run, [AllowNull()][AllowEmptyString()][string]$Text, [System.Collections.Generic.List[string]]$Unsafe = $null)
    return (Expand-FujiPlaceholder -Text $Text -Context (Get-FujiRunContext $Run) -Unsafe $Unsafe)
}

# WScript-style key codes: {SPACE} and {SPACE n} are not key codes, so they become spaces
function ConvertTo-FujiSendKeys {
    param([AllowEmptyString()][string]$Keys)
    return [regex]::Replace([string]$Keys, '\{SPACE(?:\s+([0-9]+))?\}', {
            param($m)
            $n = 1
            if ($m.Groups[1].Success) { $n = [int]$m.Groups[1].Value }
            return (' ' * $n)
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# A one-setting command whose field takes placeholders has its whole value expanded
function Test-FujiExpandValue {
    param([System.Collections.IDictionary]$Def)
    if ($Def.Contains('hideVal') -and $Def['hideVal']) { return $false }
    # No "@(...)" around the list (see Import-FujiEditorCsv)
    $fields = $Def['fields']
    return ($fields.Count -eq 1 -and $fields[0].Contains('placeholders') -and [bool]$fields[0]['placeholders'])
}

function Update-FujiRunProgress {
    param([hashtable]$Run, [string]$Extra = '')
    $row = Get-FujiRunCurrentRow $Run
    $text = Get-FujiText 'run.progress' (Get-FujiText 'run.running') (Get-FujiRunRowCaption $row) ([Math]::Min($Run.RowPos + 1, $Run.Rows.Count)) $Run.Rows.Count
    if ($Run.StepIndex -ge 0 -and $Run.StepIndex -lt $Run.Steps.Count) {
        $text += Get-FujiText 'run.progressStep' ($Run.StepIndex + 1) $Run.Steps.Count $Run.Steps[$Run.StepIndex].cmd
    }
    & $Run.Io.Progress ($text + $Extra)
}

# ----------------------------------------------------------------- results and error rows
function Start-FujiResultRow {
    param([hashtable]$Run, [hashtable]$Row)
    $r = @{ No = $Row.No; Data = [string[]]@($Row.Data); Values = @{}; Status = (Get-FujiText 'run.resultRunning'); Note = ''; Time = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss') }
    $Run.ResultRows.Add($r)
    return $r
}

function Set-FujiRowResult {
    param([hashtable]$Run, [string]$Status, [string]$Note = '')
    $r = $Run.CurrentResult
    if ($null -ne $r -and $r.Status -eq (Get-FujiText 'run.resultRunning')) {
        $r.Status = $Status
        # A note already there (an error caught by "on error") is kept
        if ($Note -and $r.Note) { $r.Note = $r.Note + ' / ' + $Note } elseif ($Note) { $r.Note = $Note }
    }
}

function Add-FujiResultValue {
    param([hashtable]$Run, [string]$Name, [AllowEmptyString()][string]$Value)
    if ($null -eq $Run.CurrentResult) { return }
    if (-not $Run.ResultColumns.Contains($Name)) { $Run.ResultColumns.Add($Name) }
    $Run.CurrentResult.Values[$Name] = $Value
}

function Add-FujiErrorRow {
    param([hashtable]$Run, [string]$Reason)
    if ($Run.RowPos -ge $Run.Rows.Count) { return }
    $row = $Run.Rows[$Run.RowPos]
    # test run without CSV / the skipped last row was already recorded
    if ($row.No -le 0 -or $Run.FinalOnly) { return }
    $Run.ErrorRows.Add(@{ No = $row.No; Data = [string[]]@($row.Data); Reason = $Reason; Time = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss') })
}

# CSV text of the error rows: the original columns, then original row number, error, time.
# Always a heading line, so re-running it with "first line is the header" finds the row numbers.
function ConvertTo-FujiErrorCsv {
    param([Parameter(Mandatory)][hashtable]$Run)
    $max = 0
    foreach ($e in $Run.ErrorRows) { $max = [Math]::Max($max, $e.Data.Length) }
    $header = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($null -ne $Run.Header) { foreach ($h in $Run.Header) { $header.Add($h) } }
    $max = [Math]::Max($max, $header.Count)
    while ($header.Count -lt $max) {
        if ($null -ne $Run.Header) { $header.Add('') } else { $header.Add((Get-FujiText 'run.colPrefix' ($header.Count + 1))) }
    }
    $header.Add((Get-FujiText 'run.colOrigNo'))
    $header.Add((Get-FujiText 'run.colError'))
    $header.Add((Get-FujiText 'run.colTime'))
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $rows.Add($header.ToArray())
    foreach ($e in $Run.ErrorRows) {
        $cols = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($v in $e.Data) { $cols.Add($v) }
        while ($cols.Count -lt $max) { $cols.Add('') }
        $cols.Add([string]$e.No)
        $cols.Add($e.Reason)
        $cols.Add($e.Time)
        $rows.Add($cols.ToArray())
    }
    return (ConvertTo-FujiCsvText -Rows $rows.ToArray())
}

# CSV text of the run results: the original columns, recorded values, result, note, row number, time
function ConvertTo-FujiResultCsv {
    param([Parameter(Mandatory)][hashtable]$Run)
    $max = 0
    if ($null -ne $Run.Header) { $max = $Run.Header.Length }
    foreach ($r in $Run.ResultRows) { $max = [Math]::Max($max, $r.Data.Length) }
    $header = New-Object -TypeName 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $max; $i++) {
        if ($null -ne $Run.Header -and $i -lt $Run.Header.Length) { $header.Add($Run.Header[$i]) } else { $header.Add((Get-FujiText 'run.colPrefix' ($i + 1))) }
    }
    foreach ($c in $Run.ResultColumns) { $header.Add($c) }
    foreach ($k in @('run.colResult', 'run.colNote', 'run.colOrigNo', 'run.colStart')) { $header.Add((Get-FujiText $k)) }
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $rows.Add($header.ToArray())
    foreach ($r in $Run.ResultRows) {
        $cols = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($v in $r.Data) { $cols.Add($v) }
        while ($cols.Count -lt $max) { $cols.Add('') }
        foreach ($c in $Run.ResultColumns) { if ($r.Values.ContainsKey($c)) { $cols.Add([string]$r.Values[$c]) } else { $cols.Add('') } }
        $cols.Add($r.Status)
        $cols.Add($r.Note)
        if ($r.No -gt 0) { $cols.Add([string]$r.No) } else { $cols.Add((Get-FujiText 'run.testRow')) }
        $cols.Add($r.Time)
        $rows.Add($cols.ToArray())
    }
    return (ConvertTo-FujiCsvText -Rows $rows.ToArray())
}

# What the variable panel shows: @( @(title, @(@(name, value), ...)), ... )
function Get-FujiRunWatch {
    param([hashtable]$Run)
    $vars = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($k in $Run.Vars.Keys) { $vars.Add(@(('$' + $k), [string]$Run.Vars[$k])) }
    $loops = New-Object -TypeName 'System.Collections.Generic.List[object]'
    for ($j = 0; $j -lt $Run.LoopStack.Count; $j++) {
        $f = $Run.LoopStack[$j]
        $text = Get-FujiText 'run.watchIter' $f.Iter
        if ($f.Count -ge 0) { $text = Get-FujiText 'run.watchIterOf' $f.Iter $f.Count }
        $loops.Add(@((Get-FujiText 'run.watchLoop' ($j + 1)), $text))
    }
    $csv = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $row = $Run.Rows[[Math]::Min($Run.RowPos, $Run.Rows.Count - 1)]
    if ($row.No -gt 0) {
        $csv.Add(@('ROW', [string]$row.No))
        for ($i = 0; $i -lt $row.Data.Length -and $i -lt 30; $i++) {
            $name = [string]($i + 1)
            if ($null -ne $Run.Header -and $i -lt $Run.Header.Length -and $Run.Header[$i]) { $name = $Run.Header[$i] }
            $csv.Add(@($name, $row.Data[$i]))
        }
    }
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $out.Add(@((Get-FujiText 'run.watchVars'), $vars.ToArray()))
    if ($loops.Count -gt 0) { $out.Add(@((Get-FujiText 'run.watchLoops'), $loops.ToArray())) }
    $out.Add(@((Get-FujiText 'run.watchCsv'), $csv.ToArray()))
    return , $out.ToArray()
}

# ----------------------------------------------------------------- windows
function Invoke-FujiActivate {
    param([hashtable]$Run, [string]$Title)
    for ($attempt = 1; $attempt -le $script:FujiRunLimits.WindowRetryMax; $attempt++) {
        if (& $Run.Io.Activate $Title) {
            Wait-FujiRun -Run $Run -Ms 250
            return $true
        }
        if ($attempt -lt $script:FujiRunLimits.WindowRetryMax) {
            Write-FujiRunLog $Run (Get-FujiText 'run.searching' $Title $attempt $script:FujiRunLimits.WindowRetryMax) 'warn'
            Wait-FujiRun -Run $Run -Ms $script:FujiRunLimits.WindowRetryMs
        }
    }
    return $false
}

# Makes sure keystrokes never land in this app itself. Returns $null or an error result.
function Confirm-FujiInputTarget {
    param([hashtable]$Run)
    $self = [bool](& $Run.Io.SelfHasFocus)
    if (-not $self -and -not $Run.SafeMode) { return $null }
    if (-not $Run.ActiveTitle) {
        if ($self) { return (Get-FujiRunError (Get-FujiText 'run.selfInput')) }
        return $null
    }
    if ($self) { Write-FujiRunLog $Run (Get-FujiText 'run.backToTarget' $Run.ActiveTitle) 'warn' }
    if (-not (Invoke-FujiActivate -Run $Run -Title $Run.ActiveTitle)) { return (Get-FujiRunError (Get-FujiText 'run.lostTarget' $Run.ActiveTitle)) }
    return $null
}

# After a dialog this app has the focus: give it back to the input target
function Restore-FujiRunTarget {
    param([hashtable]$Run, [string]$FailKey)
    if ($Run.ActiveTitle) {
        if (-not (Invoke-FujiActivate -Run $Run -Title $Run.ActiveTitle)) { return (Get-FujiRunError (Get-FujiText $FailKey $Run.ActiveTitle)) }
        return (Get-FujiRunNext 300)
    }
    Write-FujiRunLog $Run (Get-FujiText 'run.noTargetResume') 'warn'
    Wait-FujiRun -Run $Run -Ms 1500
    return (Get-FujiRunNext 0)
}

# The clipboard is written right before Ctrl+V (a pause in between must not paste whatever the
# user copied meanwhile); the next step waits until the target app has taken the paste
function Invoke-FujiPaste {
    param([hashtable]$Run, [AllowEmptyString()][string]$Text, [string]$What)
    if ($Text -eq '') {
        Write-FujiRunLog $Run (Get-FujiText 'run.pasteEmpty' $What)
        return (Get-FujiRunNext)
    }
    Wait-FujiRun -Run $Run -Ms 80
    if (-not (& $Run.Io.SetClipboard $Text)) { return (Get-FujiRunError (Get-FujiText 'run.clipboardFailed')) }
    & $Run.Io.SendKeys '^v'
    Write-FujiRunLog $Run (Get-FujiText 'run.pasted' $What (Format-FujiShort $Text 30))
    return (Get-FujiRunNext ([Math]::Max($Run.Interval, $script:FujiRunLimits.PasteSettleMs)))
}

# ----------------------------------------------------------------- blocks while running
function Skip-FujiBlockBody {
    param([hashtable]$Run, [string]$Message = '')
    $end = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $Run.StepIndex
    if ($end -gt $Run.StepIndex) { $Run.StepIndex = $end }
    if ($Message) { Write-FujiRunLog $Run $Message }
}

# Loop / try frames outside the current position are dropped (left by a jump, a skip or BREAK)
function Limit-FujiRunFrame {
    param([hashtable]$Run)
    $i = $Run.StepIndex
    foreach ($name in @('LoopStack', 'TryStack')) {
        $keep = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($f in $Run[$name]) { if ($i -ge $f.Start -and $i -le $f.End) { $keep.Add($f) } }
        $Run[$name] = $keep
    }
}

# skipFirstOnly: the current row is not the first one, so "first row only" groups are closed
function Find-FujiFinalGroup {
    param([System.Collections.IList]$Steps, [int]$From, [bool]$SkipFirstOnly)
    for ($i = [Math]::Max(0, $From); $i -lt $Steps.Count; $i++) {
        $s = $Steps[$i]
        if (-not (Test-FujiBlockStart $s.cmd)) { continue }
        $when = ''
        if ($s.Contains('when')) { $when = [string]$s['when'] }
        if (($s.Contains('disabled') -and $s['disabled']) -or ($SkipFirstOnly -and $when -eq 'first')) {
            # Never descend into a group that would not run: a "last" group inside it stays skipped
            $end = Find-FujiBlockEnd -Steps $Steps -StartIndex $i
            if ($end -gt $i) { $i = $end }
            continue
        }
        if ($when -eq 'last') { return $i }
    }
    return -1
}

# Back to the caller (end of a called macro, or RETURN). $false at the top level.
function Exit-FujiCall {
    param([hashtable]$Run)
    if ($Run.CallStack.Count -eq 0) { return $false }
    $f = $Run.CallStack[$Run.CallStack.Count - 1]
    $Run.CallStack.RemoveAt($Run.CallStack.Count - 1)
    Write-FujiRunLog $Run (Get-FujiText 'run.returned' $f.Name)
    $Run.Steps = $f.Steps
    $Run.StepIndex = $f.Index
    $Run.LoopStack = $f.LoopStack
    $Run.TryStack = $f.TryStack
    return $true
}

# An error inside "on error" goes to its CATCH section instead of stopping the run. $true when handled.
function Resolve-FujiRunError {
    param([hashtable]$Run, [string]$Message)
    Limit-FujiRunFrame -Run $Run
    while ($Run.TryStack.Count -gt 0 -or $Run.CallStack.Count -gt 0) {
        if ($Run.TryStack.Count -eq 0) {
            # No handler in the called macro: look for one around the CALL_MACRO step in the caller
            [void](Exit-FujiCall -Run $Run)
            Limit-FujiRunFrame -Run $Run
            continue
        }
        $f = $Run.TryStack[$Run.TryStack.Count - 1]
        if ($f.CatchIndex -ge 0 -and $Run.StepIndex -gt $f.CatchIndex) {
            # the error happened inside the CATCH section itself: pass it outward
            $Run.TryStack.RemoveAt($Run.TryStack.Count - 1)
            continue
        }
        $text = $Message -replace ('^' + [char]::ConvertFromUtf32(0x1F6A8) + '\s*'), ''
        $Run.Vars[(Get-FujiText 'data.errorVar')] = $text
        $more = ''
        if ($f.CatchIndex -ge 0) { $more = Get-FujiText 'run.caughtToCatch' }
        Write-FujiRunLog $Run (Get-FujiText 'run.caught' $text $more) 'warn'
        if ($f.CatchIndex -ge 0) {
            $Run.StepIndex = $f.CatchIndex + 1
        } else {
            $Run.TryStack.RemoveAt($Run.TryStack.Count - 1)
            $Run.StepIndex = $f.End + 1
        }
        if ($null -ne $Run.CurrentResult) {
            $held = $Run.CurrentResult
            $note = Get-FujiText 'run.caughtNote' $text
            if ($held.Note) { $held.Note = $held.Note + ' / ' + $note } else { $held.Note = $note }
        }
        & $Run.Io.Watch
        return $true
    }
    return $false
}

# ----------------------------------------------------------------- the run
# Runs everything; returns the final status ('done', 'stopped' or 'error')
function Invoke-FujiRun {
    param([Parameter(Mandatory)][hashtable]$Run)
    $Run.Running = $true
    $Run.StartTime = Get-Date
    try {
        if (-not $Run.TargetWindow) {
            Write-FujiRunLog $Run (Get-FujiText 'run.noTarget') 'warn'
            Wait-FujiRun -Run $Run -Ms 3000
        } else {
            Wait-FujiRun -Run $Run -Ms 100
        }
        while ($Run.RowPos -lt $Run.Rows.Count) {
            if (-not (Invoke-FujiRunRow -Run $Run)) { return $Run.Status }
            $Run.RowPos++
            if ($Run.RowPos -lt $Run.Rows.Count) { Wait-FujiRun -Run $Run -Ms ([Math]::Max($Run.Interval, 300)) }
        }
        Write-FujiRunLog $Run (Get-FujiText 'run.allDone') 'ok'
        Complete-FujiRun -Run $Run -Status 'done'
        & $Run.Io.Notify
    } catch [System.OperationCanceledException] {
        if ($Run.Running) {
            $reason = $_.Exception.Message
            Write-FujiRunLog $Run (Get-FujiText 'run.stopped' $reason) 'warn'
            Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultStopped') -Note $reason
            Complete-FujiRun -Run $Run -Status 'stopped'
        }
    } catch {
        # A failure outside a step (the target window lost while resuming from a pause ...)
        if ($Run.Running) {
            $ex = $_.Exception
            $message = $ex.Message
            if (-not $ex.Data.Contains('FujiRunFailure')) { $message = Get-FujiText 'run.unexpected' $message }
            Stop-FujiRunWithError -Run $Run -Result (Get-FujiRunError $message)
        }
    } finally {
        if ($Run.Running) { Complete-FujiRun -Run $Run -Status 'error' }
        & $Run.Io.EndRun
    }
    return $Run.Status
}

function Complete-FujiRun {
    param([hashtable]$Run, [string]$Status)
    if (-not $Run.Running) { return }
    $Run.Running = $false
    $Run.Status = $Status
    $key = @{ done = 'run.statusDone'; stopped = 'run.statusStopped'; error = 'run.statusError' }[$Status]
    $sec = [int][Math]::Round(((Get-Date) - $Run.StartTime).TotalSeconds)
    $Run.Summary = Get-FujiText 'run.summary' (Get-FujiText $key) $Run.DoneRows $Run.SkippedRows $Run.ErrorRows.Count $sec
    $level = 'warn'
    if ($Status -eq 'done') { $level = 'ok' }
    Write-FujiRunLog $Run ([string][char]0x25A0 + ' ' + $Run.Summary) $level
}

# An error that was not caught: stops the run
function Stop-FujiRunWithError {
    param([hashtable]$Run, [hashtable]$Result)
    Write-FujiRunLog $Run $Result.Message 'error'
    if ($Result.RecordRow) { Add-FujiErrorRow -Run $Run -Reason $Result.Message }
    if ($Run.FinalOnly -and $null -ne $Run.CurrentResult) {
        # The skipped last row already has its status: keep the error visible in its note
        $r = $Run.CurrentResult
        $note = Get-FujiText 'run.finalNote' $Result.Message
        if ($r.Note) { $r.Note = $r.Note + ' / ' + $note } else { $r.Note = $note }
    }
    Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultError') -Note $Result.Message
    Complete-FujiRun -Run $Run -Status 'error'
    & $Run.Io.Alarm
    & $Run.Io.FocusSelf
}

# One CSV row. $false when the run ended (error) during it.
function Invoke-FujiRunRow {
    param([hashtable]$Run)
    $row = $Run.Rows[$Run.RowPos]
    $Run.StepIndex = 0
    $Run.ActiveTitle = $Run.TargetWindow
    $Run.Steps = $Run.RootSteps
    $Run.CallStack.Clear()
    $Run.LoopStack = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $Run.TryStack = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $Run.FinalOnly = $false
    $Run.CurrentResult = Start-FujiResultRow -Run $Run -Row $row
    Update-FujiRunProgress -Run $Run
    Write-FujiRunLog $Run (Get-FujiText 'run.rowStart' (Get-FujiRunRowCaption $row) ($Run.RowPos + 1) $Run.Rows.Count) 'run'
    if ($Run.ActiveTitle) {
        if (-not (Invoke-FujiActivate -Run $Run -Title $Run.ActiveTitle)) {
            Stop-FujiRunWithError -Run $Run -Result (Get-FujiRunError (Get-FujiText 'run.targetNotFound' $Run.ActiveTitle $script:FujiRunLimits.WindowRetryMax))
            return $false
        }
        Wait-FujiRun -Run $Run -Ms 150
    }
    while ($true) {
        if ($Run.FinalOnly -and $Run.StepIndex -gt $Run.FinalGroupEnd) {
            # Only "last row only" groups run for a skipped last row
            $g = Find-FujiFinalGroup -Steps $Run.Steps -From $Run.StepIndex -SkipFirstOnly ($Run.RowPos -ne 0)
            if ($g -ge 0) { $Run.StepIndex = $g; $Run.FinalGroupEnd = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $g } else { $Run.StepIndex = $Run.Steps.Count; $Run.FinalGroupEnd = -1 }
        }
        if ($Run.StepIndex -ge $Run.Steps.Count -and -not $Run.FinalOnly -and (Exit-FujiCall -Run $Run)) {
            $Run.StepIndex++   # continue after the CALL_MACRO step
            Wait-FujiRun -Run $Run -Ms $Run.Interval
            continue
        }
        if ($Run.StepIndex -ge $Run.Steps.Count) {
            if ($Run.FinalOnly) {
                $Run.FinalOnly = $false
            } else {
                $Run.DoneRows++
                Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultDone')
                Write-FujiRunLog $Run (Get-FujiText 'run.rowDone' (Get-FujiRunRowCaption $row)) 'ok'
            }
            return $true
        }
        Limit-FujiRunFrame -Run $Run
        $highlight = $Run.StepIndex
        if ($Run.CallStack.Count -gt 0) { $highlight = $Run.CallStack[0].Index }
        & $Run.Io.Highlight $highlight
        Update-FujiRunProgress -Run $Run
        & $Run.Io.Watch
        $res = Invoke-FujiRunStep -Run $Run -Step $Run.Steps[$Run.StepIndex]
        switch ($res.Action) {
            'skipRow' {
                if ($Run.FinalOnly) {
                    # A skip inside the final-only pass: the row was already counted and recorded
                    $Run.FinalOnly = $false
                    return $true
                }
                $Run.SkippedRows++
                Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultSkip')
                # a skip inside a called macro ends the whole row: unwind to the top-level macro
                while (Exit-FujiCall -Run $Run) { $null = $Run.StepIndex }
                if ($Run.RowPos -eq $Run.Rows.Count - 1) {
                    # The last row was skipped: still run the "last row only" groups (save / clean-up)
                    $g = Find-FujiFinalGroup -Steps $Run.Steps -From ($Run.StepIndex + 1) -SkipFirstOnly ($Run.RowPos -ne 0)
                    if ($g -ge 0) {
                        $Run.FinalOnly = $true
                        $Run.StepIndex = $g
                        $Run.FinalGroupEnd = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $g
                        Write-FujiRunLog $Run (Get-FujiText 'run.finalOnly')
                        Wait-FujiRun -Run $Run -Ms $Run.Interval
                        continue
                    }
                }
                return $true
            }
            'error' {
                if (-not $res.Uncatchable -and (Resolve-FujiRunError -Run $Run -Message $res.Message)) {
                    Wait-FujiRun -Run $Run -Ms $Run.Interval
                    continue
                }
                Stop-FujiRunWithError -Run $Run -Result $res
                return $false
            }
            default {
                $Run.StepIndex++
                $delay = $Run.Interval
                if ($null -ne $res.Delay) { $delay = [int]$res.Delay }
                Wait-FujiRun -Run $Run -Ms $delay
            }
        }
    }
}

# One step; unexpected failures become errors (a stop always passes through)
function Invoke-FujiRunStep {
    param([hashtable]$Run, [System.Collections.IDictionary]$Step)
    try {
        $res = Invoke-FujiRunCommand -Run $Run -Step $Step
    } catch [System.OperationCanceledException] {
        throw
    } catch {
        $ex = $_.Exception
        if ($ex.Data.Contains('FujiRunFailure')) { return (Get-FujiRunError $ex.Message) }
        return (Get-FujiRunError (Get-FujiText 'run.unexpected' $ex.Message))
    }
    if ($null -eq $res) { return (Get-FujiRunNext) }
    return $res
}

function Invoke-FujiRunCommand {
    param([hashtable]$Run, [System.Collections.IDictionary]$Step)
    $cmd = [string]$Step.cmd
    $def = Get-FujiCommandDef $cmd
    $val = [string]$Step.val
    if ($Step.Contains('disabled') -and $Step['disabled']) {
        if (Test-FujiBlockStart $cmd) {
            $name = [string]$Step.label
            if (-not $name) { $name = Get-FujiStepLabel -Cmd $cmd -Value $val }
            Skip-FujiBlockBody -Run $Run -Message (Get-FujiText 'run.disabledSkip' $name)
        }
        return (Get-FujiRunNext 0)
    }
    $unsafe = $null
    if ($cmd -eq 'RUN') { $unsafe = New-Object -TypeName 'System.Collections.Generic.List[string]' }
    if ($null -ne $def -and (Test-FujiExpandValue $def)) { $val = Expand-FujiRunText -Run $Run -Text $val -Unsafe $unsafe }
    $p = ConvertFrom-FujiStepValue -Cmd $cmd -Value ([string]$Step.val)
    switch ($cmd) {
        'GROUP_START' {
            $when = ''
            if ($Step.Contains('when')) { $when = [string]$Step['when'] }
            if (($when -eq 'first' -and $Run.RowPos -ne 0) -or ($when -eq 'last' -and $Run.RowPos -ne $Run.Rows.Count - 1)) { Skip-FujiBlockBody -Run $Run }
            return (Get-FujiRunNext 0)
        }
        { $_ -in @('COMMENT', 'GROUP_END', 'IF_END') } { return (Get-FujiRunNext 0) }
        'KEY' {
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            & $Run.Io.SendKeys (ConvertTo-FujiSendKeys $val)
            Write-FujiRunLog $Run (Get-FujiText 'run.key' $val (Get-FujiKeyName $val))
            return (Get-FujiRunNext)
        }
        'TEXT' {
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            return (Invoke-FujiPaste -Run $Run -Text $val -What (Get-FujiText 'run.whatText'))
        }
        'CSV' {
            $col = Get-FujiInt -Text $val -Default 0
            $row = Get-FujiRunCurrentRow $Run
            $data = [string[]]@($row.Data)
            if ($row.No -gt 0 -and ($col -lt 1 -or $col -gt $data.Length)) { Write-FujiRunLog $Run (Get-FujiText 'run.csvMissingCol' $col $data.Length) 'warn' }
            $cell = ''
            if ($col -ge 1 -and $col -le $data.Length) { $cell = $data[$col - 1] }
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            return (Invoke-FujiPaste -Run $Run -Text $cell -What (Get-FujiText 'run.whatCsv' $col))
        }
        'COPY' {
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            $name = $val.Trim()
            [void](& $Run.Io.SetClipboard '')
            & $Run.Io.SendKeys '^c'
            Wait-FujiRun -Run $Run -Ms $script:FujiRunLimits.CopyWaitMs
            $text = ([string](& $Run.Io.GetClipboard)) -replace '(\r\n|\n|\r)+$', ''
            $Run.Vars[$name] = $text
            Add-FujiResultValue -Run $Run -Name $name -Value $text
            if ($text -eq '') { Write-FujiRunLog $Run (Get-FujiText 'run.copyEmpty' $name) 'warn' } else { Write-FujiRunLog $Run (Get-FujiText 'run.copied' $name (Format-FujiShort $text 40)) }
            return (Get-FujiRunNext)
        }
        'WAIT' {
            $ms = [Math]::Max(0, (Get-FujiInt -Text $val -Default 0))
            Write-FujiRunLog $Run (Get-FujiText 'run.wait' $ms)
            return (Get-FujiRunNext $ms)
        }
        'WAIT_FOR' { return (Invoke-FujiWaitFor -Run $Run -Settings $p) }
        'WINDOW_CHECK' { return (Invoke-FujiWindowCheck -Run $Run -Settings $p) }
        'CONFIRM' { return (Invoke-FujiConfirm -Run $Run -Message $val) }
        'SWITCH' {
            if (-not (Invoke-FujiActivate -Run $Run -Title $val)) { return (Get-FujiRunError (Get-FujiText 'run.switchNotFound' $val)) }
            $Run.ActiveTitle = $val
            Write-FujiRunLog $Run (Get-FujiText 'run.switched' $val)
            return (Get-FujiRunNext)
        }
        'RUN' {
            if ($unsafe.Count -gt 0) {
                $why = Get-FujiText 'run.runUnsafe' ($unsafe -join ([string][char]0x3001))
                Write-FujiRunLog $Run ([string][char]0x26A0 + ' ' + $why) 'error'
                Add-FujiErrorRow -Run $Run -Reason $why
                Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultSkip') -Note $why
                return @{ Action = 'skipRow' }
            }
            try {
                $note = & $Run.Io.Start $val
            } catch [System.OperationCanceledException] {
                throw
            } catch {
                return (Get-FujiRunError (Get-FujiText 'run.startFailed' $val $_.Exception.Message))
            }
            Write-FujiRunLog $Run ((Get-FujiText 'run.started' $val) + [string]$note)
            return (Get-FujiRunNext)
        }
        'CLICK_NAME' {
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            Write-FujiRunLog $Run (Get-FujiText 'run.clickNameSearch' $val)
            try { $note = & $Run.Io.ClickName $val $Run.ActiveTitle } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.clickNameFailed' $_.Exception.Message)) }
            Write-FujiRunLog $Run (Get-FujiText 'run.clickName' $val $note)
            return (Get-FujiRunNext)
        }
        'CLICK_POS' {
            $x = Get-FujiInt -Text $p['x'] -Default 0
            $y = Get-FujiInt -Text $p['y'] -Default 0
            $err = Confirm-FujiInputTarget -Run $Run
            if ($err) { return $err }
            try { & $Run.Io.ClickAt $x $y $p['kind'] } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.clickPosFailed' $_.Exception.Message)) }
            Write-FujiRunLog $Run (Get-FujiText 'run.clickPos' $x $y)
            return (Get-FujiRunNext)
        }
        'CLICK_IMG' { return (Invoke-FujiClickImage -Run $Run -Settings $p) }
        { $_ -in @('CLICK_TEXT', 'READ_TEXT') } { return (Invoke-FujiOcrStep -Run $Run -Cmd $cmd -Settings $p) }
        'SCREENSHOT' { return (Invoke-FujiScreenshot -Run $Run -Settings $p) }
        'MAIL' { return (Invoke-FujiMail -Run $Run -Settings $p) }
        { $_ -in @('EXCEL_READ', 'EXCEL_WRITE') } { return (Invoke-FujiExcel -Run $Run -Cmd $cmd -Settings $p) }
        'LOOP_START' { return (Invoke-FujiLoopStart -Run $Run -Settings $p) }
        'LOOP_END' {
            if ($Run.LoopStack.Count -gt 0) {
                $f = $Run.LoopStack[$Run.LoopStack.Count - 1]
                # the next step is LOOP_START, which decides whether to go round again
                if ($f.End -eq $Run.StepIndex) { $Run.StepIndex = $f.Start - 1 }
            }
            return (Get-FujiRunNext 0)
        }
        { $_ -in @('BREAK', 'CONTINUE') } {
            if ($Run.LoopStack.Count -eq 0) {
                Write-FujiRunLog $Run (Get-FujiText 'run.outsideLoop' $def['title']) 'warn'
                return (Get-FujiRunNext 0)
            }
            $f = $Run.LoopStack[$Run.LoopStack.Count - 1]
            if ($cmd -eq 'BREAK') {
                $Run.LoopStack.RemoveAt($Run.LoopStack.Count - 1)
                Write-FujiRunLog $Run (Get-FujiText 'run.break')
                $Run.StepIndex = $f.End
            } else {
                Write-FujiRunLog $Run (Get-FujiText 'run.continue')
                $Run.StepIndex = $f.End - 1
            }
            return (Get-FujiRunNext 0)
        }
        'IF_START' {
            try { $ok = Test-FujiRunCondition -Run $Run -Settings $p } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.ifFailed' $_.Exception.Message)) }
            $answer = Get-FujiText 'run.no'
            if ($ok) { $answer = Get-FujiText 'run.yes' }
            Write-FujiRunLog $Run (Get-FujiText 'run.ifResult' (Get-FujiConditionText $p) $answer)
            if (-not $ok) {
                $else = Find-FujiBlockMiddle -Steps $Run.Steps -StartIndex $Run.StepIndex -Cmd 'ELSE'
                if ($else -ge 0) { $Run.StepIndex = $else } else { $Run.StepIndex = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $Run.StepIndex }
            }
            return (Get-FujiRunNext 0)
        }
        { $_ -in @('ELSE', 'CATCH') } {
            # reached by finishing the previous section: skip to the end of the block
            $owner = Find-FujiBlockOwner -Steps $Run.Steps -Index $Run.StepIndex
            $end = -1
            if ($owner -ge 0) { $end = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $owner }
            if ($cmd -eq 'CATCH') {
                $keep = New-Object -TypeName 'System.Collections.Generic.List[object]'
                foreach ($f in $Run.TryStack) { if ($f.Start -ne $owner) { $keep.Add($f) } }
                $Run.TryStack = $keep
            }
            if ($end -ge 0) { $Run.StepIndex = $end }
            return (Get-FujiRunNext 0)
        }
        'TRY_START' {
            $Run.TryStack.Add(@{ Start = $Run.StepIndex; End = (Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $Run.StepIndex); CatchIndex = (Find-FujiBlockMiddle -Steps $Run.Steps -StartIndex $Run.StepIndex -Cmd 'CATCH') })
            return (Get-FujiRunNext 0)
        }
        'TRY_END' {
            $keep = New-Object -TypeName 'System.Collections.Generic.List[object]'
            foreach ($f in $Run.TryStack) { if ($f.End -ne $Run.StepIndex) { $keep.Add($f) } }
            $Run.TryStack = $keep
            return (Get-FujiRunNext 0)
        }
        'SET_VAR' {
            $value = Expand-FujiRunText -Run $Run -Text $p['value']
            if ($p['mode'] -eq 'CALC') {
                try { $value = Invoke-FujiCalc -Expression $value } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.calcFailed' $value $_.Exception.Message)) }
            }
            $Run.Vars[$p['name'].Trim()] = $value
            Write-FujiRunLog $Run (Get-FujiText 'run.setVar' $p['name'] (Format-FujiShort $value 40))
            & $Run.Io.Watch
            return (Get-FujiRunNext 0)
        }
        'STR_OP' {
            try {
                $result = Invoke-FujiStringOp -Op $p['op'] -Text (Expand-FujiRunText -Run $Run -Text $p['src']) -A (Expand-FujiRunText -Run $Run -Text $p['a']) -B (Expand-FujiRunText -Run $Run -Text $p['b'])
            } catch [System.OperationCanceledException] {
                throw
            } catch {
                return (Get-FujiRunError (Get-FujiText 'run.strOpFailed' (Get-FujiStrOpName $p['op']) $_.Exception.Message))
            }
            $Run.Vars[$p['name'].Trim()] = [string]$result
            Write-FujiRunLog $Run (Get-FujiText 'run.strOp' $p['name'] (Format-FujiShort ([string]$result) 40))
            & $Run.Io.Watch
            return (Get-FujiRunNext 0)
        }
        'ASK' { return (Invoke-FujiAsk -Run $Run -Settings $p) }
        'RECORD' {
            $value = Expand-FujiRunText -Run $Run -Text $p['value']
            Add-FujiResultValue -Run $Run -Name $p['name'].Trim() -Value $value
            Write-FujiRunLog $Run (Get-FujiText 'run.record' $p['name'] (Format-FujiShort $value 40))
            return (Get-FujiRunNext 0)
        }
        'CALL_MACRO' { return (Invoke-FujiCallMacro -Run $Run -Settings $p) }
        'RETURN' {
            $Run.StepIndex = $Run.Steps.Count - 1   # the runner then reaches the end of this macro
            Write-FujiRunLog $Run (Get-FujiText 'run.return')
            return (Get-FujiRunNext 0)
        }
    }
    Write-FujiRunLog $Run (Get-FujiText 'run.unknownCommand' $cmd) 'warn'
    return (Get-FujiRunNext 0)
}

# ----------------------------------------------------------------- commands with more to do
function Test-FujiRunCondition {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $left = Expand-FujiRunText -Run $Run -Text $Settings['left']
    $right = Expand-FujiRunText -Run $Run -Text $Settings['right']
    return [bool](Test-FujiCondition -Op ([string]$Settings['op']) -Left $left -Right $right -Context (Get-FujiRunContext $Run))
}

function Invoke-FujiWaitFor {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $title = Expand-FujiRunText -Run $Run -Text $Settings['title']
    $key = [string]$Settings['key']
    $timeout = [Math]::Max(1, (Get-FujiInt -Text $Settings['timeout'] -Default 30))
    if (-not $title) { return (Get-FujiRunError (Get-FujiText 'run.waitForEmpty')) }
    Write-FujiRunLog $Run (Get-FujiText 'run.waitFor' $title $timeout)
    for ($count = 0; ; $count++) {
        if (& $Run.Io.Activate $title) {
            Write-FujiRunLog $Run (Get-FujiText 'run.appeared' $title) 'ok'
            if ($key) {
                Wait-FujiRun -Run $Run -Ms 300
                & $Run.Io.SendKeys (ConvertTo-FujiSendKeys $key)
                Write-FujiRunLog $Run (Get-FujiText 'run.pressed' $key)
            }
            return (Get-FujiRunNext)
        }
        if ($count + 1 -ge $timeout) { return (Get-FujiRunError (Get-FujiText 'run.timeout' $title $timeout)) }
        Update-FujiRunProgress -Run $Run -Extra (Get-FujiText 'run.waitCount' ($count + 1) $timeout)
        Wait-FujiRun -Run $Run -Ms 1000
    }
}

function Invoke-FujiWindowCheck {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $title = Expand-FujiRunText -Run $Run -Text $Settings['title']
    $key = [string]$Settings['key']
    $found = $false
    if ($title) { $found = [bool](& $Run.Io.Activate $title) }
    if (-not $found) {
        Write-FujiRunLog $Run (Get-FujiText 'run.checkNone' $title)
        return (Get-FujiRunNext 0)
    }
    Write-FujiRunLog $Run (Get-FujiText 'run.checkFound' $title) 'warn'
    Wait-FujiRun -Run $Run -Ms 300
    if ($key) {
        & $Run.Io.SendKeys (ConvertTo-FujiSendKeys $key)
        Write-FujiRunLog $Run (Get-FujiText 'run.pressed' $key)
    }
    switch (Get-FujiCheckMode $Settings['mode']) {
        'CONTINUE' {
            Write-FujiRunLog $Run (Get-FujiText 'run.checkContinue')
            Wait-FujiRun -Run $Run -Ms 500
            return (Get-FujiRunNext)
        }
        'SKIP' {
            Add-FujiErrorRow -Run $Run -Reason (Get-FujiText 'run.checkSkipReason' $title)
            Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultSkip') -Note (Get-FujiText 'run.checkSkipNote' $title)
            Write-FujiRunLog $Run (Get-FujiText 'run.checkSkip') 'warn'
            Wait-FujiRun -Run $Run -Ms 500
            return @{ Action = 'skipRow' }
        }
    }
    return (Get-FujiRunError -Message (Get-FujiText 'run.checkStop' $title) -RecordRow $true -Uncatchable $true)
}

# Human-in-the-loop: the operator continues, skips the row or stops
function Invoke-FujiConfirm {
    param([hashtable]$Run, [string]$Message)
    Update-FujiRunProgress -Run $Run -Extra (Get-FujiText 'run.confirmWait')
    Write-FujiRunLog $Run (Get-FujiText 'run.confirmLog') 'warn'
    $choice = & $Run.Io.Confirm (Get-FujiText 'run.confirmTitle' (Get-FujiRunRowCaption (Get-FujiRunCurrentRow $Run))) $Message
    if ($choice -eq 'continue') {
        Write-FujiRunLog $Run (Get-FujiText 'run.confirmOk') 'run'
        return (Restore-FujiRunTarget -Run $Run -FailKey 'run.backFailed')
    }
    if ($choice -eq 'skip') {
        Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultSkip') -Note (Get-FujiText 'run.confirmSkipNote')
        Write-FujiRunLog $Run (Get-FujiText 'run.confirmSkip') 'warn'
        return @{ Action = 'skipRow' }
    }
    throw (New-FujiStopException (Get-FujiText 'run.confirmStop'))
}

function Invoke-FujiAsk {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $name = $Settings['name'].Trim()
    $message = Expand-FujiRunText -Run $Run -Text $Settings['message']
    $initial = Expand-FujiRunText -Run $Run -Text $Settings['defaultValue']
    Update-FujiRunProgress -Run $Run -Extra (Get-FujiText 'run.askWait')
    Write-FujiRunLog $Run (Get-FujiText 'run.askLog' $name) 'warn'
    $answer = & $Run.Io.Ask (Get-FujiText 'run.askTitle' (Get-FujiRunRowCaption (Get-FujiRunCurrentRow $Run))) $message $initial
    if ($answer.Choice -eq 'continue') {
        $Run.Vars[$name] = [string]$answer.Value
        Write-FujiRunLog $Run (Get-FujiText 'run.asked' $name (Format-FujiShort ([string]$answer.Value) 40))
        & $Run.Io.Watch
        return (Restore-FujiRunTarget -Run $Run -FailKey 'run.askBackFailed')
    }
    if ($answer.Choice -eq 'skip') {
        Set-FujiRowResult -Run $Run -Status (Get-FujiText 'run.resultSkip') -Note (Get-FujiText 'run.askSkipNote')
        return @{ Action = 'skipRow' }
    }
    throw (New-FujiStopException (Get-FujiText 'run.askStop'))
}

function Invoke-FujiLoopStart {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $frame = $null
    if ($Run.LoopStack.Count -gt 0 -and $Run.LoopStack[$Run.LoopStack.Count - 1].Start -eq $Run.StepIndex) { $frame = $Run.LoopStack[$Run.LoopStack.Count - 1] }
    if ($null -eq $frame) {
        $end = Find-FujiBlockEnd -Steps $Run.Steps -StartIndex $Run.StepIndex
        if ($end -lt 0) { return (Get-FujiRunError (Get-FujiText 'run.loopNoEnd')) }
        $counter = $Settings['counter'].Trim()
        if (-not $counter) { $counter = [string](Get-FujiCommandDef 'LOOP_START')['parseDefaults']['counter'] }
        $frame = @{ Start = $Run.StepIndex; End = $end; Iter = 0; Count = -1; Max = (Get-FujiInt -Text $Settings['max'] -Default 1000); Counter = $counter }
        if ($Settings['mode'] -eq 'COUNT') {
            $countText = (ConvertTo-FujiHalfWidthDigit -Text (Expand-FujiRunText -Run $Run -Text $Settings['count'])).Trim()
            if ($countText -notmatch '^[0-9]+$') { return (Get-FujiRunError (Get-FujiText 'run.loopCountBad' $countText)) }
            $frame.Count = [int]$countText
        }
        $Run.LoopStack.Add($frame)
    }
    try {
        if ($Settings['mode'] -eq 'COUNT') { $go = $frame.Iter -lt $frame.Count } else { $go = Test-FujiRunCondition -Run $Run -Settings $Settings }
    } catch [System.OperationCanceledException] {
        throw
    } catch {
        return (Get-FujiRunError (Get-FujiText 'run.loopCondFailed' $_.Exception.Message))
    }
    if ($go -and $frame.Iter -ge $frame.Max) { return (Get-FujiRunError (Get-FujiText 'run.loopMax' $frame.Max)) }
    if ($go) {
        $frame.Iter++
        $Run.Vars[$frame.Counter] = [string]$frame.Iter
        Write-FujiRunLog $Run (Get-FujiText 'run.loopIter' $frame.Iter)
        return (Get-FujiRunNext 0)
    }
    $Run.LoopStack.RemoveAt($Run.LoopStack.Count - 1)
    Write-FujiRunLog $Run (Get-FujiText 'run.loopDone' $frame.Iter)
    $Run.StepIndex = $frame.End
    return (Get-FujiRunNext 0)
}

function Invoke-FujiCallMacro {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $target = $null
    foreach ($m in $Run.Macros) { if ($Settings['id'] -and $m.id -eq $Settings['id']) { $target = $m; break } }
    if ($null -eq $target) { foreach ($m in $Run.Macros) { if ($Settings['name'] -and $m.name -eq $Settings['name']) { $target = $m; break } } }
    if ($null -eq $target) {
        $shown = [string]$Settings['name']
        if (-not $shown) { $shown = [string]$Settings['id'] }
        return (Get-FujiRunError (Get-FujiText 'run.callNotFound' $shown))
    }
    if ($Run.CallStack.Count -ge $script:FujiRunLimits.CallDepthMax) { return (Get-FujiRunError (Get-FujiText 'run.callDepth' $script:FujiRunLimits.CallDepthMax)) }
    if (-not (Test-FujiBlockBalanced -Steps $target.steps)) { return (Get-FujiRunError (Get-FujiText 'run.callUnbalanced' $target.name)) }
    $Run.CallStack.Add(@{ Steps = $Run.Steps; Index = $Run.StepIndex; LoopStack = $Run.LoopStack; TryStack = $Run.TryStack; Name = [string]$target.name })
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $target.steps) { $steps.Add((Copy-FujiStep -Step $s)) }
    $Run.Steps = $steps
    $Run.LoopStack = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $Run.TryStack = New-Object -TypeName 'System.Collections.Generic.List[object]'
    Write-FujiRunLog $Run (Get-FujiText 'run.called' $target.name)
    $Run.StepIndex = -1
    return (Get-FujiRunNext 0)
}

function Invoke-FujiClickImage {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $path = [string]$Settings['path']
    if ($Run.ResolvePath) { $path = [string](& $Run.ResolvePath $path) }
    $threshold = Get-FujiThreshold $Settings['threshold']
    if ($path -eq '' -or -not (& $Run.Io.FileExists $path)) {
        $shown = $path
        if (-not $shown) { $shown = Get-FujiText 'run.imgNone' }
        return (Get-FujiRunError (Get-FujiText 'run.imgMissing' $shown))
    }
    $err = Confirm-FujiInputTarget -Run $Run
    if ($err) { return $err }
    Write-FujiRunLog $Run (Get-FujiText 'run.imgSearch' (Get-FujiFileName $path) ([Math]::Round($threshold * 100)))
    try { $r = & $Run.Io.ClickImage $path $threshold } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.imgFailed' $_.Exception.Message)) }
    Write-FujiRunLog $Run (Get-FujiText 'run.imgFound' ([Math]::Round([double]$r.Score * 100, 1)) $r.X $r.Y)
    return (Get-FujiRunNext)
}

function Invoke-FujiOcrStep {
    param([hashtable]$Run, [string]$Cmd, [System.Collections.IDictionary]$Settings)
    $isClick = $Cmd -eq 'CLICK_TEXT'
    $find = ''
    if ($isClick -or $Settings['area'] -eq 'WINDOW') {
        $err = Confirm-FujiInputTarget -Run $Run
        if ($err) { return $err }
    }
    $nth = 1
    if ($isClick) {
        $find = Expand-FujiRunText -Run $Run -Text $Settings['text']
        $nth = [Math]::Max(1, (Get-FujiInt -Text $Settings['nth'] -Default 1))
        Write-FujiRunLog $Run (Get-FujiText 'run.ocrFind' $find)
    } else {
        Write-FujiRunLog $Run (Get-FujiText 'run.ocrRead' (Get-FujiOcrAreaText $Settings))
    }
    try { $out = [string](& $Run.Io.Ocr $Settings $find $nth) } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.ocrFailed' $_.Exception.Message)) }
    if ($isClick) {
        Write-FujiRunLog $Run (Get-FujiText 'run.ocrClicked' $find $out)
    } else {
        $text = (($out -replace "`r`n", "`n") -replace "`n+$", '') -replace "`n", "`r`n"
        $Run.Vars[$Settings['name'].Trim()] = $text
        Write-FujiRunLog $Run (Get-FujiText 'run.ocrText' $Settings['name'] (Format-FujiShort $text 60))
        & $Run.Io.Watch
    }
    return (Get-FujiRunNext)
}

function Invoke-FujiScreenshot {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $full = $Settings['scope'] -eq 'FULL'
    if (-not $full) {
        $err = Confirm-FujiInputTarget -Run $Run
        if ($err) { return $err }
    }
    $now = & $Run.Io.Now
    $name = Get-FujiSafeFileName (Expand-FujiRunText -Run $Run -Text $Settings['name'])
    if (-not $name) { $name = 'screen' }
    $folder = Join-Path (Join-Path $Run.Directory $script:FujiEvidenceFolder) $now.ToString('yyyyMMdd')
    $path = Join-Path $folder ($name + '_' + $now.ToString('HHmmss') + '.png')
    try { $note = & $Run.Io.Screenshot $path $full } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.shotFailed' $_.Exception.Message)) }
    Write-FujiRunLog $Run (Get-FujiText 'run.shot' $note $path)
    Add-FujiResultValue -Run $Run -Name (Get-FujiText 'run.evidenceColumn') -Value $path
    return (Get-FujiRunNext)
}

function Split-FujiAddress {
    param([AllowEmptyString()][string]$Text)
    return , @([regex]::Split([string]$Text, '[;,\uFF1B\u3001\s]+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Split-FujiPathList {
    param([AllowEmptyString()][string]$Text)
    return , @(([string]$Text).Split([char[]]@(';', [char]0xFF1B)) | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
}

function Invoke-FujiMail {
    param([hashtable]$Run, [System.Collections.IDictionary]$Settings)
    $m = @{}
    foreach ($k in @('to', 'cc', 'subject', 'body', 'attach')) { $m[$k] = Expand-FujiRunText -Run $Run -Text $Settings[$k] }
    $attachments = Split-FujiPathList $m.attach
    foreach ($a in $attachments) { if (-not (& $Run.Io.FileExists $a)) { return (Get-FujiRunError (Get-FujiText 'run.attachMissing' $a)) } }
    $to = Split-FujiAddress $m.to
    if ($to.Count -eq 0) { return (Get-FujiRunError (Get-FujiText 'run.mailNoTo')) }
    $cc = Split-FujiAddress $m.cc
    if ($Settings['method'] -eq 'MAILTO') {
        if ($attachments.Count -gt 0) { Write-FujiRunLog $Run (Get-FujiText 'run.mailtoNoAttach') 'warn' }
        $body = $m.body -replace '\r?\n', "`r`n"
        $url = 'mailto:' + ($to -join ',') + '?subject=' + [uri]::EscapeDataString($m.subject) + '&body=' + [uri]::EscapeDataString($body)
        if ($cc.Count -gt 0) { $url += '&cc=' + [uri]::EscapeDataString(($cc -join ',')) }
        try { & $Run.Io.OpenUrl $url } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.mailtoFailed' $_.Exception.Message)) }
        Write-FujiRunLog $Run (Get-FujiText 'run.mailtoOpened' ($to -join ', '))
        return (Get-FujiRunNext 1500)
    }
    $mode = [string]$Settings['mode']
    $mail = @{ To = ($to -join '; '); Cc = ($cc -join '; '); Subject = $m.subject; Body = $m.body; Attachments = $attachments; Mode = $mode }
    try { [void](& $Run.Io.Outlook $mail) } catch [System.OperationCanceledException] { throw } catch { return (Get-FujiRunError (Get-FujiText 'run.mailFailed' $_.Exception.Message)) }
    $column = Get-FujiText 'run.mailColumn'
    if ($mode -eq 'SEND') {
        Write-FujiRunLog $Run (Get-FujiText 'run.mailSent' (Format-FujiShort $m.subject 30) ($to -join ', ')) 'ok'
        Add-FujiResultValue -Run $Run -Name $column -Value (Get-FujiText 'run.mailSentValue')
    } elseif ($mode -eq 'DISPLAY') {
        Write-FujiRunLog $Run (Get-FujiText 'run.mailDisplayed')
        Add-FujiResultValue -Run $Run -Name $column -Value (Get-FujiText 'run.mailDisplayValue')
    } else {
        Write-FujiRunLog $Run (Get-FujiText 'run.mailDraft' (Format-FujiShort $m.subject 30)) 'ok'
        Add-FujiResultValue -Run $Run -Name $column -Value (Get-FujiText 'run.mailDraftValue')
    }
    return (Get-FujiRunNext 500)
}

# Excel without a window: Io keeps one hidden Excel per run, books stay open until the run ends
function Invoke-FujiExcel {
    param([hashtable]$Run, [string]$Cmd, [System.Collections.IDictionary]$Settings)
    $write = $Cmd -eq 'EXCEL_WRITE'
    $request = @{
        Write = $write
        Path  = (Expand-FujiRunText -Run $Run -Text $Settings['path']).Trim().Trim('"')
        Sheet = (Expand-FujiRunText -Run $Run -Text $Settings['sheet'])
        Cell  = (Expand-FujiRunText -Run $Run -Text $Settings['cell']).Trim()
        Value = ''
    }
    if ($write) { $request.Value = Expand-FujiRunText -Run $Run -Text $Settings['value'] }
    try {
        $text = [string](& $Run.Io.Excel $request)
    } catch [System.OperationCanceledException] {
        throw
    } catch {
        $what = Get-FujiText 'run.excelReadWord'
        if ($write) { $what = Get-FujiText 'run.excelWrite' }
        return (Get-FujiRunError (Get-FujiText 'run.excelFailed' $what $_.Exception.Message))
    }
    if ($write) {
        Write-FujiRunLog $Run (Get-FujiText 'run.excelWrote' (Get-FujiFileName $request.Path) $request.Cell (Format-FujiShort $request.Value 30))
    } else {
        $Run.Vars[$Settings['name'].Trim()] = $text
        Write-FujiRunLog $Run (Get-FujiText 'run.excelRead' (Get-FujiFileName $request.Path) $request.Cell (Format-FujiShort $text 40))
        & $Run.Io.Watch
    }
    return (Get-FujiRunNext 0)
}
