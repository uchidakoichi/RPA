# ---------------------------------------------------------------------------------------------
#  AI review: what a person checked is remembered (fujikyun_ai_answers.json) and used the next time
#  the same text comes (no AI asked); the checked texts are shown to the AI as examples for similar
#  texts; the review list (fujikyun_logs\ai_review_<date>.csv) is read for the review window and the
#  checked rows can be run again from a CSV of those rows only (as the error-row CSV).
# ---------------------------------------------------------------------------------------------
$script:FujiAiMemoryFile = 'fujikyun_ai_answers.json'
$script:FujiAiExampleMax = 30
$script:FujiAiExampleText = 100
$script:FujiAiMemoryNotice = ''
# columns of the review list (the first 11 were there before the review window; "rerun" is when the
# checked answer was put to use: given to a re-run CSV, or picked by a person in the run itself)
$script:FujiAiReviewColumns = @('time', 'macro', 'step', 'row', 'command', 'name', 'source', 'answer', 'p', 'probs', 'reason', 'kind', 'macroId', 'key', 'hash', 'done', 'rerun')
# a line with at least this many columns can be checked (it has the step key and the fingerprint)
$script:FujiAiReviewKeyed = 16

function Get-FujiSha16 {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text)) } finally { $sha.Dispose() }
    return ((-join ($h | ForEach-Object { $_.ToString('x2') })).Substring(0, 16))
}

# The fingerprint of a text read by an AI step: width and spaces (and line breaks) aside
function Get-FujiAiTextHash {
    param([AllowEmptyString()][string]$Text)
    return (Get-FujiSha16 -Text (ConvertTo-FujiAiPlain -Text $Text))
}

# Which AI step this is, kept when steps move and when its options or items change: the macro and
# the variable (AI_CHOOSE), the macro (AI_EXTRACT: its answers are kept per item name).
# -Legacy: the key before 2026.11.11, which also held the options (or the items).
function Get-FujiAiStepKey {
    param([Parameter(Mandatory)][string]$Cmd, [AllowEmptyString()][string]$MacroId, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [switch]$Legacy)
    if (-not $Legacy) {
        if ($Cmd -eq 'AI_EXTRACT') { return (Get-FujiSha16 -Text ($Cmd + '|' + $MacroId)) }
        return (Get-FujiSha16 -Text ($Cmd + '|' + $MacroId + '|' + ([string]$Settings['name']).Trim()))
    }
    if ($Cmd -eq 'AI_EXTRACT') { $parts = @(foreach ($it in (Read-FujiAiItem -Text $Settings['items'])) { $it.Name }) }
    else { $parts = @(([string]$Settings['name']).Trim()) + @(foreach ($o in (Read-FujiAiOption -Text $Settings['options'])) { $o.Value }) }
    return (Get-FujiSha16 -Text ($Cmd + '|' + $MacroId + '|' + ($parts -join '|')))
}

function New-FujiAiMemoryStep {
    return [ordered]@{ answers = [ordered]@{}; examples = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
}

# The AI steps of a macro by step key (today's key and the one before): key -> list of @{ Key; Cmd; Settings }
function Get-FujiAiStepMap {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Macro)
    $map = @{}
    foreach ($s in $Macro.steps) {
        if ($s.cmd -ne 'AI_CHOOSE' -and $s.cmd -ne 'AI_EXTRACT') { continue }
        $set = ConvertFrom-FujiStepValue -Cmd $s.cmd -Value $s.val
        $step = @{ Key = (Get-FujiAiStepKey -Cmd $s.cmd -MacroId ([string]$Macro.id) -Settings $set); Cmd = [string]$s.cmd; Settings = $set }
        foreach ($k in @($step.Key, (Get-FujiAiStepKey -Cmd $s.cmd -MacroId ([string]$Macro.id) -Settings $set -Legacy))) {
            if (-not $map.ContainsKey($k)) { $map[$k] = New-Object -TypeName 'System.Collections.Generic.List[object]' }
            $map[$k].Add($step)
        }
    }
    return $map
}

# The macro's AI step an item of the review list belongs to, or $null. When steps share a key (two
# AI_CHOOSE with one variable name): the one whose options hold the AI's answer.
function Find-FujiAiReviewStep {
    param([Parameter(Mandatory)][hashtable]$Map, [Parameter(Mandatory)][hashtable]$Item)
    $key = [string]$Item['Key']
    if (-not $key -or -not $Map.ContainsKey($key)) { return $null }
    $steps = $Map[$key]
    if ($steps.Count -gt 1 -and $Item['Command'] -ne 'AI_EXTRACT' -and $Item['Answer']) {
        foreach ($s in $steps) { if (@(Read-FujiAiOption -Text $s.Settings['options'] | ForEach-Object { $_.Value }) -contains [string]$Item['Answer']) { return $s } }
    }
    return $steps[0]
}

# Items written with the key of before get today's key (the memory is kept under it)
function Update-FujiAiReviewKey {
    param([AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][hashtable]$Map)
    foreach ($it in $Items) {
        $s = Find-FujiAiReviewStep -Map $Map -Item $it
        if ($null -ne $s) { $it['Key'] = $s.Key }
    }
}

# What was remembered under the keys of before moves to today's keys (for steps whose options or
# items are as they were then). Answers already under today's key win. Returns how many steps moved.
function Move-FujiAiMemoryKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Memory, [AllowNull()]$Macros)
    $moved = 0
    if ($null -eq $Macros) { return $moved }
    foreach ($m in $Macros) {
        foreach ($s in $m.steps) {
            if ($s.cmd -ne 'AI_CHOOSE' -and $s.cmd -ne 'AI_EXTRACT') { continue }
            $set = ConvertFrom-FujiStepValue -Cmd $s.cmd -Value $s.val
            $old = Get-FujiAiStepKey -Cmd $s.cmd -MacroId ([string]$m.id) -Settings $set -Legacy
            $new = Get-FujiAiStepKey -Cmd $s.cmd -MacroId ([string]$m.id) -Settings $set
            if (-not $Memory.Contains($old)) { continue }
            $from = $Memory[$old]
            if (-not $Memory.Contains($new)) { $Memory[$new] = New-FujiAiMemoryStep }
            $to = $Memory[$new]
            foreach ($h in @($from['answers'].Keys)) {
                $a = $from['answers'][$h]
                if (-not $to['answers'].Contains($h)) { $to['answers'][$h] = $a; continue }
                $b = $to['answers'][$h]
                if ($a -is [System.Collections.IDictionary] -and $b -is [System.Collections.IDictionary]) { foreach ($n in @($a.Keys)) { if (-not $b.Contains($n)) { $b[$n] = $a[$n] } } }
            }
            $have = @{}
            foreach ($e in $to['examples']) { $have[[string]$e['hash']] = $true }
            $keep = New-Object -TypeName 'System.Collections.Generic.List[object]'
            foreach ($e in $from['examples']) { if (-not $have.ContainsKey([string]$e['hash'])) { $keep.Add($e) } }
            foreach ($e in $to['examples']) { $keep.Add($e) }
            while ($keep.Count -gt $script:FujiAiExampleMax) { $keep.RemoveAt(0) }
            $to['examples'] = $keep
            $Memory.Remove($old)
            $moved++
        }
    }
    return $moved
}

# Forgets what a person checked for one step; returns how many answers and examples were there
function Remove-FujiAiRemembered {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Memory, [AllowEmptyString()][string]$Key)
    if (-not $Key -or -not $Memory.Contains($Key)) { return @{ Answers = 0; Examples = 0 } }
    $n = @{ Answers = $Memory[$Key]['answers'].Count; Examples = $Memory[$Key]['examples'].Count }
    $Memory.Remove($Key)
    return $n
}

# fujikyun_ai_answers.json -> step key -> @{ answers; examples }. A file that cannot be read is kept
# aside (fujikyun_ai_answers_broken_<time>.json) and the memory starts empty.
function Read-FujiAiMemory {
    param([Parameter(Mandatory)][string]$Directory)
    $memory = [ordered]@{}
    $path = Join-Path $Directory $script:FujiAiMemoryFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $memory }
    try {
        $j = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $path)
        if ($j -isnot [System.Collections.IDictionary]) { throw 'not an object' }
        foreach ($k in $j.Keys) {
            $step = New-FujiAiMemoryStep
            $s = $j[$k]
            if ($s -is [System.Collections.IDictionary] -and $s['answers'] -is [System.Collections.IDictionary]) { foreach ($h in $s['answers'].Keys) { $step.answers[$h] = $s['answers'][$h] } }
            if ($s -is [System.Collections.IDictionary] -and $s['examples'] -is [System.Collections.IList]) { foreach ($e in $s['examples']) { if ($e -is [System.Collections.IDictionary]) { $step.examples.Add($e) } } }
            $memory[[string]$k] = $step
        }
    } catch {
        $name = 'fujikyun_ai_answers_broken_' + (Get-FujiTimeStamp) + '.json'
        try { Copy-Item -LiteralPath $path -Destination (Join-Path $Directory $name) -ErrorAction Stop } catch { $null = $_ }
        $script:FujiAiMemoryNotice = Get-FujiText 'run.aiMemoryBroken' $script:FujiAiMemoryFile $name
        return [ordered]@{}
    }
    return $memory
}

function Save-FujiAiMemory {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][System.Collections.IDictionary]$Memory)
    Write-FujiFileSafely -Path (Join-Path $Directory $script:FujiAiMemoryFile) -Text (ConvertTo-FujiJson -InputObject $Memory -Indent 1)
}

function Get-FujiAiRemembered {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Memory, [AllowEmptyString()][string]$Key, [AllowEmptyString()][string]$Hash)
    if (-not $Memory.Contains($Key)) { return $null }
    $answers = $Memory[$Key]['answers']
    if ($answers.Contains($Hash)) { return $answers[$Hash] }
    return $null
}

# What a person checked; a text answer (AI_CHOOSE) is also kept as an example (newest 30, text cut at 100)
function Add-FujiAiRemembered {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Memory, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Hash, [Parameter(Mandatory)]$Answer, [AllowEmptyString()][string]$ExampleText = '')
    if (-not $Memory.Contains($Key)) { $Memory[$Key] = New-FujiAiMemoryStep }
    $step = $Memory[$Key]
    $step['answers'][$Hash] = $Answer
    if (-not $ExampleText -or $Answer -isnot [string]) { return }
    $text = [string]$ExampleText
    if ($text.Length -gt $script:FujiAiExampleText) { $text = $text.Substring(0, $script:FujiAiExampleText) }
    $keep = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($e in $step['examples']) { if ([string]$e['hash'] -ne $Hash) { $keep.Add($e) } }
    $keep.Add([ordered]@{ hash = $Hash; text = $text; answer = $Answer })
    while ($keep.Count -gt $script:FujiAiExampleMax) { $keep.RemoveAt(0) }
    $step['examples'] = $keep
}

function Get-FujiAiBigram {
    param([AllowEmptyString()][string]$Text)
    $t = (ConvertTo-FujiAiPlain -Text $Text).ToLowerInvariant()
    $set = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    for ($i = 0; $i -lt $t.Length - 1; $i++) { [void]$set.Add($t.Substring($i, 2)) }
    return , $set
}

# The examples most like Source (Jaccard of character pairs, at least 0.1), best first
function Select-FujiAiExample {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Memory, [AllowEmptyString()][string]$Key, [AllowEmptyString()][string]$Source, [int]$Max = 3)
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if (-not $Memory.Contains($Key)) { return , $out }
    $a = Get-FujiAiBigram -Text $Source
    $scored = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($e in $Memory[$Key]['examples']) {
        $b = Get-FujiAiBigram -Text ([string]$e['text'])
        $union = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (, $a)
        $union.UnionWith($b)
        if ($union.Count -eq 0) { continue }
        $inter = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (, $a)
        $inter.IntersectWith($b)
        $score = $inter.Count / $union.Count
        if ($score -ge 0.1) { $scored.Add(@{ Score = $score; Example = $e }) }
    }
    foreach ($s in ($scored | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true } | Select-Object -First $Max)) { $out.Add($s.Example) }
    return , $out
}

# The review list's lines of one macro over the last Days days (files with _2 ... included)
function Read-FujiAiReviewItem {
    param([Parameter(Mandatory)][string]$Directory, [AllowEmptyString()][string]$MacroId, [AllowEmptyString()][string]$MacroName = '', [int]$Days = 1, [datetime]$Now = (Get-Date))
    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $dir = Join-Path $Directory $script:FujiLogFolder
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $oldest = $Now.Date.AddDays(1 - [Math]::Max(1, $Days))
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name)) {
        $m = [regex]::Match($f.Name, '^ai_review_(\d{4}-\d{2}-\d{2})(?:_\d+)?\.csv$')
        if (-not $m.Success) { continue }
        $day = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($day -lt $oldest -or $day -gt $Now.Date) { continue }
        $recs = (ConvertFrom-FujiCsv -Text (Read-FujiCsvText -Path $f.FullName -Encoding 'utf-8').Text).Records
        for ($i = 1; $i -lt $recs.Count; $i++) {
            $r = $recs[$i]
            if ($r.Count -lt 11) { continue }
            $old = $r.Count -lt $script:FujiAiReviewKeyed
            $v = @{}
            # the formula guard of the CSV (a leading apostrophe before = + - @) is taken off again
            for ($c = 0; $c -lt $script:FujiAiReviewColumns.Count; $c++) { $v[$script:FujiAiReviewColumns[$c]] = $(if ($c -lt $r.Count) { ([string]$r[$c]) -replace "^'(?=[=+\-@\t\r])", '' } else { '' }) }
            if ($old) { if ($v['macro'] -ne $MacroId -and ($MacroName -eq '' -or $v['macro'] -ne $MacroName)) { continue } }
            elseif ($v['macroId'] -ne $MacroId) { continue }
            $rowNo = 0
            [void][int]::TryParse($v['row'], [ref]$rowNo)
            $items.Add(@{ File = $f.FullName; Line = $i; Old = $old; Time = $v['time']; Macro = $v['macro']; Step = $v['step']; Row = $rowNo; Command = $v['command']; Name = $v['name']
                    Source = $v['source']; Answer = $v['answer']; P = $v['p']; Probs = $v['probs']; Reason = $v['reason']; Kind = $v['kind']; MacroId = $v['macroId']; Key = $v['key']; Hash = $v['hash']; Done = $v['done']; Rerun = $v['rerun'] })
        }
    }
    # a plain array (unrolled into a pipeline; callers take it with @())
    return $items.ToArray()
}

# Writes the time in the "done" (or "rerun") column of these items' lines, one write per file (written
# beside and put in place). A line is changed only when it is still that item (same time and
# fingerprint); a line from before the "rerun" column is made as wide as today's. An item with
# Reopen (its checked answer was changed) also loses its "rerun" time, so it can be run again.
# Returns how many lines were marked; a file in use (open in Excel) is left as it is.
function Set-FujiAiReviewDoneMany {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [AllowEmptyString()][string]$Time, [ValidateSet('done', 'rerun')][string]$Column = 'done')
    $done = 0
    $width = $script:FujiAiReviewColumns.Count
    $at = [array]::IndexOf($script:FujiAiReviewColumns, $Column)
    $rerunAt = [array]::IndexOf($script:FujiAiReviewColumns, 'rerun')
    $head = [string[]]((Get-FujiText 'run.aiReviewHeader') -split ',')
    foreach ($group in @($Items | Where-Object { -not $_.Old } | Group-Object -Property { $_.File })) {
        $file = [string]$group.Name
        $tmp = $file + '.saving'
        try {
            $recs = (ConvertFrom-FujiCsv -Text (Read-FujiCsvText -Path $file -Encoding 'utf-8').Text).Records
            $marked = New-Object -TypeName 'System.Collections.Generic.List[object]'
            foreach ($it in $group.Group) {
                if ($it.Line -lt 1 -or $it.Line -ge $recs.Count) { continue }
                $row = [string[]]$recs[$it.Line]
                if ($row.Count -lt $script:FujiAiReviewKeyed -or $row[14] -ne [string]$it.Hash -or $row[0] -ne [string]$it.Time) { continue }
                if ($row.Count -lt $width) { $row = [string[]]($row + (@('') * ($width - $row.Count))) }
                $row[$at] = $Time
                if ($Column -eq 'done' -and $it['Reopen']) { $row[$rerunAt] = '' }
                $recs[$it.Line] = $row
                $marked.Add($it)
            }
            if ($marked.Count -eq 0) { continue }
            if ($recs[0].Count -lt $width -and $head.Count -eq $width) { $recs[0] = $head }
            Write-FujiTextFile -Path $tmp -Text (ConvertTo-FujiCsvText -Rows $recs.ToArray()) -Bom
            Copy-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
            foreach ($it in $marked) {
                if ($Column -eq 'rerun') { $it['Rerun'] = $Time; continue }
                $it.Done = $Time
                if ($it['Reopen']) { $it['Rerun'] = ''; $it.Remove('Reopen') }
            }
            $done += $marked.Count
        } catch {
            $null = $_
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $done
}

function Set-FujiAiReviewDone {
    param([Parameter(Mandatory)][hashtable]$Item, [AllowEmptyString()][string]$Time)
    return ((Set-FujiAiReviewDoneMany -Items @($Item) -Time $Time) -eq 1)
}

# The person's answer of each checked item, from the memory (also for items checked another day)
function Set-FujiAiReviewFinal {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][System.Collections.IDictionary]$Memory)
    foreach ($it in $Items) {
        if (-not $it.Done -or -not $it.Key -or -not $it.Hash) { continue }
        $r = Get-FujiAiRemembered -Memory $Memory -Key $it.Key -Hash $it.Hash
        if ($it.Command -eq 'AI_EXTRACT') { if ($r -is [System.Collections.IDictionary] -and $r.Contains($it.Name)) { $it['Final'] = [string]$r[$it.Name] } }
        elseif ($r -is [string]) { $it['Final'] = $r }
    }
}

# Items to run again: checked, with a row number and the person's answer. Left out: spot checks the
# person left as they were (their answer was used already), an answer a person picked in the run itself
# (used there: its "rerun" time is the line's own time), and items given to a re-run CSV before
# (unless IncludeSent).
function Get-FujiAiRerunItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [switch]$IncludeSent)
    $out = @(foreach ($it in $Items) {
            if (-not $it.Done -or $it.Row -le 0 -or -not $it.Contains('Final')) { continue }
            if ($it.Kind -eq 'spot' -and [string]$it['Final'] -eq [string]$it.Answer) { continue }
            $sent = [string]$it['Rerun']
            if ($sent -and (-not $IncludeSent -or ($it.Kind -eq 'asked' -and $sent -eq [string]$it['Time']))) { continue }
            $it
        })
    return , $out
}

function Get-FujiAiRerunRowNo {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [switch]$IncludeSent)
    $nos = @(foreach ($it in (Get-FujiAiRerunItem -Items $Items -IncludeSent:$IncludeSent)) { [int]$it.Row })
    return , [int[]]@($nos | Sort-Object -Unique)
}

# The rows checked in the review, from the loaded CSV, as an error-row CSV (original row numbers kept)
function New-FujiAiRerunCsv {
    param([AllowNull()][string[]]$Header, [AllowEmptyCollection()][System.Collections.IList]$Rows, [AllowEmptyCollection()][int[]]$RowNos)
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return @{ Text = ''; Count = 0; Error = (Get-FujiText 'run.aiRerunNoCsv') } }
    $nos = @($RowNos | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($nos.Count -eq 0) { return @{ Text = ''; Count = 0; Error = (Get-FujiText 'run.aiRerunNoRows') } }
    $byNo = @{}
    foreach ($r in $Rows) { $byNo[[int]$r.No] = $r }
    $pick = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($n in $nos) {
        if (-not $byNo.ContainsKey([int]$n)) { return @{ Text = ''; Count = 0; Error = (Get-FujiText 'run.aiRerunMissing' $n) } }
        $pick.Add($byNo[[int]$n])
    }
    $max = 0
    foreach ($p in $pick) { $max = [Math]::Max($max, @($p.Data).Count) }
    $head = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($null -ne $Header) { foreach ($h in $Header) { $head.Add($h) } }
    $max = [Math]::Max($max, $head.Count)
    while ($head.Count -lt $max) { if ($null -ne $Header) { $head.Add('') } else { $head.Add((Get-FujiText 'run.colPrefix' ($head.Count + 1))) } }
    $head.Add((Get-FujiText 'run.colOrigNo')); $head.Add((Get-FujiText 'run.colError')); $head.Add((Get-FujiText 'run.colTime'))
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $out.Add($head.ToArray())
    foreach ($p in $pick) {
        $cols = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($v in $p.Data) { $cols.Add([string]$v) }
        while ($cols.Count -lt $max) { $cols.Add('') }
        $cols.Add([string]$p.No); $cols.Add(''); $cols.Add('')
        $out.Add($cols.ToArray())
    }
    return @{ Text = (ConvertTo-FujiCsvText -Rows $out.ToArray()); Count = $pick.Count; Error = '' }
}

# Hints for the threshold: of the checked items, how many kept the AI's answer (spot checks, and per band of probability)
function Get-FujiAiReviewSummary {
    param([AllowEmptyCollection()][object[]]$Items)
    $bands = @(@{ From = 0.0; To = 0.3; Total = 0; Kept = 0 }, @{ From = 0.3; To = 0.5; Total = 0; Kept = 0 }, @{ From = 0.5; To = 0.7; Total = 0; Kept = 0 }, @{ From = 0.7; To = 1.0; Total = 0; Kept = 0 })
    $spotTotal = 0; $spotKept = 0
    foreach ($it in $Items) {
        if (-not $it.Contains('Final')) { continue }
        $kept = [string]$it['Final'] -eq [string]$it['Answer']
        if ($it['Kind'] -eq 'spot') { $spotTotal++; if ($kept) { $spotKept++ } }
        $p = 0.0
        if (-not [double]::TryParse([string]$it['P'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$p)) { continue }
        foreach ($b in $bands) {
            if ($p -ge $b.From -and ($p -lt $b.To -or ($b.To -eq 1.0 -and $p -le 1.0))) { $b.Total++; if ($kept) { $b.Kept++ }; break }
        }
    }
    return @{ SpotTotal = $spotTotal; SpotKept = $spotKept; Bands = $bands }
}

# Unchecked by probability (lowest first), then spot checks, then checked ones
function Get-FujiAiReviewOrder {
    param([object[]]$Items)
    $p = { $v = 0.0; [void][double]::TryParse([string]$_.P, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v); $v }
    $open = @($Items | Where-Object { -not $_.Done -and $_.Kind -ne 'spot' } | Sort-Object -Property @{ Expression = $p })
    $spot = @($Items | Where-Object { -not $_.Done -and $_.Kind -eq 'spot' } | Sort-Object -Property @{ Expression = $p })
    $done = @($Items | Where-Object { $_.Done })
    # a list even for one item (a single hashtable would be returned as itself)
    return , @($open + $spot + $done)
}
