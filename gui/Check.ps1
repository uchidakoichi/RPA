# ---------------------------------------------------------------------------------------------
#  Check before a run (rules: src/Check.ps1): the "check" button, and the question before Run
#  when something is found
# ---------------------------------------------------------------------------------------------

# The problems of the selected macro, with the loaded CSV and this PC's files
function Get-FujiUiProblem {
    $macro = Get-FujiCurrentMacro $script:Ed
    $columns = -1
    if ($script:Ed.Csv.Rows.Count -gt 0) {
        $columns = 0
        if ($null -ne $script:Ed.Csv.Header) { $columns = $script:Ed.Csv.Header.Length }
        foreach ($r in $script:Ed.Csv.Rows) { $columns = [Math]::Max($columns, ([string[]]$r).Length) }
    }
    return , (Get-FujiMacroProblem -Macros $script:Ed.Data.macros -Macro $macro -Directory $script:Ed.Directory `
            -ResolvePath { param($Path) Resolve-FujiEditorPath -Editor $script:Ed -Path $Path } -Header $script:Ed.Csv.Header -Columns $columns)
}

# The check button: the list, or that nothing was found
function Invoke-FujiCheckUi {
    $problems = Get-FujiUiProblem
    if ($problems.Count -eq 0) {
        Write-FujiUiLog -Message (Get-FujiText 'check.logNone') -Level 'ok'
        Show-FujiMessage -Title (Get-FujiText 'check.title') -Message (Get-FujiText 'check.none')
        return
    }
    [void](Show-FujiCheckDialog -Problems $problems)
}

# Before Run: $true to go on. Asked only for errors and warnings; with -Unattended (a schedule)
# they are written to the log and the run goes on.
function Confirm-FujiCheckBeforeRun {
    param([switch]$Unattended)
    $problems = Get-FujiUiProblem
    $serious = Select-FujiSeriousProblem -Problems $problems
    if ($serious.Count -eq 0) { return $true }
    if ($Unattended) {
        foreach ($p in $serious) { Write-FujiUiLog -Message (Get-FujiText 'check.logLine' $p.Macro (Get-FujiCheckWhere $p) $p.Message) -Level 'warn' }
        return $true
    }
    if (Show-FujiCheckDialog -Problems $problems -AskRun) {
        foreach ($p in $serious) { Write-FujiUiLog -Message (Get-FujiText 'check.logLine' $p.Macro (Get-FujiCheckWhere $p) $p.Message) -Level 'warn' }
        return $true
    }
    Write-FujiUiLog -Message (Get-FujiText 'check.stopped') -Level 'warn'
    return $false
}

function Get-FujiCheckWhere {
    param([hashtable]$Problem)
    if ($Problem.Index -lt 0) { return (Get-FujiText 'check.whole') }
    return (Get-FujiText 'run.breakWhere' ($Problem.Index + 1))
}

# The list of problems (errors first). AskRun: buttons to run anyway or stop; returns $true to run.
# A double click selects that step (and closes the list).
function Show-FujiCheckDialog {
    param([object[]]$Problems, [switch]$AskRun)
    $order = @{ error = 0; warn = 1; note = 2 }
    $sorted = @($Problems | Sort-Object -Property @{ Expression = { $order[$_.Level] } }, @{ Expression = { $_.Macro } }, @{ Expression = { $_.Index } })
    $count = @{ error = 0; warn = 0; note = 0 }
    foreach ($p in $sorted) { $count[$p.Level]++ }
    $f = New-FujiDialogForm -Title (Get-FujiText 'check.title') -Width (Get-FujiScaled 860) -Height (Get-FujiScaled 460)
    $f.MaximizeBox = $true
    $lv = New-FujiListView -Headings (Get-FujiText 'check.head') -Widths @(70, 150, 50, 520) -LeftColumns @(0, 1, 3)
    foreach ($p in $sorted) {
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList (Get-FujiText ('check.level.' + $p.Level))
        $no = ''
        if ($p.Index -ge 0) { $no = [string]($p.Index + 1) }
        foreach ($v in @($p.Macro, $no, $p.Message)) { [void]$item.SubItems.Add([string]$v) }
        if ($p.Level -eq 'error') { $item.ForeColor = Get-FujiColor '#c62828' } elseif ($p.Level -eq 'note') { $item.ForeColor = Get-FujiColor '#5e5368' }
        $item.Tag = @($p.MacroId, $p.Index)
        [void]$lv.Items.Add($item)
    }
    Resize-FujiListColumn -List $lv
    $text = Get-FujiText 'check.found' $sorted.Count $count.error $count.warn $count.note
    if ($AskRun) { $text = (Get-FujiText 'check.ask') + "`r`n" + $text }
    $note = New-FujiLabel -Text $text -MaxWidth (Get-FujiScaled 820)
    $note.Dock = [System.Windows.Forms.DockStyle]::Top
    $bar = New-FujiButtonBar
    $script:Ui.CheckDialog = @{ Run = $false }
    if ($AskRun) {
        $stop = New-FujiButton -Text (Get-FujiText 'check.stop')
        $stop.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $run = New-FujiButton -Text (Get-FujiText 'check.runAnyway')
        $run.Add_Click({ $script:Ui.CheckDialog.Run = $true; $this.FindForm().Close() })
        [void]$bar.Controls.Add($stop)
        [void]$bar.Controls.Add($run)
        $f.CancelButton = $stop
        $f.Add_Shown({ $this.CancelButton.Focus() })
    } else {
        $close = New-FujiButton -Text (Get-FujiText 'gui.close')
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$bar.Controls.Add($close)
        $f.CancelButton = $close
    }
    [void]$bar.Controls.Add((New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.check')))
    $lv.Add_DoubleClick({
            $at = $this.SelectedItems[0].Tag
            $form = $this.FindForm()
            Invoke-FujiUi { if ([int]$at[1] -ge 0) { [void](Select-FujiStepAt -MacroId ([string]$at[0]) -Index ([int]$at[1])) }; $form.Close() }
        })
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($note)
    [void]$f.Controls.Add($bar)
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
    return [bool]$script:Ui.CheckDialog.Run
}
