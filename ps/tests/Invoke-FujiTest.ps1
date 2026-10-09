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
    $isError = $null -ne (Get-Golden $case 'error')
    try {
        $v = Invoke-FujiCalc -Expression $case.expr
        if ($isError) { Assert-True $false ('calc "{0}" should fail but gave {1}' -f $case.expr, $v) } else { Assert-Equal $case.value $v ('calc "{0}"' -f $case.expr) }
    } catch {
        Assert-True $isError ('calc "{0}" failed: {1}' -f $case.expr, $_.Exception.Message)
    }
}

# ----------------------------------------------------------------- golden: string operations
foreach ($case in $golden.strop) {
    $isError = $null -ne (Get-Golden $case 'error')
    $what = 'strOp {0}("{1}", "{2}", "{3}")' -f $case.op, $case.s, $case.a, $case.b
    try {
        $v = Invoke-FujiStringOp -Op $case.op -Text $case.s -A $case.a -B $case.b
        if ($isError) { Assert-True $false ('{0} should fail but gave {1}' -f $what, $v) } else { Assert-Equal $case.value $v $what }
    } catch {
        Assert-True $isError ('{0} failed: {1}' -f $what, $_.Exception.Message)
    }
}

# ----------------------------------------------------------------- golden: numbers, conditions, wareki
foreach ($case in $golden.numbers) {
    $v = ConvertTo-FujiNumber -Text $case.text
    Assert-Equal $case.value $v ('number "{0}"' -f $case.text)
}
foreach ($case in $golden.conditions) {
    $v = Test-FujiCondition -Op $case.op -Left $case.left -Right $case.right
    Assert-Equal $case.value $v ('condition "{0}" {1} "{2}"' -f $case.left, $case.op, $case.right)
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

# ----------------------------------------------------------------- source rules
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1') + @(Get-Item -LiteralPath $PSCommandPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $bad = @($bytes | Where-Object { $_ -gt 0x7F }).Count
    Assert-True ($bad -eq 0) ('{0} must be ASCII only ({1} non-ASCII bytes)' -f $f.Name, $bad)
}

# ----------------------------------------------------------------- report
if ($script:failures.Count -gt 0) {
    $script:failures | ForEach-Object { Write-Output ('FAIL ' + $_) }
    Write-Output ('{0} of {1} checks failed' -f $script:failures.Count, $script:count)
    exit 1
}
Write-Output ('ALL {0} CHECKS PASSED ({1} {2})' -f $script:count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
