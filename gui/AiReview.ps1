# ---------------------------------------------------------------------------------------------
#  AI review window: the review list of the current macro, unsure answers first (lowest probability),
#  then spot checks, then the ones already checked. Number keys pick an option, Enter checks the
#  item and goes to the next. A checked answer is remembered (fujikyun_ai_answers.json), so the same
#  text is not asked again, and is shown to the AI as an example for similar texts. The checked rows
#  can be run again from a CSV of those rows only.
# ---------------------------------------------------------------------------------------------

# The macro's AI step an item belongs to (found again by its step key), or $null
function Find-FujiAiReviewStep {
    param([System.Collections.IDictionary]$Macro, [hashtable]$Item)
    foreach ($s in $Macro.steps) {
        if ($s.cmd -ne 'AI_CHOOSE' -and $s.cmd -ne 'AI_EXTRACT') { continue }
        $set = ConvertFrom-FujiStepValue -Cmd $s.cmd -Value $s.val
        if ((Get-FujiAiStepKey -Cmd $s.cmd -MacroId ([string]$Macro.id) -Settings $set) -eq $Item.Key) { return @{ Cmd = $s.cmd; Settings = $set } }
    }
    return $null
}

function Show-FujiAiReviewDialog {
    $macro = Get-FujiCurrentMacro $script:Ed
    if ($null -eq $macro) { return }
    $width = Get-FujiScaled 820
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.aiReviewTitle' $macro.name) -Width $width -Height (Get-FujiScaled 600)
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
    $bar = New-FujiButtonBar
    $closeBtn = New-FujiButton -Text (Get-FujiText 'gui.close')
    $rerunBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewRerun')
    $allBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewAll')
    $okBtn = New-FujiButton -Text (Get-FujiText 'gui.aiReviewCheck')
    foreach ($b in @($closeBtn, $rerunBtn, $allBtn, $okBtn)) { [void]$bar.Controls.Add($b) }
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $script:FujiAiMemoryNotice = ''
    $ctx = @{ Macro = $macro; Items = @(); Current = $null; Step = $null; Memory = (Read-FujiAiMemory -Directory $script:Ed.Directory)
        List = $list; Source = $source; Choices = $choices; Value = $value; Note = $note; Summary = $summary; Count = $count; Days = $days }
    if ($script:FujiAiMemoryNotice) { Write-FujiUiLog -Message $script:FujiAiMemoryNotice -Level 'warn' }

    $showRow = {
        param($Item, $Lvi)
        $state = Get-FujiText 'gui.aiReviewStateOpen'
        if ($Item.Old) { $state = Get-FujiText 'gui.aiReviewStateOld' } elseif ($Item.Done) { $state = Get-FujiText 'gui.aiReviewStateDone' }
        $kind = Get-FujiText ('gui.aiReviewKind.' + $(if ($Item.Kind) { $Item.Kind } else { 'low' }))
        $Lvi.SubItems.Clear()
        $Lvi.Text = $state
        foreach ($t in @($kind, $Item.P, $Item.Name, $Item.Answer, ($Item.Source -replace "`r?`n", ' '))) { [void]$Lvi.SubItems.Add([string]$t) }
        if ($Item.Done -or $Item.Old) { $Lvi.ForeColor = [System.Drawing.Color]::Gray }
    }
    $load = {
        $n = [int]([object[]]$ctx.Days.Tag)[$ctx.Days.SelectedIndex]
        $ctx.Items = Get-FujiAiReviewOrder -Items @(Read-FujiAiReviewItem -Directory $script:Ed.Directory -MacroId ([string]$ctx.Macro.id) -MacroName ([string]$ctx.Macro.name) -Days $n)
        Set-FujiAiReviewFinal -Items $ctx.Items -Memory $ctx.Memory
        $ctx.List.BeginUpdate()
        $ctx.List.Items.Clear()
        foreach ($it in $ctx.Items) { $lvi = New-Object -TypeName System.Windows.Forms.ListViewItem; & $showRow $it $lvi; $lvi.Tag = $it; [void]$ctx.List.Items.Add($lvi) }
        $ctx.List.EndUpdate()
        $open = @($ctx.Items | Where-Object { -not $_.Done -and -not $_.Old }).Count
        $ctx.Count.Text = Get-FujiText 'gui.aiReviewCount' $ctx.Items.Count $open
        & $hint
        if ($ctx.List.Items.Count -gt 0) { $ctx.List.Items[0].Selected = $true; $ctx.List.Items[0].Focused = $true } else { & $select $null }
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
        $ctx.Step = Find-FujiAiReviewStep -Macro $ctx.Macro -Item $Item
        $isExtract = $Item.Command -eq 'AI_EXTRACT'
        $ctx.Choices.Visible = -not $isExtract
        $ctx.Value.Visible = $isExtract
        if ($Item.Old) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewOldNote' } elseif ($null -eq $ctx.Step) { $ctx.Note.Text = Get-FujiText 'gui.aiReviewNoStep' }
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
        if ($Item.Old -or $null -eq (Find-FujiAiReviewStep -Macro $ctx.Macro -Item $Item) -or -not $Item.Hash) { return $false }
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
    # the memory first, then "done" in the list (a list marked done always has its answers remembered)
    $commit = {
        param([object[]]$Checked)
        Save-FujiAiMemory -Directory $script:Ed.Directory -Memory $ctx.Memory
        $n = Set-FujiAiReviewDoneMany -Items $Checked -Time (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        if ($n -lt $Checked.Count) {
            foreach ($c in $Checked) { if (-not $c.Done) { $c.Done = 'x' } }
            $ctx.Note.Text = Get-FujiText 'gui.aiReviewDoneFailed'
        }
    }
    $next = {
        $i = $ctx.List.SelectedIndices
        $at = 0
        if ($i.Count -gt 0) { $at = $i[0] }
        for ($k = $at + 1; $k -lt $ctx.List.Items.Count; $k++) { $t = $ctx.List.Items[$k].Tag; if (-not $t.Done -and -not $t.Old) { $ctx.List.Items[$k].Selected = $true; $ctx.List.Items[$k].Focused = $true; $ctx.List.EnsureVisible($k); return } }
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
                $open = @($ctx.Items | Where-Object { -not $_.Done -and -not $_.Old -and $_.Answer -ne '' -and $_.Command -ne 'AI_EXTRACT' })
                if ($open.Count -eq 0) { return }
                if ((Show-FujiChoice -Title (Get-FujiText 'gui.aiReviewAll') -Message (Get-FujiText 'gui.aiReviewAllConfirm' $open.Count) -Buttons @((Get-FujiText 'gui.aiReviewAll'), (Get-FujiText 'gui.cancel'))) -ne 0) { return }
                $checked = @(foreach ($it in $open) { if (& $checkOne $it ([string]$it.Answer)) { $it } })
                if ($checked.Count -gt 0) { & $commit $checked }
                & $load
            } })
    $rerunBtn.Add_Click({ Invoke-FujiUi {
                $nos = Get-FujiAiRerunRowNo -Items $ctx.Items
                $rows = (Get-FujiRunRow -CsvRows $script:Ed.Csv.Rows -Header $script:Ed.Csv.Header).Rows
                $r = New-FujiAiRerunCsv -Header $script:Ed.Csv.Header -Rows $rows -RowNos $nos
                if ($r.Error) { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewRerun') -Message $r.Error; return }
                $path = Get-FujiEditorPath $script:Ed 'fujikyun_ai_rerun.csv'
                try { Write-FujiTextFile -Path $path -Text $r.Text -Bom } catch { Show-FujiMessage -Title (Get-FujiText 'gui.aiReviewRerun') -Message $_.Exception.Message; return }
                $script:Ui.CsvPath.Text = $path
                Import-FujiCsvUi
                Write-FujiUiLog -Message (Get-FujiText 'gui.aiReviewRerunDone' $r.Count $path) -Level 'ok'
                $this.FindForm().Close()
            } })
    $closeBtn.Add_Click({ $this.FindForm().Close() })
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
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
}

# The answers a person checked, read once per run (the first AI step of the run reads the file)
$script:FujiAiMemoryRun = $null
function Get-FujiAiRunMemory {
    if ($null -eq $script:FujiAiMemoryRun) {
        $script:FujiAiMemoryNotice = ''
        $script:FujiAiMemoryRun = Read-FujiAiMemory -Directory $script:Ed.Directory
        if ($script:FujiAiMemoryNotice) { Write-FujiUiLog -Message $script:FujiAiMemoryNotice -Level 'warn' }
    }
    return $script:FujiAiMemoryRun
}
