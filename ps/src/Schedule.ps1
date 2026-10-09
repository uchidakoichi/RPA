# ---------------------------------------------------------------------------------------------
#  Schedules (the HTA's rules) and the per-PC settings file
#  A schedule: [ordered]@{ id; macroId; macroName; csvPath; header; time 'HH:mm';
#  repeat 'DAILY'|'WEEKDAYS'|'ONCE'; date 'yyyy/MM/dd' (ONCE); enabled; closeAfter; lastRun; taskName }
#  This window runs a due schedule while it is open; a Windows scheduled task can also start the
#  app with -AutoRun <id> at the time.
# ---------------------------------------------------------------------------------------------

$script:FujiSettingsFile = 'fujikyun_settings.json'
$script:FujiScheduleRepeats = @('DAILY', 'WEEKDAYS', 'ONCE')

function Read-FujiSetting {
    param([Parameter(Mandatory)][string]$Directory)
    $settings = [ordered]@{ schedules = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
    $path = Join-Path $Directory $script:FujiSettingsFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $settings }
    try {
        $s = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $path)
    } catch {
        # a broken settings file only means no schedules
        return $settings
    }
    if ($s -is [System.Collections.IDictionary] -and $s.Contains('schedules') -and $s['schedules'] -is [System.Collections.IList]) {
        foreach ($x in $s['schedules']) {
            if ($x -is [System.Collections.IDictionary] -and $x.Contains('id') -and $x['id'] -and $x.Contains('time') -and $x['time']) { $settings.schedules.Add($x) }
        }
    }
    return $settings
}

function Save-FujiSetting {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    Write-FujiTextFile -Path (Join-Path $Directory $script:FujiSettingsFile) -Text (ConvertTo-FujiJson -InputObject $Settings -Indent 2)
}

function Get-FujiScheduleValue {
    param([System.Collections.IDictionary]$Schedule, [string]$Key, $Default = '')
    if ($Schedule.Contains($Key) -and $null -ne $Schedule[$Key]) { return $Schedule[$Key] }
    return $Default
}

# Minutes after midnight, -1 when the time is not HH:mm
function Get-FujiScheduleMinute {
    param([System.Collections.IDictionary]$Schedule)
    $m = [regex]::Match((ConvertTo-FujiHalfWidthDigit -Text ([string](Get-FujiScheduleValue $Schedule 'time'))).Trim(), '^([0-9]{1,2}):([0-9]{2})$')
    if (-not $m.Success) { return -1 }
    return [int]$m.Groups[1].Value * 60 + [int]$m.Groups[2].Value
}

function Test-FujiScheduleDay {
    param([System.Collections.IDictionary]$Schedule, [datetime]$Date)
    switch ([string](Get-FujiScheduleValue $Schedule 'repeat')) {
        'WEEKDAYS' { return ($Date.DayOfWeek -ge [DayOfWeek]::Monday -and $Date.DayOfWeek -le [DayOfWeek]::Friday) }
        'ONCE' { return ([string](Get-FujiScheduleValue $Schedule 'date') -eq (Format-FujiDate -Date $Date)) }
    }
    return $true
}

# Due when today is a run day, the time passed less than 10 minutes ago and it has not run today
function Test-FujiScheduleDue {
    param([System.Collections.IDictionary]$Schedule, [datetime]$Now)
    $mins = Get-FujiScheduleMinute $Schedule
    $nowMins = $Now.Hour * 60 + $Now.Minute
    return ([bool](Get-FujiScheduleValue $Schedule 'enabled' $false) -and $mins -ge 0 -and (Test-FujiScheduleDay $Schedule $Now) -and
        $nowMins -ge $mins -and $nowMins - $mins -lt 10 -and [string](Get-FujiScheduleValue $Schedule 'lastRun') -ne (Format-FujiDate -Date $Now))
}

# The next run within a week: @{ Schedule; Day } or $null
function Get-FujiNextSchedule {
    param([AllowEmptyCollection()][System.Collections.IList]$Schedules, [datetime]$Now)
    for ($offset = 0; $offset -lt 8; $offset++) {
        $day = $Now.Date.AddDays($offset)
        $best = $null
        $bestMins = 0
        foreach ($s in $Schedules) {
            $mins = Get-FujiScheduleMinute $s
            if (-not (Get-FujiScheduleValue $s 'enabled' $false) -or $mins -lt 0 -or -not (Test-FujiScheduleDay $s $day)) { continue }
            if ($offset -eq 0 -and ($mins -le $Now.Hour * 60 + $Now.Minute - 10 -or [string](Get-FujiScheduleValue $s 'lastRun') -eq (Format-FujiDate -Date $Now))) { continue }
            if ($null -eq $best -or $mins -lt $bestMins) { $best = $s; $bestMins = $mins }
        }
        if ($null -ne $best) { return @{ Schedule = $best; Day = $day } }
    }
    return $null
}

# A new schedule from the dialog's fields. Returns @{ Schedule } or @{ Error }.
function New-FujiSchedule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param([string]$MacroId, [string]$MacroName, [AllowEmptyString()][string]$CsvPath, [bool]$Header, [AllowEmptyString()][string]$Time,
        [string]$Repeat, [AllowEmptyString()][string]$DateText, [bool]$CloseAfter)
    $t = ((ConvertTo-FujiHalfWidthDigit -Text $Time).Trim()).Replace([string][char]0xFF1A, ':')
    $m = [regex]::Match($t, '^([0-9]{1,2}):([0-9]{2})$')
    if (-not $m.Success -or [int]$m.Groups[1].Value -ge 24 -or [int]$m.Groups[2].Value -ge 60) { return @{ Error = (Get-FujiText 'schedule.badTime') } }
    $t = '{0:00}:{1}' -f [int]$m.Groups[1].Value, $m.Groups[2].Value
    if ($script:FujiScheduleRepeats -notcontains $Repeat) { $Repeat = 'DAILY' }
    $date = ''
    if ($Repeat -eq 'ONCE') {
        $d = ConvertFrom-FujiDateText -Text $DateText
        if ($null -eq $d) { return @{ Error = (Get-FujiText 'schedule.badDate') } }
        $date = Format-FujiDate -Date $d
    }
    return @{ Schedule = [ordered]@{
            id = (New-FujiId); macroId = $MacroId; macroName = $MacroName; csvPath = $CsvPath.Trim().Trim('"'); header = $Header
            time = $t; repeat = $Repeat; date = $date; enabled = $true; closeAfter = $CloseAfter; lastRun = ''
        }
    }
}

function Get-FujiScheduleRepeatName {
    param([string]$Repeat)
    return [string](Get-FujiText ('schedule.repeats.' + $Repeat))
}
