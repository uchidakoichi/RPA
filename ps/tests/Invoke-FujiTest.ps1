#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the PowerShell edition's core (no window, no Windows-only API).

.DESCRIPTION
    Runs on Windows PowerShell 5.1 and on PowerShell 7 (also on macOS / Linux):
        powershell -NoProfile -File ps\tests\Invoke-FujiTest.ps1
        pwsh -NoProfile -File ps/tests/Invoke-FujiTest.ps1
    golden.json holds what the HTA's own functions return for the same inputs
    (node tools/make_ps_golden.js), so these tests keep both editions in step.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$psRoot = Split-Path -Path $PSScriptRoot -Parent
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
Import-FujiCommand -Path (Join-Path $psRoot 'fujikyun_commands.json')
$templates = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path (Join-Path $psRoot 'fujikyun_templates.json'))
$golden = Read-FujiUtf8File -Path (Join-Path $PSScriptRoot 'golden.json') | ConvertFrom-Json

$script:failures = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:count = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $script:count++
    $e = ConvertTo-FujiJson -InputObject $Expected -Indent 0
    $a = ConvertTo-FujiJson -InputObject $Actual -Indent 0
    if ($e -cne $a) { $script:failures.Add(('{0}: expected {1} but got {2}' -f $What, $e, $a)) }
}

function Assert-True {
    param([bool]$Condition, [string]$What)
    $script:count++
    if (-not $Condition) { $script:failures.Add($What) }
}

function Get-Golden {
    param($Item, [string]$Name)
    $p = $Item.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# A case's expectation for this edition: the reviewed correct value (ps) where the HTA cannot give it,
# otherwise what the HTA returned. Returns @{ IsError; Value }.
function Get-Expected {
    param($Item)
    $ps = Get-Golden $Item 'ps'
    if ($null -ne $ps) { return @{ IsError = $false; Value = $ps.value } }
    return @{ IsError = ($null -ne (Get-Golden $Item 'error')); Value = (Get-Golden $Item 'value') }
}

# ----------------------------------------------------------------- golden: CSV
foreach ($case in $golden.csv) {
    $r = ConvertFrom-FujiCsv -Text $case.text
    $expected = @(foreach ($rec in $case.records) { , @($rec) })
    $actual = @(foreach ($rec in $r.Records) { , @($rec) })
    Assert-Equal -Expected $expected -Actual $actual -What ('csv {0}' -f (ConvertTo-FujiJson $case.text -Indent 0))
    Assert-Equal -Expected ([int]$case.warnings) -Actual $r.Warnings.Count -What ('csv warnings {0}' -f (ConvertTo-FujiJson $case.text -Indent 0))
}

# ----------------------------------------------------------------- golden: calculation
foreach ($case in $golden.calc) {
    $exp = Get-Expected $case
    $isError = $exp.IsError
    try {
        $v = Invoke-FujiCalc -Expression $case.expr
        if ($isError) { Assert-True $false ('calc "{0}" should fail but gave {1}' -f $case.expr, $v) } else { Assert-Equal $exp.Value $v ('calc "{0}"' -f $case.expr) }
    } catch {
        Assert-True $isError ('calc "{0}" failed: {1}' -f $case.expr, $_.Exception.Message)
    }
}

# ----------------------------------------------------------------- golden: string operations
foreach ($case in $golden.strop) {
    $exp = Get-Expected $case
    $isError = $exp.IsError
    $what = 'strOp {0}("{1}", "{2}", "{3}")' -f $case.op, $case.s, $case.a, $case.b
    try {
        $v = Invoke-FujiStringOp -Op $case.op -Text $case.s -A $case.a -B $case.b
        if ($isError) { Assert-True $false ('{0} should fail but gave {1}' -f $what, $v) } else { Assert-Equal $exp.Value $v $what }
    } catch {
        Assert-True $isError ('{0} failed: {1}' -f $what, $_.Exception.Message)
    }
}

# ----------------------------------------------------------------- golden: numbers, conditions, wareki
foreach ($case in $golden.numbers) {
    $v = ConvertTo-FujiNumber -Text $case.text
    if ($null -ne $v) { $v = ConvertTo-FujiNumberText -Value $v }
    Assert-Equal (Get-Expected $case).Value $v ('number "{0}"' -f $case.text)
}
foreach ($case in $golden.conditions) {
    $v = Test-FujiCondition -Op $case.op -Left $case.left -Right $case.right
    Assert-Equal (Get-Expected $case).Value $v ('condition "{0}" {1} "{2}"' -f $case.left, $case.op, $case.right)
}
foreach ($case in $golden.wareki) {
    $d = New-Object -TypeName DateTime -ArgumentList ([int]$case.y), ([int]$case.m), ([int]$case.d)
    Assert-Equal $case.year (Get-FujiWarekiYear -Date $d) ('wareki {0}-{1}-{2}' -f $case.y, $case.m, $case.d)
}

# ----------------------------------------------------------------- golden: placeholders
$fx = $golden.fixture
$ctx = @{
    Row = @{ No = [int]$fx.row.no; Data = @($fx.row.data) }
    Header = @($fx.header)
    Vars = ConvertTo-FujiData -InputObject $fx.vars
    Now = New-Object -TypeName DateTime -ArgumentList 2026, 10, 9, 14, 5, 12
}
foreach ($case in $golden.placeholders) {
    Assert-Equal $case.value (Expand-FujiPlaceholder -Text $case.text -Context $ctx) ('placeholder "{0}"' -f $case.text)
}
$unsafe = New-Object -TypeName 'System.Collections.Generic.List[string]'
$ctx.Row.Data = @($fx.unsafeRow)
Assert-Equal $golden.unsafe.value (Expand-FujiPlaceholder -Text $golden.unsafe.text -Context $ctx -Unsafe $unsafe) 'placeholder unsafe text'
Assert-Equal ([int]$golden.unsafe.count) $unsafe.Count 'placeholder unsafe count'

# ----------------------------------------------------------------- JSON
$data = [ordered]@{ version = 27; name = "a`"b\c`r`n`t"; list = @(1, 'x', $null, $true); empty = @(); obj = [ordered]@{}; one = @('only') }
$json = ConvertTo-FujiJson -InputObject $data -Indent 0
Assert-Equal '{"version":27,"name":"a\"b\\c\r\n\t","list":[1,"x",null,true],"empty":[],"obj":{},"one":["only"]}' $json 'json write'
$back = ConvertFrom-FujiJson -Json $json
Assert-True ($back -is [System.Collections.Specialized.OrderedDictionary]) 'json read gives an ordered dictionary'
Assert-True ($back['one'] -is [System.Collections.IList] -and $back['one'].Count -eq 1) 'json read keeps a one-element array'
Assert-Equal $json (ConvertTo-FujiJson -InputObject $back -Indent 0) 'json round trip'
$top = ConvertFrom-FujiJson -Json '[{"a":1}]'
Assert-True ($top -is [System.Collections.IList] -and $top.Count -eq 1) 'json top-level one-element array'
Assert-Equal "{`n  `"a`": [`n    1`n  ]`n}" (ConvertTo-FujiJson -InputObject ([ordered]@{ a = @(1) })) 'json indent like JSON.stringify(v, null, 2)'

# ----------------------------------------------------------------- files: encodings and safe write
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $jp = [string]$golden.fixture.header[0]
    $sample = $jp + ',1' + "`r`n"
    $p = Join-Path $tmp 'utf8.csv'
    [System.IO.File]::WriteAllBytes($p, (Get-FujiEncoding 'utf-8').GetBytes($sample))
    $r = Read-FujiCsvText -Path $p
    Assert-Equal 'utf-8' $r.Encoding 'csv utf-8 detected'
    Assert-Equal $sample $r.Text 'csv utf-8 text'
    $p = Join-Path $tmp 'sjis.csv'
    [System.IO.File]::WriteAllBytes($p, (Get-FujiEncoding 'shift_jis').GetBytes($sample))
    $r = Read-FujiCsvText -Path $p
    Assert-Equal 'shift_jis' $r.Encoding 'csv shift_jis detected'
    Assert-Equal $sample $r.Text 'csv shift_jis text'
    $p = Join-Path $tmp 'bom.csv'
    Write-FujiTextFile -Path $p -Text $sample -Bom
    Assert-Equal $sample (Read-FujiCsvText -Path $p).Text 'csv with BOM'
    $p = Join-Path $tmp 'utf16.csv'
    [System.IO.File]::WriteAllText($p, $sample, [System.Text.Encoding]::Unicode)
    Assert-Equal $sample (Read-FujiCsvText -Path $p).Text 'csv utf-16 with BOM'

    $main = Join-Path $tmp 'fujikyun_macros.json'
    $backup = Join-Path $tmp 'fujikyun_macros_backup.json'
    Write-FujiFileSafely -Path $main -Text 'v1' -BackupPath $backup
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'safe write: no backup for a new file'
    Write-FujiFileSafely -Path $main -Text ($jp + 'v2') -BackupPath $backup
    Assert-Equal ($jp + 'v2') (Read-FujiUtf8File -Path $main) 'safe write: new content'
    Assert-Equal 'v1' (Read-FujiUtf8File -Path $backup) 'safe write: previous version kept'
    Assert-True (-not (Test-Path -LiteralPath ($main + '.saving'))) 'safe write: no temp file left'

    $p = Join-Path $tmp 'bad.json'
    [System.IO.File]::WriteAllBytes($p, (Get-FujiEncoding 'shift_jis').GetBytes('{"a":"' + $jp + '"}'))
    $threw = $false
    try { [void](Read-FujiUtf8File -Path $p) } catch { $threw = $true }
    Assert-True $threw 'strict UTF-8 read rejects a Shift_JIS file'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# ----------------------------------------------------------------- CSV writer round trip
$rows = @(, @('a', 'b,c', "d`"e", "f`r`ng", ''))
$text = ConvertTo-FujiCsvText -Rows $rows
Assert-Equal "a,`"b,c`",`"d`"`"e`",`"f`r`ng`",`r`n" $text 'csv write'
Assert-Equal @(, @('a', 'b,c', "d`"e", "f`r`ng", '')) @(foreach ($rec in (ConvertFrom-FujiCsv -Text $text).Records) { , @($rec) }) 'csv write/read round trip'

# ----------------------------------------------------------------- commands and templates
$script:FujiCsvHeaderNameOf = { param($Column) $h = @($golden.fixture.header); if ($Column -ge 1 -and $Column -le $h.Count) { ([string]$h[$Column - 1]).Trim() } else { '' } }
$labelsById = @{}
foreach ($t in $golden.templateLabels) {
    $ps = Get-Golden $t 'ps'
    if ($null -ne $ps) { $labelsById[$t.id] = @($ps) } else { $labelsById[$t.id] = @($t.labels) }
}
Assert-Equal 67 $templates['templates'].Count 'template count'
foreach ($t in $templates['templates']) {
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in $t['steps']) {
        $step = New-FujiStep -Cmd $item[0] -Value ([string]$item[1])
        if ($item.Count -gt 2) { foreach ($k in $item[2].Keys) { $step[$k] = $item[2][$k] } }
        $steps.Add($step)
        $settings = ConvertFrom-FujiStepValue -Cmd $step.cmd -Value $step.val
        $err = Test-FujiStepSetting -Cmd $step.cmd -Settings $settings
        Assert-Equal '' $err ('{0}: {1} settings "{2}"' -f $t['id'], $step.cmd, $step.val)
        $back = ConvertTo-FujiStepValue -Cmd $step.cmd -Settings $settings -MacroName ([string]$settings['name'])
        Assert-Equal $step.val $back ('{0}: {1} value round trip' -f $t['id'], $step.cmd)
    }
    $labels = @(foreach ($s in $steps) { if ($s.Contains('label') -and $s.label -and $s.label -ne (Get-FujiStepLabel -Cmd $s.cmd -Value $s.val)) { $s.label } else { Get-FujiStepLabel -Cmd $s.cmd -Value $s.val } })
    Assert-Equal $labelsById[$t['id']] $labels ('{0}: labels' -f $t['id'])
    Assert-True (Test-FujiBlockBalanced -Steps $steps) ('{0}: blocks balanced' -f $t['id'])
}

# Invalid settings are reported
$bad = @(
    @('CSV', @{ col = '0' }), @('WAIT', @{ ms = '-1' }), @('WAIT_FOR', @{ title = 'x'; key = ''; timeout = '0' }), @('COPY', @{ name = 'a b' }),
    @('CLICK_IMG', @{ path = 'a.png'; threshold = '0.3' }), @('CLICK_TEXT', @{ text = 'x'; area = 'RECT'; x = '1'; y = '1'; w = '2'; h = '9'; nth = '1' }),
    @('STR_OP', @{ name = 'v'; src = ''; op = 'REGEX_EXTRACT'; a = '(unclosed'; b = '' }), @('LOOP_START', @{ mode = 'COUNT'; count = '3'; left = ''; op = 'EQ'; right = ''; counter = 'n'; max = '0' }),
    @('IF_START', @{ left = ''; op = 'EQ'; right = '' }), @('MAIL', @{ to = ' ' })
)
foreach ($b in $bad) { Assert-True ((Test-FujiStepSetting -Cmd $b[0] -Settings $b[1]) -ne '') ('{0} invalid settings must be reported' -f $b[0]) }
Assert-Equal '' (Test-FujiStepSetting -Cmd 'IF_START' -Settings @{ left = ''; op = 'EMPTY'; right = '' }) 'IF_START EMPTY needs no left value'
Assert-Equal '{"x":"12","y":"-3","kind":"LEFT"}' (ConvertTo-FujiStepValue -Cmd 'CLICK_POS' -Settings @{ x = '12px'; y = '-3'; kind = 'odd' }) 'CLICK_POS normalised'
Assert-Equal '{"path":"a.png","threshold":"0.5"}' (ConvertTo-FujiStepValue -Cmd 'CLICK_IMG' -Settings @{ path = 'a.png'; threshold = '0.2' }) 'CLICK_IMG threshold clamped'
Assert-Equal '{"id":"m1","name":"Sub"}' (ConvertTo-FujiStepValue -Cmd 'CALL_MACRO' -Settings @{ id = 'm1' } -MacroName 'Sub') 'CALL_MACRO keeps the name'
$p = ConvertFrom-FujiStepValue -Cmd 'WAIT_FOR' -Value 'not json'
Assert-Equal '30' $p['timeout'] 'broken JSON value falls back to defaults'

# ----------------------------------------------------------------- macros file (same text as the HTA writes)
$macroInput = ConvertTo-FujiData -InputObject $golden.macroInput
$norm = ConvertTo-FujiMacroData -Source $macroInput
Assert-Equal ([string]$golden.macroOutput) (ConvertTo-FujiMacroJson -Data $norm.Data) 'macros file identical to the HTA'
Assert-True (-not $norm.NewerVersion) 'data version 27 is not newer'
Assert-True (ConvertTo-FujiMacroData -Source ([ordered]@{ version = 28; macros = @() })).NewerVersion 'data version 28 is newer'
$dup = ConvertTo-FujiMacroData -Source (ConvertFrom-FujiJson -Json '{"macros":[{"id":"x","steps":[]},{"id":"x","steps":[]},{"steps":[]}]}')
$ids = @($dup.Data.macros | ForEach-Object { $_.id })
Assert-True ($ids.Count -eq 3 -and @($ids | Select-Object -Unique).Count -eq 3 -and $ids[0] -eq 'x') 'macro ids made unique'
$reread = ConvertTo-FujiMacroData -Source (ConvertFrom-FujiJson -Json (ConvertTo-FujiMacroJson -Data $norm.Data))
Assert-Equal (ConvertTo-FujiMacroJson -Data $norm.Data) (ConvertTo-FujiMacroJson -Data $reread.Data) 'macros file round trip'

# ----------------------------------------------------------------- block helpers
$blk = New-Object -TypeName 'System.Collections.Generic.List[object]'
foreach ($c in @('GROUP_START', 'IF_START', 'KEY', 'ELSE', 'KEY', 'IF_END', 'TRY_START', 'CATCH', 'TRY_END', 'GROUP_END', 'KEY')) { $blk.Add([ordered]@{ cmd = $c; val = '' }) }
Assert-Equal @(0, 1, 2, 1, 2, 1, 1, 1, 1, 0, 0) (Get-FujiDepth -Steps $blk) 'depths'
Assert-Equal 9 (Find-FujiBlockEnd -Steps $blk -StartIndex 0) 'block end'
Assert-Equal 1 (Find-FujiBlockStart -Steps $blk -EndIndex 5) 'block start'
Assert-Equal 3 (Find-FujiBlockMiddle -Steps $blk -StartIndex 1 -Cmd 'ELSE') 'block middle'
Assert-Equal 1 (Find-FujiBlockOwner -Steps $blk -Index 4) 'block owner'
Assert-Equal @(3) (Get-FujiBlockMiddleIndex -Steps $blk -Start 1 -End 5) 'middles of a block'
Assert-True (Test-FujiBlockBalanced -Steps $blk) 'balanced'
$blk.Insert(2, [ordered]@{ cmd = 'CATCH'; val = '' })
Assert-True (-not (Test-FujiBlockBalanced -Steps $blk)) 'CATCH inside an if-block is not balanced'
$vars = Get-FujiDefinedVarName -Steps (New-Object -TypeName 'System.Collections.Generic.List[object]' -ArgumentList @(, [object[]]@(
    [ordered]@{ cmd = 'COPY'; val = 'n1' }, [ordered]@{ cmd = 'SET_VAR'; val = '{"name":"n2","value":"","mode":"TEXT"}' }, [ordered]@{ cmd = 'LOOP_START'; val = '{"counter":""}' }
))) -ErrorVarName 'err'
Assert-Equal @('err', 'n1', 'n2', (Get-FujiCommandDef 'LOOP_START')['parseDefaults']['counter']) $vars 'defined variables'

# ----------------------------------------------------------------- editor: start, save, temp file
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_test_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
try {
    $script:logs = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $logger = { param($Message, $Level) $script:logs.Add($Level + ' ' + $Message) }
    $ed = New-FujiEditor -Directory $work -Log $logger
    Initialize-FujiEditorData -Editor $ed -AskRestoreTemp { throw 'no temp file expected' }
    Assert-Equal (Get-FujiText 'editor.sampleName') $ed.Data.macros[0].name 'no file: sample macro'
    Assert-True (-not $ed.Dirty -and -not $ed.SaveBlockReason -and $ed.History.Count -eq 1) 'no file: clean state, one history entry'
    Assert-Equal 'GROUP_END' $ed.Data.macros[0].steps[6].cmd 'sample steps normalized'

    Add-FujiMacro -Editor $ed -Name 'm2'
    Assert-True ($ed.Dirty -and $ed.MacroIndex -eq 1 -and $ed.History.Count -eq 2) 'add macro'
    $tempPath = Join-Path $work 'fujikyun_macros_temp.json'
    Assert-True (Test-Path -LiteralPath $tempPath) 'change autosaves the temp file'
    Assert-Equal '' (Save-FujiEditorData -Editor $ed) 'save'
    Assert-True (-not $ed.Dirty -and -not (Test-Path -LiteralPath $tempPath)) 'save removes the temp file'
    $mainPath = Join-Path $work 'fujikyun_macros.json'
    Assert-Equal (ConvertTo-FujiMacroJson -Data $ed.Data) (Read-FujiUtf8File -Path $mainPath) 'saved text'
    Rename-FujiMacro -Editor $ed -Name 'm2b'
    Assert-Equal '' (Save-FujiEditorData -Editor $ed) 'second save'
    Assert-True ((Read-FujiUtf8File -Path (Join-Path $work 'fujikyun_macros_backup.json')).Contains('"m2"')) 'backup keeps the previous version'

    # temp file found: restore
    Set-FujiTargetWindow -Editor $ed -Title ' Notepad '
    Assert-Equal 'Notepad' (Get-FujiCurrentMacro $ed).targetWindow 'target window trimmed'
    $ed2 = New-FujiEditor -Directory $work -Log $logger
    Initialize-FujiEditorData -Editor $ed2 -AskRestoreTemp { $true }
    Assert-True ($ed2.Dirty -and $ed2.Data.macros[1].targetWindow -eq 'Notepad') 'temp file restored'
    # temp file found: open the macros file, temp moved aside
    $ed3 = New-FujiEditor -Directory $work -Log $logger
    Initialize-FujiEditorData -Editor $ed3 -AskRestoreTemp { $false }
    Assert-True (-not $ed3.Dirty -and $ed3.Data.macros[1].targetWindow -eq '') 'macros file opened'
    Assert-True (-not (Test-Path -LiteralPath $tempPath) -and @(Get-ChildItem -LiteralPath $work -Filter 'fujikyun_macros_temp_discarded_*.json').Count -eq 1) 'temp file moved aside'

    # unreadable macros file: copy kept, save guarded, sample shown
    Write-FujiTextFile -Path $mainPath -Text '{ broken'
    $ed4 = New-FujiEditor -Directory $work -Log $logger
    Initialize-FujiEditorData -Editor $ed4 -AskRestoreTemp { $false }
    Assert-True ([bool]$ed4.SaveBlockReason -and $ed4.Notices.Count -eq 1) 'unreadable file guards the save'
    Assert-True (@(Get-ChildItem -LiteralPath $work -Filter 'fujikyun_macros_broken_*.json').Count -eq 1) 'unreadable file copied'
    Assert-Equal (Get-FujiText 'editor.sampleName') $ed4.Data.macros[0].name 'unreadable file: sample shown'
    # newer data version
    Write-FujiTextFile -Path $mainPath -Text '{"version":99,"macros":[{"id":"a","name":"n","steps":[{"cmd":"FUTURE","val":"x"}]}]}'
    $ed5 = New-FujiEditor -Directory $work -Log $logger
    Initialize-FujiEditorData -Editor $ed5 -AskRestoreTemp { $false }
    Assert-True ($ed5.SaveBlockReason.Contains('99') -and $ed5.Data.macros[0].steps[0].cmd -eq 'COMMENT') 'newer file: save guarded, unknown command kept as comment'

    # export / import
    $ed.MacroIndex = 0
    $exported = Export-FujiCurrentMacro -Editor $ed
    $exported2 = Export-FujiCurrentMacro -Editor $ed
    Assert-True ($exported -ne $exported2 -and (Test-Path -LiteralPath $exported2)) 'export never overwrites'
    $before = $ed.Data.macros.Count
    Assert-Equal '' (Import-FujiMacroFile -Editor $ed -Path $exported) 'import'
    Assert-True ($ed.Data.macros.Count -eq $before + 1 -and $ed.Data.macros[$before].id -ne $ed.Data.macros[0].id) 'import adds with a new id'
    Write-FujiTextFile -Path (Join-Path $work 'new.json') -Text '{"version":99,"macros":[]}'
    Assert-True ([bool](Import-FujiMacroFile -Editor $ed -Path (Join-Path $work 'new.json'))) 'import refuses a newer file'

    # template: macro, unique name, sample CSV with BOM, loading it
    $tpl = $templates['templates'][0]
    $n1 = New-FujiMacroFromTemplate -Editor $ed -Template $tpl
    $n2 = New-FujiMacroFromTemplate -Editor $ed -Template $tpl
    Assert-True ($n1 -eq $tpl['name'] -and $n2 -eq ($tpl['name'] + ' (2)')) 'template names unique'
    Assert-Equal $tpl['steps'].Count (Get-FujiCurrentStepList $ed).Count 'template steps'
    $csvPath = Write-FujiTemplateCsv -Editor $ed -Template $tpl
    $bytes = [System.IO.File]::ReadAllBytes($csvPath)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'sample CSV has a BOM (Excel)'
    $r = Import-FujiEditorCsv -Editor $ed -Path $csvPath -Encoding 'auto' -HasHeader $true
    Assert-True ($r.Ok -and @($ed.Csv.Rows).Count -eq $tpl['csv'].Count - 1 -and $ed.Csv.Header[0] -eq $tpl['csv'][0][0]) 'sample CSV loaded'
    Assert-Equal $tpl['csv'][0].Count (Get-FujiCsvMaxColumn $ed) 'CSV columns'
    $choices = Get-FujiPlaceholderChoice -Editor $ed
    Assert-Equal ('{{' + $tpl['csv'][0][0] + '}}') $choices[0][0] 'placeholder by header name'
    Set-FujiCsvHeader -Editor $ed -HasHeader $false
    Assert-Equal $tpl['csv'].Count @($ed.Csv.Rows).Count 'header off: all records are rows'
    Write-FujiTextFile -Path (Join-Path $work 'err.csv') -Text ("a," + (Get-FujiText 'editor.csv.resultHeaderName') + "`r`n1,2`r`n")
    $r = Import-FujiEditorCsv -Editor $ed -Path (Join-Path $work 'err.csv') -HasHeader $false
    Assert-True ($r.HeaderForced -and @($ed.Csv.Rows).Count -eq 1) 'results CSV turns the header on'
    Assert-True (-not (Import-FujiEditorCsv -Editor $ed -Path (Join-Path $work 'none.csv')).Ok) 'missing CSV'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}

# ----------------------------------------------------------------- editor: steps, blocks, undo
function New-TestEditor {
    param([string[]]$Cmds)
    $e = New-FujiEditor -Directory ([System.IO.Path]::GetTempPath()) -Log $null
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($c in $Cmds) { $steps.Add([ordered]@{ cmd = $c; val = ''; label = $c }) }
    $e.Data.macros.Add([ordered]@{ id = 'a'; name = 'a'; targetWindow = ''; steps = $steps })
    Add-FujiHistory -Editor $e -Description 'start'
    # no temp file writes into the real temp folder
    $e.Directory = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_none_' + [guid]::NewGuid().ToString('N'))
    return $e
}
function Get-TestCmd { param($E) return (@((Get-FujiCurrentStepList $E) | ForEach-Object { $_.cmd }) -join ' ') }

$e = New-TestEditor @('KEY', 'WAIT')
$e.Selected = 0
$res = Complete-FujiStepEdit -Cmd 'IF_START' -Raw @{ left = 'a'; op = 'EQ'; right = 'b' }
Assert-True ($res.ContainsKey('Step')) 'IF settings accepted'
Assert-True (Add-FujiEditorStep -Editor $e -Step $res.Step) 'add IF'
Assert-Equal 'KEY IF_START IF_END WAIT' (Get-TestCmd $e) 'IF added with its end after the selection'
Assert-Equal 1 $e.Selected 'new step selected'
$res = Complete-FujiStepEdit -Cmd 'ELSE' -Raw @{}
$e.Selected = 3
Assert-True (-not (Add-FujiEditorStep -Editor $e -Step $res.Step)) 'ELSE outside an if-block refused'
$e.Selected = 1
Assert-True (Add-FujiEditorStep -Editor $e -Step $res.Step) 'ELSE inside the if-block'
Assert-Equal 'KEY IF_START ELSE IF_END WAIT' (Get-TestCmd $e) 'ELSE placed'
$e.Selected = 0
$res = Complete-FujiStepEdit -Cmd 'TRY_START' -Raw @{ name = 't' }
[void](Add-FujiEditorStep -Editor $e -Step $res.Step)
Assert-Equal 'KEY TRY_START CATCH TRY_END IF_START ELSE IF_END WAIT' (Get-TestCmd $e) 'TRY added with CATCH and end'
Assert-True ((Complete-FujiStepEdit -Cmd 'WAIT' -Raw @{ ms = 'x' }).ContainsKey('Error')) 'invalid settings refused'
$g = (Complete-FujiStepEdit -Cmd 'GROUP_START' -Raw @{ name = ' g '; when = 'first' }).Step
Assert-True ($g.val -eq 'g' -and $g.when -eq 'first' -and $g.label -eq 'g') 'group: trimmed, when kept as a property'
$c = (Complete-FujiStepEdit -Cmd 'COMMENT' -Raw @{ memo = " a`r`n" }).Step
Assert-Equal " a`r`n" $c.val 'raw field kept as typed'
$l = (Complete-FujiStepEdit -Cmd 'WAIT' -Raw @{ ms = '100' } -Label ' my ').Step
Assert-Equal 'my' $l.label 'custom label'
$st = Get-FujiStepEditState -Cmd 'WAIT' -Step $l
Assert-True ($st.CustomLabel -eq 'my' -and $st.Values['ms'] -eq '100') 'edit state with a custom label'
$st = Get-FujiStepEditState -Cmd 'GROUP_START' -Step $g
Assert-True ($st.CustomLabel -eq '' -and $st.Values['when'] -eq 'first') 'edit state: automatic label, property value'
$st = Get-FujiStepEditState -Cmd 'WAIT_FOR'
Assert-Equal '30' $st.Values['timeout'] 'new step: default settings'

# move: one position at a time (a block moved up enters the block above it, like the HTA),
# and never so that a block stops being closed
$e.Selected = 4
Assert-True (Move-FujiEditorStep -Editor $e -Direction -1) 'move block up'
Assert-Equal 'KEY TRY_START CATCH IF_START ELSE IF_END TRY_END WAIT' (Get-TestCmd $e) 'whole if-block moved into the end of the try-block'
Assert-Equal 3 $e.Selected 'moved block stays selected'
$e.Selected = 5
Assert-True (-not (Move-FujiEditorStep -Editor $e -Direction -1)) 'block end cannot pass its ELSE upwards'
Assert-True (-not (Move-FujiEditorRange -Editor $e -From 5 -To 5 -InsertAt 3)) 'block end cannot go above its start'
$e.Selected = 2
Assert-True (-not (Move-FujiEditorStep -Editor $e -Direction 1)) 'CATCH cannot move into an if-block'
Assert-True (Move-FujiEditorRange -Editor $e -From 7 -To 7 -InsertAt 0) 'drag a step to the top'
Assert-Equal 'WAIT KEY TRY_START CATCH IF_START ELSE IF_END TRY_END' (Get-TestCmd $e) 'dragged'

# duplicate, disable
$e.Selected = 6
Assert-True (Copy-FujiEditorStep -Editor $e) 'duplicate from a block end copies the block'
Assert-Equal 'WAIT KEY TRY_START CATCH IF_START ELSE IF_END IF_START ELSE IF_END TRY_END' (Get-TestCmd $e) 'block duplicated'
Assert-Equal 7 $e.Selected 'copy selected'
$e.Selected = 5
Assert-True (-not (Copy-FujiEditorStep -Editor $e)) 'ELSE alone is not duplicated'
Assert-True (-not (Switch-FujiEditorStepDisabled -Editor $e)) 'ELSE cannot be disabled'
$e.Selected = 1
Assert-True ((Switch-FujiEditorStepDisabled -Editor $e) -and (Get-FujiCurrentStepList $e)[1].disabled) 'disable'
[void](Switch-FujiEditorStepDisabled -Editor $e)
Assert-True (-not (Get-FujiCurrentStepList $e)[1].Contains('disabled')) 'enable'

# delete: only the frame, a whole block, one step
Remove-FujiEditorStep -Editor $e -Index 7 -Mode 'Frame'
Assert-Equal 'WAIT KEY TRY_START CATCH IF_START ELSE IF_END TRY_END' (Get-TestCmd $e) 'frame removed with its ELSE'
$blkInfo = Get-FujiEditorBlock -Editor $e -Index 6
Assert-True ($blkInfo.Start -eq 4 -and $blkInfo.End -eq 6) 'block of an end step'
Assert-True ($null -eq (Get-FujiEditorBlock -Editor $e -Index 5)) 'ELSE is not a block start or end'
Remove-FujiEditorStep -Editor $e -Index 6 -Mode 'All'
Assert-Equal 'WAIT KEY TRY_START CATCH TRY_END' (Get-TestCmd $e) 'whole block removed'
Remove-FujiEditorStep -Editor $e -Index 0
Assert-Equal 'KEY TRY_START CATCH TRY_END' (Get-TestCmd $e) 'one step removed'
Assert-Equal 0 $e.Selected 'selection after delete'

# collapse, visible rows, insertion point
$e.Selected = 2
Switch-FujiBlockCollapsed -Editor $e -Index 1
$rows = Get-FujiStepRow -Editor $e
Assert-Equal '0,1' (@($rows | ForEach-Object { $_.Index }) -join ',') 'collapsed block hides its contents'
Assert-True ($rows[1].HiddenCount -eq 1 -and $e.Selected -eq 1) 'hidden count; selection moved to the block start'
Assert-Equal 4 (Get-FujiInsertionIndex $e) 'insertion after a collapsed block'
Assert-True (-not (ConvertTo-FujiMacroJson -Data $e.Data).Contains('collapsed')) 'collapsed is not written'
$e.Selected = 0
$res = Complete-FujiStepEdit -Cmd 'KEY' -Raw @{ key = 'a' }
Set-FujiAllCollapsed -Editor $e -Collapsed $false
Assert-True (-not (Get-FujiCurrentStepList $e)[1].Contains('collapsed')) 'expand all'
Assert-Equal '0,1,2,3' (@((Get-FujiStepRow -Editor $e) | ForEach-Object { $_.Index }) -join ',') 'all rows visible'
Assert-Equal '0,0,0,0' (@((Get-FujiStepRow -Editor $e) | ForEach-Object { $_.Depth }) -join ',') 'row depths'

# undo / redo
$e2 = New-TestEditor @('KEY')
$e2.Selected = 0
[void](Add-FujiEditorStep -Editor $e2 -Step (Complete-FujiStepEdit -Cmd 'WAIT' -Raw @{ ms = '5' }).Step)
Add-FujiMacro -Editor $e2 -Name 'other'
Assert-True (Undo-FujiEditorChange -Editor $e2) 'undo'
Assert-True ($e2.Data.macros.Count -eq 1 -and $e2.MacroIndex -eq 0) 'undo removed the macro'
Assert-True (Undo-FujiEditorChange -Editor $e2) 'undo again'
Assert-Equal 'KEY' (Get-TestCmd $e2) 'undo removed the step'
Assert-True (-not (Undo-FujiEditorChange -Editor $e2)) 'nothing more to undo'
Assert-True (Redo-FujiEditorChange -Editor $e2) 'redo'
Assert-True ((Get-TestCmd $e2) -eq 'KEY WAIT' -and $e2.Selected -eq 1) 'redo restores the step and selection'
(Get-FujiCurrentStepList $e2)[0].val = 'changed outside'
Assert-True ($e2.History[$e2.HistoryPos].Data.macros[0].steps[0].val -ne 'changed outside') 'history holds copies'
Copy-FujiCurrentMacro -Editor $e2
Assert-True ($e2.Data.macros.Count -eq 2 -and $e2.MacroIndex -eq 1 -and $e2.Data.macros[1].id -ne $e2.Data.macros[0].id) 'duplicate macro'
Assert-True ($e2.History.Count -eq 3) 'redo branch dropped by a new change'
Remove-FujiCurrentMacro -Editor $e2
Remove-FujiCurrentMacro -Editor $e2
Assert-Equal 1 $e2.Data.macros.Count 'deleting the last macro leaves a new empty one'
for ($i = 0; $i -lt 40; $i++) { Rename-FujiMacro -Editor $e2 -Name ('n' + $i) }
Assert-Equal 30 $e2.History.Count 'history limit'

# capture rectangle
$scr = @{ X = 0; Y = 0; Width = 1920; Height = 1080 }
$cr = Get-FujiCaptureRect -X 500 -Y 400 -Width 60 -Height 30 -Screen $scr
Assert-Equal '470,385,60,30' ('{0},{1},{2},{3}' -f $cr.X, $cr.Y, $cr.Width, $cr.Height) 'capture rect'
$cr = Get-FujiCaptureRect -X 5 -Y 1078 -Width 60 -Height 30 -Screen $scr
Assert-Equal '0,1077,10,2' ('{0},{1},{2},{3}' -f $cr.X, $cr.Y, $cr.Width, $cr.Height) 'capture rect shrinks at the edge, cursor centred'
$cr = Get-FujiCaptureRect -X -100 -Y 10 -Width 60 -Height 30 -Screen @{ X = -1920; Y = 0; Width = 3840; Height = 1080 }
Assert-Equal '-130,0,60,20' ('{0},{1},{2},{3}' -f $cr.X, $cr.Y, $cr.Width, $cr.Height) 'capture rect on a left monitor'

# ----------------------------------------------------------------- source rules
# The app file handed out must be the current build of the sources
$built = & (Join-Path $psRoot 'build/Build-FujiBundle.ps1') -PassThru
$current = ([System.IO.File]::ReadAllText((Join-Path $psRoot 'fujikyun.ps1'))) -replace "`r`n", "`n"
Assert-True ($current -ceq ($built -replace "`r`n", "`n")) 'fujikyun.ps1 is up to date (run ps/build/Build-FujiBundle.ps1)'

$sources = @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'gui') -Filter '*.ps1') +
    @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'build') -Filter '*.ps1') + @(Get-Item -LiteralPath (Join-Path $psRoot 'fujikyun.ps1')) + @(Get-Item -LiteralPath $PSCommandPath)
foreach ($f in $sources) {
    # The window code cannot run here (Windows Forms): at least it must parse
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) ('{0} parses ({1})' -f $f.Name, (@($parseErrors) -join '; '))
}
foreach ($f in $sources) {
    # Latin-1 maps every byte to one char, so a non-ASCII byte shows up as a char above 0x7F
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($f.FullName))
    $bad = [regex]::Matches($text, '[^\x00-\x7F]').Count
    Assert-True ($bad -eq 0) ('{0} must be ASCII only ({1} non-ASCII bytes)' -f $f.Name, $bad)
}

# ----------------------------------------------------------------- report
if ($script:failures.Count -gt 0) {
    $script:failures | ForEach-Object { Write-Output ('FAIL ' + $_) }
    Write-Output ('{0} of {1} checks failed' -f $script:failures.Count, $script:count)
    exit 1
}
Write-Output ('ALL {0} CHECKS PASSED ({1} {2})' -f $script:count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
