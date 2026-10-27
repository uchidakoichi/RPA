# ---------------------------------------------------------------------------------------------
#  Check before a run: what would stop it or go wrong, found without running it
#  The macro and every macro it calls are looked at (disabled steps and blocks are left out).
#  Each problem: @{ MacroId; Macro; Index (-1: the macro as a whole); Level; Message }
#    error  the step will fail when it is reached (a setting missing, a called macro or image gone)
#    warn   it may not do what was meant (a variable never set, a CSV column the CSV lacks,
#           a file or folder this PC does not have)
#    note   worth knowing, not a fault (a breakpoint left in)
# ---------------------------------------------------------------------------------------------

# Macros: every macro (for CALL_MACRO). Header: the loaded CSV's heading or $null. Columns: how many
# columns the loaded CSV has, -1 when none is loaded. ResolvePath: as the run resolves image paths.
# PathExists: { param($Path, $Folder) } (a stand-in in tests).
function Get-FujiMacroProblem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Macros, [Parameter(Mandatory)][System.Collections.IDictionary]$Macro,
        [string]$Directory = '', [scriptblock]$ResolvePath = $null, [string[]]$Header = $null, [int]$Columns = -1, [scriptblock]$PathExists = $null)
    if ($null -eq $PathExists) { $PathExists = { param($Path, $Folder) if ($Folder) { return [System.IO.Directory]::Exists($Path) }; return [System.IO.File]::Exists($Path) } }
    $problems = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $uses = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $defined = @{}
    foreach ($k in @('data.errorVar', 'data.retryVar', 'data.triggerFileVar', 'data.triggerWindowVar')) { $defined[(Get-FujiText $k)] = $true }
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
    $seen = @{}
    $queue.Enqueue($Macro)
    $seen[[string]$Macro.id] = $true
    while ($queue.Count -gt 0) {
        $m = $queue.Dequeue()
        $add = { param($Index, $Level, $Message) $problems.Add(@{ MacroId = [string]$m.id; Macro = [string]$m.name; Index = $Index; Level = $Level; Message = $Message }) }
        $steps = $m.steps
        if (-not (Test-FujiBlockBalanced -Steps $steps)) { & $add -1 'error' (Get-FujiText 'check.unbalanced') }
        foreach ($n in (Get-FujiDefinedVarName -Steps $steps)) { $defined[$n] = $true }
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $s = $steps[$i]
            $cmd = [string]$s.cmd
            if ($s.Contains('disabled') -and $s['disabled']) {
                # a disabled block start leaves out its whole block
                if (Test-FujiBlockStart $cmd) { $end = Find-FujiBlockEnd -Steps $steps -StartIndex $i; if ($end -gt $i) { $i = $end } }
                continue
            }
            $def = Get-FujiCommandDef -Cmd $cmd
            if ($null -eq $def -or $cmd -eq 'COMMENT' -or $def['format'] -eq 'none') { continue }
            if ($s.Contains('breakpoint') -and $s['breakpoint']) { & $add $i 'note' (Get-FujiText 'check.breakpoint') }
            $p = ConvertFrom-FujiStepValue -Cmd $cmd -Value ([string]$s.val)
            if ($cmd -ne 'CALL_MACRO') {
                $err = Test-FujiStepSetting -Cmd $cmd -Settings $p
                if ($err) { & $add $i 'error' (Get-FujiText 'check.setting' $err) }
            }
            switch ($cmd) {
                'CALL_MACRO' {
                    $target = $null
                    foreach ($x in $Macros) { if ($p['id'] -and [string]$x.id -eq $p['id']) { $target = $x; break } }
                    if ($null -eq $target) { foreach ($x in $Macros) { if ($p['name'] -and [string]$x.name -eq $p['name']) { $target = $x; break } } }
                    if ($null -eq $target) {
                        $shown = [string]$p['name']
                        if (-not $shown) { $shown = [string]$p['id'] }
                        & $add $i 'error' (Get-FujiText 'check.callMissing' $shown)
                    } elseif (-not $seen.ContainsKey([string]$target.id)) {
                        $seen[[string]$target.id] = $true
                        $queue.Enqueue($target)
                    }
                }
                'CLICK_IMG' {
                    $path = [string]$p['path']
                    if ($ResolvePath) { $path = [string](& $ResolvePath $path) }
                    if ($path -and -not (& $PathExists $path $false)) { & $add $i 'error' (Get-FujiText 'check.imageMissing' $path) }
                }
                'CSV' {
                    $col = Get-FujiInt -Text $s.val -Default 0
                    if ($Columns -ge 0 -and $col -gt $Columns) { & $add $i 'warn' (Get-FujiText 'check.csvColumn' $col $Columns) }
                }
                { $_ -in @('EXCEL_READ', 'EXCEL_WRITE') } { Test-FujiCheckPath -Path $p['path'] -Folder $false -Index $i -Add $add -PathExists $PathExists }
                'MAIL' { foreach ($a in (Split-FujiPathList ([string]$p['attach']))) { Test-FujiCheckPath -Path $a -Folder $false -Index $i -Add $add -PathExists $PathExists } }
                'FILE_OP' {
                    $src = ([string]$p['src']).Trim().Trim('"')
                    if ($src -and $src -notmatch '\{\{') {
                        if (-not [System.IO.Path]::IsPathRooted($src) -and $Directory) { $src = Join-Path $Directory $src }
                        Test-FujiCheckPath -Path ([System.IO.Path]::GetDirectoryName($src)) -Folder $true -Index $i -Add $add -PathExists $PathExists
                    }
                }
            }
            # placeholders in the fields that take them
            $texts = @()
            if ($def['format'] -eq 'text') {
                if (Test-FujiExpandValue $def) { $texts = @([string]$s.val) }
            } else {
                foreach ($f in $def['fields']) { if ($f.Contains('placeholders') -and $f['placeholders'] -and $p.Contains([string]$f['id'])) { $texts += [string]$p[[string]$f['id']] } }
            }
            foreach ($t in $texts) {
                foreach ($pm in $script:FujiPlaceholder.Matches($t)) {
                    $key = $pm.Groups[1].Value.Trim()
                    if ($key.StartsWith('$')) { $uses.Add(@{ MacroId = [string]$m.id; Macro = [string]$m.name; Index = $i; Name = $key.Substring(1).Trim() }); continue }
                    if ($key -match '^[0-9]+$') {
                        if ($Columns -ge 0 -and [int]$key -gt $Columns) { & $add $i 'warn' (Get-FujiText 'check.csvColumn' $key $Columns) }
                        continue
                    }
                    # a name: a built-in one, or a heading of the loaded CSV (unknown while no CSV is loaded)
                    if ($Columns -lt 0) { if ($null -eq (Get-FujiPlaceholderValue -Key $key -Context @{})) { & $add $i 'note' (Get-FujiText 'check.nameNoCsv' $pm.Value) }; continue }
                    $context = @{ Header = $Header; Row = @{ No = 1; Data = [string[]]@() } }
                    if ($null -eq (Get-FujiPlaceholderValue -Key $key -Context $context)) { & $add $i 'warn' (Get-FujiText 'check.unknownName' $pm.Value) }
                }
            }
        }
    }
    # variables: set anywhere in the macros run (the order is not followed: a loop may set it later)
    $told = @{}
    foreach ($u in $uses) {
        if ($defined.ContainsKey($u.Name)) { continue }
        $k = $u.MacroId + '|' + [string]$u.Index + '|' + $u.Name
        if ($told.ContainsKey($k)) { continue }
        $told[$k] = $true
        $problems.Add(@{ MacroId = $u.MacroId; Macro = $u.Macro; Index = $u.Index; Level = 'warn'; Message = (Get-FujiText 'check.varNeverSet' $u.Name) })
    }
    return , $problems.ToArray()
}

# A path typed in a step (no placeholder in it): warn when this PC does not have it
function Test-FujiCheckPath {
    param([AllowEmptyString()][string]$Path, [bool]$Folder, [int]$Index, [scriptblock]$Add, [scriptblock]$PathExists)
    $t = ([string]$Path).Trim().Trim('"')
    if (-not $t -or $t -match '\{\{' -or -not [System.IO.Path]::IsPathRooted($t)) { return }
    if (& $PathExists $t $Folder) { return }
    $key = 'check.fileMissing'
    if ($Folder) { $key = 'check.folderMissing' }
    & $Add $Index 'warn' (Get-FujiText $key $t)
}

# Errors and warnings (the problems that ask before a run), notes left out
function Select-FujiSeriousProblem {
    param([AllowEmptyCollection()][object[]]$Problems)
    return , @($Problems | Where-Object { $_.Level -ne 'note' })
}
