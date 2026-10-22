# ---------------------------------------------------------------------------------------------
#  How the app calls a person (saved per PC in fujikyun_settings.json, "alerts"):
#    error    a run stopped with an error
#    confirm  a run waits for a person (CONFIRM, ASK)
#  style 'full' (the whole screen) | 'border' (a frame round each screen) | 'none'; color '#RRGGBB';
#  flash (slow, once a second); sound (confirm only: the error sound is the run bar's alarm box);
#  file (one of the Windows sounds in FujiAlertSounds, in %SystemRoot%\Media);
#  repeat (the sound again every 'minutes' until someone answers)
# ---------------------------------------------------------------------------------------------

$script:FujiAlertKinds = @('error', 'confirm')
$script:FujiAlertStyles = @('full', 'border', 'none')
$script:FujiAlertMinutes = @(1, 2, 3, 5, 10, 15, 30)
# loud ones that last a few seconds: Alarm01-10 and Ring01-10 of Windows
$script:FujiAlertSounds = @((1..10 | ForEach-Object { 'Alarm{0:00}.wav' -f $_ }) + (1..10 | ForEach-Object { 'Ring{0:00}.wav' -f $_ }))
$script:FujiAlertDefaults = @{
    error   = [ordered]@{ style = 'full'; color = '#D32F2F'; flash = $true; file = 'Alarm01.wav'; repeat = $true; minutes = 3 }
    confirm = [ordered]@{ style = 'border'; color = '#F9A825'; flash = $true; sound = $false; file = 'Ring02.wav'; repeat = $false; minutes = 3 }
}

# The setting of one kind, every value checked (a hand-edited file falls back to the default value)
function Get-FujiAlertSetting {
    param([System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][ValidateSet('error', 'confirm')][string]$Kind)
    $d = $script:FujiAlertDefaults[$Kind]
    $r = [ordered]@{}
    foreach ($k in $d.Keys) { $r[$k] = $d[$k] }
    $s = $null
    if ($null -ne $Settings -and $Settings.Contains('alerts') -and $Settings['alerts'] -is [System.Collections.IDictionary] -and
        $Settings['alerts'].Contains($Kind) -and $Settings['alerts'][$Kind] -is [System.Collections.IDictionary]) { $s = $Settings['alerts'][$Kind] }
    if ($null -eq $s) { return $r }
    if ($s.Contains('style') -and $script:FujiAlertStyles -contains [string]$s['style']) { $r.style = [string]$s['style'] }
    if ($s.Contains('color') -and [string]$s['color'] -match '^#[0-9A-Fa-f]{6}$') { $r.color = ([string]$s['color']).ToUpperInvariant() }
    foreach ($k in @('flash', 'sound', 'repeat')) { if ($r.Contains($k) -and $s.Contains($k) -and $s[$k] -is [bool]) { $r[$k] = $s[$k] } }
    if ($s.Contains('file')) { foreach ($x in $script:FujiAlertSounds) { if ($x -eq [string]$s['file']) { $r.file = $x } } }
    if ($s.Contains('minutes') -and $s['minutes'] -is [ValueType] -and $script:FujiAlertMinutes -contains [int]$s['minutes']) { $r.minutes = [int]$s['minutes'] }
    return $r
}

function Set-FujiAlertSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][ValidateSet('error', 'confirm')][string]$Kind,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    if (-not $Settings.Contains('alerts') -or $Settings['alerts'] -isnot [System.Collections.IDictionary]) { $Settings['alerts'] = [ordered]@{} }
    $v = [ordered]@{}
    foreach ($k in $script:FujiAlertDefaults[$Kind].Keys) { $v[$k] = $Value[$k] }
    $Settings['alerts'][$Kind] = $v
}

# Black or white, whichever reads better on the colour (WCAG relative luminance)
function Get-FujiAlertTextColor {
    param([Parameter(Mandatory)][string]$Color)
    $lum = 0.0
    $weights = @(0.2126, 0.7152, 0.0722)
    for ($i = 0; $i -lt 3; $i++) {
        $c = [Convert]::ToInt32($Color.Substring(1 + 2 * $i, 2), 16) / 255.0
        if ($c -le 0.03928) { $c = $c / 12.92 } else { $c = [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
        $lum += $weights[$i] * $c
    }
    # the luminance where black and white have the same contrast
    if ($lum -gt 0.179) { return '#000000' }
    return '#FFFFFF'
}

# The darker colour the alert flashes to (the same hue at 65 %)
function Get-FujiAlertShade {
    param([Parameter(Mandatory)][string]$Color)
    $parts = for ($i = 0; $i -lt 3; $i++) { [int][Math]::Round([Convert]::ToInt32($Color.Substring(1 + 2 * $i, 2), 16) * 0.65) }
    return ('#{0:X2}{1:X2}{2:X2}' -f $parts[0], $parts[1], $parts[2])
}

# "12 minutes" since Since, for the alert and the log
function Format-FujiElapsed {
    param([datetime]$Since, [datetime]$Now)
    $mins = [int][Math]::Floor(($Now - $Since).TotalMinutes)
    if ($mins -lt 1) { return (Get-FujiText 'alert.elapsedNew') }
    if ($mins -lt 60) { return (Get-FujiText 'alert.elapsedMinutes' $mins) }
    return (Get-FujiText 'alert.elapsedHours' ([Math]::Floor($mins / 60)) ($mins % 60))
}
