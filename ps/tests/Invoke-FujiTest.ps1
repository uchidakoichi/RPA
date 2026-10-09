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

# ----------------------------------------------------------------- source rules
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1') + @(Get-Item -LiteralPath $PSCommandPath)) {
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
