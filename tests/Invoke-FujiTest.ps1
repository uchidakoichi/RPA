#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the PowerShell edition's core (no window, no Windows-only API).

.DESCRIPTION
    Runs on Windows PowerShell 5.1 and on PowerShell 7 (also on macOS / Linux):
        powershell -NoProfile -File tests\Invoke-FujiTest.ps1
        pwsh -NoProfile -File tests/Invoke-FujiTest.ps1
    golden.json holds checked input / output pairs, first taken from the original
    implementation (tag hta-final); edit it directly from now on.
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

# ----------------------------------------------------------------- text
Assert-True ((Get-FujiText 'gui.exportResults' 0) -notlike '*{0}*') 'text: 0 is put in place of {0}'
Assert-True ((Get-FujiText 'gui.exportResults' '') -notlike '*{0}*') 'text: an empty value is put in place of {0}'

# ----------------------------------------------------------------- version
Assert-True ($script:FujiAppVersion -match '^\d{4}\.\d{2}\.\d{2}(\.\d+)?$') 'version: year.month.day'
# the app file people copy alone carries its license (MIT asks for the notice in every copy)
$mainHead = [System.IO.File]::ReadAllText((Join-Path (Join-Path $psRoot 'build') 'Main.ps1'))
Assert-True ($mainHead.Contains('MIT License') -and $mainHead.Contains('Copyright (c) 2026 Koichi Uchida') -and $mainHead.Contains('THE SOFTWARE IS PROVIDED "AS IS"')) 'license: notice in the app script'

# ----------------------------------------------------------------- log file
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_log_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
try {
    Assert-Equal '' (Write-FujiLogFile -Message 'before') 'log file: nothing written before it is set up'
    [void](Initialize-FujiLogFile -Directory $work -Now ([datetime]'2026-10-22 09:00'))
    $logDir = Join-Path $work 'fujikyun_logs'
    Assert-True (Test-Path -LiteralPath $logDir) 'log file: folder made'
    Write-FujiTextFile -Path (Join-Path $logDir 'fujikyun_log_2026-09-21.txt') -Text 'old'
    Write-FujiTextFile -Path (Join-Path $logDir 'fujikyun_log_2026-09-22.txt') -Text 'kept'
    Write-FujiTextFile -Path (Join-Path $logDir 'notes.txt') -Text 'not a log'
    $removed = Initialize-FujiLogFile -Directory $work -Now ([datetime]'2026-10-22 09:00')
    Assert-Equal 'fujikyun_log_2026-09-21.txt' ($removed -join ',') 'log file: only logs older than 30 days removed'
    Assert-True ((Test-Path -LiteralPath (Join-Path $logDir 'fujikyun_log_2026-09-22.txt')) -and (Test-Path -LiteralPath (Join-Path $logDir 'notes.txt'))) 'log file: newer logs and other files kept'
    Assert-Equal '' (Write-FujiLogFile -Message ('a' + "`n" + 'b') -Now ([datetime]'2026-10-22 10:41:02')) 'log file: written'
    Assert-Equal '' (Write-FujiLogFile -Message 'stop' -Level 'error' -Now ([datetime]'2026-10-22 10:41:03')) 'log file: appended'
    $logPath = Join-Path $logDir 'fujikyun_log_2026-10-22.txt'
    $bytes = [System.IO.File]::ReadAllBytes($logPath)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and $bytes[3] -ne 0xEF) 'log file: one BOM at the start'
    Assert-Equal ("[10:41:02] a`r`nb`r`n[10:41:03] [error] stop`r`n") (Read-FujiUtf8File -Path $logPath) 'log file: lines'
    Remove-Item -LiteralPath $logDir -Recurse -Force
    Write-FujiTextFile -Path $logDir -Text 'a file where the folder should be'
    Assert-True ((Write-FujiLogFile -Message 'x') -ne '') 'log file: a failure is reported'
    Assert-Equal '' (Write-FujiLogFile -Message 'y') 'log file: not tried again after a failure'
} finally {
    $script:FujiLogFile = $null
    Remove-Item -LiteralPath $work -Recurse -Force
}

# ----------------------------------------------------------------- one app per folder
$lockA = Join-Path ([System.IO.Path]::GetTempPath()) 'fujikyun_lock_a'
Assert-Equal (Get-FujiAppLockName -Directory $lockA) (Get-FujiAppLockName -Directory ($lockA.ToUpperInvariant() + [System.IO.Path]::DirectorySeparatorChar)) 'lock: same folder, same name (case, end separator)'
Assert-True ((Get-FujiAppLockName -Directory $lockA) -ne (Get-FujiAppLockName -Directory ($lockA + 'b'))) 'lock: another folder, another name'
$lock = Enter-FujiAppLock -Directory $lockA
try {
    Assert-True ($null -ne $lock) 'lock: taken'
    # another app is another thread (here a runspace): it must not get the lock
    $other = [powershell]::Create()
    try {
        [void]$other.AddScript({ param($Name) $m = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, $Name; $got = $m.WaitOne(0); if ($got) { $m.ReleaseMutex() }; $m.Dispose(); $got }).AddArgument((Get-FujiAppLockName -Directory $lockA))
        Assert-True (-not [bool]($other.Invoke() | Select-Object -First 1)) 'lock: refused while another app has it'
    } finally {
        $other.Dispose()
    }
    $lockB = Enter-FujiAppLock -Directory ($lockA + 'b')
    Assert-True ($null -ne $lockB) 'lock: another folder is free'
    $lockB.ReleaseMutex(); $lockB.Dispose()
} finally {
    if ($null -ne $lock) { $lock.ReleaseMutex(); $lock.Dispose() }
}

# ----------------------------------------------------------------- alerts (how the app calls a person)
$al = Get-FujiAlertSetting -Settings ([ordered]@{}) -Kind 'error'
Assert-True ($al.style -eq 'full' -and $al.color -eq '#D32F2F' -and $al.repeat -and $al.minutes -eq 3 -and $al.file -eq 'Alarm01.wav' -and -not $al.Contains('sound')) 'alert: error defaults'
$al = Get-FujiAlertSetting -Settings $null -Kind 'confirm'
Assert-True ($al.style -eq 'border' -and -not $al.sound -and $al.file -eq 'Ring02.wav') 'alert: confirm defaults'
$alSet = [ordered]@{ alerts = [ordered]@{ confirm = [ordered]@{ style = 'none'; color = '#00aa00'; flash = $false; sound = $true; file = 'ring05.WAV'; repeat = $true; minutes = 10 } } }
$al = Get-FujiAlertSetting -Settings $alSet -Kind 'confirm'
Assert-True ($al.style -eq 'none' -and $al.color -eq '#00AA00' -and -not $al.flash -and $al.sound -and $al.file -eq 'Ring05.wav' -and $al.repeat -and $al.minutes -eq 10) 'alert: saved values read'
$alSet = [ordered]@{ alerts = [ordered]@{ error = [ordered]@{ style = 'big'; color = 'red'; flash = 'yes'; file = '..\x.wav'; minutes = 7 } } }
$al = Get-FujiAlertSetting -Settings $alSet -Kind 'error'
Assert-True ($al.style -eq 'full' -and $al.color -eq '#D32F2F' -and $al.flash -eq $true -and $al.file -eq 'Alarm01.wav' -and $al.minutes -eq 3) 'alert: wrong values fall back to the defaults'
$alSet = [ordered]@{ ui = [ordered]@{} }
Set-FujiAlertSetting -Settings $alSet -Kind 'confirm' -Value ([ordered]@{ style = 'full'; color = '#123456'; flash = $true; sound = $true; file = 'Alarm03.wav'; repeat = $false; minutes = 5; extra = 1 })
Assert-True ($alSet.alerts.confirm.style -eq 'full' -and -not $alSet.alerts.confirm.Contains('extra')) 'alert: saved without unknown keys'
Assert-Equal 'Alarm03.wav' (Get-FujiAlertSetting -Settings $alSet -Kind 'confirm').file 'alert: saved and read back'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_alert_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
try {
    Save-FujiSetting -Directory $work -Settings $alSet
    Assert-Equal 'full' (Get-FujiAlertSetting -Settings (Read-FujiSetting -Directory $work) -Kind 'confirm').style 'alert: kept in the settings file'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
Assert-Equal '#FFFFFF' (Get-FujiAlertTextColor -Color '#D32F2F') 'alert: white text on red'
Assert-Equal '#000000' (Get-FujiAlertTextColor -Color '#F9A825') 'alert: black text on yellow'
Assert-Equal '#891F1F' (Get-FujiAlertShade -Color '#D32F2F') 'alert: flashes to a darker shade'
$t0 = [datetime]'2026-10-22 14:05:00'
Assert-Equal (Get-FujiText 'alert.elapsedNew') (Format-FujiElapsed -Since $t0 -Now $t0.AddSeconds(59)) 'alert: under a minute'
Assert-True ((Format-FujiElapsed -Since $t0 -Now $t0.AddMinutes(12)) -match '^12\D') 'alert: minutes'
Assert-True ((Format-FujiElapsed -Since $t0 -Now $t0.AddMinutes(65)) -match '^1\D+5\D') 'alert: hours and minutes'
Assert-Equal 20 $script:FujiAlertSounds.Count 'alert: twenty sounds to choose'

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
# A RUN that starts PowerShell also refuses quotes, variables, statement ends and blocks (curly quotes too)
$normalPattern = (Get-FujiCommandUnsafePattern -Command 'cmd /c echo {{1}}').ToString()
Assert-Equal $normalPattern (Get-FujiCommandUnsafePattern -Command 'cmd /c echo {{pwsh}}').ToString() 'unsafe pattern: placeholder named pwsh'
foreach ($cmdText in @('powershell -NoProfile -Command "x {{1}}"', 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -c {{1}}', 'PWSH -c {{1}}', 'cmd /c start powershell {{1}}')) {
    Assert-True ((Get-FujiCommandUnsafePattern -Command $cmdText).ToString() -ne $normalPattern) ('unsafe pattern for PowerShell: ' + $cmdText)
}
$psPattern = Get-FujiCommandUnsafePattern -Command 'powershell -Command "x {{1}}"'
$ctx.Row.Data = @("x'; Stop-Computer; '", 'C:\RPA\a b.xlsx', '1); (1', ('a' + [char]0x2019 + 'b'), '$env:x', 'a{b}', 'a`b')
$unsafe = New-Object -TypeName 'System.Collections.Generic.List[string]'
[void](Expand-FujiPlaceholder -Text "'{{1}}' '{{2}}' {{3}} '{{4}}' {{5}} {{6}} {{7}}" -Context $ctx -Unsafe $unsafe -UnsafePattern $psPattern)
Assert-Equal 6 $unsafe.Count 'PowerShell unsafe count'
$unsafe = New-Object -TypeName 'System.Collections.Generic.List[string]'
[void](Expand-FujiPlaceholder -Text "{{1}} {{2}} {{3}}" -Context $ctx -Unsafe $unsafe)
Assert-Equal 0 $unsafe.Count 'cmd unsafe count ignores PowerShell characters'
$ctx.Row.Data = @($fx.unsafeRow)

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

# ----------------------------------------------------------------- edge cases: files other programs hold, odd folders, broken files
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # Windows enforces share modes (Excel keeps an open CSV or book locked); macOS / Linux do not
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $p = Join-Path $tmp 'open.csv'
        Write-FujiTextFile -Path $p -Text "a,b`r`n1,2`r`n"
        $fs = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'Read')
        try {
            Assert-Equal "a,b`r`n1,2`r`n" (Read-FujiCsvText -Path $p).Text 'edge: a CSV open for writing in another program (Excel) is read'
            $msg = ''
            try { Write-FujiTextFile -Path $p -Text 'x' } catch { $msg = $_.Exception.Message }
            Assert-Equal (Get-FujiText 'data.fileBusy' $p) $msg 'edge: writing a file another program holds says so in words'
        } finally {
            $fs.Dispose()
        }
        $main = Join-Path $tmp 'held.json'
        Write-FujiTextFile -Path $main -Text 'v1'
        $fs = [System.IO.File]::Open($main, 'Open', 'Read', 'Read')
        try {
            $msg = ''
            try { Write-FujiFileSafely -Path $main -Text 'v2' -BackupPath (Join-Path $tmp 'held_backup.json') } catch { $msg = $_.Exception.Message }
            Assert-Equal (Get-FujiText 'data.fileBusy' $main) $msg 'edge: safe write to a held file says so in words'
        } finally {
            $fs.Dispose()
        }
        Assert-True (-not (Test-Path -LiteralPath ($main + '.saving'))) 'edge: a failed safe write leaves no temp file'
        Assert-Equal 'v1' (Read-FujiUtf8File -Path $main) 'edge: a failed safe write keeps the file'
    }

    # folders people make: spaces, Japanese, brackets (PowerShell wildcards), quotes, % and &
    $names = @('with space', ($jp + ' x'), 'copy[1]', "o'quote", 'pct%20', 'a&b')
    foreach ($name in $names) {
        $dir = Join-Path $tmp $name
        [void][System.IO.Directory]::CreateDirectory($dir)
        $e = New-FujiEditor -Directory $dir
        Initialize-FujiEditorData -Editor $e -AskRestoreTemp { $true }
        Add-FujiMacro -Editor $e -Name 'm2'
        Assert-Equal '' (Save-FujiEditorData -Editor $e) ('edge: save in folder ' + $name)
        $e2 = New-FujiEditor -Directory $dir
        Initialize-FujiEditorData -Editor $e2 -AskRestoreTemp { $true }
        Assert-Equal 2 $e2.Data.macros.Count ('edge: load in folder ' + $name)
        [void](Initialize-FujiLogFile -Directory $dir)
        Assert-Equal '' (Write-FujiLogFile -Message 'x') ('edge: log file in folder ' + $name)
        Save-FujiSetting -Directory $dir -Settings (Read-FujiSetting -Directory $dir)
        Assert-True (Test-Path -LiteralPath (Join-Path $dir 'fujikyun_settings.json')) ('edge: settings in folder ' + $name)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir 'fujikyun_settings.json.saving'))) ('edge: settings saved without a leftover in folder ' + $name)
    }
    $script:FujiLogFile = $null

    # started by a scheduled task: the last time's temp file is left for after the run, never written over
    foreach ($restore in @($true, $false)) {
        $dir = Join-Path $tmp ('later ' + $restore)
        [void][System.IO.Directory]::CreateDirectory($dir)
        $e = New-FujiEditor -Directory $dir
        Initialize-FujiEditorData -Editor $e -AskRestoreTemp { $true }
        Add-FujiMacro -Editor $e -Name 'saved'
        [void](Save-FujiEditorData -Editor $e)
        Add-FujiMacro -Editor $e -Name 'unsaved'
        $tempPath = Join-Path $dir 'fujikyun_macros_temp.json'
        $tempText = Read-FujiUtf8File -Path $tempPath
        $e = New-FujiEditor -Directory $dir
        Initialize-FujiEditorData -Editor $e -AskRestoreTemp { 'later' }
        Assert-True ($e.TempPending -and -not $e.Dirty -and @($e.Data.macros | Where-Object { $_.name -eq 'unsaved' }).Count -eq 0) 'scheduled start: the saved macros, the temp file waits'
        Add-FujiMacro -Editor $e -Name 'during'
        [void](Save-FujiEditorData -Editor $e)
        Assert-Equal $tempText (Read-FujiUtf8File -Path $tempPath) 'scheduled start: the waiting temp file is not written over or removed'
        Assert-Equal $restore (Resolve-FujiEditorTemp -Editor $e -Restore $restore) ('scheduled start: answered after the run (' + $restore + ')')
        if ($restore) {
            Assert-True ($e.Dirty -and @($e.Data.macros | Where-Object { $_.name -eq 'unsaved' }).Count -eq 1 -and -not $e.TempPending) 'scheduled start: the unsaved work restored after the run'
        } else {
            Assert-True (-not (Test-Path -LiteralPath $tempPath) -and @(Get-ChildItem -LiteralPath $dir -Filter 'fujikyun_macros_temp_discarded_*.json').Count -eq 1) 'scheduled start: not restored, the temp file moved aside'
        }
    }

    # JSON that is not a macros file is kept like a broken one, never read as "no macros"
    foreach ($case in @(@('empty', ''), @('null', 'null'), @('array', '[]'), @('string', '"x"'), @('object', '{}'), @('macros not a list', '{"macros":{}}'), @('cut short', '{"macros":[{"name":"a"'))) {
        $dir = Join-Path $tmp ('broken ' + $case[0])
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::WriteAllText((Join-Path $dir 'fujikyun_macros.json'), $case[1])
        $e = New-FujiEditor -Directory $dir
        Initialize-FujiEditorData -Editor $e -AskRestoreTemp { $true }
        Assert-True ([bool]$e.SaveBlockReason -and $e.Notices.Count -eq 1) ('edge: macros file ' + $case[0] + ' guards the next save')
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $dir -Filter 'fujikyun_macros_broken_*.json').Count ('edge: macros file ' + $case[0] + ' copied aside')
    }
    $dir = Join-Path $tmp 'odd steps'
    [void][System.IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::WriteAllText((Join-Path $dir 'fujikyun_macros.json'), '{"macros":[{"name":12,"id":34,"steps":[1,"x",null,{"cmd":5},{"cmd":"WAIT","val":{"a":1}},{"cmd":"wait","val":"100"}]},{"steps":null}]}')
    $e = New-FujiEditor -Directory $dir
    Initialize-FujiEditorData -Editor $e -AskRestoreTemp { $true }
    Assert-True (-not $e.SaveBlockReason) 'edge: odd values inside a macros file are read'
    Assert-Equal 'COMMENT WAIT WAIT' (@($e.Data.macros[0].steps | ForEach-Object { $_.cmd }) -join ' ') 'edge: odd steps cleaned (unknown number command kept as a comment)'
    Assert-Equal '12' $e.Data.macros[0].name 'edge: a number as a macro name'

    # a settings file that cannot be read: the app starts with standard settings, a copy is kept and it is told
    foreach ($case in @(@('cut short', '{"ui":'), @('array', '[1]'), @('shift_jis', $null))) {
        $dir = Join-Path $tmp ('settings ' + $case[0])
        [void][System.IO.Directory]::CreateDirectory($dir)
        $sp = Join-Path $dir 'fujikyun_settings.json'
        if ($null -eq $case[1]) { [System.IO.File]::WriteAllBytes($sp, (Get-FujiEncoding 'shift_jis').GetBytes('{"a":"' + $jp + '"}')) } else { [System.IO.File]::WriteAllText($sp, $case[1]) }
        $script:FujiSettingsNotice = ''
        $s = Read-FujiSetting -Directory $dir
        Assert-True ($s.schedules.Count -eq 0 -and $script:FujiSettingsNotice -ne '') ('edge: settings ' + $case[0] + ' told')
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $dir -Filter 'fujikyun_settings_broken_*.json').Count ('edge: settings ' + $case[0] + ' copied aside')
    }
    $script:FujiSettingsNotice = ''
    [void](Read-FujiSetting -Directory $tmp)
    Assert-Equal '' $script:FujiSettingsNotice 'edge: no settings file is not a problem'

    # paths typed into the CSV box
    $e = New-FujiEditor -Directory $tmp
    Assert-True (-not (Import-FujiEditorCsv -Editor $e -Path 'C:\a|b.csv').Ok) 'edge: a CSV path with characters Windows refuses'
    Assert-True (-not (Import-FujiEditorCsv -Editor $e -Path $tmp).Ok) 'edge: a folder in the CSV box'
    Assert-True (-not (Import-FujiEditorCsv -Editor $e -Path (Join-Path $tmp '*.csv')).Ok) 'edge: a wildcard in the CSV box'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
# values from a CSV or typed by people
$ctx = @{ Row = @{ No = 3; Data = @('a', 'b') }; Header = @('x', 'y'); Vars = [ordered]@{} }
Assert-Equal '{{ROW+99999999999}}' (Expand-FujiPlaceholder -Text '{{ROW+99999999999}}' -Context $ctx) 'edge: a row offset too large for a number is left as text'
Assert-Equal '{{a}}' (Expand-FujiPlaceholder -Text '{{{{1}}}}' -Context $ctx) 'edge: nested braces'
Assert-Equal ('x' * 5000) (Expand-FujiPlaceholder -Text ('x' * 5000) -Context $ctx) 'edge: a long text'
Assert-Equal '1' (Invoke-FujiCalc -Expression ('(' * 300 + '1' + ')' * 300)) 'edge: deep brackets'
Assert-Equal '0.3' (Invoke-FujiCalc -Expression '0.1+0.2') 'edge: decimals add exactly'
Assert-Equal 3 (ConvertFrom-FujiCsv -Text "a,b`r`n`r`n1,2`r`n`r`n").Records.Count 'edge: blank lines inside a CSV keep their place, trailing ones go'
Assert-Equal 2 (ConvertFrom-FujiCsv -Text "a,b`r1,2`r").Records.Count 'edge: a CSV with old Mac line ends'

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
Assert-Equal 381 $templates['templates'].Count 'template count'
$cats = $templates['categories']
foreach ($t in $templates['templates']) { Assert-True ($cats.Contains($t['category'])) ('{0}: category is listed' -f $t['id']) }
$tplHits = { param($q) $ids = New-Object -TypeName 'System.Collections.Generic.List[string]'; foreach ($t in $templates['templates']) { if (Test-FujiTemplateMatch -Template $t -Query $q) { $ids.Add($t['id']) } }; , $ids.ToArray() }
Assert-Equal $templates['templates'].Count (& $tplHits ' ').Count 'template search: blank query shows all'
Assert-True ((& $tplHits ([string][char]0xFF30 + [char]0xFF44 + [char]0xFF46 + [char]0x3000 + 'word')) -contains 'word-to-pdf') 'template search: full-width letters and space, any case'
Assert-True (-not ((& $tplHits 'PDF Word') -contains 'ppt-to-pdf')) 'template search: every word must match'
Assert-Equal 0 (& $tplHits 'no-such-word-xyz').Count 'template search: no match'
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
Assert-True (-not (ConvertTo-FujiMacroData -Source ([ordered]@{ version = 28; macros = @() })).NewerVersion) 'data version 28 is not newer'
Assert-True (ConvertTo-FujiMacroData -Source ([ordered]@{ version = 29; macros = @() })).NewerVersion 'data version 29 is newer'
# watch rules: kept through the file, cleaned (no title: dropped; unknown action: stop), copied with the macro
$wsrc = ConvertFrom-FujiJson -Json '{"version":28,"macros":[{"id":"w","name":"w","targetWindow":"","watch":[{"title":" Timeout ","key":"{ENTER}","action":"call","macroId":"s","macroName":"relogin"},{"title":"","action":"STOP"},{"title":"Err","action":"boom","macroId":"x"}],"steps":[]}]}'
$wdata = (ConvertTo-FujiMacroData -Source $wsrc).Data
$wr = Get-FujiWatchRule -Macro $wdata.macros[0]
Assert-True ($wr.Count -eq 2 -and $wr[0].title -eq 'Timeout' -and $wr[0].action -eq 'CALL' -and $wr[0].macroId -eq 's' -and $wr[1].action -eq 'STOP' -and $wr[1].macroId -eq '') 'watch rules: read and cleaned'
$wjson = ConvertTo-FujiMacroJson -Data $wdata
Assert-True ($wjson.Contains('"watch": [') -and -not (ConvertTo-FujiMacroJson -Data $norm.Data).Contains('"watch"')) 'watch rules: written only when there are some'
Assert-Equal 2 (Get-FujiWatchRule -Macro (ConvertTo-FujiMacroData -Source (ConvertFrom-FujiJson -Json $wjson)).Data.macros[0]).Count 'watch rules: round trip'
$wcopy = Copy-FujiMacro -Macro $wdata.macros[0]
$wcopy.watch[0].title = 'changed'
Assert-Equal 'Timeout' $wdata.macros[0].watch[0].title 'watch rules: a copied macro has its own rules'
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
    Assert-True (@($choices | Where-Object { @($_).Count -ne 2 }).Count -eq 0) 'every placeholder choice is (token, description)'
    Assert-True (@($choices | Where-Object { $_[0] -eq ('{{$' + (Get-FujiText 'data.errorVar') + '}}') }).Count -eq 1) 'variable placeholder offered'
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

# ----------------------------------------------------------------- runner (fake Io: records what would be done)
$script:Fake = $null
function New-FakeIo {
    $script:Fake = @{
        Calls = (New-Object -TypeName 'System.Collections.Generic.List[string]'); Logs = (New-Object -TypeName 'System.Collections.Generic.List[string]')
        Windows = @('App'); Files = @(); Self = $false; Clipboard = ''; CopySource = ''; Answers = (New-Object -TypeName 'System.Collections.Generic.Queue[object]')
        Waits = 0; StopAtWait = -1; ExcelValue = 'cell'; WaitAt = (New-Object -TypeName 'System.Collections.Generic.List[string]'); PauseAfterClip = $false; ClipSeq = 0; CopyLate = 0; PauseAfterCopy = $false; Elevated = @()
        FieldMode = 'SET'; FieldFails = 0; FieldValue = 'v1'; Table = @{ Header = @('h1', 'h2'); Rows = @(@('a', '=1+1'), @('b', 'c')) }
        Saved = @{}; Secrets = @{}; Breaks = (New-Object -TypeName 'System.Collections.Generic.List[string]'); Front = @{ Title = 'Login - App'; Program = 'C:\App\app.exe' }; PasswordFocus = $true; FileFails = $false
    }
    return @{
        Log = { param($Message, $Level) $script:Fake.Logs.Add($Level + ' ' + $Message) }
        Wait = { param($Ms) $script:Fake.WaitAt.Add(('{0}:{1}' -f $script:Fake.Calls.Count, $Ms)); if ($script:Fake.PauseAfterClip -and $script:Fake.Calls.Count -gt 0 -and $script:Fake.Calls[$script:Fake.Calls.Count - 1].StartsWith('CLIP')) { $script:Fake.PauseAfterClip = $false; $script:Fake.Clipboard = 'copied while paused'; return $true }; if ($script:Fake.PauseAfterCopy -and $script:Fake.Calls.Count -gt 0 -and $script:Fake.Calls[$script:Fake.Calls.Count - 1] -eq 'KEYS ^c') { $script:Fake.PauseAfterCopy = $false; $script:Fake.Clipboard = 'copied while paused'; $script:Fake.ClipSeq++; return $true }; $script:Fake.Waits++; if ($script:Fake.Waits -eq $script:Fake.StopAtWait) { throw (New-Object -TypeName System.OperationCanceledException -ArgumentList 'test stop') } }
        Activate = { param($Title) $script:Fake.Calls.Add('ACT ' + $Title); return ($script:Fake.Windows -contains $Title) }
        WindowExists = { param($Title) return ($script:Fake.Windows -contains $Title) }
        SelfHasFocus = { return $script:Fake.Self }
        InputBlocked = { param($Title) return ($script:Fake.Elevated -contains $Title) }
        FocusSelf = { $script:Fake.Calls.Add('SELF') }
        SendKeys = { param($Keys) $script:Fake.Calls.Add('KEYS ' + $Keys); if ($Keys -eq '^c' -and $script:Fake.CopySource -ne '') { $script:Fake.Clipboard = $script:Fake.CopySource; $script:Fake.ClipSeq++ } }
        SetClipboard = { param($Text) $script:Fake.Clipboard = $Text; $script:Fake.ClipSeq++; if ($Text -ne '') { $script:Fake.Calls.Add('CLIP ' + $Text) }; return $true }
        GetClipboard = { return $script:Fake.Clipboard }
        ClipboardSeq = { return $script:Fake.ClipSeq }
        ClipboardReady = { param($Seq) if ($script:Fake.ClipSeq -eq $Seq) { return $false }; if ($script:Fake.CopyLate -gt 0) { $script:Fake.CopyLate--; return $false }; return $true }
        Start = { param($CommandLine) $script:Fake.Calls.Add('START ' + $CommandLine); return '' }
        ClickAt = { param($X, $Y, $Kind) $script:Fake.Calls.Add(('CLICK {0},{1} {2}' -f $X, $Y, $Kind)) }
        Screenshot = { param($Path, $Full) $script:Fake.Calls.Add('SHOT ' + $Path + ' ' + $Full); return '10x10' }
        ClickName = { param($Name) $script:Fake.Calls.Add('NAME ' + $Name); return 'Invoke' }
        ClickImage = { param($Path) $script:Fake.Calls.Add('IMG ' + $Path); return @{ X = 5; Y = 6; Score = 0.95 } }
        Ocr = { param($Settings, $Find) $null = $Settings; $script:Fake.Calls.Add('OCR ' + $Find); return "read`n" }
        Excel = { param($Request) $script:Fake.Calls.Add(('EXCEL {0} {1} {2}' -f $Request.Write, $Request.Cell, $Request.Value)); return $script:Fake.ExcelValue }
        Outlook = { param($Mail) $script:Fake.Calls.Add('OUTLOOK ' + $Mail.Mode + ' ' + $Mail.To); return $Mail.Mode }
        OpenUrl = { param($Url) $script:Fake.Calls.Add('URL ' + $Url) }
        FileExists = { param($Path) return ($script:Fake.Files -contains $Path) }
        Now = { return [datetime]'2026-10-09 14:05:12' }
        Confirm = { param($Caption, $Message) $null = $Caption; $script:Fake.Calls.Add('CONFIRM ' + $Message); return $script:Fake.Answers.Dequeue() }
        Ask = { param($Caption, $Message) $null = $Caption; $script:Fake.Calls.Add('ASK ' + $Message); return $script:Fake.Answers.Dequeue() }
        Progress = { }
        Highlight = { }
        Watch = { }
        Alarm = { $script:Fake.Calls.Add('ALARM') }
        Notify = { $script:Fake.Calls.Add('NOTIFY') }
        EndRun = { $script:Fake.Calls.Add('END') }
        Break = { param($Message) $script:Fake.Breaks.Add($Message); $script:Fake.Calls.Add('BREAK'); return $script:Fake.Answers.Dequeue() }
        SetField = { param($Request)
            $script:Fake.Calls.Add(('FIELD {0}#{1}={2} {3}' -f $Request.Name, $Request.Nth, $Request.Text, $Request.Mode))
            if ($script:Fake.FieldFails -gt 0) { $script:Fake.FieldFails--; throw 'field not found' }
            return $script:Fake.FieldMode }
        GetField = { param($Request) $script:Fake.Calls.Add(('GETFIELD {0}#{1}' -f $Request.Name, $Request.Nth)); return ($script:Fake.FieldValue + "`r`n") }
        ReadTable = { param($Request) $script:Fake.Calls.Add('TABLE ' + $Request.Name); return $script:Fake.Table }
        SaveText = { param($Path, $Text) $script:Fake.Saved[$Path] = $Text }
        GetSecret = { param($Target) if ($script:Fake.Secrets.ContainsKey($Target)) { return $script:Fake.Secrets[$Target] }; return $null }
        TypeSecret = { param($Text) $script:Fake.Calls.Add('SECRET ' + $Text.Length) }
        ForegroundWindow = { return $script:Fake.Front }
        FocusIsPassword = { return $script:Fake.PasswordFocus }
        FileOp = { param($Request)
            $script:Fake.Calls.Add(('FILE {0} {1} > {2} {3}' -f $Request.Op, $Request.Source, $Request.Dest, $Request.Overwrite))
            if ($script:Fake.FileFails) { throw 'locked' }
            # as the real one: the list as one object
            if ($Request.Source.Contains('*')) { return , @(@{ From = 'D\in\a.pdf'; To = 'D\out\a.pdf' }, @{ From = 'D\in\b.pdf'; To = 'D\out\b.pdf' }) }
            return , @(@{ From = $Request.Source; To = $Request.Dest }) }
    }
}

# Steps: @(cmd, val[, props]); Rows: string arrays (none = test run without CSV)
function New-TestRun {
    param([object[]]$Steps, [object[]]$Rows = @(), [string]$Target = 'App', [object[]]$Other = @(), [string[]]$Header = $null)
    # @(@('KEY', 'a')) arrives as @('KEY', 'a'): one step
    if ($Steps.Count -gt 0 -and $Steps[0] -is [string]) { $Steps = @(, $Steps) }
    $io = New-FakeIo
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $Steps) {
        $step = [ordered]@{ cmd = $s[0]; val = [string]$s[1]; label = '' }
        if ($s.Count -gt 2) { foreach ($k in $s[2].Keys) { $step[$k] = $s[2][$k] } }
        $list.Add($step)
    }
    $macros = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $macro = [ordered]@{ id = 'main'; name = 'main'; targetWindow = $Target; steps = $list }
    $macros.Add($macro)
    foreach ($o in $Other) { $macros.Add($o) }
    $rows = (Get-FujiRunRow -CsvRows $Rows -Header $Header).Rows
    return (New-FujiRun -Macro $macro -Macros $macros -Rows $rows -Header $Header -Io $io -Interval 0 -Directory 'D')
}
function Get-FakeCall { param([string]$Prefix) return (@($script:Fake.Calls | Where-Object { $_.StartsWith($Prefix) }) -join ' | ') }

$J = { param($o) ConvertTo-FujiJson -InputObject $o -Indent 0 }

# rows, paste, keys, placeholders
$run = New-TestRun -Steps @(@('CSV', '1'), @('KEY', '{TAB}'), @('TEXT', '{{2}}-{{ROW}}'), @('KEY', '{SPACE 2}'), @('CSV', '5')) -Rows @(, [string[]]@('a', 'b'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: done'
Assert-Equal 'CLIP a | KEYS ^v | KEYS {TAB} | CLIP b-1 | KEYS ^v | KEYS   ' ((@($script:Fake.Calls | Where-Object { $_ -match '^(CLIP|KEYS)' })) -join ' | ') 'run: paste, keys, placeholders, {SPACE n}, empty CSV cell not pasted'
# a paste right after the clipboard changes is sometimes dropped by the target (Notepad: 5 of 140 on
# a city hall PC, none of 140 with 150 ms in between): Ctrl+V only after the clipboard has settled
$clipAt = $script:Fake.Calls.IndexOf('CLIP a')
$settled = @($script:Fake.WaitAt | Where-Object { $_ -match ('^' + ($clipAt + 1) + ':(\d+)$') -and [int]$Matches[1] -ge $script:FujiRunLimits.ClipboardSettleMs })
Assert-True ($clipAt -ge 0 -and $script:FujiRunLimits.ClipboardSettleMs -ge 150 -and $settled.Count -eq 1 -and $script:Fake.Calls[$clipAt + 1] -eq 'KEYS ^v') 'run: Ctrl+V waits for the clipboard to settle'
Assert-True ($script:Fake.Calls[0] -eq 'ACT App' -and $script:Fake.Calls[$script:Fake.Calls.Count - 1] -eq 'END' -and $script:Fake.Calls.Contains('NOTIFY')) 'run: target activated first, end and finish sound'
Assert-True ($run.DoneRows -eq 1 -and $run.ResultRows[0].Status -eq (Get-FujiText 'run.resultDone')) 'run: row result'
Assert-True (@($script:Fake.Logs | Where-Object { $_ -like ('warn*' + (Get-FujiText 'run.csvMissingCol' 5 2)) }).Count -eq 1) 'run: missing CSV column warned'
$run = New-TestRun -Steps @(, @('CSV', '1')) -Rows @(, [string[]]@('a'))
$script:Fake.PauseAfterClip = $true
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: paused while the clipboard settles'
Assert-Equal 'CLIP a | CLIP a | KEYS ^v' ((@($script:Fake.Calls | Where-Object { $_ -match '^(CLIP|KEYS)' })) -join ' | ') 'run: after a pause the clipboard is written again before Ctrl+V'

# first / last row groups, disabled block
$run = New-TestRun -Steps @(@('GROUP_START', 'g1', @{ when = 'first' }), @('KEY', 'a'), @('GROUP_END', ''), @('KEY', 'b'), @('GROUP_START', 'g2', @{ when = 'last' }), @('KEY', 'c'), @('GROUP_END', ''),
    @('GROUP_START', 'off', @{ disabled = $true }), @('KEY', 'z'), @('GROUP_END', '')) -Rows @([string[]]@('1'), [string[]]@('2'), [string[]]@('3'))
[void](Invoke-FujiRun -Run $run)
Assert-Equal 'KEYS a | KEYS b | KEYS b | KEYS b | KEYS c' (Get-FakeCall 'KEYS') 'run: first-row group, last-row group, disabled group'
Assert-Equal 3 $run.DoneRows 'run: three rows done'

# loops, BREAK, CONTINUE, IF / ELSE
$run = New-TestRun -Target '' -Steps @(@('LOOP_START', '{"mode":"COUNT","count":"4","counter":"i"}'),
    @('IF_START', '{"left":"{{$i}}","op":"EQ","right":"2"}'), @('CONTINUE', ''), @('IF_END', ''),
    @('IF_START', '{"left":"{{$i}}","op":"GE","right":"4"}'), @('BREAK', ''), @('ELSE', ''), @('KEY', '{{$i}}'), @('IF_END', ''),
    @('LOOP_END', ''), @('KEY', 'end'))
[void](Invoke-FujiRun -Run $run)
Assert-Equal 'KEYS {{$i}} | KEYS {{$i}} | KEYS end' (Get-FakeCall 'KEYS') 'run: KEY values are sent as typed (no placeholders in KEY)'
Assert-Equal '4' $run.Vars['i'] 'run: loop counter at BREAK (no row: test run, no target)'
$run = New-TestRun -Steps @(@('LOOP_START', '{"mode":"COUNT","count":"3"}'), @('SET_VAR', '{"name":"s","value":"{{$s}}x","mode":"TEXT"}'), @('LOOP_END', ''))
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['s'] -eq 'xxx' -and $run.Vars[(Get-FujiCommandDef 'LOOP_START')['parseDefaults']['counter']] -eq '3') 'run: loop count, default counter variable'
$run = New-TestRun -Steps @(@('LOOP_START', '{"mode":"WHILE","left":"a","op":"EQ","right":"a","max":"5"}'), @('LOOP_END', ''))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: endless loop stopped at its limit'
Assert-True ($run.Summary -ne '' -and $script:Fake.Calls.Contains('ALARM')) 'run: error rings the alarm'

# try / catch, error variable, uncaught error, error rows
$run = New-TestRun -Steps @(@('TRY_START', 't'), @('SWITCH', 'Missing'), @('KEY', 'never'), @('CATCH', ''), @('SET_VAR', ('{"name":"e","value":"{{$' + (Get-FujiText 'data.errorVar') + '}}","mode":"TEXT"}')), @('TRY_END', ''), @('KEY', 'after')) -Rows @(, [string[]]@('x'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: caught error does not stop'
Assert-Equal 'KEYS after' (Get-FakeCall 'KEYS') 'run: CATCH section, then after the block'
Assert-Equal ((Get-FujiText 'run.switchNotFound' 'Missing') -replace '^\S+\s', '') $run.Vars['e'] 'run: error text in the error variable (without the mark)'
Assert-True ($run.ResultRows[0].Note.Contains('Missing') -and $run.ErrorRows.Count -eq 0) 'run: caught error noted, no error row'
$run = New-TestRun -Steps @(@('KEY', 'a'), @('SWITCH', 'Missing'), @('KEY', 'b')) -Rows @([string[]]@('x', 'y'), [string[]]@('z', 'w'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: uncaught error stops'
Assert-True ((Get-FakeCall 'KEYS') -eq 'KEYS a' -and $run.ErrorRows.Count -eq 1 -and $run.ResultRows.Count -eq 1 -and $run.ResultRows[0].Status -eq (Get-FujiText 'run.resultError')) 'run: error row and result recorded'
Assert-Equal 3 @($script:Fake.Calls | Where-Object { $_ -eq 'ACT Missing' }).Count 'run: window searched three times'
$csv = ConvertFrom-FujiCsv -Text (ConvertTo-FujiErrorCsv -Run $run)
Assert-Equal (& $J @((Get-FujiText 'run.colPrefix' 1), (Get-FujiText 'run.colPrefix' 2), (Get-FujiText 'run.colOrigNo'), (Get-FujiText 'run.colError'), (Get-FujiText 'run.colTime'))) (& $J $csv.Records[0]) 'error CSV header without a CSV header'
Assert-True ($csv.Records[1][0] -eq 'x' -and $csv.Records[1][2] -eq '1') 'error CSV row'
$rerun = Get-FujiRunRow -CsvRows @(, [string[]]@($csv.Records[1])) -Header ([string[]]$csv.Records[0])
Assert-True ($rerun.Rows[0].No -eq 1 -and $rerun.Logs.Count -eq 1) 'error CSV re-run keeps the original row number'
$res = ConvertFrom-FujiCsv -Text (ConvertTo-FujiResultCsv -Run $run)
Assert-Equal (& $J @((Get-FujiText 'run.colPrefix' 1), (Get-FujiText 'run.colPrefix' 2), (Get-FujiText 'run.errorShotColumn'), (Get-FujiText 'run.colResult'), (Get-FujiText 'run.colNote'), (Get-FujiText 'run.colOrigNo'), (Get-FujiText 'run.colStart'))) (& $J $res.Records[0]) 'result CSV header'
Assert-True ((Get-FakeCall 'SHOT') -eq ('SHOT ' + (Join-Path (Join-Path (Join-Path 'D' 'evidence') '20261009') ((Get-FujiText 'run.errorShotName' 1) + '_140512.png')) + ' True') -and $res.Records[1][2].EndsWith('_140512.png')) 'run: the screen saved when a run stops with an error'
$catchErr = New-TestRun -Steps @(@('TRY_START', 't'), @('KEY', 'a'), @('CATCH', ''), @('SWITCH', 'Missing'), @('TRY_END', ''))
$script:Fake.Windows = @('App')
Assert-Equal 'done' (Invoke-FujiRun -Run $catchErr) 'run: CATCH section skipped without an error'
$run = New-TestRun -Steps @(@('TRY_START', 't'), @('SWITCH', 'Missing'), @('CATCH', ''), @('SWITCH', 'Missing2'), @('TRY_END', ''))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: an error inside CATCH goes outward'

# window check: skip the row, last row still runs "last row only" groups; stop is not caught
$run = New-TestRun -Steps @(@('WINDOW_CHECK', '{"title":"Popup","key":"{ENTER}","mode":"SKIP"}'), @('KEY', 'a'), @('GROUP_START', 'save', @{ when = 'last' }), @('KEY', 'save'), @('GROUP_END', '')) -Rows @([string[]]@('1'), [string[]]@('2'))
$script:Fake.Windows = @('App', 'Popup')
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: skipped rows finish the run'
Assert-Equal 'KEYS {ENTER} | KEYS {ENTER} | KEYS save' (Get-FakeCall 'KEYS') 'run: skipped last row still saves'
Assert-True ($run.SkippedRows -eq 2 -and $run.ErrorRows.Count -eq 2 -and $run.DoneRows -eq 0) 'run: skipped rows counted and recorded'
$run = New-TestRun -Steps @(@('TRY_START', 't'), @('WINDOW_CHECK', '{"title":"Popup","key":"","mode":"STOP"}'), @('CATCH', ''), @('TRY_END', ''))
$script:Fake.Windows = @('App', 'Popup')
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: emergency stop is never caught'
$run = New-TestRun -Steps @(@('WAIT_FOR', '{"title":"Later","key":"","timeout":"3"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: wait-for timeout'
Assert-Equal 3 @($script:Fake.Calls | Where-Object { $_ -eq 'ACT Later' }).Count 'run: wait-for polls once a second'

# called macros, RETURN, unbalanced or missing macro
$sub = [ordered]@{ id = 'sub'; name = 'Sub'; targetWindow = ''; steps = [System.Collections.Generic.List[object]]@(
        [ordered]@{ cmd = 'KEY'; val = 'b1'; label = '' }, [ordered]@{ cmd = 'RETURN'; val = ''; label = '' }, [ordered]@{ cmd = 'KEY'; val = 'b2'; label = '' }) }
$run = New-TestRun -Steps @(@('CALL_MACRO', '{"id":"sub","name":"Sub"}'), @('KEY', 'after')) -Other @($sub)
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: call'
Assert-Equal 'KEYS b1 | KEYS after' (Get-FakeCall 'KEYS') 'run: called macro, RETURN, back to the caller'
$run = New-TestRun -Steps @(@('CALL_MACRO', '{"id":"none","name":"None"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: missing macro'
$self = [ordered]@{ id = 'loop'; name = 'Loop'; targetWindow = ''; steps = [System.Collections.Generic.List[object]]@([ordered]@{ cmd = 'CALL_MACRO'; val = '{"id":"loop","name":"Loop"}'; label = '' }) }
$run = New-TestRun -Steps @(@('CALL_MACRO', '{"id":"loop","name":"Loop"}')) -Other @($self)
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: endless calls stopped'
Assert-True ($script:Fake.Logs[$script:Fake.Logs.Count - 2].Contains([string]$script:FujiRunLimits.CallDepthMax)) 'run: call depth message'

# confirm / ask: continue, skip, stop
$run = New-TestRun -Steps @(@('CONFIRM', 'ok?'), @('KEY', 'a')) -Rows @([string[]]@('1'), [string[]]@('2'))
$script:Fake.Answers.Enqueue('skip'); $script:Fake.Answers.Enqueue('continue')
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: confirm'
Assert-True ((Get-FakeCall 'KEYS') -eq 'KEYS a' -and $run.SkippedRows -eq 1 -and $run.ResultRows[0].Note -eq (Get-FujiText 'run.confirmSkipNote')) 'run: confirm skip, then continue'
$run = New-TestRun -Steps @(@('ASK', '{"name":"v","message":"name?","defaultValue":"{{1}}"}'), @('TEXT', '{{$v}}'), @('CONFIRM', 'stop?')) -Rows @(, [string[]]@('d'))
$script:Fake.Answers.Enqueue(@{ Choice = 'continue'; Value = 'typed' }); $script:Fake.Answers.Enqueue('stop')
Assert-Equal 'stopped' (Invoke-FujiRun -Run $run) 'run: stop from a dialog'
Assert-True ($run.Vars['v'] -eq 'typed' -and (Get-FakeCall 'CLIP') -eq 'CLIP typed' -and $run.ResultRows[0].Status -eq (Get-FujiText 'run.resultStopped')) 'run: asked value used, row marked stopped'
$run = New-TestRun -Steps @(@('KEY', 'a'), @('KEY', 'b')) -Rows @([string[]]@('1'), [string[]]@('2'))
$script:Fake.StopAtWait = 3
Assert-Equal 'stopped' (Invoke-FujiRun -Run $run) 'run: stop during a wait'
Assert-True ($script:Fake.Calls[$script:Fake.Calls.Count - 1] -eq 'END' -and -not $script:Fake.Calls.Contains('NOTIFY')) 'run: stopped run ends without the finish sound'

# RUN refuses inserted values that mean something on a command line
$run = New-TestRun -Steps @(@('RUN', 'notepad.exe {{1}}')) -Rows @([string[]]@('a&b'), [string[]]@('ok.txt'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: unsafe RUN skips the row only'
Assert-True ((Get-FakeCall 'START') -eq 'START notepad.exe ok.txt' -and $run.ErrorRows.Count -eq 1 -and $run.SkippedRows -eq 1) 'run: unsafe row recorded, safe row started'
Assert-Equal (Get-FujiText 'run.runUnsafe' ('{{1}}=' + [char]0x300C + 'a&b' + [char]0x300D)) $run.ErrorRows[0].Reason 'run: cmd refusal keeps the cmd message'
$run = New-TestRun -Steps @(@('RUN', "powershell -Command `"Get-Item '{{1}}'`"")) -Rows @([string[]]@("x'; Stop-Computer; '"), [string[]]@('C:\a b.txt'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: PowerShell RUN with a quote in the value'
Assert-True ((Get-FakeCall 'START') -eq "START powershell -Command `"Get-Item 'C:\a b.txt'`"" -and $run.ErrorRows.Count -eq 1) 'run: PowerShell injection row recorded, safe row started'
Assert-Equal (Get-FujiText 'run.runUnsafePs' ('{{1}}=' + [char]0x300C + "x'; Stop-Computer; '" + [char]0x300D)) $run.ErrorRows[0].Reason 'run: PowerShell refusal tells how to rename the file'
$run = New-TestRun -Steps @(@('RUN', "{{1}} -Command `"Get-Item '{{2}}'`"")) -Rows @([string[]]@('powershell', "x'; Stop-Computer; '"), [string[]]@('powershell', 'C:\a.txt'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: PowerShell named by a value'
Assert-True ((Get-FakeCall 'START') -eq "START powershell -Command `"Get-Item 'C:\a.txt'`"" -and $run.ErrorRows.Count -eq 1) 'run: PowerShell named by a value is checked strictly'

# variables: calculation, string operations, copy, record, Excel
$run = New-TestRun -Steps @(@('SET_VAR', '{"name":"n","value":"{{1}}*2","mode":"CALC"}'), @('STR_OP', '{"name":"t","src":"  {{2}} ","op":"TRIM","a":"","b":""}'),
    @('COPY', 'c'), @('RECORD', '{"name":"r","value":"{{$n}}/{{$t}}"}'), @('EXCEL_READ', '{"path":"b.xlsx","sheet":"","cell":"A1","name":"x"}'),
    @('EXCEL_WRITE', '{"path":"b.xlsx","sheet":"","cell":"B{{ROW}}","value":"{{$x}}"}')) -Rows @(, [string[]]@('21', 'ab'))
$null = $script:Fake
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['n'] -eq '42' -and $run.Vars['t'] -eq 'ab' -and $run.Vars['x'] -eq 'cell') 'run: calc, trim, Excel read'
Assert-True ((Get-FakeCall 'EXCEL True') -eq 'EXCEL True B1 cell' -and $run.ResultRows[0].Values['r'] -eq '42/ab') 'run: Excel write with placeholders, recorded value'
$run = New-TestRun -Steps @(@('COPY', 'c'))
$script:Fake.CopySource = "copied`r`n"
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['c'] -eq 'copied' -and $run.ResultColumns.Contains('c')) 'run: copy to a variable (trailing line break dropped)'
Assert-Equal 0 @($script:Fake.WaitAt | Where-Object { $_ -eq '2:20' }).Count 'run: copy read at once when the text is there'
$run = New-TestRun -Steps @(@('COPY', 'c'))
$script:Fake.CopySource = 'late'
$script:Fake.CopyLate = 3
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['c'] -eq 'late' -and @($script:Fake.WaitAt | Where-Object { $_ -eq '2:20' }).Count -eq 3) 'run: copy waits in short steps until the text is there'
$run = New-TestRun -Steps @(@('COPY', 'c'))
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['c'] -eq '' -and @($script:Fake.WaitAt | Where-Object { $_ -eq '2:20' }).Count -eq 150 -and @($script:Fake.Logs | Where-Object { $_.StartsWith('warn') }).Count -eq 1) 'run: nothing copied: empty after the limit, warned'
$run = New-TestRun -Steps @(@('COPY', 'c'))
$script:Fake.CopySource = 'right'
$script:Fake.CopyLate = 1
$script:Fake.PauseAfterCopy = $true
[void](Invoke-FujiRun -Run $run)
Assert-True ($run.Vars['c'] -eq 'right' -and @($script:Fake.Calls | Where-Object { $_ -eq 'KEYS ^c' }).Count -eq 2) 'run: paused while waiting for a copy: copied again'
$run = New-TestRun -Steps @(@('SET_VAR', '{"name":"n","value":"1/0","mode":"CALC"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: calculation error stops'

# a program run as administrator gets none of the input: stop
$run = New-TestRun -Steps @(@('KEY', 'a'))
$script:Fake.Elevated = @('App')
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: target run as administrator: stop'
Assert-True ((Get-FakeCall 'KEYS') -eq '' -and @($script:Fake.Logs | Where-Object { $_.Contains((Get-FujiText 'run.targetElevated' 'App')) }).Count -eq 1) 'run: target run as administrator: nothing typed, told why'
$run = New-TestRun -Target '' -Steps @(@('WAIT_FOR', '{"title":"Admin","key":"{ENTER}","timeout":"5"}'))
$script:Fake.Windows = @('Admin')
$script:Fake.Elevated = @('Admin')
Assert-True ((Invoke-FujiRun -Run $run) -eq 'error' -and (Get-FakeCall 'KEYS') -eq '') 'run: wait for a window run as administrator: no key, stop'
$run = New-TestRun -Target '' -Steps @(@('WINDOW_CHECK', '{"title":"Admin","key":"","mode":"CONTINUE"}'))
$script:Fake.Windows = @('Admin')
$script:Fake.Elevated = @('Admin')
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'run: window check without a key: a window run as administrator is fine'

# keystrokes never land in this app
$run = New-TestRun -Target '' -Steps @(@('KEY', 'a'))
$script:Fake.Self = $true
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: no target and this app in front: stop'
Assert-Equal '' (Get-FakeCall 'KEYS') 'run: no key sent to this app'
$run = New-TestRun -Steps @(@('KEY', 'a'))
$script:Fake.Self = $true
[void](Invoke-FujiRun -Run $run)
Assert-True ((Get-FakeCall 'KEYS') -eq 'KEYS a' -and @($script:Fake.Calls | Where-Object { $_ -eq 'ACT App' }).Count -eq 2) 'run: target brought back before the key'

# mail, screenshot, clicks
$run = New-TestRun -Steps @(@('MAIL', ('{"method":"MAILTO","mode":"DRAFT","to":"a@x.jp, b@x.jp","cc":"","subject":"Subj {{1}}","body":"L1' + "\n" + '2","attach":""}'))) -Rows @(, [string[]]@('7'))
[void](Invoke-FujiRun -Run $run)
Assert-Equal ('URL mailto:a@x.jp,b@x.jp?subject=' + [uri]::EscapeDataString('Subj 7') + '&body=' + [uri]::EscapeDataString("L1`r`n2")) (Get-FakeCall 'URL') 'run: mailto URL'
$run = New-TestRun -Steps @(@('MAIL', '{"method":"OUTLOOK","mode":"SEND","to":"a@x.jp","cc":"","subject":"s","body":"b","attach":"C:\\no.pdf"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: missing attachment stops before mailing'
$run = New-TestRun -Steps @(@('MAIL', ('{"method":"OUTLOOK","mode":"SEND","to":"a@x.jp' + [char]0xFF1B + 'b@x.jp","cc":"","subject":"s","body":"b","attach":"C:\\a.pdf"}')))
$script:Fake.Files = @('C:\a.pdf')
[void](Invoke-FujiRun -Run $run)
Assert-True ((Get-FakeCall 'OUTLOOK') -eq 'OUTLOOK SEND a@x.jp; b@x.jp' -and $run.ResultRows[0].Values[(Get-FujiText 'run.mailColumn')] -eq (Get-FujiText 'run.mailSentValue')) 'run: Outlook send, full-width separator'
$run = New-TestRun -Steps @(@('MAIL', '{"method":"SMTP","mode":"SEND","to":"a@x.jp","cc":"","subject":"s","body":"b","attach":""}'))
Assert-True ((Invoke-FujiRun -Run $run) -eq 'error' -and (Get-FakeCall 'OUTLOOK') -eq '') 'run: SMTP (dropped) stops the row, not sent through Outlook'
$run = New-TestRun -Steps @(@('SCREENSHOT', '{"name":"Recv{{1}}","scope":"FULL"}'), @('CLICK_POS', ('{"x":"10","y":"' + [char]0xFF12 + [char]0xFF10 + '","kind":"DOUBLE"}')), @('CLICK_NAME', 'Save'),
    @('READ_TEXT', '{"area":"FULL","x":"","y":"","w":"","h":"","name":"o"}'), @('CLICK_TEXT', '{"text":"OK","area":"WINDOW","x":"","y":"","w":"","h":"","nth":"2"}')) -Rows @(, [string[]]@('/1'))
[void](Invoke-FujiRun -Run $run)
Assert-Equal ('SHOT ' + (Join-Path (Join-Path (Join-Path 'D' 'evidence') '20261009') ('Recv_1_140512.png')) + ' True') (Get-FakeCall 'SHOT') 'run: evidence path (unsafe characters replaced)'
Assert-True ((Get-FakeCall 'CLICK') -eq 'CLICK 10,20 DOUBLE' -and (Get-FakeCall 'NAME') -eq 'NAME Save' -and $run.Vars['o'] -eq 'read' -and (Get-FakeCall 'OCR') -eq 'OCR  | OCR OK') 'run: clicks and OCR'
$run = New-TestRun -Steps @(@('CLICK_IMG', '{"path":"none.png","threshold":"0.9"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'run: missing reference image'

# Excel: a formula only when typed in the step; inserted text never becomes one
$run = New-TestRun -Steps @(@('EXCEL_WRITE', '{"path":"b.xlsx","sheet":"","cell":"A1","value":"{{1}}"}'), @('EXCEL_WRITE', '{"path":"b.xlsx","sheet":"","cell":"A2","value":"=SUM(B1:B2)"}'), @('EXCEL_WRITE', '{"path":"b.xlsx","sheet":"","cell":"A3","value":"{{2}}"}')) -Rows @(, [string[]]@('=cmd|x', '-12'))
[void](Invoke-FujiRun -Run $run)
Assert-Equal "EXCEL True A1 '=cmd|x | EXCEL True A2 =SUM(B1:B2) | EXCEL True A3 -12" (Get-FakeCall 'EXCEL') 'Excel write: inserted formula as text, typed formula kept, number kept'
# files: copy, move, rename (the Io does the work; paths not starting at a drive are in the app folder)
$run = New-TestRun -Steps @(@('FILE_OP', '{"op":"COPY","src":"C:\\in\\{{1}}.pdf","dest":"out\\","overwrite":"NO","var":"p"}'), @('FILE_OP', '{"op":"RENAME","src":"C:\\in\\{{1}}.pdf","dest":"done_{{1}}.pdf","overwrite":"YES","var":""}'),
    @('FILE_OP', '{"op":"MOVE","src":"C:\\in\\*.pdf","dest":"C:\\out","overwrite":"NO","var":"all"}')) -Rows @(, [string[]]@('r1'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'file op: run'
Assert-Equal ('FILE COPY C:\in\r1.pdf > ' + (Join-Path 'D' 'out\') + ' False | FILE RENAME C:\in\r1.pdf > done_r1.pdf True | FILE MOVE C:\in\*.pdf > C:\out False') (Get-FakeCall 'FILE') 'file op: requests (relative destination in the app folder, rename keeps the name only)'
Assert-True ($run.Vars['p'] -eq (Join-Path 'D' 'out\') -and $run.Vars['all'] -eq 'D\out\a.pdf;D\out\b.pdf') 'file op: destination paths into the variable (several joined by ;)'
$run = New-TestRun -Steps @(, @('FILE_OP', '{"op":"RENAME","src":"C:\\in\\a.pdf","dest":"{{1}}","overwrite":"NO","var":""}')) -Rows @(, [string[]]@('..\x.pdf'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'file op: an inserted new name cannot move the file to another folder'
Assert-Equal '' (Get-FakeCall 'FILE') 'file op: nothing done for a bad new name'
$run = New-TestRun -Steps @(, @('FILE_OP', '{"op":"COPY","src":"C:\\in\\a;b.pdf","dest":"C:\\out\\a;b.pdf","overwrite":"NO","var":"p"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'file op: a name with ; is not put into the list variable'
Assert-True (-not $run.Vars.Contains('p')) 'file op: variable left unset for a name with ;'
$run = New-TestRun -Steps @(, @('FILE_OP', '{"op":"COPY","src":"C:\\in\\a.pdf","dest":"C:\\out\\","overwrite":"NO","var":""}'))
$script:Fake.FileFails = $true
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'file op: a failure stops the run'
Assert-True (@($script:Fake.Logs | Where-Object { $_ -like ('error*' + (Get-FujiText 'run.fileFailed' (Get-FujiText 'label.fileOpCOPY') 'locked')) }).Count -eq 1) 'file op: failure logged with the reason'
Assert-Equal 'COPY' (ConvertFrom-FujiStepValue -Cmd 'FILE_OP' -Value '{"op":"zip"}')['op'] 'file op: unknown kind read as copy'
Assert-True ((Test-FujiStepSetting -Cmd 'FILE_OP' -Settings @{ op = 'RENAME'; src = 'C:\a\*.pdf'; dest = 'b.pdf'; overwrite = 'NO'; var = '' }) -eq (Get-FujiText 'validate.fileRenameWild')) 'file op: no wildcard when renaming'
Assert-True ((Test-FujiStepSetting -Cmd 'FILE_OP' -Settings @{ op = 'RENAME'; src = 'C:\a\x.pdf'; dest = 'sub\b.pdf'; overwrite = 'NO'; var = '' }) -eq (Get-FujiText 'validate.fileNewNameOnly')) 'file op: a new name only when renaming'
Assert-True ((Test-FujiStepSetting -Cmd 'FILE_OP' -Settings @{ op = 'MOVE'; src = 'C:\a\x.pdf'; dest = ''; overwrite = 'NO'; var = '' }) -eq (Get-FujiText 'validate.fileDest')) 'file op: destination needed'
Assert-Equal '' (Test-FujiStepSetting -Cmd 'FILE_OP' -Settings @{ op = 'COPY'; src = 'C:\a\x.pdf'; dest = 'C:\b\'; overwrite = 'NO'; var = '' }) 'file op: settings fine'

# files for real: everything is checked before any file moves
$fw = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_fileop_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $fw 'in'))
try {
    foreach ($n in @('a.pdf', 'b.PDF', 'c.pdfx', 'd.txt')) { Write-FujiTextFile -Path (Join-Path (Join-Path $fw 'in') $n) -Text $n }
    $r = Invoke-FujiFileOperation -Op 'COPY' -Source (Join-Path $fw 'in\*.pdf') -Dest (Join-Path $fw 'out\')
    Assert-Equal 'a.pdf,b.PDF' ((@($r | ForEach-Object { [System.IO.Path]::GetFileName($_.To) }) | Sort-Object) -join ',') 'file op: *.pdf matches .pdf of any case, not .pdfx'
    Assert-True ((Test-Path -LiteralPath (Join-Path $fw 'out\a.pdf')) -and (Test-Path -LiteralPath (Join-Path $fw 'in\a.pdf'))) 'file op: copy made the folder and kept the original'
    $msg = ''
    try { [void](Invoke-FujiFileOperation -Op 'MOVE' -Source (Join-Path $fw 'in\*.pdf') -Dest (Join-Path $fw 'out')) } catch { $msg = $_.Exception.Message }
    Assert-Equal (Get-FujiText 'run.fileExists' (Join-Path $fw 'out\a.pdf')) $msg 'file op: a file in the way stops the move'
    Assert-True ((Test-Path -LiteralPath (Join-Path $fw 'in\a.pdf')) -and (Test-Path -LiteralPath (Join-Path $fw 'in\b.PDF'))) 'file op: nothing moved when one target is in the way'
    Write-FujiTextFile -Path (Join-Path $fw 'in\a.pdf') -Text 'new'
    [void](Invoke-FujiFileOperation -Op 'MOVE' -Source (Join-Path $fw 'in\a.pdf') -Dest (Join-Path $fw 'out\a.pdf') -Overwrite $true)
    Assert-True ((Read-FujiUtf8File -Path (Join-Path $fw 'out\a.pdf')) -eq 'new' -and -not (Test-Path -LiteralPath (Join-Path $fw 'in\a.pdf'))) 'file op: move over a file when asked'
    $r = Invoke-FujiFileOperation -Op 'RENAME' -Source (Join-Path $fw 'in\d.txt') -Dest 'done_d.txt'
    Assert-True ((Test-Path -LiteralPath (Join-Path $fw 'in\done_d.txt')) -and $r[0].To -eq (Join-Path $fw 'in\done_d.txt')) 'file op: rename in the same folder'
    [void](Invoke-FujiFileOperation -Op 'RENAME' -Source (Join-Path $fw 'in\done_d.txt') -Dest 'DONE_d.txt')
    Assert-Equal 'DONE_d.txt' ([System.IO.Path]::GetFileName(@(Get-ChildItem -LiteralPath (Join-Path $fw 'in') -Filter '*_d.txt')[0].FullName)) 'file op: only the case of the name changed'
    foreach ($bad in @(@('COPY', (Join-Path $fw 'in\none.pdf'), (Join-Path $fw 'out\'), 'run.fileNotFound'), @('MOVE', (Join-Path $fw 'in\*.xls'), (Join-Path $fw 'out\'), 'run.fileNoMatch'),
            @('COPY', (Join-Path $fw 'in\c.pdfx'), (Join-Path $fw 'in\c.pdfx'), 'run.fileSame'), @('COPY', (Join-Path $fw 'in\c.pdfx'), (Join-Path $fw 'fujikyun_macros.json'), 'run.fileProtected'),
            @('COPY', (Join-Path $fw 'in\..\in\c.pdfx'), (Join-Path $fw 'out\'), 'run.fileDotDot'), @('MOVE', (Join-Path $fw 'in\c.pdfx'), (Join-Path $fw 'out\..\'), 'run.fileDotDot'),
            @('RENAME', (Join-Path $fw 'in\c.pdfx'), 'c.pdfx:s', 'validate.fileNewNameOnly'), @('RENAME', (Join-Path $fw 'in\c.pdfx'), '..', 'validate.fileNewNameOnly'))) {
        $msg = ''
        try { [void](Invoke-FujiFileOperation -Op $bad[0] -Source $bad[1] -Dest $bad[2] -AppDirectory $fw) } catch { $msg = $_.Exception.Message }
        $raw = Get-FujiText $bad[3]
        $head = $raw
        if ($raw.IndexOf('{') -ge 0) { $head = $raw.Substring(0, $raw.IndexOf('{')) }
        Assert-True ($msg -ne '' -and $msg.StartsWith($head)) ('file op refused: ' + $bad[3] + ' (' + $msg + ')')
    }
    # the app's own file by its 8.3 short name is the same file
    Write-FujiTextFile -Path (Join-Path $fw 'fujikyun_settings.json') -Text '{}'
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile((Join-Path $fw 'fujikyun_settings.json')).ShortPath
    Assert-True (Test-FujiAppFile -Path $short -AppDirectory $fw) ('file op: the app file by its short name is protected (' + $short + ')')
    $shortDir = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($fw).ShortPath
    Assert-True (Test-FujiAppFile -Path (Join-Path $shortDir 'fujikyun.ps1') -AppDirectory $fw) 'file op: the app folder by its short name'
} finally {
    Remove-Item -LiteralPath $fw -Recurse -Force -ErrorAction SilentlyContinue
}

$run = New-TestRun -Steps @(@('MAIL', '{"method":"MAILTO","mode":"DRAFT","to":"{{1}}","cc":"","subject":"s","body":"b","attach":""}')) -Rows @(, [string[]]@('a@x.jp?bcc=evil@y.jp'))
[void](Invoke-FujiRun -Run $run)
Assert-True ((Get-FakeCall 'URL').StartsWith('URL mailto:a@x.jp%3Fbcc%3Devil@y.jp?subject=')) 'mailto: an inserted address cannot add fields'

# output CSVs: values the app adds never start a formula; original columns stay as they were
$run = New-TestRun -Steps @(@('RECORD', '{"name":"v","value":"=HYPERLINK(1)"}'), @('RECORD', '{"name":"n","value":"-5"}')) -Rows @(, [string[]]@('=A1'))
[void](Invoke-FujiRun -Run $run)
$res = ConvertFrom-FujiCsv -Text (ConvertTo-FujiResultCsv -Run $run)
Assert-True ($res.Records[1][0] -eq '=A1' -and $res.Records[1][1] -eq "'=HYPERLINK(1)" -and $res.Records[1][2] -eq '-5') 'result CSV: recorded formula neutralised, number and original column kept'
foreach ($v in @('@x', '+x', "`tx", '-x')) { Assert-Equal ("'" + $v) (ConvertTo-FujiSafeCsvValue $v) ('safe CSV value ' + [int][char]$v[0]) }
Assert-Equal '+1.5' (ConvertTo-FujiSafeCsvValue '+1.5') 'safe CSV value: signed number kept'

# image matching (the compiled matcher) and OCR results
[void](Initialize-FujiImageMatch)
Assert-True (-not (Initialize-FujiImageMatch)) 'matcher compiled once'
$sw = 40; $sh = 30
$screen = New-Object -TypeName 'int[]' -ArgumentList ($sw * $sh)
for ($i = 0; $i -lt $screen.Length; $i++) { $screen[$i] = [int](0xFF000000 -bor (($i * 2654435761) -band 0xFFFFFF)) }
$tw = 6; $th = 5
$tpl = New-Object -TypeName 'int[]' -ArgumentList ($tw * $th)
for ($y = 0; $y -lt $th; $y++) { for ($x = 0; $x -lt $tw; $x++) { $tpl[$y * $tw + $x] = $screen[(12 + $y) * $sw + 21 + $x] } }
$hit = Find-FujiTemplate -Screen $screen -ScreenWidth $sw -ScreenHeight $sh -Template $tpl -TemplateWidth $tw -TemplateHeight $th -Threshold 0.9 -Left 100 -Top 200
Assert-True ($hit.X -eq 124 -and $hit.Y -eq 214 -and $hit.Score -eq 1.0) 'image match: exact place, centre, screen offset'
$tpl[0] = 0x00FFFFFF
$tpl[1] = [int](0xFF000000 -bor ((($tpl[1] -band 0xFFFFFF) -bxor 0x808080)))
$hit = Find-FujiTemplate -Screen $screen -ScreenWidth $sw -ScreenHeight $sh -Template $tpl -TemplateWidth $tw -TemplateHeight $th -Threshold 0.9
Assert-True ($hit.X -eq 24 -and $hit.Y -eq 14 -and [Math]::Abs($hit.Score - (28 / 29.0)) -lt 0.001) 'image match: transparent pixel ignored, one wrong pixel lowers the score'
Assert-True ($null -eq (Find-FujiTemplate -Screen $screen -ScreenWidth $sw -ScreenHeight $sh -Template $tpl -TemplateWidth $tw -TemplateHeight $th -Threshold 1.0)) 'image match: nothing at 100%'
$line1 = @{ Words = @(@{ Text = 'Save'; X = 0; Y = 0; W = 40; H = 10 }, @{ Text = 'all'; X = 50; Y = 0; W = 30; H = 10 }) }
$jp = -join ([char[]](0x767B, 0x9332))
$line2 = @{ Words = @(@{ Text = [string]$jp[0]; X = 10; Y = 40; W = 20; H = 20 }, @{ Text = [string]$jp[1]; X = 30; Y = 40; W = 20; H = 20 }, @{ Text = ([string][char]0xFF2F + [char]0xFF2B); X = 60; Y = 40; W = 20; H = 20 }) }
Assert-Equal ("Save all`r`n" + $jp + [char]0xFF2F + [char]0xFF2B) (ConvertTo-FujiOcrText -Lines @($line1, $line2)) 'OCR text: a space only where a word is ASCII on either side'
$p = Find-FujiOcrText -Lines @($line1, $line2) -Find $jp -OffsetX 100 -OffsetY 200 -Scale 2
Assert-True ($p.X -eq 115 -and $p.Y -eq 225) 'OCR find: text across words, back to screen pixels'
Assert-True ((Find-FujiOcrText -Lines @($line1, $line2) -Find 'OK').X -eq 70) 'OCR find: full-width letters match half-width (case kept)'
Assert-True ((Find-FujiOcrText -Lines @($line1, $line2) -Find 'eal').X -eq 40 -and $null -eq (Find-FujiOcrText -Lines @($line1, $line2) -Find 'Save' -Nth 2)) 'OCR find: spaces ignored, Nth place'
$scr = @{ X = 0; Y = 0; Width = 1920; Height = 1080 }
Assert-True ((Get-FujiOcrRect -Settings @{ area = 'RECT'; x = '1'; y = '2'; w = '3'; h = '4' } -Screen $scr).Height -eq 4 -and (Get-FujiOcrRect -Settings @{ area = 'WINDOW' } -Screen $scr).Width -eq 1920) 'OCR rect: given, or whole screen without a window'
Assert-Equal 2.0 (Get-FujiOcrScale -Width 300 -Height 100 -MaxDimension 2600) 'OCR scale: up to 2x'
Assert-Equal 1.3 (Get-FujiOcrScale -Width 2000 -Height 100 -MaxDimension 2600) 'OCR scale: within the engine limit'

# schedules
$sch = [ordered]@{ id = 's1'; time = '9:05'; repeat = 'WEEKDAYS'; enabled = $true; lastRun = '' }
$mon = [datetime]'2026-10-12 09:07:00'
Assert-True (Test-FujiScheduleDue $sch $mon) 'schedule: due on a weekday within 10 minutes'
Assert-True (-not (Test-FujiScheduleDue $sch $mon.AddMinutes(10)) -and -not (Test-FujiScheduleDue $sch $mon.AddMinutes(-3))) 'schedule: not before the time, not 10 minutes after'
Assert-True (-not (Test-FujiScheduleDue $sch ([datetime]'2026-10-11 09:07:00'))) 'schedule: weekdays only'
$sch.lastRun = '2026/10/12'
Assert-True (-not (Test-FujiScheduleDue $sch $mon)) 'schedule: once a day'
$next = Get-FujiNextSchedule -Schedules @($sch) -Now $mon
Assert-Equal '2026/10/13' (Format-FujiDate -Date $next.Day) 'schedule: next run tomorrow after today ran'
$sat = Get-FujiNextSchedule -Schedules @($sch) -Now ([datetime]'2026-10-10 12:00:00')
Assert-Equal '2026/10/12' (Format-FujiDate -Date $sat.Day) 'schedule: next weekday after a weekend'
$r = New-FujiSchedule -MacroId 'm' -MacroName 'n' -CsvPath ' "C:\a.csv" ' -Header $true -Time ([string][char]0xFF18 + [char]0xFF1A + '05') -Repeat 'ONCE' -DateText '2026-10-31' -CloseAfter $false
Assert-True ($r.Schedule.time -eq '08:05' -and $r.Schedule.date -eq '2026/10/31' -and $r.Schedule.csvPath -eq 'C:\a.csv') 'schedule: full-width time, date and path normalised'
Assert-True ((New-FujiSchedule -Time '25:00' -Repeat 'DAILY').ContainsKey('Error') -and (New-FujiSchedule -Time '8:00' -Repeat 'ONCE' -DateText 'x').ContainsKey('Error')) 'schedule: bad time or date refused'
$once = $r.Schedule
Assert-True ((Test-FujiScheduleDue $once ([datetime]'2026-10-31 08:06')) -and -not (Test-FujiScheduleDue $once ([datetime]'2026-11-01 08:06'))) 'schedule: once on its date'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_set_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
try {
    Assert-Equal 0 (Read-FujiSetting -Directory $work).schedules.Count 'settings: none yet'
    Save-FujiSetting -Directory $work -Settings ([ordered]@{ schedules = @($once, [ordered]@{ id = ''; time = '1:00' }) })
    $back = Read-FujiSetting -Directory $work
    Assert-True ($back.schedules.Count -eq 1 -and $back.schedules[0].time -eq '08:05' -and $back.schedules[0].header -eq $true) 'settings: saved and read back, broken entries left out'
    Write-FujiTextFile -Path (Join-Path $work 'fujikyun_settings.json') -Text '{ bad'
    Assert-Equal 0 (Read-FujiSetting -Directory $work).schedules.Count 'settings: a broken file means no schedules'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}

# recording -> steps
$payload = "S`tmemo.txt - Notepad`nT`tabc`nK`t{TAB}`nK`t{TAB}`nK`t{TAB}`nW`t1500`nC`t10`t20`tDOUBLE`nN`tSave`t1`t2`nS`tother.txt - Notepad`nJ`nK`t^s`nW`t3000"
$rec = ConvertFrom-FujiRecording -Payload $payload
Assert-Equal 'SWITCH TEXT KEY WAIT CLICK_POS CLICK_NAME COMMENT KEY' (@($rec | ForEach-Object { $_.cmd }) -join ' ') 'recording: commands (same app switch once, trailing wait dropped)'
Assert-True ($rec[0].val -eq 'Notepad' -and $rec[2].val -eq '{TAB 3}' -and $rec[3].val -eq '1500' -and $rec[4].val -eq '{"x":"10","y":"20","kind":"DOUBLE"}' -and $rec[7].val -eq '^s') 'recording: values ({TAB}x3 -> {TAB 3})'
Assert-Equal (Get-FujiStepLabel -Cmd 'KEY' -Value '{TAB 3}') $rec[2].label 'recording: label follows the merged key'
$e3 = New-TestEditor @('KEY', 'WAIT')
Assert-Equal 8 (Add-FujiRecordedStep -Editor $e3 -MacroId 'a' -At 1 -Payload $payload) 'recording: steps added'
Assert-Equal 'KEY GROUP_START SWITCH TEXT KEY WAIT CLICK_POS CLICK_NAME COMMENT KEY GROUP_END WAIT' (Get-TestCmd $e3) 'recording: one group at the insertion point'
Assert-True (Test-FujiBlockBalanced -Steps (Get-FujiCurrentStepList $e3)) 'recording: balanced'
Assert-Equal 0 (Add-FujiRecordedStep -Editor $e3 -MacroId 'gone' -At 0 -Payload $payload) 'recording: macro gone'
Assert-Equal 0 (Add-FujiRecordedStep -Editor $e3 -MacroId 'a' -At 0 -Payload "W`t2000") 'recording: nothing to add'

# rows to run
$rr = Get-FujiRunRow -CsvRows @([string[]]@('a'), [string[]]@(''), [string[]]@('c'), [string[]]@('d')) -StartText ([string][char]0xFF12) -EndText '3'
Assert-True ($rr.Rows.Count -eq 1 -and $rr.Rows[0].No -eq 3 -and $rr.Logs.Count -eq 1) 'run rows: range (full-width digits), blank row skipped'
Assert-True ([bool](Get-FujiRunRow -CsvRows @(, [string[]]@('a')) -StartText 'x').Error) 'run rows: a typo is refused, not "all rows"'
Assert-True ((Get-FujiRunRow -CsvRows @(, [string[]]@('a')) -StartText '3').Logs[0][1] -eq 'warn') 'run rows: start after end'
Assert-True ((Get-FujiRunRow).Rows[0].No -eq 0) 'run rows: no CSV = one test row'
Assert-Equal '   a ' (ConvertTo-FujiSendKey '{SPACE 3}a{space}') 'SendKeys: {SPACE n}'
$run = New-TestRun -Steps @(@('SET_VAR', '{"name":"v","value":"1","mode":"TEXT"}')) -Rows @(, [string[]]@('a')) -Header @('H')
[void](Invoke-FujiRun -Run $run)
$watch = Get-FujiRunWatch -Run $run
Assert-True ($watch.Count -eq 2 -and $watch[0][1][0][0] -eq '$v' -and $watch[1][1][0][0] -eq 'ROW' -and $watch[1][1][1][0] -eq 'H') 'variable panel: vars and CSV row with header names'
# A PowerShell engine fault this code avoids: "@(...)" around a generic List, once compiled, fails
# on an empty List. Many runs in a row with empty and full lists must keep working.
for ($i = 0; $i -lt 40; $i++) { [void](Test-FujiExpandValue (Get-FujiCommandDef 'TEXT')); [void](Test-FujiExpandValue (Get-FujiCommandDef 'ELSE')) }
Assert-True $true 'expand-value check survives compilation'

# ----------------------------------------------------------------- authoring tools: debugging, retry, fields, tables, passwords
# breakpoints and stepping
$run = New-TestRun -Steps @(@('KEY', 'a'), @('KEY', 'b', @{ breakpoint = $true }), @('COMMENT', 'c'), @('KEY', 'c'), @('KEY', 'd'))
$script:Fake.Answers.Enqueue('step'); $script:Fake.Answers.Enqueue('run')
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'debug: run with a breakpoint'
Assert-Equal 'KEYS a | KEYS b | KEYS c | KEYS d' (Get-FakeCall 'KEYS') 'debug: every step still runs'
Assert-Equal 2 $script:Fake.Breaks.Count 'debug: stopped at the breakpoint, then once more after "next" (the comment is passed over)'
Assert-True ($script:Fake.Breaks[0].Contains((Get-FujiText 'run.breakWhere' 2)) -and $script:Fake.Breaks[1].Contains((Get-FujiText 'run.breakWhere' 4))) 'debug: where it stopped'
$run = New-TestRun -Steps @(@('KEY', 'a', @{ breakpoint = $true }), @('KEY', 'b'))
$run.Breaks = $false
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'debug: unattended run'
Assert-Equal 0 $script:Fake.Breaks.Count 'debug: an unattended run never stops at breakpoints'
$run = New-TestRun -Steps @(@('LOOP_START', '{"mode":"COUNT","count":"2","left":"","op":"NOT_EMPTY","right":"","counter":"n","max":"10"}'), @('KEY', 'x'), @('LOOP_END', ''))
$run.Stepping = $true
foreach ($a in @('step', 'step', 'step', 'run')) { $script:Fake.Answers.Enqueue($a) }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'debug: stepping'
Assert-Equal 4 $script:Fake.Breaks.Count 'debug: stepping stops before the loop start and the step, not at the loop end'
$run = New-TestRun -Steps @(@('KEY', 'a', @{ breakpoint = $true; disabled = $true }), @('KEY', 'b'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'debug: disabled step'
Assert-Equal 0 $script:Fake.Breaks.Count 'debug: a disabled step does not stop the run'

# run from here / only this
$run = New-TestRun -Steps @(@('KEY', 'a'), @('KEY', 'b'), @('KEY', 'c')) -Rows @([string[]]@('1'), [string[]]@('2'))
$run.StartAt = 1
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'partial: from here'
Assert-Equal 'KEYS b | KEYS c | KEYS a | KEYS b | KEYS c' (Get-FakeCall 'KEYS') 'partial: the first row starts at the chosen step, the next row from the top'
$run = New-TestRun -Steps @(@('KEY', 'a'), @('GROUP_START', 'g'), @('KEY', 'b'), @('GROUP_END', ''), @('KEY', 'c'))
$run.StartAt = 1
$run.EndAt = 3
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'partial: only this block'
Assert-True ((Get-FakeCall 'KEYS') -eq 'KEYS b' -and $run.DoneRows -eq 1) 'partial: only the chosen block runs, the row counts as done'
$run = New-TestRun -Steps @(@('LOOP_START', '{"mode":"COUNT","count":"2","left":"","op":"NOT_EMPTY","right":"","counter":"n","max":"10"}'), @('KEY', 'x'), @('LOOP_END', ''), @('KEY', 'y'))
$run.StartAt = 1
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'partial: from inside a loop'
Assert-Equal 'KEYS x | KEYS y' (Get-FakeCall 'KEYS') 'partial: a loop end without its start goes on'

# retry
$retry = '{"times":"2","wait":"10"}'
$run = New-TestRun -Steps @(@('RETRY_START', $retry), @('FIELD_SET', '{"name":"f","text":"t","nth":"1","how":"AUTO"}'), @('RETRY_END', ''), @('KEY', 'after'))
$script:Fake.FieldFails = 1
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'retry: second try works'
Assert-True ((Get-FakeCall 'FIELD') -eq 'FIELD f#1=t AUTO | FIELD f#1=t AUTO' -and (Get-FakeCall 'KEYS') -eq 'KEYS after') 'retry: the body ran again, then the run went on'
Assert-Equal '1' $run.Vars[(Get-FujiText 'data.retryVar')] 'retry: the try number in a variable'
$run = New-TestRun -Steps @(@('RETRY_START', $retry), @('KEY', 'a'), @('SWITCH', 'Missing'), @('RETRY_END', ''), @('KEY', 'after'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'retry: gives up after the last try'
Assert-True ((Get-FakeCall 'KEYS') -eq 'KEYS a | KEYS a | KEYS a' -and $run.ErrorRows.Count -eq 0) 'retry: first try and two more, then the error stops the run'
$run = New-TestRun -Steps @(@('TRY_START', 't'), @('RETRY_START', '{"times":"1","wait":"0"}'), @('SWITCH', 'Missing'), @('RETRY_END', ''), @('CATCH', ''), @('KEY', 'caught'), @('TRY_END', ''))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'retry: inside on-error'
Assert-Equal 'KEYS caught' (Get-FakeCall 'KEYS') 'retry: the last failure goes to the CATCH section around it'
$run = New-TestRun -Steps @(@('RETRY_START', $retry), @('WINDOW_CHECK', '{"title":"App","key":"","mode":"STOP"}'), @('RETRY_END', ''))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'retry: an emergency stop'
Assert-Equal 0 @($script:Fake.Logs | Where-Object { $_ -like ('warn*' + (Get-FujiText 'run.retryGaveUp' 2)) }).Count 'retry: an emergency stop is never retried'

# fields
$run = New-TestRun -Steps @(@('FIELD_SET', '{"name":"No","text":"{{1}}","nth":"2","how":"PASTE"}')) -Rows @(, [string[]]@('123'))
$script:Fake.FieldMode = 'FOCUSED'
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'field: focused, then pasted'
Assert-Equal 'FIELD No#2=123 PASTE | KEYS ^a | CLIP 123 | KEYS ^v' ((@($script:Fake.Calls | Where-Object { $_ -match '^(FIELD|KEYS|CLIP)' })) -join ' | ') 'field: replace what the field holds'
$run = New-TestRun -Steps @(@('FIELD_SET', '{"name":"No","text":"","nth":"1","how":"PASTE"}'))
$script:Fake.FieldMode = 'FOCUSED'
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'field: emptied'
Assert-Equal 'KEYS ^a | KEYS {DEL}' (Get-FakeCall 'KEYS') 'field: an empty text clears the field'
$run = New-TestRun -Steps @(@('FIELD_GET', '{"name":"Due","nth":"1","var":"due"}'), @('TEXT', '[{{$due}}]'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'field: read'
Assert-True ($run.Vars['due'] -eq 'v1' -and (Get-FakeCall 'CLIP') -eq 'CLIP [v1]' -and $run.ResultRows[0].Values['due'] -eq 'v1') 'field: value in the variable and the result CSV, line end dropped'
$run = New-TestRun -Steps @(@('FIELD_SET', '{"name":"No","text":"x","nth":"1","how":"AUTO"}'))
$script:Fake.FieldFails = 1
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'field: not found stops the run'

# table
$run = New-TestRun -Steps @(@('TABLE_READ', '{"name":"","path":"t_{{ROW}}.csv","var":"count"}')) -Rows @(, [string[]]@('x'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'table: read'
$tablePath = Join-Path 'D' 't_1.csv'
Assert-Equal ("h1,h2`r`na,'=1+1`r`nb,c`r`n") $script:Fake.Saved[$tablePath] 'table: saved next to the macros, formula-like text kept as text'
Assert-Equal '2' $run.Vars['count'] 'table: row count'
foreach ($bad in @('..\fujikyun', 'C:\Windows\x', '\x', "a`r`nb")) {
    $run = New-TestRun -Steps @(@('TABLE_READ', '{"name":"","path":"out\\{{1}}.csv","var":""}')) -Rows @(, [string[]]@($bad))
    Assert-Equal 'error' (Invoke-FujiRun -Run $run) ('table: an inserted path part is refused: ' + ($bad -replace '\s', ' '))
    Assert-Equal 0 $script:Fake.Saved.Count 'table: nothing saved for a refused path'
}
$run = New-TestRun -Steps @(@('TABLE_READ', '{"name":"","path":"{{1}}","var":""}')) -Rows @(, [string[]]@('fujikyun.ps1'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'table: only a .csv file is written'
$run = New-TestRun -Steps @(@('TABLE_READ', '{"name":"","path":"out\\{{1}}.csv","var":""}')) -Rows @(, [string[]]@('2026\list'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'table: an inserted sub folder is fine'
Assert-True ($script:Fake.Saved.ContainsKey((Join-Path 'D' 'out\2026\list.csv'))) 'table: saved under the macro folder'
Assert-True ((Test-FujiStepSetting -Cmd 'TABLE_READ' -Settings @{ name = ''; path = 'a.txt'; var = '' }) -ne '') 'TABLE_READ path must be a .csv'

# passwords
$secretName = 'kikan'
$run = New-TestRun -Steps @(@('SECRET', ('{"target":"' + $secretName + '","part":"USER"}')), @('SECRET', ('{"target":"' + $secretName + '","part":"PASSWORD"}')))
$script:Fake.Secrets[$secretName] = @{ User = 'user1'; Password = 'p+w(1)'; Program = 'c:\app\APP.exe'; Window = 'login' }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'secret: typed'
Assert-Equal 'SECRET 5 | SECRET 6' (Get-FakeCall 'SECRET') 'secret: user name and password typed'
Assert-Equal 0 @($script:Fake.Logs | Where-Object { $_.Contains('p+w') -or $_.Contains('user1') }).Count 'secret: values never in the log'
$run = New-TestRun -Steps @(@('SECRET', '{"target":"none","part":"PASSWORD"}'))
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'secret: not registered'
$run = New-TestRun -Steps @(@('TRY_START', 't'), @('SECRET', ('{"target":"' + $secretName + '","part":"PASSWORD"}')), @('CATCH', ''), @('KEY', 'caught'), @('TRY_END', ''))
$script:Fake.Secrets[$secretName] = @{ User = 'u'; Password = 'p'; Program = 'C:\App\app.exe'; Window = 'login' }
$script:Fake.Front = @{ Title = 'memo - Notepad'; Program = 'C:\Windows\notepad.exe' }
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'secret: another window in front stops the run'
Assert-True ((Get-FakeCall 'SECRET') -eq '' -and (Get-FakeCall 'KEYS') -eq '') 'secret: nothing typed into another window, and "on error" does not catch it'
$run = New-TestRun -Steps @(@('SECRET', ('{"target":"' + $secretName + '","part":"PASSWORD"}')))
$script:Fake.Secrets[$secretName] = @{ User = 'u'; Password = 'p'; Program = 'C:\App\app.exe'; Window = 'login' }
$script:Fake.Front = @{ Title = 'login copy.txt - app'; Program = 'C:\Users\x\app.exe' }
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'secret: a look-alike title and a copied program of the same name are refused'
$run = New-TestRun -Steps @(@('SECRET', ('{"target":"' + $secretName + '","part":"PASSWORD"}')), @('SECRET', ('{"target":"' + $secretName + '","part":"USER"}')))
$script:Fake.Secrets[$secretName] = @{ User = 'u'; Password = 'p'; Program = 'C:\App\app.exe'; Window = 'login' }
$script:Fake.PasswordFocus = $false
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'secret: a password only into a password field'
Assert-Equal '' (Get-FakeCall 'SECRET') 'secret: nothing typed into an ordinary field'
$run = New-TestRun -Steps @(@('SECRET', ('{"target":"' + $secretName + '","part":"USER"}')))
$script:Fake.Secrets[$secretName] = @{ User = 'u'; Password = 'p'; Program = 'C:\App\app.exe'; Window = 'login' }
$script:Fake.PasswordFocus = $false
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'secret: the user name may go into an ordinary field'
$run = New-TestRun -Steps @(@('SECRET', ('{"target":"' + $secretName + '","part":"PASSWORD"}')))
$script:Fake.Secrets[$secretName] = @{ User = 'u'; Password = 'p'; Program = ''; Window = 'login' }
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'secret: no program registered'
Assert-True (-not (Test-FujiSecretPlace -Foreground @{ Title = 'Kikan Login'; Program = 'C:\k.exe' } -Program '' -Window 'login')) 'secret place: a title alone is never enough'
Assert-True (Test-FujiSecretPlace -Foreground @{ Title = 'Kikan Login'; Program = 'C:\K.EXE' } -Program 'c:\k.exe' -Window 'login') 'secret place: title and program path'
Assert-Equal 'prog|title|x' (ConvertTo-FujiSecretPlace -Program 'pr|og' -Window ' title|x ') 'secret place written'
Assert-True ((ConvertFrom-FujiSecretPlace 'prog|title|x').Window -eq 'title|x' -and (ConvertFrom-FujiSecretPlace '').Window -eq '') 'secret place read'
Assert-Equal 'a{+}b{^}{%}{~}{(}{)}{{}{}}{[}{]}' (ConvertTo-FujiSendKeyLiteral 'a+b^%~(){}[]') 'secret: SendKeys characters typed as they are'

# commands: settings, values, labels
Assert-Equal '{"name":"No","text":"x","nth":"1","how":"AUTO"}' (ConvertTo-FujiStepValue -Cmd 'FIELD_SET' -Settings ([ordered]@{ name = 'No'; text = 'x'; nth = '0'; how = 'odd' })) 'FIELD_SET normalised'
Assert-Equal '{"times":"3","wait":"0"}' (ConvertTo-FujiStepValue -Cmd 'RETRY_START' -Settings ([ordered]@{ times = 'x'; wait = '-5' })) 'RETRY_START normalised'
foreach ($b in @(@('FIELD_SET', @{ name = ''; text = ''; nth = '1'; how = 'AUTO' }), @('FIELD_GET', @{ name = 'a'; nth = '1'; var = '' }), @('FIELD_GET', @{ name = 'a'; nth = 'x'; var = 'v' }),
        @('TABLE_READ', @{ name = ''; path = ' '; var = '' }), @('TABLE_READ', @{ name = ''; path = 'a.csv'; var = 'a b' }), @('SECRET', @{ target = ''; part = 'PASSWORD' }),
        @('RETRY_START', @{ times = '0'; wait = '1' }))) {
    Assert-True ((Test-FujiStepSetting -Cmd $b[0] -Settings $b[1]) -ne '') ('{0} invalid settings must be reported' -f $b[0])
}
Assert-Equal '' (Test-FujiStepSetting -Cmd 'TABLE_READ' -Settings @{ name = ''; path = 'a.csv'; var = '' }) 'TABLE_READ needs no variable'
Assert-True ((Get-FujiStepLabel -Cmd 'FIELD_SET' -Value '{"name":"No","text":"x","nth":"2","how":"AUTO"}').EndsWith((Get-FujiLabelText 'nth' @{ nth = 2 }))) 'FIELD_SET label shows the field number'
Assert-True ((Get-FujiStepLabel -Cmd 'RETRY_START' -Value '{"times":"3","wait":"1500"}').Contains('1.5')) 'RETRY_START label in seconds'
Assert-Equal @('pick') @(foreach ($f in (Get-FujiCommandDef 'CLICK_NAME')['fields']) { if (Test-FujiButtonField $f) { [string]$f['id'] } }) 'CLICK_NAME has a pick button that is not a value'
Assert-Equal 'Btn' (ConvertTo-FujiStepValue -Cmd 'CLICK_NAME' -Settings ([ordered]@{ name = 'Btn' })) 'CLICK_NAME value unchanged by the pick button'
Assert-True (Test-FujiBlockBalanced -Steps @([ordered]@{ cmd = 'RETRY_START'; val = '' }, [ordered]@{ cmd = 'RETRY_END'; val = '' })) 'retry block balanced'

# breakpoints in the file and the editor
$conv = (ConvertTo-FujiMacroData -Source (ConvertFrom-FujiJson -Json '{"macros":[{"name":"m","steps":[{"cmd":"KEY","val":"a","breakpoint":true},{"cmd":"COMMENT","val":"c","breakpoint":true}]}]}')).Data
Assert-True ($conv.macros[0].steps[0]['breakpoint'] -eq $true -and -not $conv.macros[0].steps[1].Contains('breakpoint')) 'breakpoint kept in the macros file, not on a comment'
Assert-True ((ConvertTo-FujiMacroJson -Data $conv).Contains('"breakpoint": true')) 'breakpoint written to the macros file'

# triggers
$hk = ConvertFrom-FujiHotkeyText -Text ' ctrl + shift + 1 '
Assert-True ($hk.Ctrl -and $hk.Shift -and -not $hk.Alt -and $hk.Vk -eq 0x31 -and $hk.Text -eq 'Ctrl+Shift+1') 'hotkey parsed'
Assert-Equal 0x78 (ConvertFrom-FujiHotkeyText -Text 'F9').Vk 'hotkey: F-key alone'
foreach ($t in @('A', 'Shift+A', 'Ctrl+', 'Ctrl+A+B', 'Ctrl+Space', '')) { Assert-True ($null -eq (ConvertFrom-FujiHotkeyText -Text $t)) ('hotkey refused: "{0}"' -f $t) }
$st = @{ Seen = @{}; Pending = @{} }
[void](Update-FujiFileTrigger -State $st -Files @(@{ Name = 'old.csv'; Length = 1; Ticks = 1 }) -First $true)
Assert-Equal 0 (Update-FujiFileTrigger -State $st -Files @(@{ Name = 'old.csv'; Length = 1; Ticks = 1 }, @{ Name = 'new.csv'; Length = 5; Ticks = 2 })).Count 'file trigger: a new file waits one look'
Assert-Equal 0 (Update-FujiFileTrigger -State $st -Files @(@{ Name = 'old.csv'; Length = 1; Ticks = 1 }, @{ Name = 'new.csv'; Length = 9; Ticks = 3 })).Count 'file trigger: still growing'
Assert-Equal @('New.csv') (Update-FujiFileTrigger -State $st -Files @(@{ Name = 'old.csv'; Length = 1; Ticks = 1 }, @{ Name = 'New.csv'; Length = 9; Ticks = 3 })) 'file trigger: ready once it stayed the same'
Assert-Equal 0 (Update-FujiFileTrigger -State $st -Files @(@{ Name = 'new.csv'; Length = 9; Ticks = 3 })).Count 'file trigger: fires once per file'
$ws = @{ Present = $false }
Assert-True (-not (Update-FujiWindowTrigger -State $ws -Present $true -First $true)) 'window trigger: already open at the start'
Assert-True (-not (Update-FujiWindowTrigger -State $ws -Present $true)) 'window trigger: still open'
[void](Update-FujiWindowTrigger -State $ws -Present $false)
Assert-True (Update-FujiWindowTrigger -State $ws -Present $true) 'window trigger: opened again'
$tr = New-FujiSchedule -MacroId 'm' -MacroName 'M' -CsvPath '' -Header $true -Time '' -Repeat 'DAILY' -DateText '' -CloseAfter $false -Kind 'FILE' -Folder ' C:\in ' -Pattern '' -UseFile $true
Assert-True ($tr.Schedule.kind -eq 'FILE' -and $tr.Schedule.folder -eq 'C:\in' -and $tr.Schedule.pattern -eq '*' -and $tr.Schedule.useFile) 'file trigger made'
Assert-Equal (-1) (Get-FujiScheduleMinute $tr.Schedule) 'a trigger has no time'
Assert-True ($null -eq (Get-FujiNextSchedule -Schedules @($tr.Schedule) -Now ([datetime]'2026-10-09 10:00'))) 'a trigger is not a next scheduled time'
Assert-True ((New-FujiSchedule -MacroId 'm' -MacroName 'M' -CsvPath '' -Header $true -Time '' -Repeat 'DAILY' -DateText '' -CloseAfter $false -Kind 'HOTKEY' -Hotkey 'X').ContainsKey('Error')) 'hotkey trigger refused'
Assert-True ((New-FujiSchedule -MacroId 'm' -MacroName 'M' -CsvPath '' -Header $true -Time '' -Repeat 'DAILY' -DateText '' -CloseAfter $false -Kind 'FILE' -Folder 'C:\in' -Pattern 'a\b').ContainsKey('Error')) 'file pattern with a folder refused'
Assert-True ((New-FujiSchedule -MacroId 'm' -MacroName 'M' -CsvPath '' -Header $true -Time '' -Repeat 'DAILY' -DateText '' -CloseAfter $false -Kind 'WINDOW' -Window 'W').Schedule.window -eq 'W') 'window trigger made'
$sdir = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_sched_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sdir)
try {
    $set = [ordered]@{ schedules = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
    $set.schedules.Add($tr.Schedule)
    Save-FujiSetting -Directory $sdir -Settings $set
    Assert-Equal 1 (Read-FujiSetting -Directory $sdir).schedules.Count 'a trigger survives the settings file'
} finally {
    Remove-Item -LiteralPath $sdir -Recurse -Force
}

# editor: breakpoints and partial runs
$e = New-TestEditor @('KEY', 'GROUP_START', 'KEY', 'GROUP_END', 'COMMENT')
$e.Selected = 2
Assert-True (Switch-FujiEditorBreakpoint -Editor $e) 'breakpoint set'
Assert-True ((Get-FujiCurrentStepList $e)[2]['breakpoint'] -and $e.Dirty) 'breakpoint on the step, a change to save'
Assert-True (Switch-FujiEditorBreakpoint -Editor $e) 'breakpoint removed'
Assert-True (-not (Get-FujiCurrentStepList $e)[2].Contains('breakpoint')) 'breakpoint gone'
$e.Selected = 4
Assert-True (-not (Switch-FujiEditorBreakpoint -Editor $e)) 'no breakpoint on a comment'
$e.Selected = 1
$pr = Get-FujiPartialRun -Editor $e -Mode 'only'
Assert-True ($pr.StartAt -eq 1 -and $pr.EndAt -eq 3) 'only this: a block start covers its block'
$pr = Get-FujiPartialRun -Editor $e -Mode 'from'
Assert-True ($pr.StartAt -eq 1 -and $pr.EndAt -eq -1) 'from here: to the end'
$e.Selected = 3
Assert-True ((Get-FujiPartialRun -Editor $e -Mode 'from').ContainsKey('Error')) 'no partial run from a block end'
$e.Selected = -1
Assert-True ((Get-FujiPartialRun -Editor $e -Mode 'only').ContainsKey('Error')) 'no partial run without a selection'

# ----------------------------------------------------------------- effect: step times, time a person spent, records, summary
$run = New-TestRun -Steps @(@('LOOP_START', '{"mode":"COUNT","count":"3"}'), @('KEY', 'a'), @('WAIT', '0', @{ disabled = $true }), @('LOOP_END', ''), @('COMMENT', 'x'), @('CONFIRM', 'ok?')) -Rows @([string[]]@('1'), [string[]]@('2'))
$script:Fake.Answers.Enqueue('continue'); $script:Fake.Answers.Enqueue('continue')
$run.Io.Confirm = { param($Caption, $Message) $null = $Caption, $Message; Start-Sleep -Milliseconds 60; return $script:Fake.Answers.Dequeue() }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'step times: run'
$times = Get-FujiStepTimeRow -Run $run
$byIndex = @{}
foreach ($t in $times) { $byIndex[$t.Index] = $t }
Assert-True ($byIndex[0].Count -eq 8 -and $byIndex[1].Count -eq 6 -and $byIndex[5].Count -eq 2) 'step times: counted per step and row (loop start 4 times a row)'
Assert-True (-not $byIndex.ContainsKey(2) -and -not $byIndex.ContainsKey(3) -and -not $byIndex.ContainsKey(4)) 'step times: no disabled step, block end or comment'
Assert-True ($times[0].Index -eq 5 -and $times[0].TotalMs -ge 100 -and [Math]::Abs((@($times | ForEach-Object { $_.Share }) | Measure-Object -Sum).Sum - 100) -lt 0.01) 'step times: longest first, shares add up to 100'
Assert-True ($run.AttendedMs -ge 100) ('attended time: the confirm waits are a person''s time (' + $run.AttendedMs + ')')
$text = ConvertTo-FujiStepTimeText -Rows $times
Assert-True ($text.StartsWith(((Get-FujiText 'steptime.head') -join "`t")) -and ($text -split "`r`n").Count -eq 5) 'step times: tab text with a heading'
$sub = [ordered]@{ id = 'sub'; name = 'part'; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
$sub.steps.Add([ordered]@{ cmd = 'KEY'; val = 'z'; label = '' })
$run = New-TestRun -Steps @(, @('CALL_MACRO', '{"id":"sub","name":"part"}')) -Other @($sub)
[void](Invoke-FujiRun -Run $run)
Assert-True (@(Get-FujiStepTimeRow -Run $run | Where-Object { $_.MacroId -eq 'sub' -and $_.Macro -eq 'part' -and $_.Index -eq 0 }).Count -eq 1) 'step times: a called macro''s steps under its own name'

$ew = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_effect_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $ew)
try {
    $run = New-TestRun -Steps @(, @('KEY', 'a')) -Rows @([string[]]@('1'), [string[]]@('2')) -Header @('name', (Get-FujiText 'editor.csv.resultHeaderName'))
    [void](Invoke-FujiRun -Run $run)
    $rec = New-FujiRunRecord -Run $run -How 'manual' -End ($run.StartTime.AddSeconds(42))
    Assert-True ($rec.done -eq '2' -and $rec.rows -eq '2' -and $rec.seconds -eq '42' -and $rec.how -eq (Get-FujiText 'effect.how.manual') -and $rec.status -eq (Get-FujiText 'effect.status.done') -and $rec.rerun -eq (Get-FujiText 'effect.yes')) 'run record: rows, time, how, a re-run of rows'
    $run.Macro.name = '=evil'
    Add-FujiRunRecord -Directory $ew -Record $rec
    Add-FujiRunRecord -Directory $ew -Record (New-FujiRunRecord -Run $run -How 'test')
    $back = Read-FujiRunRecord -Directory $ew
    Assert-True ($back.Count -eq 2 -and $back[0].done -eq '2' -and $back[1].macro -eq '=evil' -and $back[1].how -eq (Get-FujiText 'effect.how.test')) 'run records: appended and read back (a formula-looking name kept as text)'
    $raw = [System.IO.File]::ReadAllBytes((Join-Path $ew 'fujikyun_runs.csv'))
    Assert-True ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and ([System.Text.Encoding]::UTF8.GetString($raw)).Contains("'=evil")) 'run records: a BOM for Excel, the name neutralised in the file'
    $bad = New-TestRun -Steps @(, @('SWITCH', 'none'))
    [void](Invoke-FujiRun -Run $bad)
    $badRec = New-FujiRunRecord -Run $bad -How 'manual'
    Assert-True ($badRec.errors -eq '1' -and $badRec.done -eq '0' -and $badRec.status -eq (Get-FujiText 'effect.status.error')) 'run record: an error without CSV counts as an error row'
    Assert-True (Set-FujiRunRecordAck -Directory $ew -Start $rec.start -MacroId 'main' -Seconds 95) 'run record: alert answer written'
    Assert-Equal '95' (Read-FujiRunRecord -Directory $ew)[1].waitAck 'run record: the last matching record got it'

    $ed = New-TestEditor @('KEY')
    $ed.Directory = $ew
    $ed.LastChangeAt = (Get-Date).AddSeconds(-90)
    Submit-FujiEditorChange -Editor $ed -Description 'x'
    $ed.LastChangeAt = (Get-Date).AddSeconds(-600)
    Submit-FujiEditorChange -Editor $ed -Description 'y'
    $edit = @($ed.EditTime.Values)[0]
    Assert-True ($ed.EditTime.Count -eq 1 -and $edit.Seconds -ge 89 -and $edit.Seconds -lt 120) ('edit time: a short gap counts, a long break does not (' + $edit.Seconds + ')')
    Save-FujiEditTime -Editor $ed
    $er = Read-FujiEditRecord -Directory $ew
    Assert-True ($er.Count -eq 1 -and $er[0].macroId -eq 'a' -and [int]$er[0].editSeconds -ge 89 -and $ed.EditTime.Count -eq 0) 'edit time: written per day and macro, then started again'
} finally {
    Remove-Item -LiteralPath $ew -Recurse -Force -ErrorAction SilentlyContinue
}

$settings = [ordered]@{}
Set-FujiEffectSetting -Settings $settings -Key 'hourly' -Value '2000'
Set-FujiEffectSetting -Settings $settings -Key 'manual' -MacroId 'm1' -Value '4.5'
Set-FujiEffectSetting -Settings $settings -Key 'manual' -MacroId 'm2' -Value '3'
Set-FujiEffectSetting -Settings $settings -Key 'manual' -MacroId 'm2' -Value ''
$eff = Get-FujiEffectSetting -Settings $settings
Assert-True ($eff.Hourly -eq 2000 -and $eff.Manual['m1'] -eq 4.5 -and -not $eff.Manual.ContainsKey('m2')) 'effect settings: pay per hour, minutes by hand, one removed'
Assert-Equal 1200 (ConvertTo-FujiEffectNumber ([string][char]0xFF11 + [char]0xFF12 + ',' + '00')) 'effect number: full-width digits and comma'
Assert-True ($null -eq (ConvertTo-FujiEffectNumber '-1') -and $null -eq (ConvertTo-FujiEffectNumber 'abc') -and $null -eq (ConvertTo-FujiEffectNumber '')) 'effect number: not negative, not text'
$sw = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_set_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $sw)
try {
    Save-FujiSetting -Directory $sw -Settings $settings
    Assert-True ((Get-FujiEffectSetting -Settings (Read-FujiSetting -Directory $sw)).Manual['m1'] -eq 4.5) 'effect settings: kept in the settings file'
} finally { Remove-Item -LiteralPath $sw -Recurse -Force -ErrorAction SilentlyContinue }

$hm = Get-FujiText 'effect.how.manual'
$runsIn = @(
    [ordered]@{ start = '2026/10/01 09:00:00'; macroId = 'm1'; macro = 'old'; how = $hm; rows = '12'; done = '10'; skipped = '1'; errors = '1'; seconds = '600'; attended = '120'; waitAck = '300' },
    [ordered]@{ start = '2026/10/02 09:00:00'; macroId = 'm1'; macro = 'old'; how = (Get-FujiText 'effect.how.schedule'); rows = '8'; done = '8'; skipped = '0'; errors = '0'; seconds = '480'; attended = '0'; waitAck = '' },
    [ordered]@{ start = '2026/10/03 09:00:00'; macroId = 'm1'; macro = 'old'; how = (Get-FujiText 'effect.how.test'); done = '1'; skipped = '0'; errors = '0'; seconds = '60'; attended = '0'; waitAck = '' },
    [ordered]@{ start = '2026/09/30 09:00:00'; macroId = 'm1'; macro = 'old'; how = $hm; done = '5'; skipped = '0'; errors = '0'; seconds = '300'; attended = '0'; waitAck = '' },
    [ordered]@{ start = '2026/10/04 09:00:00'; macroId = 'm3'; macro = 'other'; how = $hm; done = '2'; skipped = '0'; errors = '0'; seconds = '60'; attended = '0'; waitAck = '' })
$editsIn = @([ordered]@{ date = '2026/10/01'; macroId = 'm1'; macro = 'old'; editSeconds = '1800' })
$macrosIn = New-Object -TypeName 'System.Collections.Generic.List[object]'
$macrosIn.Add([ordered]@{ id = 'm1'; name = 'Monthly'; targetWindow = ''; steps = @() })
Assert-Equal '2026/10,2026/09' ((Get-FujiEffectMonth -Runs $runsIn) -join ',') 'effect: months newest first'
$sum = Get-FujiEffectSummary -Runs $runsIn -Edits $editsIn -Macros $macrosIn -Effect $eff -Month '2026/10'
$m1 = @($sum.Rows | Where-Object { $_.id -eq 'm1' })[0]
Assert-True ($m1.macro -eq 'Monthly' -and $m1.runs -eq 2 -and $m1.done -eq 18 -and $m1.errors -eq 1) 'effect: one month, test runs left out, the current macro name'
Assert-True ([Math]::Abs($m1.savedMin - (18 * 4.5 - 2)) -lt 0.001 -and $m1.yen -eq [Math]::Round((18 * 4.5 - 2) / 60 * 2000) -and $m1.editMin -eq 30 -and $m1.waitMin -eq 5) 'effect: saved = done x minutes by hand - attended; yen; editing; waiting'
Assert-Equal 5.0 (Get-FujiEffectErrorRate $m1) 'effect: error rate among the rows handled'
$m3 = @($sum.Rows | Where-Object { $_.id -eq 'm3' })[0]
Assert-True ($null -eq $m3.savedMin -and $null -eq $m3.yen -and $sum.Total.done -eq 20 -and [Math]::Abs($sum.Total.savedMin - 79) -lt 0.001) 'effect: no minutes by hand, no saving; totals'
$table = ConvertTo-FujiEffectTable -Summary $sum
Assert-True ($table.Count -eq 4 -and $table[0][0] -eq (Get-FujiText 'effect.head')[0] -and $table[3][0] -eq (Get-FujiText 'effect.total') -and $table[1][9] -eq '79.0' -and $table[2][9] -eq '') 'effect: table with heading, rows, total'
Assert-Equal 3 (@((Get-FujiEffectSummary -Runs $runsIn -Edits @() -Macros $macrosIn -Effect $eff -Month '').Rows | Where-Object { $_.id -eq 'm1' })[0].runs) 'effect: every month'
$evil = @([string[]]@('name', 'n'), [string[]]@('=HYPERLINK(1)', '-1.5'))
Assert-Equal "name`tn`r`n'=HYPERLINK(1)`t-1.5`r`n" (ConvertTo-FujiTabText -Rows $evil) 'effect copy: a formula-looking name as text, numbers kept'
Assert-Equal "'=HYPERLINK(1)" (ConvertTo-FujiSafeTable -Rows $evil)[1][0] 'effect CSV: a formula-looking name as text'
$st = ConvertTo-FujiStepTimeText -Rows @(@{ Macro = '@x'; Index = 0; Label = '+y'; Count = 1; TotalMs = 1.0; MaxMs = 1.0; Share = 100.0 })
Assert-True ($st.Contains("'@x`t1`t'+y")) 'step times copy: formula-looking macro name and label as text'

# ----------------------------------------------------------------- watch rules while running
$relogin = [ordered]@{ id = 's'; name = 'relogin'; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
$relogin.steps.Add([ordered]@{ cmd = 'KEY'; val = 'login'; label = '' })
$wrun = { param($Action, [string[]]$Windows, $Rows = @(), $Steps = @(@('KEY', 'a'), @('KEY', 'b')))
    $r = New-TestRun -Steps $Steps -Rows $Rows -Other @($relogin)
    $r.WatchRules.Add([ordered]@{ title = 'Timeout'; key = '{ENTER}'; action = $Action; macroId = 's'; macroName = 'relogin' })
    $script:Fake.Windows = @('App') + $Windows
    return $r
}
# the window appears once (before step 2) and is gone after the key: continue
$run = & $wrun 'CONTINUE' @()
$run.Io.SendKeys = { param($Keys) $script:Fake.Calls.Add('KEYS ' + $Keys); if ($Keys -eq 'a') { $script:Fake.Windows = @('App', 'Timeout') } elseif ($Keys -eq '{ENTER}') { $script:Fake.Windows = @('App') } }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'watch: continue after pressing the key'
Assert-Equal 'KEYS a | KEYS {ENTER} | KEYS b' (Get-FakeCall 'KEYS') 'watch: the key pressed before the next step'
# call a macro, then the step that was about to run
$run = & $wrun 'CALL' @()
$run.Io.SendKeys = { param($Keys) $script:Fake.Calls.Add('KEYS ' + $Keys); if ($Keys -eq 'a') { $script:Fake.Windows = @('App', 'Timeout') } elseif ($Keys -eq 'login') { $script:Fake.Windows = @('App') } }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'watch: call a macro'
Assert-Equal 'KEYS a | KEYS {ENTER} | KEYS login | KEYS b' (Get-FakeCall 'KEYS') 'watch: the called macro ran, then the step it stopped before'
# still there after the key: stop instead of pressing it again and again
$run = & $wrun 'CONTINUE' @('Timeout')
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'watch: a window that stays stops the run'
Assert-Equal 'KEYS {ENTER} | KEYS a' (Get-FakeCall 'KEYS') 'watch: pressed once, stopped before the next step'
# skip the row, error caught by "on error", stop
$run = & $wrun 'SKIP' @('Timeout') @([string[]]@('1'), [string[]]@('2'))
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'watch: skip rows'
Assert-True ($run.SkippedRows -eq 2 -and $run.ErrorRows.Count -eq 2 -and (Get-FakeCall 'KEYS a') -eq '') 'watch: each row skipped and recorded'
$run = & $wrun 'ERROR' @() @() @(@('TRY_START', 'try'), @('KEY', 'x'), @('KEY', 'a'), @('CATCH', ''), @('SET_VAR', ('{"name":"seen","value":"{{$' + (Get-FujiText 'data.errorVar') + '}}","mode":"TEXT"}')), @('TRY_END', ''))
$run.Io.SendKeys = { param($Keys) $script:Fake.Calls.Add('KEYS ' + $Keys); if ($Keys -eq 'x') { $script:Fake.Windows = @('App', 'Timeout') } elseif ($Keys -eq '{ENTER}') { $script:Fake.Windows = @('App') } }
Assert-Equal 'done' (Invoke-FujiRun -Run $run) 'watch: an error the "on error" block catches'
Assert-True ($run.Vars['seen'] -like ('*Timeout*') -and (Get-FakeCall 'KEYS') -eq 'KEYS x | KEYS {ENTER}') 'watch: caught, the rest of the try part not run'
$run = & $wrun 'STOP' @('Timeout')
$run.WatchRules[0].key = ''
Assert-Equal 'error' (Invoke-FujiRun -Run $run) 'watch: stop'
Assert-True ((Get-FakeCall 'ALARM') -eq 'ALARM' -and (Get-FakeCall 'KEYS') -eq '') 'watch: alarm, no key'

# ----------------------------------------------------------------- pause when touched
$ts = @{ Mark = $null; RobotUntil = 0 }
$down = { $true }
$up = { $false }
Assert-True (-not (Test-FujiUserInput -State $ts -LastInput 100 -Now 1000 -Pressed $down)) 'touch: the first look only takes the input as it is'
Assert-True (-not (Test-FujiUserInput -State $ts -LastInput 100 -Now 1100 -Pressed $down)) 'touch: no new input'
$ts.RobotUntil = 1700
Assert-True (-not (Test-FujiUserInput -State $ts -LastInput 150 -Now 1200 -Pressed $down) -and $ts.Mark -eq 150) 'touch: input during the robot''s own keys and clicks is not a person'
Assert-True (-not (Test-FujiUserInput -State $ts -LastInput 155 -Now 1800 -Pressed $up) -and $ts.Mark -eq 155) 'touch: the cursor only moving (nothing pressed) does not pause'
Assert-True (Test-FujiUserInput -State $ts -LastInput 160 -Now 1810 -Pressed $down) 'touch: a key or button pressed after that is a person'
Assert-True (-not (Test-FujiUserInput -State @{ Mark = [uint32]4294967200; RobotUntil = 0 } -LastInput ([uint32]4294967200) -Now 5 -Pressed $down)) 'touch: tick counts above 2^31'

# ----------------------------------------------------------------- check before a run
$chk = { param($Cmds, [string[]]$Header = $null, [int]$Columns = -1, [object[]]$Other = @(), [string[]]$Have = @())
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($c in $Cmds) {
        $step = [ordered]@{ cmd = $c[0]; val = [string]$c[1]; label = '' }
        if ($c.Count -gt 2) { foreach ($k in $c[2].Keys) { $step[$k] = $c[2][$k] } }
        $list.Add($step)
    }
    $all = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $main = [ordered]@{ id = 'main'; name = 'main'; targetWindow = ''; steps = $list }
    $all.Add($main)
    foreach ($o in $Other) { $all.Add($o) }
    $haveSet = $Have
    return , (Get-FujiMacroProblem -Macros $all -Macro $main -Directory 'C:\app' -Header $Header -Columns $Columns -PathExists { param($Path, $Folder) $null = $Folder; return ($haveSet -contains $Path) }.GetNewClosure())
}
$probSub = [ordered]@{ id = 'sub'; name = 'part'; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
$probSub.steps.Add([ordered]@{ cmd = 'SET_VAR'; val = '{"name":"fromSub","value":"1","mode":"TEXT"}'; label = '' })
$probSub.steps.Add([ordered]@{ cmd = 'KEY'; val = ''; label = '' })
$found = & $chk @(@('KEY', ''), @('CALL_MACRO', '{"id":"gone","name":"gone"}'), @('CALL_MACRO', '{"id":"sub","name":"part"}'), @('CLICK_IMG', '{"path":"C:\\img\\a.png","threshold":"0.9"}'),
    @('TEXT', '{{$fromSub}}{{$never}}{{5}}{{name}}{{place}}{{TODAY}}{{ROW+1}}'), @('KEY', 'a', @{ breakpoint = $true }),
    @('GROUP_START', 'off', @{ disabled = $true }), @('KEY', ''), @('TEXT', '{{$ghost}}'), @('GROUP_END', ''),
    @('EXCEL_READ', '{"path":"C:\\book.xlsx","sheet":"1","cell":"A1","name":"v"}'), @('FILE_OP', '{"op":"COPY","src":"in\\a.pdf","dest":"C:\\x\\","overwrite":"NO","var":""}'),
    @('MAIL', '{"method":"OUTLOOK","mode":"DRAFT","to":"a@b","cc":"","subject":"s","body":"{{$v}}","attach":"C:\\here.pdf;{{$p}}"}')) -Header @('name') -Columns 3 -Other @($probSub) -Have @('C:\here.pdf')
$show = { param($Level) (@($found | Where-Object { $_.Level -eq $Level } | ForEach-Object { '{0}#{1}:{2}' -f $_.Macro, $_.Index, $_.Message }) -join ' | ') }
$errors = & $show 'error'
Assert-Equal ('main#0:' + (Get-FujiText 'check.setting' (Get-FujiText 'validate.key')) + ' | main#1:' + (Get-FujiText 'check.callMissing' 'gone') + ' | main#3:' + (Get-FujiText 'check.imageMissing' 'C:\img\a.png') + ' | part#1:' + (Get-FujiText 'check.setting' (Get-FujiText 'validate.key'))) $errors 'check: missing setting, called macro, image; the called macro checked too'
$warns = & $show 'warn'
Assert-Equal ('main#4:' + (Get-FujiText 'check.csvColumn' 5 3) + ' | main#4:' + (Get-FujiText 'check.unknownName' '{{place}}') + ' | main#10:' + (Get-FujiText 'check.fileMissing' 'C:\book.xlsx') + ' | main#11:' + (Get-FujiText 'check.folderMissing' 'C:\app\in') + ' | main#4:' + (Get-FujiText 'check.varNeverSet' 'never') + ' | main#12:' + (Get-FujiText 'check.varNeverSet' 'p')) $warns 'check: CSV column, unknown name, missing file and folder, variables never set (one set in the called macro is fine; disabled block left out)'
Assert-Equal ('main#5:' + (Get-FujiText 'check.breakpoint')) (& $show 'note') 'check: a breakpoint left in is a note'
Assert-Equal 2 (Select-FujiSeriousProblem -Problems (& $chk @(@('KEY', 'a', @{ breakpoint = $true }), @('KEY', ''), @('TEXT', '{{$x}}')))).Count 'check: notes do not ask before a run'
Assert-Equal ('main#0:' + (Get-FujiText 'check.nameNoCsv' '{{name}}')) (@((& $chk @(, @('TEXT', '{{name}}{{3}}'))) | ForEach-Object { '{0}#{1}:{2}' -f $_.Macro, $_.Index, $_.Message }) -join ' | ') 'check: without a CSV, a heading name is a note and a column number is not checked'
Assert-Equal 0 (& $chk @(@('IF_START', '{"left":"{{$a}}","op":"EQ","right":"1"}'), @('SET_VAR', '{"name":"a","value":"1","mode":"TEXT"}'), @('IF_END', ''))).Count 'check: a variable set later (in a loop) counts as set'
$wm = [ordered]@{ id = 'main'; name = 'main'; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]'); watch = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
$wm.steps.Add([ordered]@{ cmd = 'TEXT'; val = '{{$fromRelogin}}'; label = '' })
$wm.watch.Add([ordered]@{ title = 'A'; key = ''; action = 'CALL'; macroId = 'gone'; macroName = 'gone' })
$wm.watch.Add([ordered]@{ title = 'B'; key = ''; action = 'CALL'; macroId = 'r2'; macroName = 'r2' })
$r2 = [ordered]@{ id = 'r2'; name = 'r2'; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
$r2.steps.Add([ordered]@{ cmd = 'SET_VAR'; val = '{"name":"fromRelogin","value":"1","mode":"TEXT"}'; label = '' })
$wl = New-Object -TypeName 'System.Collections.Generic.List[object]'
$wl.Add($wm); $wl.Add($r2)
Assert-Equal ('main#-1:' + (Get-FujiText 'check.watchCall' 'A' 'gone')) (@(Get-FujiMacroProblem -Macros $wl -Macro $wm -PathExists { $true } | ForEach-Object { '{0}#{1}:{2}' -f $_.Macro, $_.Index, $_.Message }) -join ' | ') 'check: a watch rule calling a macro that is gone; the macro a rule calls is checked (its variables count)'
$bad = New-Object -TypeName 'System.Collections.Generic.List[string]'
foreach ($t in $templates['templates']) {
    $tm = [ordered]@{ id = 't'; name = [string]$t['id']; targetWindow = ''; steps = (Get-FujiTemplateStep -Template $t) }
    $hdr = $null
    $cols = -1
    if ($t.Contains('csv') -and $t['csv'] -is [System.Collections.IList] -and $t['csv'].Count -gt 0) { $hdr = [string[]]$t['csv'][0]; $cols = $hdr.Length }
    $tl = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $tl.Add($tm)
    foreach ($p in (Get-FujiMacroProblem -Macros $tl -Macro $tm -Directory 'C:\app' -Header $hdr -Columns $cols -PathExists { $true })) {
        if ($p.Level -ne 'note' -and $p.Message -notlike ((Get-FujiText 'check.callMissing' '*'))) { $bad.Add($t['id'] + '#' + $p.Index + ': ' + $p.Message) }
    }
}
Assert-Equal '' ($bad -join ' / ') 'check: the built-in templates have no errors or warnings'
$sample = New-FujiSampleData
$sampleList = New-Object -TypeName 'System.Collections.Generic.List[object]'
foreach ($sm in $sample.macros) { $sampleList.Add($sm) }
Assert-Equal 0 (Select-FujiSeriousProblem -Problems (Get-FujiMacroProblem -Macros $sampleList -Macro $sampleList[0] -PathExists { $true })).Count 'check: the sample macro runs without a question'

# editor: an Excel book in the CSV box (Excel itself is not here: a stand-in reader)
$bookDir = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_book_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $bookDir)
try {
    $book = Join-Path $bookDir 'list.xlsx'
    [System.IO.File]::WriteAllBytes($book, [byte[]]@(80, 75))
    $eb = New-TestEditor @('KEY')
    $script:FujiWorkbookReader = $null
    Assert-True (-not (Import-FujiEditorCsv -Editor $eb -Path $book).Ok) 'a book needs Excel'
    $script:FujiWorkbookReader = { param($Path) $null = $Path; "No,Name`r`n1,A`r`n2,B`r`n" }
    $r = Import-FujiEditorCsv -Editor $eb -Path $book
    Assert-True ($r.Ok -and @($eb.Csv.Rows).Count -eq 2 -and $eb.Csv.Header[1] -eq 'Name' -and $eb.Csv.Encoding -eq 'xlsx') 'a book read through the reader, first line the header'
    Assert-True (Test-FujiWorkbookPath 'a.XLSM') 'book file names'
} finally {
    $script:FujiWorkbookReader = $null
    Remove-Item -LiteralPath $bookDir -Recurse -Force
}

# recording: a click into a named text box, then typing
$rec = ConvertFrom-FujiRecording -Payload ("F`tNo`t10`t20`nW`t1500`nT`t123`nF`tName`t5`t6`nK`t{TAB}")
Assert-Equal 'WAIT FIELD_SET CLICK_POS KEY' (@($rec | ForEach-Object { $_.cmd }) -join ' ') 'recording: the pause, the field, a field click without typing stays a click'
Assert-Equal '{"name":"No","text":"123","nth":"1","how":"AUTO"}' $rec[1].val 'recording: typed text goes into the field by name'

# the window's look on this PC: text size, place, size, pane split
$ui = [ordered]@{ ui = [ordered]@{} }
Assert-Equal 1.0 (Get-FujiZoom -Settings $ui) 'zoom: standard when not set'
Set-FujiUiSetting -Settings $ui -Key 'zoom' -Value '1.3'
Assert-Equal 1.3 (Get-FujiZoom -Settings $ui) 'zoom: a chosen size'
Set-FujiUiSetting -Settings $ui -Key 'zoom' -Value '9'
Assert-Equal 2.0 (Get-FujiZoom -Settings $ui) 'zoom: a hand-edited value snaps to the nearest offered size'
Set-FujiUiSetting -Settings $ui -Key 'zoom' -Value 'big'
Assert-Equal 1.0 (Get-FujiZoom -Settings $ui) 'zoom: not a number'
Set-FujiUiSetting -Settings $ui -Key 'window' -Value (ConvertTo-FujiWindowPlacementText -X -1600 -Y 20 -Width 1200 -Height 800 -Maximized $true)
Set-FujiUiSetting -Settings $ui -Key 'split' -Value '0.400'
$wp = Get-FujiWindowPlacement -Settings $ui
Assert-True ($wp.X -eq -1600 -and $wp.Width -eq 1200 -and $wp.Maximized -and $wp.Split -eq 0.4) 'window placement read back'
$screensNow = @(@{ X = 0; Y = 0; Width = 1920; Height = 1040 })
Assert-True (-not (Test-FujiWindowPlacementVisible -Placement $wp -Screens $screensNow)) 'window placement: on a monitor that is gone'
Assert-True (Test-FujiWindowPlacementVisible -Placement $wp -Screens @(@{ X = -1920; Y = 0; Width = 1920; Height = 1040 }, $screensNow[0])) 'window placement: on the left monitor'
Assert-True (Test-FujiWindowPlacementVisible -Placement @{ X = 1800; Y = 100; Width = 900; Height = 600 } -Screens $screensNow) 'window placement: partly off the screen but its top edge can be grabbed'
Set-FujiUiSetting -Settings $ui -Key 'split' -Value '0.99'
Assert-Equal 0.0 (Get-FujiWindowPlacement -Settings $ui).Split 'window placement: an odd split is not used'
Set-FujiUiSetting -Settings $ui -Key 'window' -Value '10,10,50,50'
Assert-True ($null -eq (Get-FujiWindowPlacement -Settings $ui)) 'window placement: too small to use'
$udir = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_ui_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $udir)
try {
    $set = Read-FujiSetting -Directory $udir
    Set-FujiUiSetting -Settings $set -Key 'zoom' -Value '1.5'
    Save-FujiSetting -Directory $udir -Settings $set
    Assert-Equal 1.5 (Get-FujiZoom -Settings (Read-FujiSetting -Directory $udir)) 'zoom kept in the settings file'
} finally {
    Remove-Item -LiteralPath $udir -Recurse -Force
}

# manuals opened from the window: every place the app points to exists in the built pages
# (fujikyun_manual.html holds every page as a section)
$docHtml = [System.IO.File]::ReadAllText((Join-Path $psRoot $script:FujiDocFileName))
$docIds = @{}
foreach ($pg in $script:FujiDocPages) {
    $section = [regex]::Match($docHtml, '<section class="page" id="page-' + $pg + '"[\s\S]*?</section>').Value
    Assert-True ($section -ne '') ('the manual file has the page ' + $pg)
    $docIds[$pg] = @{}
    foreach ($m in [regex]::Matches($section, 'id="([^"]+)"')) { $docIds[$pg][[System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)] = $true }
}
$badDoc = New-Object -TypeName 'System.Collections.Generic.List[string]'
foreach ($c in Get-FujiCommandName) { $a = Get-FujiCommandDocAnchor -Cmd $c; if (-not $docIds['manual'].ContainsKey($a)) { $badDoc.Add($c + ' -> ' + $a) } }
Assert-True ($badDoc.Count -eq 0) ('every command explained at a place in the manual page: ' + ($badDoc -join ', '))
Assert-True ($docIds['manual'].ContainsKey((Get-FujiText 'gui.docCommandAnchor'))) 'the command list anchor exists'
foreach ($pair in @(@('setup', 'trouble'), @('manual', 'diagnostics'), @('manual', 'schedule'), @('manual', 'secret'), @('manual', 'effect'), @('manual', 'stepTime'), @('manual', 'check'))) {
    Assert-True ($docIds[$pair[0]].ContainsKey((Get-FujiText ('gui.docAnchors.' + $pair[1])))) ('dialog help anchor exists: ' + $pair[1])
}
$missingTpl = @(foreach ($t in $templates['templates']) { if (-not $docIds['templates'].ContainsKey([string]$t['id'])) { $t['id'] } })
Assert-Equal 0 $missingTpl.Count ('every template has its anchor in the templates page: ' + ($missingTpl -join ', '))
$docRoot = Join-Path 'R' 'app'
$found = Find-FujiDocFile -Directory $docRoot -FileExists { param($p) $p -eq (Join-Path $docRoot 'fujikyun_manual.html') }
Assert-Equal (Join-Path $docRoot 'fujikyun_manual.html') $found 'manual found next to fujikyun.ps1'
Assert-Equal '' (Find-FujiDocFile -Directory $docRoot -FileExists { param($p) $null = $p; $false }) 'no manual here'
Assert-Equal 'page-manual' (Get-FujiDocPageAnchor -Page 'manual') 'a page of the manual'
Assert-Equal 'page-setup/trouble' (Get-FujiDocPageAnchor -Page 'setup' -Anchor 'trouble') 'a heading in a page'
Assert-Equal 'page-index' (Get-FujiDocPageAnchor -Page '..\x') 'only the known pages'
Assert-True ((ConvertTo-FujiDocUrl -Path ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'fujikyun_manual.html')) -Anchor 'page-manual/a').EndsWith('#page-manual%2Fa')) 'page and heading in one address'
$docUrl = ConvertTo-FujiDocUrl -Path ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'manual.html')) -Anchor ([string][char]0x8868 + 'a b')
Assert-True ($docUrl.StartsWith('file:///') -and $docUrl.EndsWith('#%E8%A1%A8a%20b')) 'manual address with its place'
Assert-True ((New-FujiDocForwardHtml -Url 'file:///a"><b>').Contains('url=file:///a&quot;&gt;&lt;b&gt;"')) 'forwarding page keeps the address one attribute'

# ----------------------------------------------------------------- Windows API declarations (built, not called here)
$native = Get-FujiNativeType
Assert-True ($null -ne $native.GetMethod('SetProcessDPIAware') -and $null -ne $native.GetMethod('SendMessage')) 'native functions declared without a compiler'
Assert-True ([object]::ReferenceEquals($native, (Get-FujiNativeType))) 'native type made once'
Assert-True ($null -ne $native.GetMethod('GetWindowRect') -and $null -ne $native.GetMethod('GetCurrentThreadId') -and $null -ne $native.GetMethod('mouse_event')) 'window, keyboard and mouse functions declared'
# Credential Manager: declared like the others; CREDENTIALW member offsets for this process
$cred = Get-FujiCredNativeType
Assert-True ($null -ne $cred.GetMethod('CredReadW') -and $null -ne $cred.GetMethod('CredWriteW') -and $null -ne $cred.GetMethod('CredDeleteW') -and $null -ne $cred.GetMethod('CredFree')) 'credential functions declared'
$cl = Get-FujiCredLayout
if ([IntPtr]::Size -eq 8) { $expect = '4,8,16,32,40,48,72,80' } else { $expect = '4,8,12,24,28,32,48,52' }
Assert-Equal $expect (($cl.Type, $cl.TargetName, $cl.Comment, $cl.BlobSize, $cl.Blob, $cl.Persist, $cl.UserName, $cl.Size) -join ',') 'CREDENTIALW offsets (Type, TargetName, Comment, CredentialBlobSize, CredentialBlob, Persist, UserName, size)'
$wins = @(@{ Handle = 1; Title = 'Book1 - Excel' }, @{ Handle = 2; Title = 'Notepad' }, @{ Handle = 3; Title = 'notepad memo' })
Assert-Equal 2 (Select-FujiWindow -Windows $wins -Title 'NOTEPAD').Handle 'window title: exact match first (case ignored)'
Assert-Equal 1 (Select-FujiWindow -Windows $wins -Title 'Book1').Handle 'window title: prefix'
Assert-Equal 1 (Select-FujiWindow -Windows $wins -Title 'Excel').Handle 'window title: suffix'
Assert-True ($null -eq (Select-FujiWindow -Windows $wins -Title 'memo pad') -and $null -eq (Select-FujiWindow -Windows $wins -Title '')) 'window title: no match'

# ----------------------------------------------------------------- every text the scripts ask for exists
Assert-Equal '' (Test-FujiTextVersion) 'fujikyun_ja.json has the text version the scripts need'
Assert-Equal '' (Test-FujiCommandsVersion) 'fujikyun_commands.json has the version the scripts need'
$keepCommands = $script:FujiCommands
$script:FujiCommands = [ordered]@{ commands = $keepCommands['commands'] }
Assert-Equal (Get-FujiText 'gui.commandsOld' 0 $script:FujiCommandsVersion) (Test-FujiCommandsVersion) 'an old fujikyun_commands.json (no version) is reported'
$script:FujiCommands = $keepCommands
$keyFiles = @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $psRoot 'gui') -Filter '*.ps1') + @(Get-Item -LiteralPath (Join-Path $psRoot 'build/Main.ps1'))
$missing = New-Object -TypeName 'System.Collections.Generic.List[string]'
$seen = 0
foreach ($f in $keyFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    # Get-FujiText 'a.b' and the keys of label / key lists written as 'gui.x' / 'run.x' ...
    foreach ($m in [regex]::Matches($text, "'((?:gui|run|editor|schedule|rec|diag|calc|csv|data|validate|label|placeholder|date|strOp|cred)\.[A-Za-z0-9_.]+)'")) {
        $key = $m.Groups[1].Value
        if ($key.EndsWith('.')) { continue }
        $seen++
        $value = Get-FujiText $key
        if ($value -is [string] -and $value -eq $key) { $missing.Add($f.Name + ': ' + $key) }
    }
}
Assert-True ($seen -gt 300) ('text keys found in the sources ({0})' -f $seen)
Assert-True ($missing.Count -eq 0) ('every text key exists in fujikyun_ja.json: ' + ($missing -join ', '))

# ----------------------------------------------------------------- source rules
# The app file handed out must be the current build of the sources
$built = & (Join-Path $psRoot 'build/Build-FujiBundle.ps1') -PassThru
$current = ([System.IO.File]::ReadAllText((Join-Path $psRoot 'fujikyun.ps1'))) -replace "`r`n", "`n"
Assert-True ($current -ceq ($built -replace "`r`n", "`n")) 'fujikyun.ps1 is up to date (run build/Build-FujiBundle.ps1)'

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
