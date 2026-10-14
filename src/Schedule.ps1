# ---------------------------------------------------------------------------------------------
#  Schedules (the HTA's rules) and the per-PC settings file
#  A schedule: [ordered]@{ id; macroId; macroName; csvPath; header; time 'HH:mm';
#  repeat 'DAILY'|'WEEKDAYS'|'ONCE'; date 'yyyy/MM/dd' (ONCE); enabled; closeAfter; lastRun; taskName;
#  kind 'TIME'|'HOTKEY'|'FILE'|'WINDOW'; hotkey 'Ctrl+Shift+1'; folder; pattern '*.csv'; window; useFile }
#  This window runs a due schedule while it is open; a Windows scheduled task can also start the
#  app with -AutoRun <id> at the time. The other kinds (triggers) work while the app is open:
#  a key pressed anywhere, a new file in a folder, a window that appears.
# ---------------------------------------------------------------------------------------------

$script:FujiSettingsFile = 'fujikyun_settings.json'
$script:FujiScheduleRepeats = @('DAILY', 'WEEKDAYS', 'ONCE')
$script:FujiScheduleKinds = @('TIME', 'HOTKEY', 'FILE', 'WINDOW')

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
            if ($x -isnot [System.Collections.IDictionary] -or -not $x.Contains('id') -or -not $x['id']) { continue }
            $kind = Get-FujiScheduleKind $x
            if (($kind -eq 'TIME' -and $x.Contains('time') -and $x['time']) -or $kind -ne 'TIME') { $settings.schedules.Add($x) }
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

function Get-FujiScheduleKind {
    param([System.Collections.IDictionary]$Schedule)
    $k = ([string](Get-FujiScheduleValue $Schedule 'kind' 'TIME')).ToUpperInvariant()
    if ($script:FujiScheduleKinds -notcontains $k) { return 'TIME' }
    return $k
}

# Minutes after midnight, -1 when the time is not HH:mm (or the schedule is a trigger)
function Get-FujiScheduleMinute {
    param([System.Collections.IDictionary]$Schedule)
    if ((Get-FujiScheduleKind $Schedule) -ne 'TIME') { return -1 }
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
        [string]$Repeat, [AllowEmptyString()][string]$DateText, [bool]$CloseAfter,
        [string]$Kind = 'TIME', [AllowEmptyString()][string]$Hotkey = '', [AllowEmptyString()][string]$Folder = '',
        [AllowEmptyString()][string]$Pattern = '', [AllowEmptyString()][string]$Window = '', [bool]$UseFile = $false)
    if ($script:FujiScheduleKinds -notcontains $Kind) { $Kind = 'TIME' }
    if ($Kind -ne 'TIME') { return (New-FujiTrigger -MacroId $MacroId -MacroName $MacroName -CsvPath $CsvPath -Header $Header -Kind $Kind -Hotkey $Hotkey -Folder $Folder -Pattern $Pattern -Window $Window -UseFile $UseFile) }
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

# ----------------------------------------------------------------- triggers
function New-FujiTrigger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param([string]$MacroId, [string]$MacroName, [AllowEmptyString()][string]$CsvPath, [bool]$Header, [string]$Kind,
        [AllowEmptyString()][string]$Hotkey, [AllowEmptyString()][string]$Folder, [AllowEmptyString()][string]$Pattern,
        [AllowEmptyString()][string]$Window, [bool]$UseFile)
    $s = [ordered]@{
        id = (New-FujiId); kind = $Kind; macroId = $MacroId; macroName = $MacroName; csvPath = $CsvPath.Trim().Trim('"'); header = $Header
        time = ''; repeat = ''; date = ''; enabled = $true; closeAfter = $false; lastRun = ''
    }
    switch ($Kind) {
        'HOTKEY' {
            $k = ConvertFrom-FujiHotkeyText -Text $Hotkey
            if ($null -eq $k) { return @{ Error = (Get-FujiText 'schedule.badHotkey') } }
            $s['hotkey'] = $k.Text
        }
        'FILE' {
            $f = $Folder.Trim().Trim('"')
            if (-not $f) { return @{ Error = (Get-FujiText 'schedule.badFolder') } }
            $p = $Pattern.Trim()
            if (-not $p) { $p = '*' }
            if ($p.IndexOfAny([char[]]@('\', '/', ':')) -ge 0) { return @{ Error = (Get-FujiText 'schedule.badPattern') } }
            $s['folder'] = $f
            $s['pattern'] = $p
            $s['useFile'] = $UseFile
        }
        'WINDOW' {
            $w = $Window.Trim()
            if (-not $w) { return @{ Error = (Get-FujiText 'schedule.badWindow') } }
            $s['window'] = $w
        }
    }
    return @{ Schedule = $s }
}

# "Ctrl+Shift+1" -> @{ Ctrl; Alt; Shift; Vk; Text } ($null when not a usable key). A letter or digit
# needs Ctrl or Alt (alone it would fire while typing); F1-F12 may be used alone.
function ConvertFrom-FujiHotkeyText {
    param([AllowEmptyString()][string]$Text)
    $parts = @(([string]$Text).ToUpperInvariant().Replace([string][char]0xFF0B, '+').Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return $null }
    $k = @{ Ctrl = $false; Alt = $false; Shift = $false; Vk = 0; Text = '' }
    $key = ''
    foreach ($p in $parts) {
        switch -Regex ($p) {
            '^(CTRL|CONTROL)$' { $k.Ctrl = $true; continue }
            '^ALT$' { $k.Alt = $true; continue }
            '^SHIFT$' { $k.Shift = $true; continue }
            default { if ($key) { return $null }; $key = $p }
        }
    }
    $key = ConvertTo-FujiHalfWidthDigit -Text $key
    if ($key -match '^[A-Z]$' -or $key -match '^[0-9]$') {
        if (-not ($k.Ctrl -or $k.Alt)) { return $null }
        $k.Vk = [int][char]$key
    } elseif ($key -match '^F([1-9]|1[0-2])$') {
        $k.Vk = 0x6F + [int]$Matches[1]
    } else {
        return $null
    }
    $names = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($k.Ctrl) { $names.Add('Ctrl') }
    if ($k.Alt) { $names.Add('Alt') }
    if ($k.Shift) { $names.Add('Shift') }
    $names.Add($key)
    $k.Text = $names.ToArray() -join '+'
    return $k
}

# A file trigger fires for a file that was not in the folder when watching began, once its size
# and time stayed the same for two looks (so a file still being copied is not used half written).
# State: @{ Seen = @{}; Pending = @{} } (name -> "length|ticks"); Files: @(@{ Name; Length; Ticks }).
# Returns the names that are ready now. First: the first look, which only records what is there.
function Update-FujiFileTrigger {
    param([Parameter(Mandatory)][hashtable]$State, [AllowEmptyCollection()][object[]]$Files, [bool]$First = $false)
    $ready = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $now = @{}
    foreach ($f in $Files) {
        $key = ([string]$f.Name).ToLowerInvariant()
        $sig = '{0}|{1}' -f $f.Length, $f.Ticks
        $now[$key] = $true
        if ($First) { $State.Seen[$key] = $sig; continue }
        if ($State.Seen.ContainsKey($key)) { continue }
        if ($State.Pending.ContainsKey($key) -and $State.Pending[$key] -eq $sig) {
            $State.Pending.Remove($key)
            $State.Seen[$key] = $sig
            $ready.Add([string]$f.Name)
        } else {
            $State.Pending[$key] = $sig
        }
    }
    # a file that went away and comes back later counts as new again (keys copied: the tables change)
    foreach ($table in @($State.Seen, $State.Pending)) {
        $keys = New-Object -TypeName 'string[]' -ArgumentList $table.Count
        $table.Keys.CopyTo($keys, 0)
        foreach ($key in $keys) { if (-not $now.ContainsKey($key)) { $table.Remove($key) } }
    }
    return , $ready.ToArray()
}

# A window trigger fires when the window appears (it was not there at the previous look)
function Update-FujiWindowTrigger {
    param([Parameter(Mandatory)][hashtable]$State, [bool]$Present, [bool]$First = $false)
    $was = [bool]$State.Present
    $State.Present = $Present
    return ($Present -and -not $was -and -not $First)
}

# What the schedule list shows in its "when" column
function Get-FujiScheduleWhenText {
    param([System.Collections.IDictionary]$Schedule)
    switch (Get-FujiScheduleKind $Schedule) {
        'HOTKEY' { return (Get-FujiText 'schedule.whenHotkey' (Get-FujiScheduleValue $Schedule 'hotkey')) }
        'FILE' { return (Get-FujiText 'schedule.whenFile' (Get-FujiScheduleValue $Schedule 'folder') (Get-FujiScheduleValue $Schedule 'pattern' '*')) }
        'WINDOW' { return (Get-FujiText 'schedule.whenWindow' (Get-FujiScheduleValue $Schedule 'window')) }
    }
    $repeat = Get-FujiScheduleRepeatName ([string](Get-FujiScheduleValue $Schedule 'repeat'))
    if (Get-FujiScheduleValue $Schedule 'date') { $repeat += ' ' + $Schedule.date }
    return ([string](Get-FujiScheduleValue $Schedule 'time') + ' ' + $repeat)
}
