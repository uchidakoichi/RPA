# ---------------------------------------------------------------------------------------------
#  Placeholders  {{1}} {{column}} {{$variable}} {{ROW}} {{ROW+1}} {{TODAY}} {{WAREKI}} ...
#  (same rules as the HTA's placeholderValue / expandPlaceholders)
#
#  Context (hashtable):
#    Row     @{ No = <int>; Data = <string[]> }   the CSV row being processed (No 0 = no CSV)
#    Header  <string[]> or $null                  CSV header
#    Vars    <IDictionary>                        variables
#    Now     <datetime>                           optional, for tests (default: Get-Date)
#    Log     <scriptblock> { param($Message, $Level) }   optional
# ---------------------------------------------------------------------------------------------

$script:FujiPlaceholder = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @('\{\{([^{}]+)\}\}', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# Characters with a meaning on a command line: an inserted value holding one makes RUN refuse the row
$script:FujiCommandUnsafe = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @('["&|<>^%\r\n]', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# A RUN that starts PowerShell also refuses PowerShell's own quote, variable, statement and block characters
# (PowerShell reads the curly quotes U+2018-U+201E as quotes too), so a value cannot leave its '...' or end the statement
$script:FujiPowerShellUnsafe = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @('["&|<>^%\r\n\x27`$;(){}\u2018-\u201E]', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# A value inserted into a file path a step writes: no "..", no drive or stream ":", no root at the start
$script:FujiPathUnsafe = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @('\.\.|[:\r\n]|^[\\/]', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$script:FujiPowerShellCommand = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @('\b(powershell|pwsh)\b', ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))

# The characters RUN refuses in inserted values: Command is the RUN text before insertion
function Get-FujiCommandUnsafePattern {
    param([AllowNull()][AllowEmptyString()][string]$Command)
    if (-not [string]::IsNullOrEmpty($Command) -and $script:FujiPowerShellCommand.IsMatch($script:FujiPlaceholder.Replace($Command, ' '))) { return $script:FujiPowerShellUnsafe }
    return $script:FujiCommandUnsafe
}

function Write-FujiContextLog {
    param([hashtable]$Context, [string]$Message, [string]$Level = 'info')
    if ($Context -and $Context.ContainsKey('Log') -and $Context.Log) { & $Context.Log $Message $Level }
}

# Value of one placeholder key, or $null when the key means nothing
function Get-FujiPlaceholderValue {
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Context = @{})
    $now = Get-Date
    if ($Context.ContainsKey('Now') -and $Context.Now) { $now = [datetime]$Context.Now }
    $row = @{ No = 0; Data = @() }
    if ($Context.ContainsKey('Row') -and $Context.Row) { $row = $Context.Row }
    $data = @($row.Data)
    if ($Key -match '^[0-9]+$') {
        $col = [int]$Key
        if ($col -ge 1 -and $col -le $data.Count) { return [string]$data[$col - 1] }
        return ''
    }
    # An exact CSV header wins over the built-in names, so a column called "ROW" or "DAY" works
    if ($Context.ContainsKey('Header') -and $Context.Header) {
        $header = @($Context.Header)
        for ($i = 0; $i -lt $header.Count; $i++) {
            if (([string]$header[$i]).Trim() -ceq $Key) {
                if ($i -lt $data.Count) { return [string]$data[$i] }
                return ''
            }
        }
    }
    if ($Key.StartsWith('$')) {
        $name = $Key.Substring(1).Trim()
        if ($Context.ContainsKey('Vars') -and $Context.Vars -and $Context.Vars.Contains($name)) { return [string]$Context.Vars[$name] }
        Write-FujiContextLog -Context $Context -Message (Get-FujiText 'placeholder.emptyVar' $name)
        return ''
    }
    $up = $Key.ToUpperInvariant()
    $m = [regex]::Match($up, '^ROW\s*([+\-])\s*([0-9]+)$')
    if ($m.Success) {
        $delta = [int]$m.Groups[2].Value
        if ($m.Groups[1].Value -eq '-') { $delta = -$delta }
        return [string]([int]$row.No + $delta)
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    switch -CaseSensitive ($up) {
        'ROW' { return [string]$row.No }
        'TODAY' { return $now.ToString('yyyy/MM/dd', $inv) }
        'TODAY_JP' { return [string]$now.Year + (Get-FujiText 'date.year') + $now.Month + (Get-FujiText 'date.month') + $now.Day + (Get-FujiText 'date.day') }
        'WAREKI' { return (Get-FujiWarekiDate -Date $now) }
        'WAREKI_YEAR' { return (Get-FujiWarekiYear -Date $now) }
        'YYYYMMDD' { return $now.ToString('yyyyMMdd', $inv) }
        'NOW' { return $now.ToString('HH:mm', $inv) }
        'TIMESTAMP' { return $now.ToString('yyyyMMdd_HHmmss', $inv) }
        'YEAR' { return [string]$now.Year }
        'MONTH' { return [string]$now.Month }
        'DAY' { return [string]$now.Day }
    }
    return $null
}

# Unsafe (optional list): collects inserted values that hold command-line characters (for RUN)
function Expand-FujiPlaceholder {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [hashtable]$Context = @{},
        [System.Collections.Generic.List[string]]$Unsafe = $null,
        [System.Text.RegularExpressions.Regex]$UnsafePattern = $null
    )
    if ($null -eq $UnsafePattern) { $UnsafePattern = $script:FujiCommandUnsafe }
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = New-Object -TypeName System.Text.StringBuilder
    $last = 0
    foreach ($m in $script:FujiPlaceholder.Matches($Text)) {
        [void]$sb.Append($Text, $last, $m.Index - $last)
        $value = Get-FujiPlaceholderValue -Key $m.Groups[1].Value.Trim() -Context $Context
        if ($null -eq $value) {
            Write-FujiContextLog -Context $Context -Message (Get-FujiText 'placeholder.unknown' $m.Value) -Level 'warn'
            $value = $m.Value
        } elseif ($null -ne $Unsafe -and $UnsafePattern.IsMatch($value)) {
            $short = $value
            if ($short.Length -gt 20) { $short = $short.Substring(0, 20) + [char]0x2026 }
            $Unsafe.Add(('{0}={1}{2}{3}' -f $m.Value, [char]0x300C, $short, [char]0x300D))
        }
        [void]$sb.Append($value)
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Text, $last, $Text.Length - $last)
    return $sb.ToString()
}
