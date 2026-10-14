# ---------------------------------------------------------------------------------------------
#  The password dialog of the SECRET step: register, change or remove a credential
#  (src/Credential.ps1 reads and writes the Windows Credential Manager)
# ---------------------------------------------------------------------------------------------

# ----------------------------------------------------------------- the dialog: register, change, remove
# Returns the status text for the step dialog
# DefaultWindow: the window title offered when nothing is registered yet (the macro's target window)
function Show-FujiCredentialDialog {
    param([Parameter(Mandatory)][string]$Target, [AllowEmptyString()][string]$DefaultWindow = '')
    $existing = $null
    try { $existing = Read-FujiCredential -Target $Target } catch { $existing = $null }
    $width = Get-FujiScaled 480
    $f = New-FujiDialogForm -Title (Get-FujiText 'cred.title' $Target) -Width $width -Height (Get-FujiScaled 470)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    $inner = $width - (Get-FujiScaled 40)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'cred.help') -MaxWidth $inner))
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'cred.user')))
    $userText = ''
    if ($null -ne $existing) { $userText = $existing.User }
    $user = New-FujiTextBox -Text $userText -Width $inner
    [void]$layout.Controls.Add($user)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'cred.password')))
    $pass = New-FujiTextBox -Width $inner
    $pass.UseSystemPasswordChar = $true
    [void]$layout.Controls.Add($pass)
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'cred.again')))
    $again = New-FujiTextBox -Width $inner
    $again.UseSystemPasswordChar = $true
    [void]$layout.Controls.Add($again)
    # the only window the password may be typed into
    [void]$layout.Controls.Add((New-FujiLabel -Text (Get-FujiText 'cred.place') -MaxWidth $inner))
    $windowText = $DefaultWindow
    $programText = ''
    if ($null -ne $existing -and $existing.Window) { $windowText = $existing.Window; $programText = $existing.Program }
    $window = New-FujiTextBox -Text $windowText -Width $inner
    [void]$layout.Controls.Add($window)
    $placeRow = New-FujiFlow -NoWrap
    $point = New-FujiButton -Text (Get-FujiText 'cred.point') -Tip (Get-FujiText 'cred.pointTip')
    $point.Add_Click({ Invoke-FujiUi { Start-FujiCredentialPoint } })
    $program = New-FujiLabel -Text (Get-FujiCredentialProgramText $programText)
    [void]$placeRow.Controls.Add($point)
    [void]$placeRow.Controls.Add($program)
    [void]$layout.Controls.Add($placeRow)
    $err = New-FujiLabel -Text '' -MaxWidth $inner
    $err.ForeColor = Get-FujiColor '#c62828'
    [void]$layout.Controls.Add($err)
    $bar = New-FujiButtonBar
    $script:Ui.CredDialog = @{ Target = $Target; User = $user; Pass = $pass; Again = $again; Error = $err; Result = ''
        Window = $window; Program = $programText; ProgramLabel = $program; Timer = $null; Remaining = 0 }
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $save = New-FujiButton -Text (Get-FujiText 'cred.save')
    $save.Font = $script:Ui.BoldFont
    $save.Add_Click({ Invoke-FujiUi { Complete-FujiCredentialDialog } })
    # RightToLeft bar: the last added is leftmost
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($save)
    if ($null -ne $existing) {
        $remove = New-FujiButton -Text (Get-FujiText 'cred.remove')
        $remove.Add_Click({ Invoke-FujiUi { Remove-FujiCredentialFromDialog } })
        [void]$bar.Controls.Add($remove)
    }
    $f.AcceptButton = $save
    $f.CancelButton = $cancel
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $f.Add_Shown({ if ($script:Ui.CredDialog.User.Text) { $script:Ui.CredDialog.Pass.Focus() } else { $script:Ui.CredDialog.User.Focus() } })
    $f.Add_FormClosed({ if ($script:Ui.CredDialog.Timer) { $script:Ui.CredDialog.Timer.Stop(); $script:Ui.CredDialog.Timer.Dispose() } })
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
    $result = $script:Ui.CredDialog.Result
    $script:Ui.CredDialog = $null
    if ($result) { return $result }
    return (Get-FujiCredentialStatus -Target $Target)
}

function Complete-FujiCredentialDialog {
    $d = $script:Ui.CredDialog
    if ($d.Pass.Text -eq '') { $d.Error.Text = Get-FujiText 'cred.empty'; return }
    if ($d.Pass.Text -cne $d.Again.Text) { $d.Error.Text = Get-FujiText 'cred.mismatch'; return }
    if ($d.Window.Text.Trim() -eq '' -or -not $d.Program) { $d.Error.Text = Get-FujiText 'cred.placeEmpty'; return }
    $secret = New-Object -TypeName System.Security.SecureString
    foreach ($ch in $d.Pass.Text.ToCharArray()) { $secret.AppendChar($ch) }
    $secret.MakeReadOnly()
    try {
        Write-FujiCredential -Target $d.Target -Account $d.User.Text.Trim() -Secret $secret -Program $d.Program -Window $d.Window.Text.Trim()
    } catch {
        $d.Error.Text = Get-FujiText 'cred.failed' $_.Exception.Message
        return
    } finally {
        $secret.Dispose()
    }
    $d.Pass.Clear()
    $d.Again.Clear()
    Write-FujiUiLog -Message (Get-FujiText 'cred.saved' $d.Target) -Level 'ok'
    $d.Result = Get-FujiText 'cred.statusSet' $d.User.Text.Trim()
    $d.Pass.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Remove-FujiCredentialFromDialog {
    $d = $script:Ui.CredDialog
    $answer = Show-FujiChoice -Title (Get-FujiText 'cred.removeTitle') -Message (Get-FujiText 'cred.removeConfirm' $d.Target) -Buttons @((Get-FujiText 'cred.remove'), (Get-FujiText 'gui.cancel'))
    if ($answer -ne 0) { return }
    [void](Remove-FujiCredential -Target $d.Target)
    Write-FujiUiLog -Message (Get-FujiText 'cred.removed' $d.Target) -Level 'ok'
    $d.Result = Get-FujiText 'cred.statusNone'
    $d.Pass.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
}

# "registered (user: x)" / "not registered yet" for the step dialog (the password is never shown)
function Get-FujiCredentialStatus {
    param([AllowEmptyString()][string]$Target)
    if (-not $Target) { return (Get-FujiText 'cred.statusNoTarget') }
    try { $c = Read-FujiCredential -Target $Target } catch { return (Get-FujiText 'cred.failed' $_.Exception.Message) }
    if ($null -eq $c) { return (Get-FujiText 'cred.statusNone') }
    return (Get-FujiText 'cred.statusSet' $c.User)
}

function Get-FujiCredentialProgramText {
    param([AllowEmptyString()][string]$Program)
    if ($Program) { return (Get-FujiText 'cred.program' $Program) }
    return (Get-FujiText 'cred.programNone')
}

# "Point at the window": 3 seconds to click the login window, then its title and program are taken
function Start-FujiCredentialPoint {
    $d = $script:Ui.CredDialog
    if ($null -eq $d.Timer) {
        $d.Timer = New-Object -TypeName System.Windows.Forms.Timer
        $d.Timer.Interval = 1000
        $d.Timer.Add_Tick({ Invoke-FujiUi { Step-FujiCredentialPoint } })
    }
    $d.Remaining = 3
    $d.ProgramLabel.Text = Get-FujiText 'cred.pointWait' $d.Remaining
    $d.Timer.Start()
}

function Step-FujiCredentialPoint {
    $d = $script:Ui.CredDialog
    if ($null -eq $d) { return }
    $d.Remaining--
    if ($d.Remaining -gt 0) { $d.ProgramLabel.Text = Get-FujiText 'cred.pointWait' $d.Remaining; return }
    $d.Timer.Stop()
    $front = Get-FujiForegroundWindowInfo
    $form = $d.Window.FindForm()
    if ($null -eq $front -or (Test-FujiSelfForeground)) {
        $d.ProgramLabel.Text = Get-FujiText 'cred.pointNone'
    } else {
        $d.Window.Text = $front.Title
        $d.Program = $front.Program
        $d.ProgramLabel.Text = Get-FujiCredentialProgramText $front.Program
    }
    [void](Invoke-FujiWindowActivate -Handle $form.Handle)
}
