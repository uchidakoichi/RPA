# ---------------------------------------------------------------------------------------------
#  Window helpers: fonts, colours, log, small dialogs (Windows Forms, Windows only)
#  Event handlers only use $script: state, $this (the control) and $_ (event arguments): a
#  handler runs after the function that attached it has returned.
# ---------------------------------------------------------------------------------------------

$script:Ui = @{}
$script:LogBuffer = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:LogLimit = 500
$script:CategoryColors = @{
    input = '#1e88e5'; wait = '#c0a000'; flow = '#fb8c00'; var = '#3949ab'
    mouse = '#00897b'; window = '#8e24aa'; group = '#795548'; note = '#43a047'
}
$script:CategoryBack = @{ group = '#f6f1ee'; note = '#f5fbf5' }
$script:LogColors = @{ info = '#ece6f0'; ok = '#a5e3a8'; warn = '#ffe082'; error = '#ff8a9a'; run = '#8fd3ff' }

$script:ColorCache = @{}
function Get-FujiColor {
    param([Parameter(Mandatory)][string]$Hex)
    if (-not $script:ColorCache.ContainsKey($Hex)) { $script:ColorCache[$Hex] = [System.Drawing.ColorTranslator]::FromHtml($Hex) }
    return $script:ColorCache[$Hex]
}

# Pixels at 96 dpi -> pixels on this screen (the process is DPI aware)
function Get-FujiScaled {
    param([double]$Pixels)
    return [int][Math]::Round($Pixels * $script:Ui.Scale)
}

function Initialize-FujiUi {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('FujiUi.Native' -as [type])) {
        Add-Type -Namespace 'FujiUi' -Name 'Native' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
'@
    }
    # Real pixels everywhere (screen capture and clicks use the same coordinates as the screen)
    [void][FujiUi.Native]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { $null = $_ }
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $script:Ui.Scale = $g.DpiX / 96.0 } finally { $g.Dispose() }
    $family = 'Segoe UI'
    $installed = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
    foreach ($name in @('Yu Gothic UI', 'Meiryo UI', 'MS UI Gothic')) {
        if ($installed -contains $name) { $family = $name; break }
    }
    $script:Ui.Font = New-Object -TypeName System.Drawing.Font -ArgumentList $family, 10
    $script:Ui.BoldFont = New-Object -TypeName System.Drawing.Font -ArgumentList $script:Ui.Font, ([System.Drawing.FontStyle]::Bold)
    $script:Ui.StrikeFont = New-Object -TypeName System.Drawing.Font -ArgumentList $script:Ui.Font, ([System.Drawing.FontStyle]::Strikeout)
    $script:Ui.SmallFont = New-Object -TypeName System.Drawing.Font -ArgumentList $family, 9
    $mono = 'Consolas'
    if ($installed -contains 'BIZ UDGothic') { $mono = 'BIZ UDGothic' } elseif ($installed -contains 'MS Gothic') { $mono = 'MS Gothic' }
    $script:Ui.LogFont = New-Object -TypeName System.Drawing.Font -ArgumentList $mono, 9.5
    $script:Ui.ToolTip = New-Object -TypeName System.Windows.Forms.ToolTip
    $script:Ui.ToolTip.AutoPopDelay = 20000
}

# Runs an event handler body; an unexpected error goes to the log instead of closing the window
function Invoke-FujiUi {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        $where = ''
        if ($_.InvocationInfo) { $where = ' [' + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber + ']' }
        Write-FujiUiLog -Message ((Get-FujiText 'gui.unexpected' $_.Exception.Message) + $where) -Level 'error'
    }
}

# ----------------------------------------------------------------- log
function Write-FujiUiLog {
    param([string]$Message, [string]$Level = 'info')
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    $box = $script:Ui['Log']
    # Colours need the RichTextBox's window: lines before it exists wait in the buffer
    if ($null -eq $box -or -not $box.IsHandleCreated) {
        $script:LogBuffer.Add(@($line, $Level))
        return
    }
    Add-FujiLogLine -Box $box -Line $line -Level $Level
}

function Add-FujiLogLine {
    param($Box, [string]$Line, [string]$Level)
    $color = $script:LogColors[$Level]
    if (-not $color) { $color = $script:LogColors['info'] }
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionColor = Get-FujiColor $color
    if ($Level -eq 'error') { $Box.SelectionFont = $script:Ui.BoldFont } else { $Box.SelectionFont = $Box.Font }
    $Box.AppendText($Line + "`n")
    if ($Box.Lines.Length -gt $script:LogLimit + 50) {
        $Box.ReadOnly = $false
        $Box.Select(0, $Box.GetFirstCharIndexFromLine($Box.Lines.Length - $script:LogLimit))
        $Box.SelectedText = ''
        $Box.ReadOnly = $true
    }
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
}

# ----------------------------------------------------------------- controls
function New-FujiButton {
    param([string]$Text, [string]$Tip = '', $Tag = $null)
    $b = New-Object -TypeName System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 4), (Get-FujiScaled 2), (Get-FujiScaled 4), (Get-FujiScaled 2)
    $b.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 2)
    $b.UseMnemonic = $false
    $b.Tag = $Tag
    if ($Tip) { $script:Ui.ToolTip.SetToolTip($b, $Tip) }
    return $b
}

function New-FujiLabel {
    param([string]$Text, [int]$MaxWidth = 0)
    $l = New-Object -TypeName System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.UseMnemonic = $false
    $l.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 3), (Get-FujiScaled 7), (Get-FujiScaled 3), (Get-FujiScaled 3)
    if ($MaxWidth -gt 0) { $l.MaximumSize = New-Object -TypeName System.Drawing.Size -ArgumentList $MaxWidth, 0 }
    return $l
}

function New-FujiTextBox {
    param([string]$Text = '', [int]$Width = 200, [switch]$Multiline)
    $t = New-Object -TypeName System.Windows.Forms.TextBox
    $t.Width = $Width
    if ($Multiline) {
        $t.Multiline = $true
        $t.AcceptsReturn = $true
        $t.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $t.Height = Get-FujiScaled 90
    }
    $t.Text = $Text
    $t.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 2), (Get-FujiScaled 3), (Get-FujiScaled 2), (Get-FujiScaled 3)
    return $t
}

# Drop-down list; Values (codes) kept in Tag beside the shown labels
function New-FujiComboBox {
    param([object[]]$Items = @(), [object[]]$Values = $null, [int]$Width = 200)
    $c = New-Object -TypeName System.Windows.Forms.ComboBox
    $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $c.Width = $Width
    $c.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 2), (Get-FujiScaled 3), (Get-FujiScaled 2), (Get-FujiScaled 3)
    foreach ($i in $Items) { [void]$c.Items.Add([string]$i) }
    $c.Tag = $Values
    return $c
}

# One full-width column: rows that hold wrapping FlowLayoutPanels get the width to wrap in
function Add-FujiFullColumn {
    param([Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Table)
    [void]$Table.ColumnStyles.Add((New-Object -TypeName System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
}

function New-FujiFlow {
    $f = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $f.WrapContents = $true
    $f.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList 0
    $f.Dock = [System.Windows.Forms.DockStyle]::Fill
    return $f
}

function New-FujiDialogForm {
    param([string]$Title, [int]$Width, [int]$Height)
    $f = New-Object -TypeName System.Windows.Forms.Form
    $f.Text = $Title
    $f.Font = $script:Ui.Font
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $f.ShowInTaskbar = $false
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false
    $f.ClientSize = New-Object -TypeName System.Drawing.Size -ArgumentList $Width, $Height
    $f.KeyPreview = $true
    return $f
}

# A row of buttons at the bottom of a dialog, right-aligned
function New-FujiButtonBar {
    $bar = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bar.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $bar.AutoSize = $true
    $bar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $bar.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
    return $bar
}

function Get-FujiOwner {
    $f = $script:Ui['Form']
    if ($null -ne $f -and $f.Visible) { return $f }
    return $null
}

function Show-FujiDialog {
    param([Parameter(Mandatory)]$Form)
    $owner = Get-FujiOwner
    if ($null -eq $owner) { $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen; return $Form.ShowDialog() }
    return $Form.ShowDialog($owner)
}

# ----------------------------------------------------------------- small dialogs
function Show-FujiMessage {
    param([string]$Title, [string]$Message)
    [void](Show-FujiChoice -Title $Title -Message $Message -Buttons @((Get-FujiText 'gui.ok')))
}

# Returns the index of the pressed button, -1 when closed (Esc / x). The first button is the default.
function Show-FujiChoice {
    param([string]$Title, [string]$Message, [string[]]$Buttons)
    $width = Get-FujiScaled 520
    $f = New-FujiDialogForm -Title $Title -Width $width -Height (Get-FujiScaled 200)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.AutoSize = $true
    $f.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $text = New-FujiLabel -Text $Message -MaxWidth ($width - (Get-FujiScaled 30))
    $text.Margin = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 14)
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.AutoSize = $true
    $layout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $layout.ColumnCount = 1
    $layout.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList $width, 0
    [void]$layout.Controls.Add($text)
    $bar = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $bar.AutoSize = $true
    $bar.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bar.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 8)
    $script:Ui.ChoiceResult = -1
    # RightToLeft: add the last button first so they read in the given order
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $b = New-FujiButton -Text $Buttons[$i] -Tag $i
        $b.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList (Get-FujiScaled 90), 0
        $b.Add_Click({ $script:Ui.ChoiceResult = [int]$this.Tag; $this.FindForm().Close() })
        [void]$bar.Controls.Add($b)
        if ($i -eq 0) { $f.AcceptButton = $b }
    }
    [void]$layout.Controls.Add($bar)
    [void]$f.Controls.Add($layout)
    $f.Add_Shown({ $this.AcceptButton.Focus() })
    $f.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $this.Close() } })
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
    return $script:Ui.ChoiceResult
}

# One line of text; '' when cancelled. Empty input is refused in the dialog.
function Show-FujiInput {
    param([string]$Title, [string]$Label, [string]$Default = '')
    $width = Get-FujiScaled 460
    $f = New-FujiDialogForm -Title $Title -Width $width -Height (Get-FujiScaled 170)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    Add-FujiFullColumn -Table $layout
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList (Get-FujiScaled 10)
    [void]$layout.Controls.Add((New-FujiLabel -Text $Label))
    $box = New-FujiTextBox -Text $Default -Width ($width - (Get-FujiScaled 30))
    [void]$layout.Controls.Add($box)
    $err = New-FujiLabel -Text ''
    $err.ForeColor = Get-FujiColor '#c62828'
    [void]$layout.Controls.Add($err)
    $bar = New-FujiButtonBar
    $cancel = New-FujiButton -Text (Get-FujiText 'gui.cancel')
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-FujiButton -Text (Get-FujiText 'gui.ok')
    [void]$bar.Controls.Add($cancel)
    [void]$bar.Controls.Add($ok)
    $script:Ui.InputDialog = @{ Box = $box; Error = $err; Value = '' }
    $ok.Add_Click({
            $d = $script:Ui.InputDialog
            $v = $d.Box.Text.Trim()
            if ($v -eq '') { $d.Error.Text = Get-FujiText 'gui.emptyInput'; return }
            $d.Value = $v
            $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
        })
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    [void]$f.Controls.Add($layout)
    [void]$f.Controls.Add($bar)
    $f.Add_Shown({ $script:Ui.InputDialog.Box.SelectAll(); $script:Ui.InputDialog.Box.Focus() })
    $result = Show-FujiDialog -Form $f
    $f.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
    return $script:Ui.InputDialog.Value
}

function Open-FujiFolder {
    param([Parameter(Mandatory)][string]$Path)
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('/select,"' + $Path + '"')
}
