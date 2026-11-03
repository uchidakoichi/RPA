# ---------------------------------------------------------------------------------------------
#  Recording: the recorder's event lines -> steps (the HTA's rules)
#  Lines (tab separated): S title = window came to the front, W ms = pause, C x y kind = click at,
#  N name x y = click on a named button, F name x y = click into a named text box, K keys = key
#  with Ctrl / Alt / named key, T text = typed text, J = typing through the Japanese input method
#  (not recordable as keys), G name = Tab moved the focus into a named text box.
#  A click into a named text box followed by typing becomes FIELD_SET. So does Tab into a named
#  text box followed by typing, and the Tabs that led there are dropped (no counting of Tabs).
#  A pause before a window comes to the front becomes "wait until the window appears" (WAIT_FOR),
#  so the macro goes on as soon as the window is there and still waits when the PC is slow.
#  Stats (optional) gets Tab = Tab runs replaced, Wait = pauses replaced.
# ---------------------------------------------------------------------------------------------

function ConvertFrom-FujiRecording {
    param([AllowEmptyString()][string]$Payload, [hashtable]$Stats)
    if ($null -eq $Stats) { $Stats = @{} }
    $Stats.Tab = 0
    $Stats.Wait = 0
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $lastSwitch = ''
    $waitMs = 0
    # a click into a named text box waits for what is typed next (pauses in between are kept)
    $field = $null
    foreach ($line in ([string]$Payload).Split("`n")) {
        $f = $line.TrimEnd("`r").Split("`t")
        $step = $null
        if ($null -ne $field -and $f[0] -ne 'T' -and $f[0] -ne 'W') {
            # a click into the field without typing stays a click; Tabs without typing stay as they are
            if (-not $field.Tab) { $steps.Add((New-FujiStep -Cmd 'CLICK_POS' -Value (ConvertTo-FujiStepValue -Cmd 'CLICK_POS' -Settings ([ordered]@{ x = $field.X; y = $field.Y; kind = 'LEFT' })))) }
            $field = $null
        }
        switch ($f[0]) {
            'F' {
                if ($f.Count -ge 4) { $field = @{ Name = $f[1]; X = $f[2]; Y = $f[3]; Tab = $false } }
            }
            'G' {
                if ($f.Count -ge 2 -and $f[1] -ne '' -and $steps.Count -gt 0 -and (Test-FujiTabKeyStep $steps[$steps.Count - 1])) { $field = @{ Name = $f[1]; Tab = $true } }
            }
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
                    $last = $steps.Count - 1
                    if ($last -ge 0 -and $steps[$last].cmd -eq 'WAIT' -and $waitMs -gt 0) {
                        # timeout: 3 times the recorded pause, at least 10 seconds (our own choice)
                        $timeout = [Math]::Max(10, [int][Math]::Ceiling($waitMs / 1000.0) * 3)
                        $v = ConvertTo-FujiStepValue -Cmd 'WAIT_FOR' -Settings ([ordered]@{ title = $target; key = ''; timeout = [string]$timeout })
                        $steps[$last] = New-FujiStep -Cmd 'WAIT_FOR' -Value $v
                        $Stats.Wait++
                    }
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
                if ($null -ne $field) {
                    $step = @{ cmd = 'FIELD_SET'; val = (ConvertTo-FujiStepValue -Cmd 'FIELD_SET' -Settings ([ordered]@{ name = $field.Name; text = $v; nth = '1'; how = 'AUTO' })) }
                    if ($field.Tab) { Remove-FujiTabRun -Steps $steps; $Stats.Tab++ }
                    $field = $null
                } else {
                    $step = @{ cmd = 'TEXT'; val = $v }
                }
            }
            'J' { $step = @{ cmd = 'COMMENT'; val = (Get-FujiText 'rec.imeNote') } }
        }
        if ($null -ne $step) {
            $steps.Add([ordered]@{ cmd = $step.cmd; val = $step.val; label = (Get-FujiStepLabel -Cmd $step.cmd -Value $step.val) })
        }
        $waitMs = 0
        if ($f[0] -eq 'W' -and $null -ne $step) { $waitMs = Get-FujiInt -Text $step.val -Default 0 }
    }
    if ($null -ne $field) { $steps.Add((New-FujiStep -Cmd 'CLICK_POS' -Value (ConvertTo-FujiStepValue -Cmd 'CLICK_POS' -Settings ([ordered]@{ x = $field.X; y = $field.Y; kind = 'LEFT' })))) }
    while ($steps.Count -gt 0 -and $steps[$steps.Count - 1].cmd -eq 'WAIT') { $steps.RemoveAt($steps.Count - 1) }
    return , $steps
}

function Test-FujiTabKeyStep {
    param([System.Collections.IDictionary]$Step)
    return ($Step.cmd -eq 'KEY' -and [string]$Step.val -cmatch '^\+?\{TAB( [0-9]+)?\}$')
}

# Drops the Tab keys at the end of Steps (and the pauses between them; a pause before the first
# Tab stays, it may be waiting for the screen)
function Remove-FujiTabRun {
    param([System.Collections.Generic.List[object]]$Steps)
    $from = $Steps.Count
    while ($from -gt 0 -and ((Test-FujiTabKeyStep $Steps[$from - 1]) -or $Steps[$from - 1].cmd -eq 'WAIT')) { $from-- }
    while ($from -lt $Steps.Count -and $Steps[$from].cmd -eq 'WAIT') { $from++ }
    if ($from -lt $Steps.Count) { $Steps.RemoveRange($from, $Steps.Count - $from) }
}

# Puts the recorded steps into the macro they were recorded for, as one group at At.
# Returns the number of steps (0 when nothing was recorded or the macro is gone).
function Add-FujiRecordedStep {
    param([Parameter(Mandatory)][hashtable]$Editor, [string]$MacroId, [int]$At, [AllowEmptyString()][string]$Payload)
    $stats = @{}
    $steps = ConvertFrom-FujiRecording -Payload $Payload -Stats $stats
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
    if ($stats.Tab -gt 0 -or $stats.Wait -gt 0) { Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'rec.smart' $stats.Tab $stats.Wait) -Level 'ok' }
    return $steps.Count
}
