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
    $settings = [ordered]@{ schedules = (New-Object -TypeName 'System.Collections.Generic.List[object]'); ui = [ordered]@{} }
    $path = Join-Path $Directory $script:FujiSettingsFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $settings }
    try {
        $s = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $path)
        if ($s -isnot [System.Collections.IDictionary]) { throw (Get-FujiText 'schedule.settingsNotObject') }
    } catch {
        # the app still starts (no schedules, standard look), but the file is kept: the next save
        # writes over it
        $script:FujiSettingsNotice = Save-FujiBrokenSetting -Path $path -Reason $_.Exception.Message
        return $settings
    }
    # the window's look on this PC: text size, window place and size, where the panes are split
    if ($s -is [System.Collections.IDictionary] -and $s.Contains('ui') -and $s['ui'] -is [System.Collections.IDictionary]) {
        foreach ($k in $s['ui'].Keys) { $settings.ui[[string]$k] = $s['ui'][$k] }
    }
    # how the app calls a person (Alert.ps1 checks each value when it is used)
    if ($s -is [System.Collections.IDictionary] -and $s.Contains('alerts') -and $s['alerts'] -is [System.Collections.IDictionary]) { $settings['alerts'] = $s['alerts'] }
    # minutes by hand per macro and pay per hour (Effect.ps1 checks each value when it is used)
    if ($s -is [System.Collections.IDictionary] -and $s.Contains('effect') -and $s['effect'] -is [System.Collections.IDictionary]) { $settings['effect'] = $s['effect'] }
    if ($s -is [System.Collections.IDictionary] -and $s.Contains('schedules') -and $s['schedules'] -is [System.Collections.IList]) {
        foreach ($x in $s['schedules']) {
            if ($x -isnot [System.Collections.IDictionary] -or -not $x.Contains('id') -or -not $x['id']) { continue }
            $kind = Get-FujiScheduleKind $x
            if (($kind -eq 'TIME' -and $x.Contains('time') -and $x['time']) -or $kind -ne 'TIME') { $settings.schedules.Add($x) }
        }
    }
    return $settings
}

# Set by Read-FujiSetting when the file could not be read: the text shown once after start
$script:FujiSettingsNotice = ''

# Copies an unreadable settings file to fujikyun_settings_broken_<time>.json; returns the notice text
function Save-FujiBrokenSetting {
    param([Parameter(Mandatory)][string]$Path, [string]$Reason)
    $name = 'fujikyun_settings_broken_' + (Get-FujiTimeStamp) + '.json'
    try {
        Copy-Item -LiteralPath $Path -Destination (Join-Path (Split-Path -Path $Path -Parent) $name) -ErrorAction Stop
        return (Get-FujiText 'schedule.settingsBroken' $script:FujiSettingsFile $Reason $name)
    } catch {
        return (Get-FujiText 'schedule.settingsBrokenNotCopied' $script:FujiSettingsFile $Reason)
    }
}

function Save-FujiSetting {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    # written beside and then put in place, so a stop halfway does not leave a cut-off file
    Write-FujiFileSafely -Path (Join-Path $Directory $script:FujiSettingsFile) -Text (ConvertTo-FujiJson -InputObject $Settings -Indent 2)
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

# ----------------------------------------------------------------- the window's look on this PC
# Text size: how much larger than standard everything is drawn (text and the room around it)
$script:FujiZoomLevels = @(0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0)

function Get-FujiZoom {
    param([System.Collections.IDictionary]$Settings)
    $text = ''
    if ($null -ne $Settings -and $Settings.Contains('ui') -and $Settings['ui'].Contains('zoom')) { $text = [string]$Settings['ui']['zoom'] }
    $z = 0.0
    if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$z)) { return 1.0 }
    # the nearest of the offered sizes (a hand-edited file cannot make the window unusable)
    $best = 1.0
    foreach ($l in $script:FujiZoomLevels) { if ([Math]::Abs($l - $z) -lt [Math]::Abs($best - $z)) { $best = $l } }
    return $best
}

function Set-FujiUiSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Key, $Value)
    if (-not $Settings.Contains('ui') -or $Settings['ui'] -isnot [System.Collections.IDictionary]) { $Settings['ui'] = [ordered]@{} }
    $Settings['ui'][$Key] = $Value
}

# The saved place of the main window: @{ X; Y; Width; Height; Maximized; Split } or $null.
# Split: the left pane's share of the window width (0.15 - 0.85).
function Get-FujiWindowPlacement {
    param([System.Collections.IDictionary]$Settings)
    if ($null -eq $Settings -or -not $Settings.Contains('ui') -or -not $Settings['ui'].Contains('window')) { return $null }
    $w = [string]$Settings['ui']['window']
    $m = [regex]::Match($w, '^(-?[0-9]+),(-?[0-9]+),([0-9]+),([0-9]+)(,max)?$')
    if (-not $m.Success) { return $null }
    $p = @{ X = [int]$m.Groups[1].Value; Y = [int]$m.Groups[2].Value; Width = [int]$m.Groups[3].Value; Height = [int]$m.Groups[4].Value; Maximized = $m.Groups[5].Success; Split = 0.0 }
    if ($p.Width -lt 200 -or $p.Height -lt 150) { return $null }
    $split = 0.0
    if ($Settings['ui'].Contains('split') -and [double]::TryParse([string]$Settings['ui']['split'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$split)) {
        if ($split -ge 0.15 -and $split -le 0.85) { $p.Split = $split }
    }
    return $p
}

function ConvertTo-FujiWindowPlacementText {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height, [bool]$Maximized)
    $t = '{0},{1},{2},{3}' -f $X, $Y, $Width, $Height
    if ($Maximized) { $t += ',max' }
    return $t
}

# The window comes back where it was only if its top edge (where it is dragged) is on a screen
# that is still there: at least 120 x 40 pixels of it inside a screen's working area.
# Screens: @(@{ X; Y; Width; Height }, ...)
function Test-FujiWindowPlacementVisible {
    param([Parameter(Mandatory)][hashtable]$Placement, [AllowEmptyCollection()][object[]]$Screens)
    $top = @{ X = $Placement.X; Y = $Placement.Y; Width = $Placement.Width; Height = [Math]::Min(40, $Placement.Height) }
    foreach ($s in $Screens) {
        $w = [Math]::Min($top.X + $top.Width, $s.X + $s.Width) - [Math]::Max($top.X, $s.X)
        $h = [Math]::Min($top.Y + $top.Height, $s.Y + $s.Height) - [Math]::Max($top.Y, $s.Y)
        if ($w -ge [Math]::Min(120, $top.Width) -and $h -ge [Math]::Min(40, $top.Height)) { return $true }
    }
    return $false
}
