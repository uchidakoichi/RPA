# ---------------------------------------------------------------------------------------------
#  Effect: how much hand work the robot took over
#  Every run adds one line to fujikyun_runs.csv (time, macro, rows done, how long, how long a person
#  had to answer it). Time spent editing a macro is added up in fujikyun_edits.csv. The summary puts
#  them together with the minutes one row takes by hand (set per macro, kept in the settings file):
#    saved = rows done x minutes by hand - minutes a person spent answering the runs
#  Both files are in the app's folder (UTF-8 with BOM: Excel opens them as they are).
# ---------------------------------------------------------------------------------------------

$script:FujiRunsFile = 'fujikyun_runs.csv'
$script:FujiEditsFile = 'fujikyun_edits.csv'
# Two edits further apart than this are not one sitting: the gap is not counted (a value set here,
# not a rule from elsewhere)
$script:FujiEditGapSeconds = 300
# Keys of the columns of fujikyun_runs.csv; the headings are effect.col.<key>
$script:FujiRunColumns = @('start', 'end', 'macroId', 'macro', 'how', 'status', 'rows', 'done', 'skipped', 'errors', 'rerun', 'seconds', 'attended', 'waitAck')
$script:FujiEditColumns = @('date', 'macroId', 'macro', 'editSeconds')
$script:FujiRecordTimeFormat = 'yyyy/MM/dd HH:mm:ss'

# ----------------------------------------------------------------- run records
# One finished run -> a record (ordered: column key -> text). How: manual, schedule, trigger or test.
function New-FujiRunRecord {
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$How, [datetime]$End = (Get-Date))
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    # rows read from an error-row (or result) CSV: a run that does rows again
    $rerun = $false
    if ($null -ne $Run.Header) {
        $marker = Get-FujiText 'editor.csv.resultHeaderName'
        foreach ($h in $Run.Header) { if ([string]$h.Trim() -ceq $marker) { $rerun = $true } }
    }
    # rows that ended in an error (a test run without CSV too, which keeps no error row)
    $failed = 0
    $errorText = Get-FujiText 'run.resultError'
    foreach ($r in $Run.ResultRows) { if ($r.Status -eq $errorText) { $failed++ } }
    $rows = $Run.ResultRows.Count
    return [ordered]@{
        start = $Run.StartTime.ToString($script:FujiRecordTimeFormat, $inv); end = $End.ToString($script:FujiRecordTimeFormat, $inv)
        macroId = [string]$Run.Macro.id; macro = [string]$Run.Macro.name; how = (Get-FujiText ('effect.how.' + $How)); status = (Get-FujiText ('effect.status.' + [string]$Run.Status))
        rows = [string]$rows; done = [string]$Run.DoneRows; skipped = [string]$Run.SkippedRows; errors = [string]$failed
        rerun = $(if ($rerun) { Get-FujiText 'effect.yes' } else { '' })
        seconds = [string][int][Math]::Round(($End - $Run.StartTime).TotalSeconds)
        attended = [string][int][Math]::Round($Run.AttendedMs / 1000.0)
        waitAck = ''
    }
}

function Get-FujiRecordHeader {
    param([string[]]$Keys)
    return [string[]]@($Keys | ForEach-Object { Get-FujiText ('effect.col.' + $_) })
}

# Adds a record at the end of fujikyun_runs.csv (made with its heading line when missing)
function Add-FujiRunRecord {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    Add-FujiRecordLine -Path (Join-Path $Directory $script:FujiRunsFile) -Keys $script:FujiRunColumns -Record $Record
}

function Add-FujiRecordLine {
    param([string]$Path, [string[]]$Keys, [System.Collections.IDictionary]$Record)
    $values = [string[]]@($Keys | ForEach-Object { ConvertTo-FujiSafeCsvValue ([string]$Record[$_]) })
    $text = ConvertTo-FujiCsvText -Rows @(, $values)
    $enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
    try {
        if (-not [System.IO.File]::Exists($Path)) {
            [System.IO.File]::WriteAllText($Path, (ConvertTo-FujiCsvText -Rows @(, (Get-FujiRecordHeader $Keys))) + $text, $enc)
        } else {
            # appending adds no BOM
            [System.IO.File]::AppendAllText($Path, $text, $enc)
        }
    } catch {
        if (Test-FujiFileBusy -Exception $_.Exception) { throw (Get-FujiText 'data.fileBusy' $Path) }
        throw
    }
}

# The records of a file as ordered dictionaries (column key -> text). Columns are found by their
# headings, so a file with columns moved in Excel still reads. A missing file: no records.
function Read-FujiRecordFile {
    param([string]$Path, [string[]]$Keys)
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if (-not [System.IO.File]::Exists($Path)) { return , $out.ToArray() }
    $records = (ConvertFrom-FujiCsv -Text (Read-FujiCsvText -Path $Path).Text).Records
    if ($records.Count -eq 0) { return , $out.ToArray() }
    $head = Get-FujiRecordHeader $Keys
    $at = @{}
    for ($i = 0; $i -lt $records[0].Length; $i++) {
        $k = [Array]::IndexOf($head, $records[0][$i].Trim())
        if ($k -ge 0) { $at[$Keys[$k]] = $i }
    }
    for ($r = 1; $r -lt $records.Count; $r++) {
        $row = $records[$r]
        if (Test-FujiBlankRow -Row $row) { continue }
        $rec = [ordered]@{}
        foreach ($k in $Keys) {
            $v = ''
            if ($at.ContainsKey($k) -and $at[$k] -lt $row.Length) { $v = $row[$at[$k]] }
            # a value written with the apostrophe that keeps Excel from reading it as a formula
            if ($v.StartsWith("'")) { $v = $v.Substring(1) }
            $rec[$k] = $v
        }
        $out.Add($rec)
    }
    return , $out.ToArray()
}

function Read-FujiRunRecord {
    param([Parameter(Mandatory)][string]$Directory)
    return , (Read-FujiRecordFile -Path (Join-Path $Directory $script:FujiRunsFile) -Keys $script:FujiRunColumns)
}

# How long the stop of a run waited until someone answered the alert: written into its record
# (the last one with that start and macro). $false when the record was not found.
function Set-FujiRunRecordAck {
    param([Parameter(Mandatory)][string]$Directory, [string]$Start, [string]$MacroId, [int]$Seconds)
    $path = Join-Path $Directory $script:FujiRunsFile
    if (-not [System.IO.File]::Exists($path)) { return $false }
    $parsed = (ConvertFrom-FujiCsv -Text (Read-FujiCsvText -Path $path).Text).Records
    if ($parsed.Count -lt 2) { return $false }
    $head = Get-FujiRecordHeader $script:FujiRunColumns
    $col = @{}
    for ($i = 0; $i -lt $parsed[0].Length; $i++) { $col[$parsed[0][$i].Trim()] = $i }
    $cStart = $col[$head[0]]
    $cId = $col[$head[2]]
    $cAck = $col[$head[13]]
    if ($null -eq $cStart -or $null -eq $cId -or $null -eq $cAck) { return $false }
    for ($r = $parsed.Count - 1; $r -ge 1; $r--) {
        $row = $parsed[$r]
        if ($row.Length -gt [Math]::Max($cStart, $cId) -and $row[$cStart] -eq $Start -and $row[$cId] -eq $MacroId) {
            $cells = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $cells.AddRange([string[]]$row)
            while ($cells.Count -le $cAck) { $cells.Add('') }
            $cells[$cAck] = [string]$Seconds
            $parsed[$r] = $cells.ToArray()
            Write-FujiTextFile -Path $path -Text (ConvertTo-FujiCsvText -Rows $parsed.ToArray()) -Bom
            return $true
        }
    }
    return $false
}

# ----------------------------------------------------------------- time spent editing
# Called on every change: the time since the previous change counts for this macro when it is no
# longer than FujiEditGapSeconds (a longer gap is a break). Kept in the editor until Save-FujiEditTime.
function Add-FujiEditTime {
    param([Parameter(Mandatory)][hashtable]$Editor, [datetime]$Now = (Get-Date))
    $m = Get-FujiCurrentMacro $Editor
    $last = $null
    if ($Editor.ContainsKey('LastChangeAt')) { $last = $Editor.LastChangeAt }
    $Editor.LastChangeAt = $Now
    if ($null -eq $m -or $null -eq $last) { return }
    $gap = ($Now - [datetime]$last).TotalSeconds
    if ($gap -le 0 -or $gap -gt $script:FujiEditGapSeconds) { return }
    if (-not $Editor.ContainsKey('EditTime')) { $Editor.EditTime = [ordered]@{} }
    $key = $Now.ToString('yyyy/MM/dd', [System.Globalization.CultureInfo]::InvariantCulture) + '|' + [string]$m.id
    if (-not $Editor.EditTime.Contains($key)) { $Editor.EditTime[$key] = @{ Date = $key.Split('|')[0]; Id = [string]$m.id; Name = [string]$m.name; Seconds = 0.0 } }
    $Editor.EditTime[$key].Seconds += $gap
    $Editor.EditTime[$key].Name = [string]$m.name
}

# Adds the time counted so far to fujikyun_edits.csv (one line per day and macro) and starts again
function Save-FujiEditTime {
    param([Parameter(Mandatory)][hashtable]$Editor)
    if (-not $Editor.ContainsKey('EditTime') -or $Editor.EditTime.Count -eq 0) { return }
    $path = Join-Path $Editor.Directory $script:FujiEditsFile
    foreach ($e in @($Editor.EditTime.Values)) {
        $sec = [int][Math]::Round($e.Seconds)
        if ($sec -le 0) { continue }
        Add-FujiRecordLine -Path $path -Keys $script:FujiEditColumns -Record ([ordered]@{ date = $e.Date; macroId = $e.Id; macro = $e.Name; editSeconds = [string]$sec })
    }
    $Editor.EditTime = [ordered]@{}
}

function Read-FujiEditRecord {
    param([Parameter(Mandatory)][string]$Directory)
    return , (Read-FujiRecordFile -Path (Join-Path $Directory $script:FujiEditsFile) -Keys $script:FujiEditColumns)
}

# ----------------------------------------------------------------- settings: minutes by hand, pay per hour
# settings.effect = { hourly: '2000', manual: { <macro id>: '4.5' } }
function Get-FujiEffectSetting {
    param([System.Collections.IDictionary]$Settings)
    $e = $null
    if ($null -ne $Settings -and $Settings.Contains('effect') -and $Settings['effect'] -is [System.Collections.IDictionary]) { $e = $Settings['effect'] }
    $out = @{ Hourly = $null; Manual = @{} }
    if ($null -eq $e) { return $out }
    if ($e.Contains('hourly')) { $out.Hourly = ConvertTo-FujiEffectNumber ([string]$e['hourly']) }
    if ($e.Contains('manual') -and $e['manual'] -is [System.Collections.IDictionary]) {
        foreach ($k in $e['manual'].Keys) {
            $n = ConvertTo-FujiEffectNumber ([string]$e['manual'][$k])
            if ($null -ne $n) { $out.Manual[[string]$k] = $n }
        }
    }
    return $out
}

# Value: '' removes it
function Set-FujiEffectSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [ValidateSet('hourly', 'manual')][string]$Key, [string]$MacroId = '', [AllowEmptyString()][string]$Value)
    if (-not $Settings.Contains('effect') -or $Settings['effect'] -isnot [System.Collections.IDictionary]) { $Settings['effect'] = [ordered]@{} }
    $e = $Settings['effect']
    if ($Key -eq 'hourly') { $e['hourly'] = $Value; return }
    if (-not $e.Contains('manual') -or $e['manual'] -isnot [System.Collections.IDictionary]) { $e['manual'] = [ordered]@{} }
    if ($Value -eq '') { if ($e['manual'].Contains($MacroId)) { $e['manual'].Remove($MacroId) } } else { $e['manual'][$MacroId] = $Value }
}

# A number of 0 or more as typed (full-width digits, commas); $null when it is not one
function ConvertTo-FujiEffectNumber {
    param([AllowEmptyString()][string]$Text)
    $t = (ConvertTo-FujiHalfWidthDigit -Text ([string]$Text)).Trim().Replace(',', '').Replace([string][char]0xFF0E, '.')
    $n = 0.0
    if ($t -notmatch '^[0-9]+(\.[0-9]+)?$' -or -not [double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    return $n
}

# ----------------------------------------------------------------- the summary
# Months found in the records, newest first ('2026/10' ...)
function Get-FujiEffectMonth {
    param([AllowEmptyCollection()][object[]]$Runs)
    $set = New-Object -TypeName 'System.Collections.Generic.SortedSet[string]'
    foreach ($r in $Runs) { if ([string]$r['start'] -match '^(\d{4}/\d{2})') { [void]$set.Add($Matches[1]) } }
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($m in $set) { $list.Insert(0, $m) }
    return , $list.ToArray()
}

# Per macro for one month ('2026/10') or every month (''). Test runs (run from here, one step,
# stepping) are left out. Macros: the current list (names); Effect: Get-FujiEffectSetting.
# Returns @{ Rows = @(ordered per macro); Total = ordered } with numbers (minutes, yen) or $null
# where no minutes by hand are set.
function Get-FujiEffectSummary {
    param([AllowEmptyCollection()][object[]]$Runs, [AllowEmptyCollection()][object[]]$Edits, [AllowEmptyCollection()][System.Collections.IList]$Macros,
        [hashtable]$Effect, [AllowEmptyString()][string]$Month = '')
    $by = [ordered]@{}
    $names = @{}
    foreach ($m in $Macros) { $names[[string]$m.id] = [string]$m.name }
    $get = {
        param($Id, $Name)
        if (-not $by.Contains($Id)) {
            $shown = $Name
            if ($names.ContainsKey($Id)) { $shown = $names[$Id] }
            $by[$Id] = [ordered]@{ id = $Id; macro = $shown; runs = 0; done = 0; errors = 0; handled = 0; robotMin = 0.0; attendedMin = 0.0; waitMin = 0.0; manualMin = $null; savedMin = $null; yen = $null; editMin = 0.0 }
        }
        return $by[$Id]
    }
    foreach ($r in $Runs) {
        if ($Month -and -not ([string]$r['start']).StartsWith($Month + '/')) { continue }
        if ($r['how'] -eq (Get-FujiText 'effect.how.test')) { continue }
        $s = & $get ([string]$r['macroId']) ([string]$r['macro'])
        $s.runs++
        $s.done += (Get-FujiInt -Text $r['done'] -Default 0)
        $s.errors += (Get-FujiInt -Text $r['errors'] -Default 0)
        $s.handled += (Get-FujiInt -Text $r['rows'] -Default 0)
        $s.robotMin += (Get-FujiInt -Text $r['seconds'] -Default 0) / 60.0
        $s.attendedMin += (Get-FujiInt -Text $r['attended'] -Default 0) / 60.0
        $s.waitMin += (Get-FujiInt -Text $r['waitAck'] -Default 0) / 60.0
    }
    foreach ($e in $Edits) {
        if ($Month -and -not ([string]$e['date']).StartsWith($Month + '/')) { continue }
        $s = & $get ([string]$e['macroId']) ([string]$e['macro'])
        $s.editMin += (Get-FujiInt -Text $e['editSeconds'] -Default 0) / 60.0
    }
    $total = [ordered]@{ id = ''; macro = (Get-FujiText 'effect.total'); runs = 0; done = 0; errors = 0; handled = 0; robotMin = 0.0; attendedMin = 0.0; waitMin = 0.0; manualMin = $null; savedMin = $null; yen = $null; editMin = 0.0 }
    foreach ($s in $by.Values) {
        if ($Effect.Manual.ContainsKey($s.id)) {
            $s.manualMin = $Effect.Manual[$s.id]
            $s.savedMin = $s.done * $s.manualMin - $s.attendedMin
            if ($null -ne $Effect.Hourly) { $s.yen = [Math]::Round($s.savedMin / 60.0 * $Effect.Hourly) }
            if ($null -eq $total.savedMin) { $total.savedMin = 0.0 }
            $total.savedMin += $s.savedMin
            if ($null -ne $s.yen) { if ($null -eq $total.yen) { $total.yen = 0.0 }; $total.yen += $s.yen }
        }
        foreach ($k in @('runs', 'done', 'errors', 'handled', 'robotMin', 'attendedMin', 'waitMin', 'editMin')) { $total[$k] += $s[$k] }
    }
    return @{ Rows = @($by.Values); Total = $total }
}

# Error rate in percent (rows that ended in an error among the rows handled), $null with no rows
function Get-FujiEffectErrorRate {
    param([System.Collections.IDictionary]$Row)
    if ($Row.handled -le 0) { return $null }
    return [Math]::Round(100.0 * $Row.errors / $Row.handled, 1)
}

# The summary as rows of text: heading, one row per macro, the total (minutes with one decimal)
function ConvertTo-FujiEffectTable {
    param([Parameter(Mandatory)][hashtable]$Summary)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmt = { param($v, $f) if ($null -eq $v) { return '' }; return ([double]$v).ToString($f, $inv) }
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $rows.Add([string[]](Get-FujiText 'effect.head'))
    foreach ($s in @($Summary.Rows) + @($Summary.Total)) {
        $rows.Add([string[]]@(
                [string]$s.macro, [string]$s.runs, [string]$s.done, [string]$s.errors, (& $fmt (Get-FujiEffectErrorRate $s) '0.0'),
                (& $fmt $s.robotMin '0.0'), (& $fmt $s.attendedMin '0.0'), (& $fmt $s.waitMin '0.0'), (& $fmt $s.manualMin '0.##'),
                (& $fmt $s.savedMin '0.0'), (& $fmt $s.yen '0'), (& $fmt $s.editMin '0.0')))
    }
    return , $rows.ToArray()
}

# Rows of text -> tab-separated lines (pasted into Excel as a table). A cell Excel would take for a
# formula (a macro named "=...") gets the leading apostrophe, as in every CSV the app writes.
function ConvertTo-FujiTabText {
    param([object[]]$Rows)
    return ((@($Rows | ForEach-Object { (@($_) | ForEach-Object { ConvertTo-FujiSafeCsvValue (([string]$_) -replace '[\t\r\n]+', ' ') }) -join "`t" }) -join "`r`n") + "`r`n")
}

function ConvertTo-FujiSafeTable {
    param([object[]]$Rows)
    return , @($Rows | ForEach-Object { , [string[]]@(@($_) | ForEach-Object { ConvertTo-FujiSafeCsvValue ([string]$_) }) })
}
