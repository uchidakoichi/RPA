# ---------------------------------------------------------------------------------------------
#  Watch rules of the selected macro (rules: Runner.ps1 Invoke-FujiWatchRule): windows that may
#  appear at any time during a run (a session timeout, a server error) and what to do then
# ---------------------------------------------------------------------------------------------

function Show-FujiWatchDialog {
    if (Test-FujiEditLocked) { return }
    $m = Get-FujiCurrentMacro $script:Ed
    if ($null -eq $m) { return }
    $rules = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($r in (Get-FujiWatchRule -Macro $m)) { $rules.Add((Copy-FujiStep -Step $r)) }
    $f = New-FujiDialogForm -Title (Get-FujiText 'watch.title' $m.name) -Width (Get-FujiScaled 820) -Height (Get-FujiScaled 440)
    $f.MaximizeBox = $true
    $help = New-FujiLabel -Text (Get-FujiText 'watch.help') -MaxWidth (Get-FujiScaled 790)
    $help.Dock = [System.Windows.Forms.DockStyle]::Top
    $lv = New-FujiListView -Headings (Get-FujiText 'watch.head') -Widths @(280, 110, 220, 180) -LeftColumns @(0, 1, 2, 3)
    $tools = New-FujiFlow
    $tools.Dock = [System.Windows.Forms.DockStyle]::Bottom
    foreach ($b in @(@('watch.add', 'add'), @('watch.edit', 'edit'), @('watch.delete', 'delete'), @('watch.up', 'up'), @('watch.down', 'down'))) {
        $btn = New-FujiButton -Text (Get-FujiText $b[0]) -Tag $b[1]
        $btn.Add_Click({ $what = [string]$this.Tag; Invoke-FujiUi { Edit-FujiWatchListUi -What $what } })
        [void]$tools.Controls.Add($btn)
    }
    $bar = New-FujiButtonBar
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-FujiButton -Text (Get-FujiText 'gui.ok')
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    [void]$bar.Controls.Add((New-FujiDocButton -Page 'manual' -Anchor (Get-FujiText 'gui.docAnchors.watch')))
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    $lv.Add_DoubleClick({ Invoke-FujiUi { Edit-FujiWatchListUi -What 'edit' } })
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($help)
    [void]$f.Controls.Add($tools)
    [void]$f.Controls.Add($bar)
    $script:Ui.WatchDialog = @{ Rules = $rules; List = $lv }
    Update-FujiWatchList
    $result = Show-FujiDialog -Form $f
    $f.Dispose()
    $script:Ui.WatchDialog = $null
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
    Set-FujiMacroWatch -Editor $script:Ed -Rules $rules.ToArray()
    Update-FujiAll
}

function Update-FujiWatchList {
    param([int]$Select = -1)
    $d = $script:Ui.WatchDialog
    $lv = $d.List
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($r in $d.Rules) {
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList ([string]$r.title)
        $key = ''
        if ($r.key) { $key = Get-FujiKeyName ([string]$r.key) }
        $call = ''
        if ($r.action -eq 'CALL') { $call = Get-FujiWatchMacroName -Rule $r }
        foreach ($v in @($key, (Get-FujiText ('watch.action.' + $r.action)), $call)) { [void]$item.SubItems.Add([string]$v) }
        [void]$lv.Items.Add($item)
    }
    if ($Select -ge 0 -and $Select -lt $lv.Items.Count) { $lv.Items[$Select].Selected = $true }
    $lv.EndUpdate()
}

# The called macro's current name (by id, else the name kept in the rule)
function Get-FujiWatchMacroName {
    param([System.Collections.IDictionary]$Rule)
    foreach ($m in $script:Ed.Data.macros) { if ($Rule.macroId -and [string]$m.id -eq $Rule.macroId) { return [string]$m.name } }
    return [string]$Rule.macroName
}

function Edit-FujiWatchListUi {
    param([string]$What)
    $d = $script:Ui.WatchDialog
    $i = -1
    if ($d.List.SelectedIndices.Count -gt 0) { $i = $d.List.SelectedIndices[0] }
    switch ($What) {
        'add' {
            $r = Show-FujiWatchRuleDialog -Rule $null
            if ($null -ne $r) { $d.Rules.Add($r); Update-FujiWatchList -Select ($d.Rules.Count - 1) }
        }
        'edit' {
            if ($i -lt 0) { return }
            $r = Show-FujiWatchRuleDialog -Rule $d.Rules[$i]
            if ($null -ne $r) { $d.Rules[$i] = $r; Update-FujiWatchList -Select $i }
        }
        'delete' {
            if ($i -lt 0) { return }
            $d.Rules.RemoveAt($i)
            Update-FujiWatchList -Select ([Math]::Min($i, $d.Rules.Count - 1))
        }
        { $_ -in @('up', 'down') } {
            $j = $i - 1
            if ($What -eq 'down') { $j = $i + 1 }
            if ($i -lt 0 -or $j -lt 0 -or $j -ge $d.Rules.Count) { return }
            $tmp = $d.Rules[$i]
            $d.Rules[$i] = $d.Rules[$j]
            $d.Rules[$j] = $tmp
            Update-FujiWatchList -Select $j
        }
    }
}

# One rule: the window title, a key to press, what to do, the macro to call. $null when cancelled.
function Show-FujiWatchRuleDialog {
    param([System.Collections.IDictionary]$Rule)
    if ($null -eq $Rule) { $Rule = [ordered]@{ title = ''; key = ''; action = 'STOP'; macroId = ''; macroName = '' } }
    $width = Get-FujiScaled 560
    $f = New-FujiDialogForm -Title (Get-FujiText 'watch.ruleTitle') -Width $width -Height (Get-FujiScaled 420)
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.AutoScroll = $true
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    $inner = $width - (Get-FujiScaled 50)
    $title = New-FujiTextBox -Text ([string]$Rule.title) -Width ($inner - (Get-FujiScaled 110))
    $pick = New-FujiButton -Text (Get-FujiText 'gui.windowList')
    $pick.Add_Click({ Invoke-FujiUi { $t = Show-FujiWindowListDialog; if ($t) { $script:Ui.WatchRuleDialog.Title.Text = $t } } })
    $key = New-Object -TypeName System.Windows.Forms.ComboBox
    $key.Width = Get-FujiScaled 200
    foreach ($p in $script:FujiCommands['keyPresets']) { [void]$key.Items.Add([string]$p[0]) }
    $key.Text = [string]$Rule.key
    $script:Ui.ToolTip.SetToolTip($key, (Get-FujiText 'watch.keyTip'))
    $actions = @($script:FujiWatchActions | ForEach-Object { Get-FujiText ('watch.action.' + $_) })
    $action = New-FujiComboBox -Items $actions -Values $script:FujiWatchActions -Width $inner
    $action.SelectedIndex = [Math]::Max(0, [Array]::IndexOf($script:FujiWatchActions, [string]$Rule.action))
    $names = @($script:Ed.Data.macros | ForEach-Object { [string]$_.name })
    $ids = @($script:Ed.Data.macros | ForEach-Object { [string]$_.id })
    $macro = New-FujiComboBox -Items $names -Values $ids -Width $inner
    if ($Rule.action -eq 'CALL') {
        $mi = [Array]::IndexOf($ids, [string]$Rule.macroId)
        if ($mi -lt 0) { $mi = [Array]::IndexOf($names, [string]$Rule.macroName) }
        $macro.SelectedIndex = $mi
    }
    $err = New-FujiLabel -Text '' -MaxWidth $inner
    $err.ForeColor = Get-FujiColor '#c62828'
    $add = { param($c) [void]$layout.Controls.Add($c) }
    & $add (New-FujiFieldLabel -Text (Get-FujiText 'watch.fieldTitle'))
    & $add (New-FujiGlued @($title, $pick))
    & $add (New-FujiFieldLabel -Text (Get-FujiText 'watch.fieldKey'))
    & $add $key
    & $add (New-FujiFieldLabel -Text (Get-FujiText 'watch.fieldAction'))
    & $add $action
    & $add (New-FujiFieldLabel -Text (Get-FujiText 'watch.fieldMacro'))
    & $add $macro
    & $add $err
    $bar = New-FujiButtonBar
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-FujiButton -Text (Get-FujiText 'gui.ok')
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    $script:Ui.WatchRuleDialog = @{ Title = $title; Key = $key; Action = $action; Macro = $macro; Error = $err; Result = $null }
    $action.Add_SelectedIndexChanged({ $d = $script:Ui.WatchRuleDialog; $d.Macro.Enabled = ([object[]]$d.Action.Tag)[$d.Action.SelectedIndex] -eq 'CALL' })
    $macro.Enabled = ($action.SelectedIndex -ge 0 -and $script:FujiWatchActions[$action.SelectedIndex] -eq 'CALL')
    $ok.Add_Click({
            $d = $script:Ui.WatchRuleDialog
            $act = [string]([object[]]$d.Action.Tag)[$d.Action.SelectedIndex]
            if ($d.Title.Text.Trim() -eq '') { $d.Error.Text = Get-FujiText 'watch.needTitle'; return }
            $rule = [ordered]@{ title = $d.Title.Text.Trim(); key = $d.Key.Text.Trim(); action = $act; macroId = ''; macroName = '' }
            if ($act -eq 'CALL') {
                if ($d.Macro.SelectedIndex -lt 0) { $d.Error.Text = Get-FujiText 'watch.needMacro'; return }
                $rule.macroId = [string]([object[]]$d.Macro.Tag)[$d.Macro.SelectedIndex]
                $rule.macroName = [string]$d.Macro.SelectedItem
            }
            $d.Result = ConvertTo-FujiWatchRule -Source $rule
            $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
        })
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $result = Show-FujiDialog -Form $f
    $f.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $script:Ui.WatchRuleDialog.Result
}
