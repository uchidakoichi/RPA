# ---------------------------------------------------------------------------------------------
#  Log file: every line of the log pane is also written to fujikyun_logs\fujikyun_log_<date>.txt,
#  so the log is still there after the app is closed (for example for a question about an error).
#  Files older than FujiLogKeepDays days are removed at start.
# ---------------------------------------------------------------------------------------------

$script:FujiLogFolder = 'fujikyun_logs'
$script:FujiLogKeepDays = 30
# @{ Directory; Failed } once Initialize-FujiLogFile ran; $null = not written
$script:FujiLogFile = $null

# fujikyun_log_2026-10-22.txt
function Get-FujiLogFileName {
    param([datetime]$Date)
    return ('fujikyun_log_' + $Date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) + '.txt')
}

# Makes the log folder in Directory and removes log files older than KeepDays (by the date in the name).
# Returns the names removed.
function Initialize-FujiLogFile {
    param([Parameter(Mandatory)][string]$Directory, [datetime]$Now = (Get-Date))
    $dir = Join-Path $Directory $script:FujiLogFolder
    $script:FujiLogFile = @{ Directory = $dir; Failed = $false }
    $removed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -ErrorAction Stop) }
        $oldest = $Now.Date.AddDays(-$script:FujiLogKeepDays)
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'fujikyun_log_*.txt')) {
            $m = [regex]::Match($f.Name, '^fujikyun_log_(\d{4}-\d{2}-\d{2})\.txt$')
            if (-not $m.Success) { continue }
            $day = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
            if ($day -lt $oldest) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed.Add($f.Name)
            }
        }
    } catch {
        $script:FujiLogFile.Failed = $true
    }
    return , $removed
}

# Appends one line ("[10:41:02] [error] text"). '' when written (or not set up), otherwise the reason it
# could not be: after the first failure nothing more is tried, so the caller shows the reason once.
function Write-FujiLogFile {
    param([string]$Message, [string]$Level = 'info', [datetime]$Now = (Get-Date))
    $state = $script:FujiLogFile
    if ($null -eq $state -or $state.Failed) { return '' }
    $mark = ''
    if ($Level -eq 'error' -or $Level -eq 'warn') { $mark = '[' + $Level + '] ' }
    $line = '[' + $Now.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + '] ' + $mark + (($Message -replace "`r`n", "`n") -replace "`n", "`r`n") + "`r`n"
    try {
        # a new file gets a BOM (Notepad on older Windows reads it as UTF-8); appending adds none
        [System.IO.File]::AppendAllText((Join-Path $state.Directory (Get-FujiLogFileName -Date $Now)), $line, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
    } catch {
        $state.Failed = $true
        return $_.Exception.Message
    }
    return ''
}
