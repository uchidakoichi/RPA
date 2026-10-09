# ---------------------------------------------------------------------------------------------
#  Step editor dialog, built from the command's fields in fujikyun_commands.json
#  Field types: text, textarea, select, keypreset, csvcol, imgpath, capture, rectcapture,
#  macroselect; "placeholders" adds the insert-a-placeholder list, "hint" a note below.
# ---------------------------------------------------------------------------------------------

$script:StepDlg = $null
$script:EmSetCueBanner = 0x1501

# Returns the new step (ordered dictionary) or $null when cancelled
function Show-FujiStepDialog {
    param([Parameter(Mandatory)][string]$Cmd, $Step = $null)
    $def = Get-FujiCommandDef $Cmd
    $lookup = Get-FujiMacroNameLookup $script:Ed
    $state = Get-FujiStepEditState -Cmd $Cmd -Step $Step -MacroNameOf $lookup
    $titleKey = 'gui.addTitle'
    if ($null -ne $Step) { $titleKey = 'gui.editTitle' }
    $width = Get-FujiScaled 720
    $content = $width - (Get-FujiScaled 60)
    $form = New-FujiDialogForm -Title (Get-FujiText $titleKey $def['icon'] $def['title'] $Cmd) -Width $width -Height (Get-FujiScaled 400)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList ([int]($width / 2)), (Get-FujiScaled 220)

    $panel = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.ColumnCount = 1
    Add-FujiFullColumn -Table $panel
    $panel.AutoScroll = $true
    $panel.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 12)

    $script:StepDlg = @{
        Form = $form; Cmd = $Cmd; Inputs = @{}; Status = @{}; Cues = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        Timer = $null; Mode = ''; Remaining = 0; First = $null; Result = $null
        Preview = $null; ImgW = $null; ImgH = $null; Error = $null; Label = $null
    }

    $help = New-FujiLabel -Text ([string]$def['help']) -MaxWidth $content
    $help.ForeColor = Get-FujiColor '#5e5368'
    [void]$panel.Controls.Add($help)
    foreach ($field in $def['fields']) {
        Add-FujiStepField -Panel $panel -Field $field -Value ([string]$state.Values[[string]$field['id']]) -Width $content
    }
    [void]$panel.Controls.Add((New-FujiFieldLabel -Text (Get-FujiText 'gui.labelField') -Width $content))
    $labelBox = New-FujiTextBox -Text $state.CustomLabel -Width $content
    $script:StepDlg.Label = $labelBox
    [void]$panel.Controls.Add($labelBox)
    $err = New-FujiLabel -Text '' -MaxWidth $content
    $err.ForeColor = Get-FujiColor '#c62828'
    $err.Font = $script:Ui.BoldFont
    $script:StepDlg.Error = $err
    [void]$panel.Controls.Add($err)

    $bar = New-FujiButtonBar
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $okText = Get-FujiText 'gui.addButton'
    if ($null -ne $Step) { $okText = Get-FujiText 'gui.update' }
    $ok = New-FujiButton -Text $okText
    $ok.Font = $script:Ui.BoldFont
    $ok.Add_Click({ Invoke-FujiUi { Complete-FujiStepDialog } })
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    [void]$form.Controls.Add($panel)
    [void]$form.Controls.Add($bar)

    # Height that fits the fields, within the screen
    $pref = $panel.GetPreferredSize((New-Object -TypeName System.Drawing.Size -ArgumentList $width, 0))
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $height = [Math]::Min([int]($area.Height * 0.85), $pref.Height + $bar.GetPreferredSize([System.Drawing.Size]::Empty).Height + (Get-FujiScaled 20))
    $form.ClientSize = New-Object -TypeName System.Drawing.Size -ArgumentList $width, ([Math]::Max($height, (Get-FujiScaled 200)))

    $form.Add_Shown({
            # Grey example text inside empty one-line boxes (EM_SETCUEBANNER)
            foreach ($cue in $script:StepDlg.Cues) {
                [void][FujiUi.Native]::SendMessage($cue[0].Handle, $script:EmSetCueBanner, [IntPtr]1, [string]$cue[1])
            }
            Update-FujiImagePreview -Opening
        })
    $form.Add_FormClosed({ if ($script:StepDlg.Timer) { $script:StepDlg.Timer.Stop(); $script:StepDlg.Timer.Dispose() } })
    [void](Show-FujiDialog -Form $form)
    $result = $script:StepDlg.Result
    if ($script:StepDlg.Preview -and $script:StepDlg.Preview.Image) { $script:StepDlg.Preview.Image.Dispose() }
    $form.Dispose()
    $script:StepDlg = $null
    return $result
}

function New-FujiFieldLabel {
    param([string]$Text, [int]$Width)
    $l = New-FujiLabel -Text $Text -MaxWidth $Width
    $l.Font = $script:Ui.BoldFont
    $l.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 3), (Get-FujiScaled 10), (Get-FujiScaled 3), 0
    return $l
}

function New-FujiHintLabel {
    param([string]$Text, [int]$Width)
    $l = New-FujiLabel -Text $Text -MaxWidth $Width
    $l.ForeColor = Get-FujiColor '#7a6f84'
    $l.Font = $script:Ui.SmallFont
    return $l
}

# A drop-down that fills Target: Mode 'set' replaces the text, 'append' adds to it
function New-FujiHelperCombo {
    param([string]$First, [object[]]$Choices, [object[]]$Values, $Target, [string]$Mode, [int]$Width)
    $items = @($First) + @($Choices)
    $c = New-FujiComboBox -Items $items -Width $Width
    $c.Tag = @{ Values = (@('') + @($Values)); Target = $Target; Mode = $Mode }
    $c.SelectedIndex = 0
    $c.Add_SelectedIndexChanged({
            $box = $this
            if ($box.SelectedIndex -le 0) { return }
            $info = $box.Tag
            $v = [string]$info.Values[$box.SelectedIndex]
            if ($info.Mode -eq 'append') {
                $info.Target.Text += $v
                $info.Target.Focus()
                $info.Target.SelectionStart = $info.Target.TextLength
            } else {
                $info.Target.Text = $v
            }
            $box.SelectedIndex = 0
        })
    return $c
}

function Set-FujiComboValue {
    param($Combo, [string]$Value)
    $i = [Array]::IndexOf([object[]]$Combo.Tag, $Value)
    if ($i -lt 0) { $i = 0 }
    if ($Combo.Items.Count -gt 0) { $Combo.SelectedIndex = $i }
}

function Get-FujiInputValue {
    param($Control)
    if ($Control -is [System.Windows.Forms.ComboBox]) {
        if ($Control.SelectedIndex -lt 0) { return '' }
        return [string]([object[]]$Control.Tag)[$Control.SelectedIndex]
    }
    return [string]$Control.Text
}

function Add-FujiStepField {
    param($Panel, [System.Collections.IDictionary]$Field, [string]$Value, [int]$Width)
    $d = $script:StepDlg
    $id = [string]$Field['id']
    $type = [string]$Field['type']
    [void]$Panel.Controls.Add((New-FujiFieldLabel -Text ([string]$Field['label']) -Width $Width))
    $row = New-FujiFlow -NoWrap
    $inputControl = $null
    switch ($type) {
        'textarea' {
            $inputControl = New-FujiTextBox -Text $Value -Width $Width -Multiline
            [void]$row.Controls.Add($inputControl)
        }
        'select' {
            $labels = @()
            $values = @()
            foreach ($o in $Field['options']) { $values += [string]$o[0]; $labels += [string]$o[1] }
            $inputControl = New-FujiComboBox -Items $labels -Values $values -Width ([Math]::Min($Width, (Get-FujiScaled 460)))
            Set-FujiComboValue -Combo $inputControl -Value $Value
            [void]$row.Controls.Add($inputControl)
        }
        'keypreset' {
            $inputControl = New-FujiTextBox -Text $Value -Width (Get-FujiScaled 260)
            $choices = @()
            $keys = @()
            foreach ($p in $script:FujiCommands['keyPresets']) { $keys += [string]$p[0]; $choices += ([string]$p[0] + '  ' + [string]$p[1]) }
            [void]$row.Controls.Add($inputControl)
            [void]$row.Controls.Add((New-FujiHelperCombo -First (Get-FujiText 'gui.presetKeys') -Choices $choices -Values $keys -Target $inputControl -Mode 'set' -Width (Get-FujiScaled 300)))
        }
        'csvcol' {
            $inputControl = New-FujiTextBox -Text $Value -Width (Get-FujiScaled 120)
            [void]$row.Controls.Add($inputControl)
            $cols = Get-FujiCsvMaxColumn $script:Ed
            if ($cols -gt 0) {
                $choices = @()
                $nums = @()
                $first = @()
                if (@($script:Ed.Csv.Rows).Count -gt 0) { $first = @($script:Ed.Csv.Rows[0]) }
                for ($i = 1; $i -le $cols; $i++) {
                    $name = Get-FujiCsvHeaderName -Editor $script:Ed -Column $i
                    if (-not $name) { $name = Get-FujiText 'gui.noHeader' }
                    $sample = ''
                    if ($i -le $first.Count) { $sample = Format-FujiShort ([string]$first[$i - 1]) 14 }
                    $choices += (Get-FujiText 'gui.csvColItem' $i $name $sample)
                    $nums += [string]$i
                }
                [void]$row.Controls.Add((New-FujiHelperCombo -First (Get-FujiText 'gui.csvCols') -Choices $choices -Values $nums -Target $inputControl -Mode 'set' -Width (Get-FujiScaled 420)))
            }
        }
        'imgpath' {
            $inputControl = New-FujiTextBox -Text $Value -Width ($Width - (Get-FujiScaled 150))
            $inputControl.Add_TextChanged({ Invoke-FujiUi { Update-FujiImagePreview } })
            $browse = New-FujiButton -Text (Get-FujiText 'gui.imgBrowse')
            $browse.Add_Click({ Invoke-FujiUi { Select-FujiImageFile } })
            [void]$row.Controls.Add($inputControl)
            [void]$row.Controls.Add($browse)
            [void]$Panel.Controls.Add($row)
            $row = New-FujiFlow -NoWrap
            $cap = New-FujiButton -Text (Get-FujiText 'gui.imgCapture') -Tag 'img'
            $cap.Add_Click({ Invoke-FujiUi { Start-FujiStepCapture -Mode 'img' } })
            $d.ImgW = New-FujiTextBox -Text '60' -Width (Get-FujiScaled 50)
            $d.ImgH = New-FujiTextBox -Text '30' -Width (Get-FujiScaled 50)
            [void]$row.Controls.Add($cap)
            [void]$row.Controls.Add((New-FujiLabel -Text (Get-FujiText 'gui.imgWidth')))
            [void]$row.Controls.Add($d.ImgW)
            [void]$row.Controls.Add((New-FujiLabel -Text ([string][char]0x00D7 + ' ' + (Get-FujiText 'gui.imgHeight'))))
            [void]$row.Controls.Add($d.ImgH)
            [void]$Panel.Controls.Add($row)
            $d.Status['img'] = New-FujiHintLabel -Text '' -Width $Width
            [void]$Panel.Controls.Add($d.Status['img'])
            $pic = New-Object -TypeName System.Windows.Forms.PictureBox
            $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $pic.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (Get-FujiScaled 240), (Get-FujiScaled 90)
            $pic.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $d.Preview = $pic
            $row = New-FujiFlow -NoWrap
            [void]$row.Controls.Add($pic)
        }
        'capture' {
            $b = New-FujiButton -Text (Get-FujiText 'gui.capture')
            $b.Add_Click({ Invoke-FujiUi { Start-FujiStepCapture -Mode 'pos' } })
            [void]$row.Controls.Add($b)
            $d.Status['pos'] = New-FujiHintLabel -Text '' -Width ($Width - (Get-FujiScaled 260))
            [void]$row.Controls.Add($d.Status['pos'])
        }
        'rectcapture' {
            $b = New-FujiButton -Text (Get-FujiText 'gui.rect')
            $b.Add_Click({ Invoke-FujiUi { Start-FujiStepCapture -Mode 'rect1' } })
            [void]$row.Controls.Add($b)
            $d.Status['rect'] = New-FujiHintLabel -Text '' -Width $Width
            [void]$Panel.Controls.Add($row)
            $row = New-FujiFlow -NoWrap
            [void]$row.Controls.Add($d.Status['rect'])
        }
        'macroselect' {
            $labels = @(Get-FujiText 'gui.chooseMacro')
            $values = @('')
            for ($i = 0; $i -lt $script:Ed.Data.macros.Count; $i++) {
                $m = $script:Ed.Data.macros[$i]
                $text = [string]$m.name
                if ($i -eq $script:Ed.MacroIndex) { $text += Get-FujiText 'gui.thisMacro' }
                $labels += $text
                $values += [string]$m.id
            }
            $inputControl = New-FujiComboBox -Items $labels -Values $values -Width ([Math]::Min($Width, (Get-FujiScaled 460)))
            Set-FujiComboValue -Combo $inputControl -Value $Value
            [void]$row.Controls.Add($inputControl)
        }
        default {
            $inputControl = New-FujiTextBox -Text $Value -Width $Width
            [void]$row.Controls.Add($inputControl)
        }
    }
    if ($null -ne $inputControl) {
        $d.Inputs[$id] = $inputControl
        if ($inputControl -is [System.Windows.Forms.TextBox] -and -not $inputControl.Multiline -and $Field.Contains('placeholder') -and $Field['placeholder']) {
            $d.Cues.Add(@($inputControl, [string]$Field['placeholder']))
        }
    }
    [void]$Panel.Controls.Add($row)
    if ($Field.Contains('placeholders') -and $Field['placeholders'] -and $null -ne $inputControl) {
        $choices = @()
        $tokens = @()
        foreach ($p in (Get-FujiPlaceholderChoice -Editor $script:Ed)) { $tokens += [string]$p[0]; $choices += ([string]$p[0] + '  ' + [string]$p[1]) }
        [void]$Panel.Controls.Add((New-FujiHelperCombo -First (Get-FujiText 'gui.placeholders') -Choices $choices -Values $tokens -Target $inputControl -Mode 'append' -Width (Get-FujiScaled 420)))
    }
    if ($type -eq 'csvcol' -and (Get-FujiCsvMaxColumn $script:Ed) -eq 0) {
        [void]$Panel.Controls.Add((New-FujiHintLabel -Text (Get-FujiText 'gui.csvColHint') -Width $Width))
    }
    if ($Field.Contains('hint') -and $Field['hint']) {
        [void]$Panel.Controls.Add((New-FujiHintLabel -Text ([string]$Field['hint']) -Width $Width))
    }
}

function Complete-FujiStepDialog {
    $d = $script:StepDlg
    $raw = @{}
    foreach ($id in $d.Inputs.Keys) { $raw[$id] = Get-FujiInputValue $d.Inputs[$id] }
    $res = Complete-FujiStepEdit -Cmd $d.Cmd -Raw $raw -Label $d.Label.Text -MacroNameOf (Get-FujiMacroNameLookup $script:Ed)
    if ($res.ContainsKey('Error')) {
        $d.Error.Text = $res.Error
        return
    }
    $d.Result = $res.Step
    $d.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

# ----------------------------------------------------------------- reference image
# Opening: the dialog was just opened. A network path (\\server\...) from a macro file is not read
# then: reading it connects to that server, and Windows may send the user's sign-in (NTLM) to it.
# It is shown once the user types or picks the path.
function Update-FujiImagePreview {
    param([switch]$Opening)
    $d = $script:StepDlg
    if ($null -eq $d -or $null -eq $d.Preview -or -not $d.Inputs.ContainsKey('path')) { return }
    $old = $d.Preview.Image
    $d.Preview.Image = $null
    if ($old) { $old.Dispose() }
    $full = Resolve-FujiEditorPath -Editor $script:Ed -Path $d.Inputs['path'].Text
    if ($full -eq '') { return }
    if ($Opening -and ($full.StartsWith('\\') -or $full.StartsWith('//'))) {
        $d.Status['img'].Text = Get-FujiText 'gui.imgNetworkNotShown' $full
        return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $d.Status['img'].Text = Get-FujiText 'gui.imgMissing' $full
        return
    }
    # A copy, so the file is not kept locked while the dialog is open
    $src = [System.Drawing.Image]::FromFile($full)
    try { $d.Preview.Image = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $src } finally { $src.Dispose() }
    if ($d.Status['img'].Text.StartsWith([string][char]0x26A0)) { $d.Status['img'].Text = '' }
}

function Select-FujiImageFile {
    $dlg = New-Object -TypeName System.Windows.Forms.OpenFileDialog
    $dlg.Filter = Get-FujiText 'gui.imageFilter'
    $folder = Get-FujiEditorPath $script:Ed $script:FujiFileNames.Images
    if (Test-Path -LiteralPath $folder) { $dlg.InitialDirectory = $folder } else { $dlg.InitialDirectory = $script:Ed.Directory }
    if ($dlg.ShowDialog($script:StepDlg.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $path = $dlg.FileName
        $base = $script:Ed.Directory.TrimEnd('\') + '\'
        if ($path.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring($base.Length) }
        $script:StepDlg.Inputs['path'].Text = $path
    }
    $dlg.Dispose()
}

# ----------------------------------------------------------------- mouse position / region / image capture
# Counts down with a timer (the window stays responsive), then reads the cursor position
function Start-FujiStepCapture {
    param([ValidateSet('pos', 'rect1', 'img')][string]$Mode)
    $d = $script:StepDlg
    if ($null -eq $d.Timer) {
        $d.Timer = New-Object -TypeName System.Windows.Forms.Timer
        $d.Timer.Interval = 1000
        $d.Timer.Add_Tick({ Invoke-FujiUi { Step-FujiStepCapture } })
    }
    $d.Timer.Stop()
    $d.Mode = $Mode
    $d.Remaining = 3
    if ($Mode -eq 'img') { $d.Remaining = 5 }
    Update-FujiCaptureStatus
    $d.Timer.Start()
}

function Update-FujiCaptureStatus {
    $d = $script:StepDlg
    switch ($d.Mode) {
        'pos' { $d.Status['pos'].Text = Get-FujiText 'gui.captureWait' $d.Remaining }
        'rect1' { $d.Status['rect'].Text = Get-FujiText 'gui.rectWait1' $d.Remaining }
        'rect2' { $d.Status['rect'].Text = Get-FujiText 'gui.rectWait2' $d.Remaining }
        'img' { $d.Status['img'].Text = Get-FujiText 'gui.imgWait' $d.Remaining }
    }
}

function Step-FujiStepCapture {
    $d = $script:StepDlg
    if ($null -eq $d) { return }
    $d.Remaining--
    if ($d.Remaining -gt 0) { Update-FujiCaptureStatus; return }
    $p = [System.Windows.Forms.Cursor]::Position
    switch ($d.Mode) {
        'pos' {
            $d.Timer.Stop()
            $d.Inputs['x'].Text = [string]$p.X
            $d.Inputs['y'].Text = [string]$p.Y
            $d.Status['pos'].Text = Get-FujiText 'gui.captureDone' $p.X $p.Y
        }
        'rect1' {
            $d.First = $p
            [System.Media.SystemSounds]::Beep.Play()
            $d.Mode = 'rect2'
            $d.Remaining = 3
            Update-FujiCaptureStatus
        }
        'rect2' {
            $d.Timer.Stop()
            $a = $d.First
            $x = [Math]::Min($a.X, $p.X)
            $y = [Math]::Min($a.Y, $p.Y)
            $w = [Math]::Abs($p.X - $a.X)
            $h = [Math]::Abs($p.Y - $a.Y)
            $d.Inputs['x'].Text = [string]$x
            $d.Inputs['y'].Text = [string]$y
            $d.Inputs['w'].Text = [string]$w
            $d.Inputs['h'].Text = [string]$h
            if ($d.Inputs.ContainsKey('area')) { Set-FujiComboValue -Combo $d.Inputs['area'] -Value 'RECT' }
            $d.Status['rect'].Text = Get-FujiText 'gui.rectDone' $x $y $w $h
        }
        'img' {
            $d.Timer.Stop()
            Save-FujiCursorImage -Cursor $p
        }
    }
}

function Save-FujiCursorImage {
    param([Parameter(Mandatory)][System.Drawing.Point]$Cursor)
    $d = $script:StepDlg
    $w = [Math]::Min(400, [Math]::Max(8, (Get-FujiInt -Text $d.ImgW.Text -Default 60)))
    $h = [Math]::Min(400, [Math]::Max(8, (Get-FujiInt -Text $d.ImgH.Text -Default 30)))
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $r = Get-FujiCaptureRect -X $Cursor.X -Y $Cursor.Y -Width $w -Height $h -Screen @{ X = $vs.X; Y = $vs.Y; Width = $vs.Width; Height = $vs.Height }
    $folder = Get-FujiEditorPath $script:Ed $script:FujiFileNames.Images
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder) }
    $name = 'img_' + (Get-FujiTimeStamp) + '.png'
    $relative = $script:FujiFileNames.Images + '\' + $name
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $r.Width, $r.Height
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { $g.CopyFromScreen($r.X, $r.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
        $bmp.Save((Join-Path $folder $name), [System.Drawing.Imaging.ImageFormat]::Png)
    } catch {
        $d.Status['img'].Text = Get-FujiText 'gui.imgFailed' $_.Exception.Message
        return
    } finally {
        $bmp.Dispose()
    }
    $d.Inputs['path'].Text = $relative
    $text = Get-FujiText 'gui.imgDone' $Cursor.X $Cursor.Y $r.Width $r.Height $relative
    if ($r.Width -lt $w - 1 -or $r.Height -lt $h - 1) { $text += Get-FujiText 'gui.imgEdge' }
    $d.Status['img'].Text = $text
    Write-FujiUiLog -Message (Get-FujiText 'gui.imgSaved' $relative) -Level 'ok'
}
