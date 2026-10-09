# ---------------------------------------------------------------------------------------------
#  JSON
#  ConvertFrom-Json gives PSCustomObjects (and Windows PowerShell 5.1 has no -AsHashtable), so data
#  is turned into ordered dictionaries and lists once after reading. Writing uses our own
#  serializer: the output is the same on 5.1 and 7 (key order kept, JSON.stringify-style escapes,
#  no depth limit), so files written by the HTA and by this edition look alike.
# ---------------------------------------------------------------------------------------------

function ConvertTo-FujiData {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $map[$p.Name] = ConvertTo-FujiData -InputObject $p.Value
        }
        return $map
    }
    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($item in $InputObject) { $list.Add((ConvertTo-FujiData -InputObject $item)) }
        return , $list
    }
    return $InputObject
}

function ConvertFrom-FujiJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    # Wrapped in an object: ConvertFrom-Json enumerates a top-level array on PowerShell 7 but not on
    # 5.1, and a one-element array would otherwise collapse into its element
    $wrapper = ConvertFrom-Json -InputObject ('{"v":' + $Json + '}')
    $value = ConvertTo-FujiData -InputObject $wrapper.v
    if ($value -is [System.Collections.IList]) { return , $value }
    return $value
}

function ConvertTo-FujiJsonString {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $sb = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($Value.Length + 2)
    [void]$sb.Append('"')
    foreach ($c in $Value.ToCharArray()) {
        switch ([int]$c) {
            0x22 { [void]$sb.Append('\"') }
            0x5C { [void]$sb.Append('\\') }
            0x08 { [void]$sb.Append('\b') }
            0x0C { [void]$sb.Append('\f') }
            0x0A { [void]$sb.Append('\n') }
            0x0D { [void]$sb.Append('\r') }
            0x09 { [void]$sb.Append('\t') }
            default {
                if ([int]$c -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Indent: spaces per level (0 = one line), like JSON.stringify(value, null, indent)
function ConvertTo-FujiJson {
    param($InputObject, [int]$Indent = 2, [int]$Level = 0)
    $nl = ''
    $pad = ''
    $padIn = ''
    $colon = ':'
    if ($Indent -gt 0) {
        $nl = "`n"
        $pad = ' ' * ($Indent * $Level)
        $padIn = ' ' * ($Indent * ($Level + 1))
        $colon = ': '
    }
    if ($null -eq $InputObject) { return 'null' }
    if ($InputObject -is [string] -or $InputObject -is [char]) { return (ConvertTo-FujiJsonString -Value ([string]$InputObject)) }
    if ($InputObject -is [bool]) { if ($InputObject) { return 'true' } else { return 'false' } }
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal] -or $InputObject -is [single]) {
        return ([System.Convert]::ToString($InputObject, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '{}' }
        $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($key in $InputObject.Keys) {
            $parts.Add($padIn + (ConvertTo-FujiJsonString -Value ([string]$key)) + $colon + (ConvertTo-FujiJson -InputObject $InputObject[$key] -Indent $Indent -Level ($Level + 1)))
        }
        return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $pad + '}'
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($item in $InputObject) {
            $parts.Add($padIn + (ConvertTo-FujiJson -InputObject $item -Indent $Indent -Level ($Level + 1)))
        }
        if ($parts.Count -eq 0) { return '[]' }
        return '[' + $nl + ($parts -join (',' + $nl)) + $nl + $pad + ']'
    }
    return (ConvertTo-FujiJsonString -Value ([string]$InputObject))
}
