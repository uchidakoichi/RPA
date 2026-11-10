# ---------------------------------------------------------------------------------------------
#  AI windows: the AI settings (shared folder, the copy on this PC, a test question), the copy
#  window, and the window where a person picks the answer when the AI is not sure (low = ASK)
# ---------------------------------------------------------------------------------------------

# The shared AI folder chosen by the person; '' when cancelled
function Select-FujiAiFolderUi {
    param([string]$Start = '')
    $d = New-Object -TypeName System.Windows.Forms.FolderBrowserDialog
    $d.Description = Get-FujiText 'gui.aiPickFolder'
    $d.ShowNewFolderButton = $false
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
    try {
        if ($d.ShowDialog((Get-FujiOwner)) -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
        if (-not (Test-Path -LiteralPath (Join-Path $d.SelectedPath 'ai.json') -PathType Leaf)) {
            Show-FujiMessage -Title (Get-FujiText 'gui.aiTitle') -Message (Get-FujiText 'gui.aiNotAiFolder' $d.SelectedPath)
            return ''
        }
        return $d.SelectedPath
    } finally { $d.Dispose() }
}

# Copies the shared AI folder to this PC with a progress window; 'copied' | 'canceled' (throws on errors)
function Show-FujiAiCopyDialog {
    param([Parameter(Mandatory)][string]$SharedDir)
    $width = Get-FujiScaled 460
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.aiCopyTitle') -Width $width -Height (Get-FujiScaled 170)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.ControlBox = $false
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiCopyNote') -MaxWidth ($width - (Get-FujiScaled 30))))
    $bar = New-Object -TypeName System.Windows.Forms.ProgressBar
    $bar.Width = $width - (Get-FujiScaled 30)
    $bar.Maximum = 1000
    [void]$layout.Controls.Add($bar)
    $status = New-FujiLabel -Text ''
    [void]$layout.Controls.Add($status)
    $buttons = New-FujiButtonBar
    $state = @{ Cancel = $false; Last = [DateTime]::MinValue }
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.aiCopyCancel')
    $cancel.Add_Click({ $state.Cancel = $true })
    [void]$buttons.Controls.Add($cancel)
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($buttons)
    $owner = Get-FujiOwner
    if ($null -ne $owner) { $f.Show($owner) } else { $f.Show() }
    try {
        return (Copy-FujiAiLocal -SharedDir $SharedDir -Progress {
                param($Done, $Total)
                $now = [DateTime]::Now
                if (($now - $state.Last).TotalMilliseconds -lt 200 -and $Done -lt $Total) { return }
                $state.Last = $now
                if ($Total -gt 0) { $bar.Value = [int][Math]::Min(1000, $Done * 1000 / $Total) }
                $status.Text = Get-FujiText 'gui.aiCopyStatus' ([int]($Done / 1MB)) ([int]($Total / 1MB)) ([int]($Done * 100 / [Math]::Max(1, $Total)))
                [System.Windows.Forms.Application]::DoEvents()
            } -Cancel { $state.Cancel })
    } finally {
        $f.Close()
        $f.Dispose()
    }
}

# The AI was not sure (low = ASK): the question, the text read and the options with their probabilities;
# returns @{ Choice = 'continue'|'stop'; Value }
function Show-FujiRunAiPick {
    param([string]$Caption, [string]$Message, [object[]]$Options, [string]$Initial)
    [void](Invoke-FujiWindowActivate -Handle $script:Ui.Form.Handle)
    $width = Get-FujiScaled 520
    $f = New-FujiDialogForm -Title $Caption -Width $width -Height (Get-FujiScaled 420)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiPickNote') -MaxWidth ($width - (Get-FujiScaled 30))))
    $text = New-FujiTextBox -Text ($Message -replace "`r?`n", "`r`n") -Width ($width - (Get-FujiScaled 30)) -Multiline
    $text.ReadOnly = $true
    $text.Height = Get-FujiScaled 150
    [void]$layout.Controls.Add($text)
    $list = New-Object -TypeName System.Windows.Forms.ListBox
    $list.Width = $width - (Get-FujiScaled 30)
    $list.Height = Get-FujiScaled 120
    $list.IntegralHeight = $false
    foreach ($o in $Options) {
        [void]$list.Items.Add((Get-FujiText 'gui.aiPickItem' $o.Value ([double]$o.P).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)))
        if ($o.Value -eq $Initial) { $list.SelectedIndex = $list.Items.Count - 1 }
    }
    if ($list.SelectedIndex -lt 0 -and $list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    [void]$layout.Controls.Add($list)
    $bar = New-FujiButtonBar
    $script:Ui.AiPick = @{ Choice = 'stop'; Index = -1; List = $list }
    foreach ($b in @(@('stop', 'gui.aiPickStop'), @('continue', 'gui.aiPickUse'))) {
        $btn = New-FujiButton -Text (Get-FujiText $b[1]) -Tag $b[0]
        $btn.Add_Click({ $script:Ui.AiPick.Choice = [string]$this.Tag; $script:Ui.AiPick.Index = $script:Ui.AiPick.List.SelectedIndex; $this.FindForm().Close() })
        [void]$bar.Controls.Add($btn)
        if ($b[0] -eq 'continue') { $f.AcceptButton = $btn }
    }
    $list.Add_DoubleClick({ $script:Ui.AiPick.Choice = 'continue'; $script:Ui.AiPick.Index = $this.SelectedIndex; $this.FindForm().Close() })
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    # the answer list has the focus (Enter takes the chosen one); the text is not selected
    $f.Add_Shown({ $script:Ui.AiPick.List.Focus() })
    Show-FujiAlert -Kind 'confirm' -Title (Get-FujiText 'alert.confirmTitle') -Lines @($Caption)
    try { [void](Show-FujiDialog -Form $f) } finally { Close-FujiAlert }
    $f.Dispose()
    $r = $script:Ui.AiPick
    if ($r.Choice -ne 'continue' -or $r.Index -lt 0 -or $r.Index -ge $Options.Count) { return @{ Choice = 'stop'; Value = '' } }
    return @{ Choice = 'continue'; Value = [string]$Options[$r.Index].Value }
}

# The state shown in the AI settings: shared and copied versions, and what to do
function Get-FujiAiStatusText {
    param([string]$Folder)
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $shared = $null
    if ($Folder) { try { $shared = Read-FujiAiManifest -Path (Join-Path $Folder 'ai.json') } catch { $shared = $null } }
    if ($null -ne $shared) { $lines.Add((Get-FujiText 'gui.aiStatusShared' $shared.AiVersion $shared.Model)) }
    elseif ($Folder) { $lines.Add((Get-FujiText 'gui.aiStatusSharedNone' $Folder)) }
    else { $lines.Add((Get-FujiText 'gui.aiStatusNoFolder')) }
    $localDir = Get-FujiAiLocalDir
    $local = Get-FujiAiLocalManifest -LocalDir $localDir
    if ($null -ne $local) { $lines.Add((Get-FujiText 'gui.aiStatusLocal' $local.AiVersion $localDir)) } else { $lines.Add((Get-FujiText 'gui.aiStatusLocalNone')) }
    if ($null -ne $shared -and (Test-FujiAiCopyNeeded -Shared $shared -Local $local -LocalDir $localDir) -eq 'copy') { $lines.Add((Get-FujiText 'gui.aiStatusCopyNeeded')) }
    return ($lines -join "`r`n")
}

# Starts the server, asks one question, stops it; returns the text to show (and checks the copy's SHA-256)
function Invoke-FujiAiTest {
    param([string]$Folder)
    $out = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $dir = Resolve-FujiAiReady -SharedDir $Folder -Copy { Show-FujiAiCopyDialog -SharedDir $Folder } -Log { param($Message) $out.Add($Message) }
    $m = Get-FujiAiLocalManifest -LocalDir $dir
    $want = ''
    if ($m.Files[$m.Model].Contains('sha256')) { $want = ([string]$m.Files[$m.Model]['sha256']).ToLowerInvariant() }
    $got = (Get-FileHash -LiteralPath (Join-Path $dir $m.Model) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($want -and $got -ne $want) { throw (Get-FujiText 'run.aiCopyBad' $m.Model) }
    $out.Add((Get-FujiText 'gui.aiTestSha'))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-FujiAiServer
    $srv = Start-FujiAiServer -LocalDir $dir -LogDir (Join-Path $script:Ed.Directory $script:FujiLogFolder)
    $start = $sw.Elapsed.TotalSeconds
    try {
        $opts = Read-FujiAiOption -Text (Get-FujiText 'gui.aiTestOptions')
        $body = New-FujiAiChooseBody -Question (Get-FujiText 'gui.aiTestQuestion') -Options $opts -Source (Get-FujiText 'gui.aiTestSource')
        $body.Remove('Truncated')
        $sw.Restart()
        $c = Read-FujiAiChoice -Response (Invoke-FujiAiChat -Server $srv -Body $body) -Options $opts
        $out.Add((Get-FujiText 'gui.aiTestResult' ('{0:N1}' -f $start) $c.Value ([double]$c.P).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture) ('{0:N1}' -f $sw.Elapsed.TotalSeconds)))
    } finally { Stop-FujiAiServer -Server $srv }
    return ($out -join "`r`n")
}

function Show-FujiAiSettingDialog {
    $width = Get-FujiScaled 560
    $f = New-FujiDialogForm -Title (Get-FujiText 'gui.aiTitle') -Width $width -Height (Get-FujiScaled 380)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiFolderLabel') -MaxWidth ($width - (Get-FujiScaled 30))))
    $row = New-FujiFlow
    $box = New-FujiTextBox -Text (Get-FujiAiFolderSetting -Settings $script:Settings) -Width ($width - (Get-FujiScaled 130))
    $pick = New-FujiButton -Text (Get-FujiText 'gui.aiFolderPick')
    [void]$row.Controls.Add($box)
    [void]$row.Controls.Add($pick)
    [void]$layout.Controls.Add($row)
    $spotRow = New-FujiFlow
    $spotBox = New-FujiTextBox -Text ([string](Get-FujiAiSpotSetting -Settings $script:Settings)) -Width (Get-FujiScaled 50)
    [void]$spotRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiSpotLabel')))
    [void]$spotRow.Controls.Add($spotBox)
    [void]$spotRow.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.aiSpotNote')))
    [void]$layout.Controls.Add($spotRow)
    $status = New-FujiTextBox -Text '' -Width ($width - (Get-FujiScaled 30)) -Multiline
    $status.ReadOnly = $true
    $status.Height = Get-FujiScaled 150
    [void]$layout.Controls.Add($status)
    $actions = New-FujiFlow
    $copyBtn = New-FujiButton -Text (Get-FujiText 'gui.aiCopyNow')
    $deleteBtn = New-FujiButton -Text (Get-FujiText 'gui.aiDeleteCopy')
    $testBtn = New-FujiButton -Text (Get-FujiText 'gui.aiTest')
    foreach ($b in @($copyBtn, $deleteBtn, $testBtn)) { [void]$actions.Controls.Add($b) }
    [void]$layout.Controls.Add($actions)
    $ctx = @{ Box = $box; Status = $status }
    $refresh = { $ctx.Status.Text = Get-FujiAiStatusText -Folder $ctx.Box.Text.Trim() }
    $pick.Add_Click({ Invoke-FujiUi { $p = Select-FujiAiFolderUi -Start $ctx.Box.Text.Trim(); if ($p) { $ctx.Box.Text = $p }; & $refresh } })
    $box.Add_Leave({ Invoke-FujiUi { & $refresh } })
    $copyBtn.Add_Click({ Invoke-FujiUi {
                try {
                    Stop-FujiAiServer
                    if ((Show-FujiAiCopyDialog -SharedDir $ctx.Box.Text.Trim()) -eq 'copied') { & $refresh; $ctx.Status.AppendText("`r`n" + (Get-FujiText 'gui.aiCopied')) }
                } catch { & $refresh; $ctx.Status.AppendText("`r`n" + $_.Exception.Message) }
            } })
    $deleteBtn.Add_Click({ Invoke-FujiUi {
                if ((Show-FujiChoice -Title (Get-FujiText 'gui.aiTitle') -Message (Get-FujiText 'gui.aiDeleteConfirm' (Get-FujiAiLocalDir)) -Buttons @((Get-FujiText 'gui.aiDeleteCopy'), (Get-FujiText 'gui.cancel'))) -ne 0) { return }
                Stop-FujiAiServer
                try { Remove-FujiAiCopy } catch { $ctx.Status.AppendText("`r`n" + $_.Exception.Message) }
                & $refresh
            } })
    $testBtn.Add_Click({ Invoke-FujiUi {
                $ctx.Status.Text = Get-FujiText 'gui.aiTesting'
                [System.Windows.Forms.Application]::DoEvents()
                try { $ctx.Status.Text = Invoke-FujiAiTest -Folder $ctx.Box.Text.Trim() } catch { $ctx.Status.Text = $_.Exception.Message }
            } })
    $bar = New-FujiButtonBar
    $close = New-FujiButton -Text (Get-FujiText 'gui.aiSaveClose')
    $close.Add_Click({ $this.FindForm().Close() })
    [void]$bar.Controls.Add($close)
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $f.Add_Shown({ Invoke-FujiUi { & $refresh } })
    [void](Show-FujiDialog -Form $f)
    $spot = 0
    if (-not [int]::TryParse((ConvertTo-FujiHalfWidthDigit -Text $spotBox.Text.Trim()), [ref]$spot)) { $spot = Get-FujiAiSpotSetting -Settings $script:Settings }
    if ($box.Text.Trim() -ne (Get-FujiAiFolderSetting -Settings $script:Settings) -or $spot -ne (Get-FujiAiSpotSetting -Settings $script:Settings)) {
        Set-FujiAiFolderSetting -Settings $script:Settings -Folder $box.Text
        Set-FujiAiSpotSetting -Settings $script:Settings -Percent $spot
        Save-FujiSetting -Directory $script:Ed.Directory -Settings $script:Settings
    }
    $f.Dispose()
    Update-FujiAiAvailableUi
}

# The AI commands and the review are usable only when this person has chosen an AI folder:
# without one they are gray (the rest of the app does not need the AI). The name and the row of
# the AI commands say how to turn them on (a gray button shows no tip of its own)
function Update-FujiAiAvailableUi {
    $on = Test-FujiAiAvailable -Settings $script:Settings
    $tip = if ($on) { '' } else { Get-FujiText 'gui.aiOffTip' }
    if ($null -ne $script:Ui['AiPalette']) {
        foreach ($c in $script:Ui.AiPalette) {
            if ($c -is [System.Windows.Forms.Button]) {
                # a flat button keeps its colours when off, so it is made gray to look off
                $c.Enabled = $on
                $edge = if ($on) { Get-FujiColor $script:CategoryColors['ai'] } else { Get-FujiColor '#bdbdbd' }
                $c.FlatAppearance.BorderColor = $edge
                $c.BackColor = if ($on) { Get-FujiTint -Color $edge -Amount 0.88 } else { Get-FujiColor '#eeeeee' }
            } else { $script:Ui.ToolTip.SetToolTip($c, $tip) }
        }
    }
    if ($null -ne $script:Ui['AiReviewButton']) { $script:Ui.AiReviewButton.Enabled = $on }
}
