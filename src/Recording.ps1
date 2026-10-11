# ---------------------------------------------------------------------------------------------
#  Recording: the recorder's event lines -> steps (the HTA's rules)
#  Lines (tab separated): S title = window came to the front, W ms = pause, C x y kind = click at,
#  N name x y = click on a named button, K keys = key with Ctrl / Alt / named key, T text = typed
#  text, J = typing through the Japanese input method (not recordable as keys)
# ---------------------------------------------------------------------------------------------

function ConvertFrom-FujiRecording {
    param([AllowEmptyString()][string]$Payload)
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $lastSwitch = ''
    foreach ($line in ([string]$Payload).Split("`n")) {
        $f = $line.TrimEnd("`r").Split("`t")
        $step = $null
        switch ($f[0]) {
            'S' {
                if ($f.Count -lt 2) { break }
                $title = $f[1].Trim()
                # "document - App" -> "App": the document part changes, the app name does not
                $parts = $title -split ' - '
                $target = $title
                if ($parts.Count -gt 1) { $target = $parts[$parts.Count - 1].Trim() }
                if ($target -ne '' -and $target -ne $lastSwitch) {
                    $step = @{ cmd = 'SWITCH'; val = $target }
                    $lastSwitch = $target
                }
            }
            'W' { if ($f.Count -ge 2) { $step = @{ cmd = 'WAIT'; val = [string](Get-FujiInt -Text $f[1] -Default 1000) } } }
            'C' {
                if ($f.Count -ge 3) {
                    $kind = 'LEFT'
                    if ($f.Count -ge 4 -and $f[3]) { $kind = $f[3] }
                    $step = @{ cmd = 'CLICK_POS'; val = (ConvertTo-FujiStepValue -Cmd 'CLICK_POS' -Settings ([ordered]@{ x = $f[1]; y = $f[2]; kind = $kind })) }
                }
            }
            'N' { if ($f.Count -ge 2) { $step = @{ cmd = 'CLICK_NAME'; val = $f[1] } } }
            'K' {
                if ($f.Count -lt 2) { break }
                # {TAB}{TAB} -> {TAB 2}
                if ($steps.Count -gt 0 -and $steps[$steps.Count - 1].cmd -eq 'KEY') {
                    $prev = $steps[$steps.Count - 1]
                    $m = [regex]::Match($prev.val, '^(\{[A-Z0-9]+)( ([0-9]+))?\}$')
                    if ($m.Success -and $f[1] -ceq ($m.Groups[1].Value + '}')) {
                        $n = 1
                        if ($m.Groups[3].Success) { $n = [int]$m.Groups[3].Value }
                        $prev.val = $m.Groups[1].Value + ' ' + ($n + 1) + '}'
                        $prev.label = Get-FujiStepLabel -Cmd 'KEY' -Value $prev.val
                        break
                    }
                }
                $step = @{ cmd = 'KEY'; val = $f[1] }
            }
            'T' {
                $v = ''
                if ($f.Count -ge 2) { $v = $f[1] }
                $step = @{ cmd = 'TEXT'; val = $v }
            }
            'J' { $step = @{ cmd = 'COMMENT'; val = (Get-FujiText 'rec.imeNote') } }
        }
        if ($null -ne $step) {
            $steps.Add([ordered]@{ cmd = $step.cmd; val = $step.val; label = (Get-FujiStepLabel -Cmd $step.cmd -Value $step.val) })
        }
    }
    while ($steps.Count -gt 0 -and $steps[$steps.Count - 1].cmd -eq 'WAIT') { $steps.RemoveAt($steps.Count - 1) }
    return , $steps
}

# Puts the recorded steps into the macro they were recorded for, as one group at At.
# Returns the number of steps (0 when nothing was recorded or the macro is gone).
function Add-FujiRecordedStep {
    param([Parameter(Mandatory)][hashtable]$Editor, [string]$MacroId, [int]$At, [AllowEmptyString()][string]$Payload)
    $steps = ConvertFrom-FujiRecording -Payload $Payload
    if ($steps.Count -eq 0) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'rec.nothing') -Level 'warn'
        return 0
    }
    $index = -1
    for ($i = 0; $i -lt $Editor.Data.macros.Count; $i++) { if ($Editor.Data.macros[$i].id -eq $MacroId) { $index = $i } }
    if ($index -lt 0) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'rec.macroGone') -Level 'error'
        return 0
    }
    $Editor.MacroIndex = $index
    $target = Get-FujiCurrentStepList $Editor
    $at = [Math]::Min([Math]::Max(0, $At), $target.Count)
    $name = Get-FujiText 'rec.groupName' (Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
    $block = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $block.Add([ordered]@{ cmd = 'GROUP_START'; val = $name; label = (Get-FujiStepLabel -Cmd 'GROUP_START' -Value $name) })
    $block.AddRange($steps)
    $block.Add([ordered]@{ cmd = 'GROUP_END'; val = ''; label = [string](Get-FujiCommandDef 'GROUP_END')['title'] })
    $target.InsertRange($at, $block)
    $Editor.Selected = $at
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'rec.history' $steps.Count)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'rec.done' $steps.Count) -Level 'ok'
    return $steps.Count
}
