# ---------------------------------------------------------------------------------------------
#  Values: numbers, dates, calculation, string operations and conditions
#  (same results as the HTA's toNumberOrNull, warekiOf, parseDateText, calcExpression, strOp,
#  evalCondition; full-width characters are written as \uXXXX so this file stays ASCII)
# ---------------------------------------------------------------------------------------------

$script:FujiInvariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:FujiRegexOptions = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

function ConvertTo-FujiHalfWidthDigit {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, '[\uFF10-\uFF19]', { param($m) [string][char]([int][char]$m.Value - 0xFEE0) })
}

# JavaScript's String(number) for the values a clerk meets (integers stay integers)
function ConvertTo-FujiNumberText {
    param([double]$Value)
    if ($Value -eq [Math]::Floor($Value) -and [Math]::Abs($Value) -lt 1e15) {
        return ([long]$Value).ToString($script:FujiInvariant)
    }
    return $Value.ToString('R', $script:FujiInvariant)
}

# "1,200" / full-width digits -> number; anything else -> $null
function ConvertTo-FujiNumber {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $t = (ConvertTo-FujiHalfWidthDigit -Text ([string]$Text).Trim()).Replace(',', '')
    if ($t -match '^[+\-]?[0-9]+(\.[0-9]+)?$') { return [double]::Parse($t, $script:FujiInvariant) }
    return $null
}

# ----------------------------------------------------------------- dates
function Get-FujiWarekiYear {
    param([Parameter(Mandatory)][datetime]$Date)
    $eras = Get-FujiText 'date.eras'
    $y = $Date.Year
    $m = $Date.Month
    if ($y -gt 2019 -or ($y -eq 2019 -and $m -ge 5)) {
        $era = $eras[0]; $ey = $y - 2018
    } elseif ($y -gt 1989 -or ($y -eq 1989 -and ($m -gt 1 -or $Date.Day -ge 8))) {
        $era = $eras[1]; $ey = $y - 1988
    } else {
        $era = $eras[2]; $ey = $y - 1925
    }
    $num = [string]$ey
    if ($ey -eq 1) { $num = Get-FujiText 'date.firstYear' }
    return $era + $num + (Get-FujiText 'date.year')
}

function Get-FujiWarekiDate {
    param([Parameter(Mandatory)][datetime]$Date)
    return (Get-FujiWarekiYear -Date $Date) + $Date.Month + (Get-FujiText 'date.month') + $Date.Day + (Get-FujiText 'date.day')
}

function Format-FujiDate {
    param([Parameter(Mandatory)][datetime]$Date)
    return $Date.ToString('yyyy/MM/dd', $script:FujiInvariant)
}

# Reads 2026/10/01, 2026-10-1, 20261001, Reiwa 8 nen 10 gatsu 1 nichi, full-width digits; $null otherwise
function ConvertFrom-FujiDateText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $t = ConvertTo-FujiHalfWidthDigit -Text ([string]$Text).Trim()
    $eras = Get-FujiText 'date.eras'
    $first = [regex]::Escape((Get-FujiText 'date.firstYear'))
    $nen = [regex]::Escape((Get-FujiText 'date.year'))
    $tsuki = [regex]::Escape((Get-FujiText 'date.month'))
    $hi = [regex]::Escape((Get-FujiText 'date.day'))
    $eraPattern = (@($eras) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $m = [regex]::Match($t, ('({0})([0-9]+|{1}){2}([0-9]{{1,2}}){3}([0-9]{{1,2}}){4}' -f $eraPattern, $first, $nen, $tsuki, $hi))
    try {
        if ($m.Success) {
            $base = @(2018, 1988, 1925)[[array]::IndexOf([string[]]$eras, $m.Groups[1].Value)]
            $ey = 1
            if ($m.Groups[2].Value -match '^[0-9]+$') { $ey = [int]$m.Groups[2].Value }
            return (New-Object -TypeName DateTime -ArgumentList ($base + $ey), ([int]$m.Groups[3].Value), ([int]$m.Groups[4].Value))
        }
        $m = [regex]::Match($t, '^([0-9]{4})([0-9]{2})([0-9]{2})$')
        if (-not $m.Success) { $m = [regex]::Match($t, '([0-9]{4})[^0-9]+([0-9]{1,2})[^0-9]+([0-9]{1,2})') }
        if (-not $m.Success) { return $null }
        return (New-Object -TypeName DateTime -ArgumentList ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value))
    } catch [System.ArgumentOutOfRangeException] {
        return $null
    }
}

# ----------------------------------------------------------------- calculation  (+ - * / % and brackets)
function Invoke-FujiCalc {
    param([AllowNull()][AllowEmptyString()][string]$Expression)
    $s = ConvertTo-FujiHalfWidthDigit -Text ([string]$Expression)
    $s = $s -replace '[,\uFF0C]', '' -replace '\uFF0B', '+' -replace '[\uFF0D\u2212]', '-' -replace '[\uFF0A\u00D7]', '*'
    $s = $s -replace '[\uFF0F\u00F7]', '/' -replace '\uFF05', '%' -replace '\uFF08', '(' -replace '\uFF09', ')' -replace '\uFF0E', '.'
    $s = $s -replace '\s+', ''
    if ($s -eq '') { throw (Get-FujiText 'calc.empty') }
    $state = @{ S = $s; Pos = 0 }
    $result = Read-FujiCalcExpr -State $state
    if ($state.Pos -lt $s.Length) { throw (Get-FujiText 'calc.badChar' $s.Substring($state.Pos)) }
    return (ConvertTo-FujiNumberText -Value ([Math]::Round($result * 1e10) / 1e10))
}

function Get-FujiCalcPeek {
    param($State)
    if ($State.Pos -lt $State.S.Length) { return [string]$State.S[$State.Pos] }
    return ''
}

function Read-FujiCalcNumber {
    param($State)
    $m = [regex]::Match($State.S.Substring($State.Pos), '^[0-9]+(\.[0-9]+)?')
    if (-not $m.Success) {
        $rest = $State.S.Substring($State.Pos)
        if ($rest -eq '') { $rest = Get-FujiText 'calc.ended' }
        throw (Get-FujiText 'calc.badChar' $rest)
    }
    $State.Pos += $m.Length
    return [double]::Parse($m.Value, $script:FujiInvariant)
}

function Read-FujiCalcFactor {
    param($State)
    $c = Get-FujiCalcPeek -State $State
    if ($c -eq '+') { $State.Pos++; return (Read-FujiCalcFactor -State $State) }
    if ($c -eq '-') { $State.Pos++; return -(Read-FujiCalcFactor -State $State) }
    if ($c -eq '(') {
        $State.Pos++
        $v = Read-FujiCalcExpr -State $State
        if ((Get-FujiCalcPeek -State $State) -ne ')') { throw (Get-FujiText 'calc.paren') }
        $State.Pos++
        return $v
    }
    return (Read-FujiCalcNumber -State $State)
}

function Read-FujiCalcTerm {
    param($State)
    $v = Read-FujiCalcFactor -State $State
    while (@('*', '/', '%') -contains (Get-FujiCalcPeek -State $State)) {
        $op = Get-FujiCalcPeek -State $State
        $State.Pos++
        $r = Read-FujiCalcFactor -State $State
        if ($op -eq '*') {
            $v = $v * $r
        } else {
            if ($r -eq 0) { throw (Get-FujiText 'calc.divZero') }
            # .NET % on doubles keeps the sign of the dividend, like JavaScript
            if ($op -eq '/') { $v = $v / $r } else { $v = $v % $r }
        }
    }
    return $v
}

function Read-FujiCalcExpr {
    param($State)
    $v = Read-FujiCalcTerm -State $State
    while (@('+', '-') -contains (Get-FujiCalcPeek -State $State)) {
        $op = Get-FujiCalcPeek -State $State
        $State.Pos++
        $r = Read-FujiCalcTerm -State $State
        if ($op -eq '+') { $v = $v + $r } else { $v = $v - $r }
    }
    return $v
}

# ----------------------------------------------------------------- string operations (STR_OP)
function Invoke-FujiStringOp {
    param(
        [Parameter(Mandatory)][string]$Op,
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$A = '',
        [AllowEmptyString()][string]$B = ''
    )
    $s = $Text
    switch ($Op) {
        'REPLACE' {
            if ($A -eq '') { return $s }
            return $s.Replace($A, $B)
        }
        'REGEX_REPLACE' { return [regex]::Replace($s, $A, $B, $script:FujiRegexOptions) }
        'REGEX_EXTRACT' {
            $m = [regex]::Match($s, $A, $script:FujiRegexOptions)
            $g = 0
            if ($B -ne '') { $g = Get-FujiInt -Text $B -Default 0 }
            if ($m.Success -and $g -ge 0 -and $g -lt $m.Groups.Count -and $m.Groups[$g].Success) { return $m.Groups[$g].Value }
            return ''
        }
        'SUBSTR' {
            $start = [Math]::Max(1, (Get-FujiInt -Text $A -Default 1)) - 1
            if ($start -ge $s.Length) { return '' }
            if ($B -eq '') { return $s.Substring($start) }
            $n = [Math]::Min([Math]::Max(0, (Get-FujiInt -Text $B -Default 0)), $s.Length - $start)
            return $s.Substring($start, $n)
        }
        'SPLIT' {
            $sep = $A
            if ($sep -eq '') { $sep = ',' }
            $parts = $s.Split([string[]]@($sep), [System.StringSplitOptions]::None)
            $idx = Get-FujiInt -Text $B -Default 1
            if ($idx -ge 1 -and $idx -le $parts.Length) { return $parts[$idx - 1] }
            return ''
        }
        'TRIM' { return ($s -replace '^[\s\u3000]+|[\s\u3000]+$', '') }
        'ZEN2HAN' {
            $r = [regex]::Replace($s, '[\uFF01-\uFF5E]', { param($m) [string][char]([int][char]$m.Value - 0xFEE0) })
            return $r.Replace([string][char]0x3000, ' ')
        }
        'HAN2ZEN' {
            $r = [regex]::Replace($s, '[!-~]', { param($m) [string][char]([int][char]$m.Value + 0xFEE0) })
            return $r.Replace(' ', [string][char]0x3000)
        }
        'PAD' {
            $len = Get-FujiInt -Text $A -Default 0
            $fill = '0'
            if ($B -ne '') { $fill = [string]$B[0] }
            while ($s.Length -lt $len) { $s = $fill + $s }
            return $s
        }
        'WAREKI' {
            $d = ConvertFrom-FujiDateText -Text $s
            if ($null -eq $d) { throw (Get-FujiText 'strOp.badDate' $s) }
            return (Get-FujiWarekiDate -Date $d)
        }
        'DATE_ADD' {
            $d = ConvertFrom-FujiDateText -Text $s
            if ($null -eq $d) { throw (Get-FujiText 'strOp.badDate' $s) }
            return (Format-FujiDate -Date $d.AddDays((Get-FujiInt -Text $A -Default 0)))
        }
        'COMMA' {
            $n = (ConvertTo-FujiHalfWidthDigit -Text $s).Replace(',', '')
            $parts = $n.Split('.')
            $parts[0] = [regex]::Replace($parts[0], '\B(?=([0-9]{3})+(?![0-9]))', ',')
            return ($parts -join '.')
        }
        'UNCOMMA' { return ($s -replace '[,\uFF0C]', '') }
        'LENGTH' { return [string]$s.Length }
    }
    return $s
}

# parseInt-like: leading integer of the (half-width) text, or Default
function Get-FujiInt {
    param([AllowEmptyString()][string]$Text, [int]$Default = 0)
    $m = [regex]::Match((ConvertTo-FujiHalfWidthDigit -Text $Text).Trim(), '^[+\-]?[0-9]+')
    if ($m.Success) { return [int]$m.Value }
    return $Default
}

# ----------------------------------------------------------------- conditions (IF_START / LOOP_START while)
# Left / Right are already expanded. WINDOW / FILE checks go through the context so the runner (and
# the tests) decide how a window is found.
function Test-FujiCondition {
    param(
        [Parameter(Mandatory)][string]$Op,
        [AllowEmptyString()][string]$Left = '',
        [AllowEmptyString()][string]$Right = '',
        [hashtable]$Context = @{}
    )
    $ln = ConvertTo-FujiNumber -Text $Left
    $rn = ConvertTo-FujiNumber -Text $Right
    $numeric = ($null -ne $ln) -and ($null -ne $rn)
    $cmp = [string]::CompareOrdinal($Left, $Right)
    switch ($Op) {
        'EQ' { if ($numeric) { return ($ln -eq $rn) } else { return ($Left -ceq $Right) } }
        'NE' { if ($numeric) { return ($ln -ne $rn) } else { return ($Left -cne $Right) } }
        'CONTAINS' { return ($Left.IndexOf($Right, [System.StringComparison]::Ordinal) -ge 0) }
        'NOT_CONTAINS' { return ($Left.IndexOf($Right, [System.StringComparison]::Ordinal) -lt 0) }
        'EMPTY' { return ($Left.Trim() -eq '') }
        'NOT_EMPTY' { return ($Left.Trim() -ne '') }
        'GT' { if ($numeric) { return ($ln -gt $rn) } else { return ($cmp -gt 0) } }
        'GE' { if ($numeric) { return ($ln -ge $rn) } else { return ($cmp -ge 0) } }
        'LT' { if ($numeric) { return ($ln -lt $rn) } else { return ($cmp -lt 0) } }
        'LE' { if ($numeric) { return ($ln -le $rn) } else { return ($cmp -le 0) } }
        'REGEX' { return [regex]::IsMatch($Left, $Right, $script:FujiRegexOptions) }
        'FILE' { return (Test-FujiFileCondition -Path $Left -Context $Context) }
        'NO_FILE' { return -not (Test-FujiFileCondition -Path $Left -Context $Context) }
        'WINDOW' { return (Test-FujiWindowCondition -Title $Left -Context $Context) }
        'NO_WINDOW' { return -not (Test-FujiWindowCondition -Title $Left -Context $Context) }
    }
    return $false
}

function Test-FujiFileCondition {
    param([string]$Path, [hashtable]$Context)
    if ($Context.ContainsKey('FileExists')) { return [bool](& $Context.FileExists $Path) }
    return ($Path -ne '' -and (Test-Path -LiteralPath $Path -PathType Leaf))
}

function Test-FujiWindowCondition {
    param([string]$Title, [hashtable]$Context)
    if ($Context.ContainsKey('WindowExists')) { return [bool](& $Context.WindowExists $Title) }
    return $false
}
