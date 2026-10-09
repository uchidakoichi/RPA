# ---------------------------------------------------------------------------------------------
#  Commands
#  fujikyun_commands.json holds each command's display data (title, icon, help, input fields,
#  palette, key presets, condition and string operations). This file holds the logic: reading and
#  writing a step's value, checking the settings, and the automatic label.
#
#  Step value formats (fujikyun_commands.json "format"):
#    text  one setting, stored as the plain value          KEY "{TAB}", SWITCH "Notepad"
#    json  several settings, stored as a compact JSON text  WAIT_FOR {"title":"..","key":"..","timeout":"30"}
#    none  block markers without settings                   LOOP_END, ELSE, ...
# ---------------------------------------------------------------------------------------------

$script:FujiCommands = $null
$script:FujiBlockEnds = @{}

function Import-FujiCommand {
    param([Parameter(Mandatory)][string]$Path)
    $script:FujiCommands = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $Path)
    $script:FujiBlockEnds = @{}
    foreach ($start in $script:FujiCommands['blocks']['pairs'].Keys) {
        $script:FujiBlockEnds[$script:FujiCommands['blocks']['pairs'][$start]] = $start
    }
}

function Get-FujiCommandDef {
    param([Parameter(Mandatory)][string]$Cmd)
    if ($script:FujiCommands['commands'].Contains($Cmd)) { return $script:FujiCommands['commands'][$Cmd] }
    return $null
}

function Get-FujiCommandName {
    return @($script:FujiCommands['commands'].Keys)
}

# ----------------------------------------------------------------- blocks
function Test-FujiBlockStart { param([string]$Cmd) return $script:FujiCommands['blocks']['pairs'].Contains($Cmd) }
function Test-FujiBlockEnd { param([string]$Cmd) return $script:FujiBlockEnds.ContainsKey($Cmd) }
function Test-FujiBlockMiddle { param([string]$Cmd) return $script:FujiCommands['blocks']['middles'].Contains($Cmd) }
function Get-FujiBlockEndOf { param([string]$Cmd) return $script:FujiCommands['blocks']['pairs'][$Cmd] }
function Get-FujiBlockStartOf { param([string]$Cmd) return $script:FujiBlockEnds[$Cmd] }
function Get-FujiBlockOwnerOf { param([string]$Cmd) return $script:FujiCommands['blocks']['middles'][$Cmd] }

# ----------------------------------------------------------------- small helpers
# The HTA's truncateText: line breaks shown as one mark, long text cut with an ellipsis
function Format-FujiShort {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max)
    $s = [regex]::Replace([string]$Text, '\r\n|\r|\n', (Get-FujiText 'label.newline'))
    if ($s.Length -gt $Max) { return $s.Substring(0, $Max) + (Get-FujiText 'label.ellipsis') }
    return $s
}

# 'x {name} y' with @{ name = 'v' }; unknown names stay as written
function Format-FujiTemplate {
    param([Parameter(Mandatory)][string]$Template, [hashtable]$Values = @{})
    $sb = New-Object -TypeName System.Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($Template, '\{(\w+)\}')) {
        [void]$sb.Append($Template, $last, $m.Index - $last)
        $k = $m.Groups[1].Value
        if ($Values.ContainsKey($k)) { [void]$sb.Append([string]$Values[$k]) } else { [void]$sb.Append($m.Value) }
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Template, $last, $Template.Length - $last)
    return $sb.ToString()
}

function Get-FujiLabelText {
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Values = @{})
    return Format-FujiTemplate -Template (Get-FujiText ('label.' + $Key)) -Values $Values
}

function Get-FujiKeyName {
    param([AllowEmptyString()][string]$Key)
    foreach ($p in $script:FujiCommands['keyPresets']) {
        if ([string]::Equals([string]$p[0], $Key, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$p[1] }
    }
    return $Key
}

function Get-FujiStrOpName {
    param([string]$Op)
    foreach ($o in $script:FujiCommands['strOps']) {
        # The option text is "name<full-width colon>explanation"
        if ($o[0] -eq $Op) { return ([string]$o[1]).Split([char]0xFF1A)[0] }
    }
    return $Op
}

function Test-FujiConditionNeedsLeft { param([string]$Op) return ($Op -ne 'EMPTY' -and $Op -ne 'NOT_EMPTY') }

function Get-FujiConditionText {
    param([System.Collections.IDictionary]$Condition)
    $left = Get-FujiLabelText 'condLeft' @{ left = (Format-FujiShort $Condition['left'] 20) }
    $unary = (Get-FujiText 'label.condUnary').PSObject.Properties[[string]$Condition['op']]
    if ($null -ne $unary) { return $left + [string]$unary.Value }
    $binary = (Get-FujiText 'label.condBinary').PSObject.Properties[[string]$Condition['op']]
    $tail = (Get-FujiText 'label.condBinary').EQ
    if ($null -ne $binary) { $tail = [string]$binary.Value }
    return $left + (Get-FujiLabelText 'condRight' @{ right = (Format-FujiShort $Condition['right'] 20) }) + $tail
}

function Get-FujiOcrAreaText {
    param([System.Collections.IDictionary]$Settings)
    switch ([string]$Settings['area']) {
        'FULL' { return (Get-FujiText 'label.areaFull') }
        'RECT' { return (Get-FujiLabelText 'areaRect' @{ x = $Settings['x']; y = $Settings['y']; w = $Settings['w']; h = $Settings['h'] }) }
        default { return (Get-FujiText 'label.areaWindow') }
    }
}

function Get-FujiFileName { param([AllowEmptyString()][string]$Path) return ($Path -replace '^.*[\\/]', '') }

# ----------------------------------------------------------------- value <-> settings
function Get-FujiValueFieldId {
    param([System.Collections.IDictionary]$Def)
    $ids = @()
    foreach ($f in $Def['fields']) {
        if (-not $f.Contains('prop') -and $f['type'] -ne 'capture' -and $f['type'] -ne 'rectcapture') { $ids += [string]$f['id'] }
    }
    return , $ids
}

# Step value -> ordered settings (every value a string; missing JSON keys get their defaults)
function ConvertFrom-FujiStepValue {
    param([Parameter(Mandatory)][string]$Cmd, [AllowNull()][AllowEmptyString()][string]$Value)
    $def = Get-FujiCommandDef -Cmd $Cmd
    $settings = [ordered]@{}
    if ($null -eq $def -or $def['format'] -eq 'none') { return $settings }
    if ($def['format'] -eq 'text') {
        $ids = Get-FujiValueFieldId -Def $def
        $settings[$ids[0]] = [string]$Value
        return $settings
    }
    $parsed = $null
    try { $parsed = ConvertFrom-FujiJson -Json ([string]$Value) } catch { $parsed = $null }
    if ($parsed -isnot [System.Collections.IDictionary]) { $parsed = @{} }
    foreach ($k in $def['parseDefaults'].Keys) {
        if ($parsed.Contains($k) -and $null -ne $parsed[$k]) { $settings[$k] = [string]$parsed[$k] } else { $settings[$k] = [string]$def['parseDefaults'][$k] }
    }
    switch ($Cmd) {
        'WINDOW_CHECK' { $settings['mode'] = Get-FujiCheckMode $settings['mode'] }
        'CLICK_POS' { if ($settings['kind'] -ne 'DOUBLE' -and $settings['kind'] -ne 'RIGHT') { $settings['kind'] = 'LEFT' } }
        'SCREENSHOT' { if ($settings['scope'] -ne 'FULL') { $settings['scope'] = 'WINDOW' } }
    }
    return $settings
}

function Get-FujiCheckMode {
    param([AllowEmptyString()][string]$Mode)
    $m = ([string]$Mode).ToUpperInvariant()
    if ($m -eq 'SKIP' -or $m -eq 'CONTINUE') { return $m }
    return 'STOP'
}

function Get-FujiThreshold {
    param([AllowEmptyString()][string]$Text)
    $n = 0.0
    if (-not [double]::TryParse(([string]$Text).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return 0.9 }
    return [Math]::Min(1.0, [Math]::Max(0.5, $n))
}

# Settings -> step value. MacroName: the called macro's current name (CALL_MACRO keeps both)
function ConvertTo-FujiStepValue {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [string]$MacroName = '')
    $def = Get-FujiCommandDef -Cmd $Cmd
    if ($null -eq $def -or $def['format'] -eq 'none') { return '' }
    $v = [ordered]@{}
    foreach ($k in $Settings.Keys) { $v[$k] = [string]$Settings[$k] }
    switch ($Cmd) {
        'CSV' { return [string](Get-FujiInt -Text $v['col'] -Default 1) }
        'WAIT' { return [string](Get-FujiInt -Text $v['ms'] -Default 0) }
        'WAIT_FOR' { $v['timeout'] = [string](Get-FujiInt -Text $v['timeout'] -Default 30) }
        'WINDOW_CHECK' { $v['mode'] = Get-FujiCheckMode $v['mode'] }
        'CLICK_POS' {
            $v['x'] = [string](Get-FujiInt -Text $v['x'] -Default 0)
            $v['y'] = [string](Get-FujiInt -Text $v['y'] -Default 0)
            if ($v['kind'] -ne 'DOUBLE' -and $v['kind'] -ne 'RIGHT') { $v['kind'] = 'LEFT' }
        }
        'CLICK_IMG' { $v['threshold'] = (Get-FujiThreshold $v['threshold']).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
        'SCREENSHOT' { if ($v['scope'] -ne 'FULL') { $v['scope'] = 'WINDOW' } }
        'CALL_MACRO' { $v['name'] = $MacroName }
    }
    if ($def['format'] -eq 'text') {
        $ids = Get-FujiValueFieldId -Def $def
        return [string]$v[$ids[0]]
    }
    $out = [ordered]@{}
    foreach ($k in $def['parseDefaults'].Keys) {
        if ($v.Contains($k)) { $out[$k] = $v[$k] } else { $out[$k] = [string]$def['parseDefaults'][$k] }
    }
    return (ConvertTo-FujiJson -InputObject $out -Indent 0)
}

# ----------------------------------------------------------------- checking the settings
function Get-FujiVarNameError {
    param([AllowEmptyString()][string]$Name)
    $n = ([string]$Name).Trim()
    if ($n -eq '') { return (Get-FujiText 'validate.varEmpty') }
    if ($n -match '[\s{}:,$]') { return (Get-FujiText 'validate.varBad') }
    return ''
}

function Get-FujiRectError {
    param([System.Collections.IDictionary]$S)
    if ($S['area'] -ne 'RECT') { return '' }
    foreach ($k in @('x', 'y', 'w', 'h')) {
        if ((ConvertTo-FujiHalfWidthDigit -Text ([string]$S[$k]).Trim()) -notmatch '^-?[0-9]+$') { return (Get-FujiText 'validate.rect') }
    }
    if ((Get-FujiInt $S['w'] 0) -lt 4 -or (Get-FujiInt $S['h'] 0) -lt 4) { return (Get-FujiText 'validate.rectSize') }
    return ''
}

function Test-FujiPositiveInt {
    param([AllowEmptyString()][string]$Text, [int]$Min = 1)
    $t = (ConvertTo-FujiHalfWidthDigit -Text ([string]$Text).Trim())
    return ($t -match '^[0-9]+$' -and [long]$t -ge $Min)
}

# Settings as entered (already trimmed except raw fields) -> error message, or '' when fine
function Test-FujiStepSetting {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $s = $Settings
    switch ($Cmd) {
        'KEY' { if ($s['key'] -eq '') { return (Get-FujiText 'validate.key') } }
        'TEXT' { if ($s['text'] -eq '') { return (Get-FujiText 'validate.text') } }
        'CSV' { if (-not (Test-FujiPositiveInt $s['col'] 1)) { return (Get-FujiText 'validate.csvCol') } }
        'COPY' { return (Get-FujiVarNameError $s['name']) }
        'WAIT' { if (-not (Test-FujiPositiveInt $s['ms'] 0)) { return (Get-FujiText 'validate.waitMs') } }
        'WAIT_FOR' {
            if ($s['title'] -eq '') { return (Get-FujiText 'validate.waitTitle') }
            if (-not (Test-FujiPositiveInt $s['timeout'] 1)) { return (Get-FujiText 'validate.timeout') }
        }
        'WINDOW_CHECK' { if ($s['title'] -eq '') { return (Get-FujiText 'validate.checkTitle') } }
        'CONFIRM' { if (([string]$s['message']).Trim() -eq '') { return (Get-FujiText 'validate.message') } }
        'CLICK_NAME' { if ($s['name'] -eq '') { return (Get-FujiText 'validate.clickName') } }
        'CLICK_POS' { if ($s['x'] -notmatch '^-?[0-9]+$' -or $s['y'] -notmatch '^-?[0-9]+$') { return (Get-FujiText 'validate.xy') } }
        'CLICK_IMG' {
            if ($s['path'] -eq '') { return (Get-FujiText 'validate.imgPath') }
            $n = 0.0
            $ok = $s['threshold'] -match '^[0-9]*\.?[0-9]+$' -and [double]::TryParse($s['threshold'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
            if (-not $ok -or $n -lt 0.5 -or $n -gt 1) { return (Get-FujiText 'validate.threshold') }
        }
        'CLICK_TEXT' {
            if (([string]$s['text']).Trim() -eq '') { return (Get-FujiText 'validate.findText') }
            $nth = [string]$s['nth']
            if ($nth -eq '') { $nth = '1' }
            if (-not (Test-FujiPositiveInt $nth 1)) { return (Get-FujiText 'validate.nth') }
            return (Get-FujiRectError $s)
        }
        'READ_TEXT' {
            $e = Get-FujiRectError $s
            if ($e) { return $e }
            return (Get-FujiVarNameError $s['name'])
        }
        'SWITCH' { if ($s['title'] -eq '') { return (Get-FujiText 'validate.switchTitle') } }
        'RUN' { if ($s['path'] -eq '') { return (Get-FujiText 'validate.runPath') } }
        'SCREENSHOT' { if ($s['name'] -eq '') { return (Get-FujiText 'validate.fileName') } }
        'MAIL' { if (([string]$s['to']).Trim() -eq '') { return (Get-FujiText 'validate.mailTo') } }
        'LOOP_START' {
            if ($s['mode'] -eq 'COUNT' -and ([string]$s['count']).Trim() -eq '') { return (Get-FujiText 'validate.count') }
            if ($s['mode'] -eq 'WHILE' -and (Test-FujiConditionNeedsLeft $s['op']) -and ([string]$s['left']).Trim() -eq '') { return (Get-FujiText 'validate.left') }
            if (-not (Test-FujiPositiveInt $s['max'] 1)) { return (Get-FujiText 'validate.max') }
            return (Get-FujiVarNameError $s['counter'])
        }
        'IF_START' { if ((Test-FujiConditionNeedsLeft $s['op']) -and ([string]$s['left']).Trim() -eq '') { return (Get-FujiText 'validate.left') } }
        'TRY_START' { if ($s['name'] -eq '') { return (Get-FujiText 'validate.tryName') } }
        'CALL_MACRO' { if ($s['id'] -eq '') { return (Get-FujiText 'validate.macro') } }
        'SET_VAR' { return (Get-FujiVarNameError $s['name']) }
        'STR_OP' {
            $e = Get-FujiVarNameError $s['name']
            if ($e) { return $e }
            if (($s['op'] -eq 'REGEX_REPLACE' -or $s['op'] -eq 'REGEX_EXTRACT') -and $s['a'] -ne '' -and $s['a'] -notmatch '\{\{') {
                try { [void][regex]::new($s['a']) } catch { return (Get-FujiText 'validate.regex' $_.Exception.InnerException.Message) }
            }
        }
        'ASK' { return (Get-FujiVarNameError $s['name']) }
        'RECORD' { return (Get-FujiVarNameError $s['name']) }
        'EXCEL_READ' {
            if (([string]$s['path']).Trim() -eq '') { return (Get-FujiText 'validate.bookPath') }
            if (([string]$s['cell']).Trim() -eq '') { return (Get-FujiText 'validate.cell') }
            return (Get-FujiVarNameError $s['name'])
        }
        'EXCEL_WRITE' {
            if (([string]$s['path']).Trim() -eq '') { return (Get-FujiText 'validate.bookPath') }
            if (([string]$s['cell']).Trim() -eq '') { return (Get-FujiText 'validate.cell') }
        }
        'GROUP_START' { if ($s['name'] -eq '') { return (Get-FujiText 'validate.groupName') } }
        'COMMENT' { if ($s['memo'] -eq '') { return (Get-FujiText 'validate.memo') } }
    }
    return ''
}

# ----------------------------------------------------------------- automatic label
# MacroNameOf: scriptblock { param($Id) ... } giving a macro's current name (CALL_MACRO)
function Get-FujiStepLabel {
    param([Parameter(Mandatory)][string]$Cmd, [AllowNull()][AllowEmptyString()][string]$Value, [scriptblock]$MacroNameOf = $null)
    $def = Get-FujiCommandDef -Cmd $Cmd
    if ($null -eq $def) { return [string]$Value }
    if ($def['format'] -eq 'none') { return [string]$def['title'] }
    $val = [string]$Value
    $p = ConvertFrom-FujiStepValue -Cmd $Cmd -Value $val
    switch ($Cmd) {
        'KEY' {
            $name = Get-FujiKeyName $val
            if ($name -eq $val) { return (Get-FujiLabelText 'key' @{ key = $val }) }
            return $name
        }
        'TEXT' { return (Get-FujiLabelText 'text' @{ text = (Format-FujiShort $val 20) }) }
        'CSV' {
            $name = ''
            if ($script:FujiCsvHeaderNameOf) { $name = & $script:FujiCsvHeaderNameOf (Get-FujiInt $val 0) }
            $nameText = ''
            if ($name) { $nameText = Get-FujiLabelText 'csvName' @{ name = $name } }
            return (Get-FujiLabelText 'csv' @{ col = $val; name = $nameText })
        }
        'COPY' { return (Get-FujiLabelText 'copy' @{ name = $val }) }
        'WAIT' { return (Get-FujiLabelText 'wait' @{ ms = $val }) }
        'WAIT_FOR' {
            $key = ''
            if ($p['key']) { $key = Get-FujiLabelText 'waitForKey' @{ key = (Get-FujiKeyName $p['key']) } }
            return (Get-FujiLabelText 'waitFor' @{ title = $p['title']; timeout = $p['timeout'] }) + $key
        }
        'WINDOW_CHECK' {
            $key = ''
            if ($p['key']) { $key = Get-FujiLabelText 'checkKey' @{ key = (Get-FujiKeyName $p['key']) } }
            $action = Get-FujiText 'label.checkStop'
            if ($p['mode'] -eq 'SKIP') { $action = Get-FujiText 'label.checkSkip' } elseif ($p['mode'] -eq 'CONTINUE') { $action = Get-FujiText 'label.checkContinue' }
            return (Get-FujiLabelText 'check' @{ title = $p['title']; key = $key; action = $action })
        }
        'CONFIRM' { return (Get-FujiLabelText 'confirm' @{ message = (Format-FujiShort $val 30) }) }
        'CLICK_NAME' { return (Get-FujiLabelText 'clickName' @{ name = $val }) }
        'CLICK_POS' {
            $kind = Get-FujiText 'label.posLeft'
            if ($p['kind'] -eq 'DOUBLE') { $kind = Get-FujiText 'label.posDouble' } elseif ($p['kind'] -eq 'RIGHT') { $kind = Get-FujiText 'label.posRight' }
            return (Get-FujiLabelText 'clickPos' @{ x = $p['x']; y = $p['y']; kind = $kind })
        }
        'CLICK_IMG' {
            $file = Get-FujiFileName $p['path']
            if (-not $file) { $file = Get-FujiText 'label.noFile' }
            $percent = [int][Math]::Round((Get-FujiThreshold $p['threshold']) * 100, [System.MidpointRounding]::AwayFromZero)
            return (Get-FujiLabelText 'clickImg' @{ file = $file; percent = $percent })
        }
        'CLICK_TEXT' { return (Get-FujiLabelText 'clickText' @{ text = (Format-FujiShort $p['text'] 20); area = (Get-FujiOcrAreaText $p) }) }
        'READ_TEXT' { return (Get-FujiLabelText 'readText' @{ area = (Get-FujiOcrAreaText $p); name = $p['name'] }) }
        'SWITCH' { return (Get-FujiLabelText 'switch' @{ title = $val }) }
        'RUN' { return (Get-FujiLabelText 'run' @{ path = (Format-FujiShort $val 30) }) }
        'SCREENSHOT' {
            $scope = Get-FujiText 'label.shotWindow'
            if ($p['scope'] -eq 'FULL') { $scope = Get-FujiText 'label.shotFull' }
            return (Get-FujiLabelText 'screenshot' @{ name = (Format-FujiShort $p['name'] 20); scope = $scope })
        }
        'MAIL' {
            $how = Get-FujiText 'label.mailDraft'
            if ($p['method'] -eq 'MAILTO') { $how = Get-FujiText 'label.mailTo' }
            elseif ($p['mode'] -eq 'SEND') { $how = Get-FujiText 'label.mailSend' }
            elseif ($p['mode'] -eq 'DISPLAY') { $how = Get-FujiText 'label.mailDisplay' }
            return (Get-FujiLabelText 'mail' @{ to = (Format-FujiShort $p['to'] 24); subject = (Format-FujiShort $p['subject'] 20); how = $how })
        }
        'LOOP_START' {
            if ($p['mode'] -eq 'WHILE') { return (Get-FujiLabelText 'loopWhile' @{ cond = (Get-FujiConditionText $p) }) }
            return (Get-FujiLabelText 'loopCount' @{ count = $p['count'] })
        }
        'IF_START' { return (Get-FujiLabelText 'if' @{ cond = (Get-FujiConditionText $p) }) }
        'TRY_START' { return (Get-FujiLabelText 'try' @{ name = $val }) }
        'CALL_MACRO' {
            $name = ''
            if ($MacroNameOf) { $name = [string](& $MacroNameOf $p['id']) }
            if (-not $name) { $name = $p['name'] }
            if (-not $name) { $name = '?' }
            return (Get-FujiLabelText 'call' @{ name = $name })
        }
        'SET_VAR' {
            $calc = ''
            if ($p['mode'] -eq 'CALC') { $calc = Get-FujiText 'label.setVarCalc' }
            return (Get-FujiLabelText 'setVar' @{ name = $p['name']; value = (Format-FujiShort $p['value'] 30); calc = $calc })
        }
        'STR_OP' { return (Get-FujiLabelText 'strOp' @{ name = $p['name']; src = (Format-FujiShort $p['src'] 20); op = (Get-FujiStrOpName $p['op']) }) }
        'ASK' { return (Get-FujiLabelText 'ask' @{ name = $p['name'] }) }
        'RECORD' { return (Get-FujiLabelText 'record' @{ name = $p['name']; value = (Format-FujiShort $p['value'] 30) }) }
        'EXCEL_READ' { return (Get-FujiLabelText 'excelRead' @{ file = (Get-FujiFileName $p['path']); cell = $p['cell']; name = $p['name'] }) }
        'EXCEL_WRITE' { return (Get-FujiLabelText 'excelWrite' @{ file = (Get-FujiFileName $p['path']); cell = $p['cell']; value = (Format-FujiShort $p['value'] 20) }) }
        'GROUP_START' { return $val }
        'COMMENT' { return (Format-FujiShort $val 40) }
    }
    return $val
}

# Set by the editor: { param($Column) ... } giving the loaded CSV's header name for a column number
$script:FujiCsvHeaderNameOf = $null
