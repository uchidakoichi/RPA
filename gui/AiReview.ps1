# ---------------------------------------------------------------------------------------------
#  AI review window: the review list of the current macro, unsure answers first (lowest probability),
#  then spot checks, then the ones already checked. Number keys pick an option, Enter checks the
#  item and goes to the next. A checked answer is remembered (fujikyun_ai_answers.json), so the same
#  text is not asked again, and is shown to the AI as an example for similar texts. The checked rows
#  can be run again from a CSV of those rows only.
# ---------------------------------------------------------------------------------------------

function Show-FujiAiReviewDialog {
    $macro = Get-FujiCurrentMacro $script:Ed
    if ($null -eq $macro) { return }
    $width = Get-FujiScaled 820
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.aiReviewTitle' $macro.name) -Width $width -Height (Get-FujiScaled 640)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
    $top = New-FujiFlow
    $days = New-FujiComboBox -Items @((Get-FujiText 'gui.aiReviewDays' 1), (Get-FujiText 'gui.aiReviewDays' 7), (Get-FujiText 'gui.aiReviewDays' 30)) -Values @(1, 7, 30) -Width (Get-FujiScaled 110)
    $days.SelectedIndex = 0
    $count = New-FujiLabel -Text ''
    [void]$top.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiReviewDaysLabel')))
    [void]$top.Controls.Add($days)
    [void]$top.Controls.Add($count)
    [void]$layout.Controls.Add($top)
    $list = New-Object -TypeName System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.MultiSelect = $false
    $list.Width = $width - (Get-FujiScaled 30)
    $list.Height = Get-FujiScaled 220
    foreach ($c in @(@('gui.aiReviewColState', 60), @('gui.aiReviewColKind', 90), @('gui.aiReviewColP', 50), @('gui.aiReviewColName', 90), @('gui.aiReviewColAnswer', 120), @('gui.aiReviewColSource', 360))) { [void]$list.Columns.Add((Get-FujiText $c[0]), (Get-FujiScaled $c[1])) }
    [void]$layout.Controls.Add($list)
    $source = New-FujiTextBox -Text '' -Width ($width - (Get-FujiScaled 30)) -Multiline
    $source.ReadOnly = $true
    $source.Height = Get-FujiScaled 60
    [void]$layout.Controls.Add($source)
    $choices = New-Object -TypeName System.Windows.Forms.ListBox
    $choices.Width = $width - (Get-FujiScaled 30)
    $choices.Height = Get-FujiScaled 110
    $choices.IntegralHeight = $false
    [void]$layout.Controls.Add($choices)
    $value = New-FujiTextBox -Text '' -Width ($width - (Get-FujiScaled 30))
    $value.Visible = $false
    [void]$layout.Controls.Add($value)
    $note = New-FujiLabel -Text '' -MaxWidth ($width - (Get-FujiScaled 30))
    [void]$layout.Controls.Add($note)
    $summary = New-FujiLabel -Text '' -MaxWidth ($width - (Get-FujiScaled 30))
    [void]$layout.Controls.Add($summary)
    # the re-run: a row given to a re-run CSV before is left out, unless the box is ticked
    $rerunRow = New-FujiFlow
    $rerunBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewRerun')
    $sentBox = New-Object -TypeName System.Windows.Forms.CheckBox
    $sentBox.Text = Get-FujiText 'gui.aiReviewRerunAll'
    $sentBox.AutoSize = $true
    $forgetBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewForget')
    foreach ($b in @($rerunBtn, $sentBox, $forgetBtn)) { [void]$rerunRow.Controls.Add($b) }
    [void]$layout.Controls.Add($rerunRow)
    $bar = New-FujiButtonBar
    $closeBtn = New-FujiButton -Text (Get-FujiText 'gui.close')
    $allBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewAll')
    $okBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewCheck')
    foreach ($b in @($closeBtn, $allBtn, $okBtn)) { [void]$bar.Controls.Add($b) }
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    # the steps of every macro: a macro it called wrote its own steps' lines in this run
    $map = Get-FujiAiStepMap -Macro $macro
    if ($script:Ed.Contains('Data') -and $null -ne $script:Ed.Data) { $map = Get-FujiAiStepMap -Macros $script:Ed.Data.macros }
    # checked answers are written a moment after the last Enter (and before anything that reads them)
    $timer = New-Object -TypeName System.Windows.Forms.Timer
    $timer.Interval = 1500
    $ctx = @{ Macro = $macro; Items = @(); Current = $null; Step = $null; Memory = (Read-FujiAiReviewMemory); Map = $map
        List = $list; Source = $source; Choices = $choices; Value = $value; Note = $note; Summary = $summary; Count = $count; Days = $days; Sent = $sentBox
        Timer = $timer; Pending = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Failed = '' }

    $showRow = {
        param($Item, $Lvi)
        $state = Get-FujiText 'gui.aiReviewStateOpen'
        if ($Item.Old) { $state = Get-FujiText 'gui.aiReviewStateOld' } elseif ($Item.Done) { $state = Get-FujiText 'gui.aiReviewStateDone' } elseif (-not (Test-FujiAiReviewCheckable -Item $Item)) { $state = Get-FujiText 'gui.aiReviewStateEmpty' }
        $kind = Get-FujiText ('gui.aiReviewKind.' + $(if ($Item.Kind) { $Item.Kind } else { 'low' }))
        $Lvi.SubItems.Clear()
        $Lvi.Text = $state
        foreach ($t in @($kind, $Item.P, $Item.Name, $Item.Answer, ($Item.Source -replace "`r?`n", ' '))) { [void]$Lvi.SubItems.Add([string]$t) }
        if ($Item.Done -or -not (Test-FujiAiReviewCheckable -Item $Item)) { $Lvi.ForeColor = [System.Drawing.Color]::Gray }
    }
    $load = {
        [void](& $flush)
        $n = [int]([object[]]$ctx.Days.Tag)[$ctx.Days.SelectedIndex]
        $ctx.Items = Get-FujiAiReviewOrder -Items @(Read-FujiAiReviewItem -Directory $script:Ed.Directory -MacroId ([string]$ctx.Macro.id) -MacroName ([string]$ctx.Macro.name) -Days $n)
        Update-FujiAiReviewKey -Items $ctx.Items -Map $ctx.Map
        Set-FujiAiReviewFinal -Items $ctx.Items -Memory $ctx.Memory
        $ctx.List.BeginUpdate()
        $ctx.List.Items.Clear()
        foreach ($it in $ctx.Items) { $lvi = New-Object -TypeName System.Windows.Forms.ListViewItem; & $showRow $it $lvi; $lvi.Tag = $it; [void]$ctx.List.Items.Add($lvi) }
        $ctx.List.EndUpdate()
        $open = @($ctx.Items | Where-Object { -not $_.Done -and (Test-FujiAiReviewCheckable -Item $_) }).Count
        $ctx.Count.Text = Get-FujiText 'gui.aiReviewCount' $ctx.Items.Count $open
        & $hint
        if ($ctx.List.Items.Count -gt 0) { $ctx.List.Items[0].Selected = $true; $ctx.List.Items[0].Focused = $true } else { & $select $null }
        # what could not be written stays in sight (choosing an item clears the note)
        if ($ctx.Failed) { $ctx.Note.Text = $ctx.Failed }
    }
    $hint = {
        $s = Get-FujiAiReviewSummary -Items @($ctx.Items | Where-Object { $_.Contains('Final') })
        $parts = @(foreach ($b in $s.Bands) { if ($b.Total -gt 0) { Get-FujiText 'gui.aiReviewBand' ('{0:0.0}' -f $b.From) ('{0:0.0}' -f $b.To) $b.Kept $b.Total } })
        $text = Get-FujiText 'gui.aiReviewSpot' $s.SpotKept $s.SpotTotal
        if ($parts.Count -gt 0) { $text += '  ' + ($parts -join '  ') }
        $ctx.Summary.Text = $text
    }
    $select = {
        param($Item)
        $ctx.Current = $Item
        $ctx.Choices.Items.Clear()
        $ctx.Note.Text = ''
        if ($null -eq $Item) { $ctx.Source.Text = ''; return }
        $ctx.Source.Text = $Item.Source -replace "`r?`n", "`r`n"
        $ctx.Step = Find-FujiAiReviewStep -Map $ctx.Map -Item $Item
        $isExtract = $Item.Command -eq 'AI_EXTRACT'
        $ctx.Choices.Visible = -not $isExtract
        $ctx.Value.Visible = $isExtract
        if ($Item.Old) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewOldNote' }
        elseif (-not (Test-FujiAiReviewCheckable -Item $Item)) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewEmptyNote' }
        elseif ($null -eq $ctx.Step) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewNoStep' }
        if ($isExtract) { $ctx.Value.Text = $(if ($Item.Contains('Final')) { [string]$Item['Final'] } else { [string]$Item.Answer }); return }
        if ($null -eq $ctx.Step) { return }
        $opts = Read-FujiAiOption -Text $ctx.Step.Settings['options']
        $initial = [string]$Item.Answer
        if ($Item.Contains('Final')) { $initial = [string]$Item['Final'] }
        for ($i = 0; $i -lt $opts.Count; $i++) {
            [void]$ctx.Choices.Items.Add(('{0}: {1}' -f (($i + 1) % 10), $opts[$i].Value))
            if ($opts[$i].Value -eq $initial) { $ctx.Choices.SelectedIndex = $i }
        }
    }
    # check one item with this answer; returns $true when it could be remembered
    $checkOne = {
        param($Item, [string]$Answer)
        if (-not (Test-FujiAiReviewCheckable -Item $Item) -or $null -eq (Find-FujiAiReviewStep -Map $ctx.Map -Item $Item)) { return $false }
        # an answer that was put to use already and is changed now: its row can be run again
        if ($Item['Rerun'] -and $Item.Contains('Final') -and [string]$Item['Final'] -ne $Answer) { $Item['Reopen'] = $true }
        if ($Item.Command -eq 'AI_EXTRACT') {
            # only the items a person checked: the run asks the AI for the others
            $pairs = Get-FujiAiRemembered -Memory $ctx.Memory -Key $Item.Key -Hash $Item.Hash
            if ($pairs -isnot [System.Collections.IDictionary]) { $pairs = [ordered]@{} }
            $pairs[$Item.Name] = $Answer
            Add-FujiAiRemembered -Memory $ctx.Memory -Key $Item.Key -Hash $Item.Hash -Answer $pairs
        } else {
            Add-FujiAiRemembered -Memory $ctx.Memory -Key $Item.Key -Hash $Item.Hash -Answer $Answer -ExampleText $Item.Source
        }
        $Item['Final'] = $Answer
        return $true
    }
    # checked items are shown as done at once and written a moment later, all together (one write of
    # the memory and of each list file for many Enters)
    $commit = {
        param([object[]]$Checked)
        $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        foreach ($c in $Checked) {
            if (-not $c.Done) { $c.Done = $time }
            if (-not $ctx.Pending.Contains($c)) { $ctx.Pending.Add($c) }
        }
        $ctx.Timer.Stop()
        $ctx.Timer.Start()
    }
    # the memory first, then "done" in the list (a list marked done always has its answers remembered).
    # Returns $false when something could not be written (said in the log and under the list)
    $flush = {
        $ctx.Timer.Stop()
        if ($ctx.Pending.Count -eq 0) { return $true }
        try {
            Save-FujiAiMemory -Directory $script:Ed.Directory -Memory $ctx.Memory
        } catch {
            # kept: written again with the next ones (or when the window closes)
            $ctx.Failed = Get-FujiText 'gui.aiReviewSaveFailed' $_.Exception.Message
            Write-FujiUiLog -Message $ctx.Failed -Level 'warn'
            $ctx.Note.Text = $ctx.Failed
            return $false
        }
        $items = $ctx.Pending.ToArray()
        $ctx.Pending.Clear()
        $ctx.Failed = ''
        $n = Set-FujiAiReviewDoneMany -Items $items -Time (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        if ($n -lt $items.Count) {
            $ctx.Failed = Get-FujiText 'gui.aiReviewDoneFailed'
            Write-FujiUiLog -Message $ctx.Failed -Level 'warn'
            $ctx.Note.Text = $ctx.Failed
            return $false
        }
        return $true
    }
    $timer.Add_Tick({ Invoke-FujiUi { [void](& $flush) } })
    $next = {
        $i = $ctx.List.SelectedIndices
        $at = 0
        if ($i.Count -gt 0) { $at = $i[0] }
        for ($k = $at + 1; $k -lt $ctx.List.Items.Count; $k++) { $t = $ctx.List.Items[$k].Tag; if (-not $t.Done -and (Test-FujiAiReviewCheckable -Item $t)) { $ctx.List.Items[$k].Selected = $true; $ctx.List.Items[$k].Focused = $true; $ctx.List.EnsureVisible($k); return } }
    }
    $confirm = {
        $it = $ctx.Current
        if ($null -eq $it) { return }
        $answer = ''
        if ($it.Command -eq 'AI_EXTRACT') { $answer = $ctx.Value.Text.Trim() }
        elseif ($ctx.Choices.SelectedIndex -ge 0) { $answer = (Read-FujiAiOption -Text $ctx.Step.Settings['options'])[$ctx.Choices.SelectedIndex].Value }
        else { return }
        if (& $checkOne $it $answer) {
            & $commit @($it)
            foreach ($lvi in $ctx.List.Items) { if ([object]::ReferenceEquals($lvi.Tag, $it)) { & $showRow $it $lvi } }
            & $hint
            & $next
        }
    }
    $list.Add_SelectedIndexChanged({ Invoke-FujiUi { if ($ctx.List.SelectedItems.Count -gt 0) { & $select $ctx.List.SelectedItems[0].Tag } else { & $select $null } } })
    $days.Add_SelectedIndexChanged({ Invoke-FujiUi { & $load } })
    $okBtn.Add_Click({ Invoke-FujiUi { & $confirm } })
    $allBtn.Add_Click({ Invoke-FujiUi {
                # choices only: an extracted value on the list was left out as not in the text, so a person looks at it
                $open = @($ctx.Items | Where-Object { -not $_.Done -and (Test-FujiAiReviewCheckable -Item $_) -and $_.Answer -ne '' -and $_.Command -ne 'AI_EXTRACT' })
                if ($open.Count -eq 0) { return }
                if ((Show-FujiChoice -Title (Get-FujiText 'gui.aiReviewAll') -Message (Get-FujiText 'gui.aiReviewAllConfirm' $open.Count) -Buttons @((Get-FujiText 'gui.aiReviewAll'), (Get-FujiText 'gui.cancel'))) -ne 0) { return }
                $checked = @(foreach ($it in $open) { if (& $checkOne $it ([string]$it.Answer)) { $it } })
                if ($checked.Count -gt 0) { & $commit $checked }
                & $load
            } })
    $forgetBtn.Add_Click({ Invoke-FujiUi {
                [void](& $flush)
                $it = $ctx.Current
                if ($null -eq $it -or $it.Old -or $null -eq $ctx.Step) { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewForget') -Message (Get-FujiText 'gui.aiReviewForgetPick'); return }
                $key = [string]$ctx.Step.Key
                $label = '$' + [string]$it.Name
                if ($ctx.Step.Cmd -eq 'AI_EXTRACT') { $label = Get-FujiText 'gui.aiReviewForgetExtract' }
                $have = @{ Answers = 0; Examples = 0 }
                if ($ctx.Memory.Contains($key)) { $have = @{ Answers = $ctx.Memory[$key]['answers'].Count; Examples = $ctx.Memory[$key]['examples'].Count } }
                if ($have.Answers -eq 0) { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewForget') -Message (Get-FujiText 'gui.aiReviewForgetNone' $label); return }
                if ((Show-FujiChoice -Title (Get-FujiText 'gui.aiReviewForget') -Message (Get-FujiText 'gui.aiReviewForgetConfirm' $label $have.Answers $have.Examples) -Buttons @((Get-FujiText 'gui.aiReviewForgetYes'), (Get-FujiText 'gui.cancel'))) -ne 0) { return }
                [void](Remove-FujiAiRemembered -Memory $ctx.Memory -Key $key)
                Save-FujiAiMemory -Directory $script:Ed.Directory -Memory $ctx.Memory
                # the lines of this step are not checked any more (a line marked done always has its answer remembered).
                # Their "given to a re-run" time stays: a row that was run again is not run a third time by itself
                $again = @($ctx.Items | Where-Object { $_.Done -and -not $_.Old -and $_.Key -eq $key })
                $n = 0
                if ($again.Count -gt 0) { $n = Set-FujiAiReviewDoneMany -Items $again -Time '' }
                Write-FujiUiLog -Message (Get-FujiText 'gui.aiReviewForgetDone' $label $have.Answers) -Level 'ok'
                & $load
                if ($n -lt $again.Count) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewDoneFailed' }
            } })
    $rerunBtn.Add_Click({ Invoke-FujiUi {
                [void](& $flush)
                $all = [bool]$ctx.Sent.Checked
                # the rows of runs of this macro only (a macro it called may also have been run by itself, on another CSV)
                $runId = [string]$ctx.Macro.id
                $sent = Get-FujiAiRerunItem -Items $ctx.Items -IncludeSent:$all -RunMacroId $runId
                $nos = Get-FujiAiRerunRowNo -Items $ctx.Items -IncludeSent:$all -RunMacroId $runId
                $rows = (Get-FujiRunRow -CsvRows $script:Ed.Csv.Rows -Header $script:Ed.Csv.Header).Rows
                $r = New-FujiAiRerunCsv -Header $script:Ed.Csv.Header -Rows $rows -RowNos $nos -Prints (Get-FujiAiRerunPrint -Items $sent)
                if ($r.Error) { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewRerun') -Message $r.Error; return }
                $path = Get-FujiEditorPath $script:Ed 'fujikyun_ai_rerun.csv'
                try { Write-FujiTextFile -Path $path -Text $r.Text -Bom } catch { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewRerun') -Message $_.Exception.Message; return }
                $script:Ui.CsvPath.Text = $path
                Import-FujiCsvUi
                Write-FujiUiLog -Message (Get-FujiText 'gui.aiReviewRerunDone' $r.Count $path) -Level 'ok'
                # these rows are not put in the next re-run CSV again
                if ((Set-FujiAiReviewDoneMany -Items $sent -Time (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Column 'rerun') -lt $sent.Count) { Write-FujiUiLog -Message (Get-FujiText 'gui.aiReviewRerunMarkFailed') -Level 'warn' }
                $this.FindForm().Close()
            } })
    $closeBtn.Add_Click({ $this.FindForm().Close() })
    $f.Add_FormClosing({ Invoke-FujiUi { [void](& $flush) } })
    $f.Add_KeyDown({
            $e = $_
            Invoke-FujiUi {
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; & $confirm; return }
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; & $next; return }
                if ($ctx.Value.Focused) { return }
                $d = -1
                if ($e.KeyCode -ge [System.Windows.Forms.Keys]::D0 -and $e.KeyCode -le [System.Windows.Forms.Keys]::D9) { $d = [int]$e.KeyCode - [int][System.Windows.Forms.Keys]::D0 }
                if ($e.KeyCode -ge [System.Windows.Forms.Keys]::NumPad0 -and $e.KeyCode -le [System.Windows.Forms.Keys]::NumPad9) { $d = [int]$e.KeyCode - [int][System.Windows.Forms.Keys]::NumPad0 }
                if ($d -ge 0) {
                    $idx = $d - 1
                    if ($d -eq 0) { $idx = 9 }
                    if ($idx -lt $ctx.Choices.Items.Count) { $ctx.Choices.SelectedIndex = $idx; $e.SuppressKeyPress = $true }
                }
            }
        })
    $f.Add_Shown({ Invoke-FujiUi { & $load; $ctx.List.Focus() } })
    try { [void](Show-FujiDialog -Form $f) } finally { $timer.Stop(); $timer.Dispose() }
    $f.Dispose()
}

# The answers a person checked, from the file. What was kept under the step keys of before
# (2026.11.10 and older) is moved to today's keys and written back.
function Read-FujiAiReviewMemory {
    $script:FujiAiMemoryNotice = ''
    $memory = Read-FujiAiMemory -Directory $script:Ed.Directory
    if ($script:FujiAiMemoryNotice) { Write-FujiUiLog -Message $script:FujiAiMemoryNotice -Level 'warn' }
    if ((Move-FujiAiMemoryKey -Memory $memory -Macros $script:Ed.Data.macros) -gt 0) {
        # not written (the file is in use): moved again the next time
        try { Save-FujiAiMemory -Directory $script:Ed.Directory -Memory $memory } catch { $null = $_ }
    }
    return $memory
}

# The answers a person checked, read once per run (the first AI step of the run reads the file)
$script:FujiAiMemoryRun = $null
function Get-FujiAiRunMemory {
    if ($null -eq $script:FujiAiMemoryRun) { $script:FujiAiMemoryRun = Read-FujiAiReviewMemory }
    return $script:FujiAiMemoryRun
}

# An answer a person picked in the run: remembered at once (the review window is closed while a run goes)
function Add-FujiAiRunRemembered {
    param([string]$Key, [string]$Hash, [string]$Answer, [AllowEmptyString()][string]$Source)
    $memory = Get-FujiAiRunMemory
    Add-FujiAiRemembered -Memory $memory -Key $Key -Hash $Hash -Answer $Answer -ExampleText $Source
    Save-FujiAiMemory -Directory $script:Ed.Directory -Memory $memory
}
