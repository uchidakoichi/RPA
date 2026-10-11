# ---------------------------------------------------------------------------------------------
#  CSV  (same rules as the HTA's parseCsv)
#  Like Excel / RFC 4180: a quote opens a quoted field only as the field's first character
#  (12"monitor stays text). Blank lines inside the data keep their place so row numbers match the
#  file; only trailing blank lines are dropped. Scanning is per field (one regex match each), not
#  per character, so large files stay fast in PowerShell.
# ---------------------------------------------------------------------------------------------

$script:FujiCsvField = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @(
    '\G(?:"(?<q>(?:[^"]|"")*)(?<close>"?)(?<tail>[^,\r\n]*)|(?<plain>[^,\r\n]*))',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
)

# Returns @{ Records = List[string[]]; Warnings = string[] }
function ConvertFrom-FujiCsv {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $records = New-Object -TypeName 'System.Collections.Generic.List[string[]]'
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $len = $Text.Length
    $pos = 0
    if ($len -eq 0) { return @{ Records = $records; Warnings = $warnings.ToArray() } }
    $row = New-Object -TypeName 'System.Collections.Generic.List[string]'
    while ($true) {
        $m = $script:FujiCsvField.Match($Text, $pos)
        if ($m.Groups['q'].Success) {
            $field = $m.Groups['q'].Value.Replace('""', '"') + $m.Groups['tail'].Value
            if ($m.Groups['close'].Value -eq '') {
                $warnings.Add((Get-FujiText 'csv.unclosedQuote' ($records.Count + 1)))
            }
        } else {
            $field = $m.Groups['plain'].Value
        }
        $pos = $m.Index + $m.Length
        $row.Add($field)
        if ($pos -ge $len) {
            $records.Add($row.ToArray())
            break
        }
        $c = $Text[$pos]
        if ($c -eq ',') {
            $pos++
            continue
        }
        # \r\n, \r or \n ends the record
        $records.Add($row.ToArray())
        $row.Clear()
        $pos++
        if ($c -eq "`r" -and $pos -lt $len -and $Text[$pos] -eq "`n") { $pos++ }
        if ($pos -ge $len) { break }
    }
    while ($records.Count -gt 0 -and (Test-FujiBlankRow -Row $records[$records.Count - 1])) {
        $records.RemoveAt($records.Count - 1)
    }
    return @{ Records = $records; Warnings = $warnings.ToArray() }
}

function Test-FujiBlankRow {
    param([AllowEmptyCollection()][string[]]$Row)
    foreach ($v in $Row) { if ($v -ne '') { return $false } }
    return $true
}

function ConvertTo-FujiCsvField {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -match '[",\r\n]') { return '"' + $Value.Replace('"', '""') + '"' }
    return $Value
}

function ConvertTo-FujiCsvText {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $lines = foreach ($r in $Rows) { (@($r) | ForEach-Object { ConvertTo-FujiCsvField -Value ([string]$_) }) -join ',' }
    return ((@($lines) -join "`r`n") + "`r`n")
}

# A value the app adds to an output CSV (recorded screen text, notes, errors) that Excel would run as
# a formula (= + - @, tab, CR at the start) gets a leading apostrophe. Plain numbers such as -5 stay.
# The original CSV columns are never changed: an error-row CSV is read back to re-run those rows.
function ConvertTo-FujiSafeCsvValue {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $v = [string]$Value
    if ($v -match '^[=+\-@\t\r]' -and $v -notmatch '^[+\-]?[0-9]+(\.[0-9]+)?$') { return "'" + $v }
    return $v
}
