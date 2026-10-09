# ---------------------------------------------------------------------------------------------
#  Data model: macros file, steps and block structure
#  A macro: [ordered]@{ id; name; targetWindow; steps = List[object] }
#  A step:  [ordered]@{ cmd; val; label [; when = 'first'|'last'] [; disabled = $true] }
#  The file format is the HTA's fujikyun_macros.json (data version 27).
# ---------------------------------------------------------------------------------------------

$script:FujiDataVersion = 27

function New-FujiId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param()
    # 8 hex digits like the HTA's generateId
    return [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function New-FujiStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param([Parameter(Mandatory)][string]$Cmd, [AllowEmptyString()][string]$Value = '', [string]$Label = '', [scriptblock]$MacroNameOf = $null)
    $step = [ordered]@{ cmd = $Cmd; val = $Value; label = $Label }
    if (-not $step.label) { $step.label = Get-FujiStepLabel -Cmd $Cmd -Value $Value -MacroNameOf $MacroNameOf }
    return $step
}

# Parsed file content (dictionary) -> clean data. Unknown commands become comments so nothing is
# lost silently; every macro gets a unique id. Returns @{ Data; NewerVersion }.
function ConvertTo-FujiMacroData {
    param($Source)
    $data = [ordered]@{ version = $script:FujiDataVersion; macros = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
    $newer = $false
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains('version') -and $Source['version'] -is [ValueType] -and [double]$Source['version'] -gt $script:FujiDataVersion) { $newer = $true }
    }
    $list = @()
    if ($Source -is [System.Collections.IDictionary] -and $Source.Contains('macros') -and $Source['macros'] -is [System.Collections.IList]) { $list = $Source['macros'] }
    $used = @{}
    $known = @{}
    foreach ($c in Get-FujiCommandName) { $known[$c] = $true }
    foreach ($m in $list) {
        if ($m -isnot [System.Collections.IDictionary]) { $m = @{} }
        $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $src = @()
        if ($m.Contains('steps') -and $m['steps'] -is [System.Collections.IList]) { $src = $m['steps'] }
        foreach ($s in $src) {
            if ($s -isnot [System.Collections.IDictionary] -or -not $s.Contains('cmd') -or -not $s['cmd']) { continue }
            $cmd = ([string]$s['cmd']).ToUpperInvariant()
            $val = ''
            if ($s.Contains('val') -and $null -ne $s['val']) { $val = [string]$s['val'] }
            if (-not $known.ContainsKey($cmd)) {
                $val = Get-FujiText 'data.unknownCommand' $cmd $val
                $cmd = 'COMMENT'
            }
            $label = ''
            if ($s.Contains('label') -and $null -ne $s['label']) { $label = [string]$s['label'] }
            $step = [ordered]@{ cmd = $cmd; val = $val; label = $label }
            if ($cmd -eq 'GROUP_START' -and $s.Contains('when') -and ($s['when'] -eq 'first' -or $s['when'] -eq 'last')) { $step['when'] = [string]$s['when'] }
            if ($s.Contains('disabled') -and $s['disabled'] -eq $true) { $step['disabled'] = $true }
            if (-not $step.label) { $step.label = Get-FujiStepLabel -Cmd $cmd -Value $val }
            $steps.Add($step)
        }
        $id = ''
        if ($m.Contains('id') -and $m['id']) { $id = [string]$m['id'] }
        if (-not $id) { $id = New-FujiId }
        while ($used.ContainsKey($id)) { $id = New-FujiId }
        $used[$id] = $true
        $name = Get-FujiText 'data.unnamedMacro'
        if ($m.Contains('name') -and $m['name']) { $name = [string]$m['name'] }
        $target = ''
        if ($m.Contains('targetWindow') -and $m['targetWindow']) { $target = [string]$m['targetWindow'] }
        $data.macros.Add([ordered]@{ id = $id; name = $name; targetWindow = $target; steps = $steps })
    }
    return @{ Data = $data; NewerVersion = $newer }
}

# Clean data -> file text (same shape and indentation as the HTA's JSON.stringify(..., null, 2)).
# The editor's "collapsed" mark on a block start is view state and is not written.
function ConvertTo-FujiMacroJson {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $macros = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($m in $Data.macros) {
        $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($s in $m.steps) {
            if ($s.Contains('collapsed')) {
                $c = [ordered]@{}
                foreach ($k in $s.Keys) { if ($k -ne 'collapsed') { $c[$k] = $s[$k] } }
                $steps.Add($c)
            } else {
                $steps.Add($s)
            }
        }
        $macros.Add([ordered]@{ id = $m.id; name = $m.name; targetWindow = $m.targetWindow; steps = $steps })
    }
    return (ConvertTo-FujiJson -InputObject ([ordered]@{ version = $script:FujiDataVersion; macros = $macros }) -Indent 2)
}

# ----------------------------------------------------------------- block structure (same as the HTA)
function Get-FujiDepth {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Steps)
    $depths = New-Object -TypeName 'System.Collections.Generic.List[int]'
    $depth = 0
    foreach ($s in $Steps) {
        if (Test-FujiBlockEnd $s.cmd) {
            $depth = [Math]::Max(0, $depth - 1)
            $depths.Add($depth)
        } elseif (Test-FujiBlockMiddle $s.cmd) {
            $depths.Add([Math]::Max(0, $depth - 1))
        } else {
            $depths.Add($depth)
            if (Test-FujiBlockStart $s.cmd) { $depth++ }
        }
    }
    return , $depths.ToArray()
}

function Find-FujiBlockEnd {
    param([System.Collections.IList]$Steps, [int]$StartIndex)
    $depth = 0
    for ($i = $StartIndex; $i -lt $Steps.Count; $i++) {
        if (Test-FujiBlockStart $Steps[$i].cmd) { $depth++ }
        elseif (Test-FujiBlockEnd $Steps[$i].cmd) { $depth--; if ($depth -eq 0) { return $i } }
    }
    return -1
}

function Find-FujiBlockStart {
    param([System.Collections.IList]$Steps, [int]$EndIndex)
    $depth = 0
    for ($i = $EndIndex; $i -ge 0; $i--) {
        if (Test-FujiBlockEnd $Steps[$i].cmd) { $depth++ }
        elseif (Test-FujiBlockStart $Steps[$i].cmd) { $depth--; if ($depth -eq 0) { return $i } }
    }
    return -1
}

# The middle marker (ELSE / CATCH) that belongs directly to the block starting at StartIndex
function Find-FujiBlockMiddle {
    param([System.Collections.IList]$Steps, [int]$StartIndex, [string]$Cmd)
    $depth = 0
    for ($i = $StartIndex + 1; $i -lt $Steps.Count; $i++) {
        if (Test-FujiBlockStart $Steps[$i].cmd) { $depth++ }
        elseif (Test-FujiBlockEnd $Steps[$i].cmd) { if ($depth -eq 0) { return -1 }; $depth-- }
        elseif ($depth -eq 0 -and $Steps[$i].cmd -eq $Cmd) { return $i }
    }
    return -1
}

# Index of the block start that directly contains Index, or -1
function Find-FujiBlockOwner {
    param([System.Collections.IList]$Steps, [int]$Index)
    $depth = 0
    for ($i = $Index - 1; $i -ge 0; $i--) {
        if (Test-FujiBlockEnd $Steps[$i].cmd) { $depth++ }
        elseif (Test-FujiBlockStart $Steps[$i].cmd) { if ($depth -eq 0) { return $i }; $depth-- }
    }
    return -1
}

function Get-FujiBlockMiddleIndex {
    param([System.Collections.IList]$Steps, [int]$Start, [int]$End)
    $list = @()
    $depth = 0
    for ($i = $Start + 1; $i -lt $End; $i++) {
        if (Test-FujiBlockStart $Steps[$i].cmd) { $depth++ }
        elseif (Test-FujiBlockEnd $Steps[$i].cmd) { $depth-- }
        elseif ($depth -eq 0 -and (Test-FujiBlockMiddle $Steps[$i].cmd)) { $list += $i }
    }
    return , $list
}

# @{ From; To }: a block start covers its whole block
function Get-FujiBlockRange {
    param([System.Collections.IList]$Steps, [int]$Index)
    $to = $Index
    if ($Index -ge 0 -and $Index -lt $Steps.Count -and (Test-FujiBlockStart $Steps[$Index].cmd)) {
        $end = Find-FujiBlockEnd -Steps $Steps -StartIndex $Index
        if ($end -gt $Index) { $to = $end }
    }
    return @{ From = $Index; To = $to }
}

# Every block closed by its own kind of end; ELSE only directly inside an if-block, CATCH only
# directly inside a try-block, at most one each
function Test-FujiBlockBalanced {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Steps)
    $stack = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $Steps) {
        $c = $s.cmd
        if (Test-FujiBlockStart $c) {
            $stack.Add(@{ Cmd = $c; Middles = @{} })
        } elseif (Test-FujiBlockEnd $c) {
            if ($stack.Count -eq 0 -or $stack[$stack.Count - 1].Cmd -ne (Get-FujiBlockStartOf $c)) { return $false }
            $stack.RemoveAt($stack.Count - 1)
        } elseif (Test-FujiBlockMiddle $c) {
            if ($stack.Count -eq 0) { return $false }
            $top = $stack[$stack.Count - 1]
            if ($top.Cmd -ne (Get-FujiBlockOwnerOf $c) -or $top.Middles.ContainsKey($c)) { return $false }
            $top.Middles[$c] = $true
        }
    }
    return ($stack.Count -eq 0)
}

# Variables a macro defines (for the placeholder helper), "error text" always included
function Get-FujiDefinedVarName {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Steps, [string]$ErrorVarName = '')
    $names = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($ErrorVarName) { $names.Add($ErrorVarName) }
    foreach ($s in $Steps) {
        $def = Get-FujiCommandDef -Cmd $s.cmd
        if ($null -eq $def -or -not $def.Contains('definesVar')) { continue }
        $name = ([string](ConvertFrom-FujiStepValue -Cmd $s.cmd -Value $s.val)[$def['definesVar']]).Trim()
        if (-not $name -and $s.cmd -eq 'LOOP_START') { $name = [string]$def['parseDefaults']['counter'] }
        if ($name -and -not $names.Contains($name)) { $names.Add($name) }
    }
    return , $names.ToArray()
}

function Test-FujiExecutableStep {
    param([System.Collections.IDictionary]$Step)
    if ($Step.Contains('disabled') -and $Step['disabled']) { return $false }
    $c = $Step.cmd
    return -not ($c -eq 'COMMENT' -or (Test-FujiBlockStart $c) -or (Test-FujiBlockEnd $c) -or (Test-FujiBlockMiddle $c))
}
