# ---------------------------------------------------------------------------------------------
#  Fields and tables by UI Automation: put text into a field, read a field, read a whole table,
#  find the part under the mouse (the step dialog's "point at it"), show where a part is
#  A field is found by its name or automation id, or by the label just left of it (or above it),
#  in the window that has the focus and then in the windows whose title contains the target
#  window's title. The search runs in a second runspace (Invoke-FujiBackground), like click by name.
# ---------------------------------------------------------------------------------------------

$script:FujiUiaScript = @'
param($State, $Mode, $Name, $Nth, $Hint, $Text, $X, $Y, $OwnPid)
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName WindowsBase
    $AE = [System.Windows.Automation.AutomationElement]
    $CT = [System.Windows.Automation.ControlType]
    $TS = [System.Windows.Automation.TreeScope]
    $maxRows = 5000

    function New-TypeCondition([object[]]$Types) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[System.Windows.Automation.Condition]'
        foreach ($t in $Types) { $list.Add((New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $AE::ControlTypeProperty, $t)) }
        if ($list.Count -eq 1) { return $list[0] }
        return (New-Object -TypeName System.Windows.Automation.OrCondition -ArgumentList (, $list.ToArray()))
    }
    function Get-Rect($El) {
        $r = $El.Current.BoundingRectangle
        if ($r.IsEmpty -or $r.Width -le 0 -or $r.Height -le 0) { return $null }
        return @{ X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height }
    }
    # A label's text without the marks around it: "Name:" "Name *" " Name " are all "Name"
    function Get-Clean([string]$S) { return ([string]$S).Trim().TrimEnd([char[]]@(':', [char]0xFF1A, '*', [char]0x203B, ' ', [char]0x3000)).Trim() }
    function Get-Info($El) {
        $c = $El.Current
        return @{ Kind = [string]$c.ControlType.ProgrammaticName -replace '^ControlType\.', ''; Name = [string]$c.Name; Id = [string]$c.AutomationId; Rect = (Get-Rect $El) }
    }
    # Where to look: the window with the focus, then the target window. A try from the step dialog
    # (LOCATE...) has the focus itself: it looks in the target window, or else in every other window.
    function Get-Scopes {
        $scopes = New-Object -TypeName System.Collections.ArrayList
        $trying = $Mode -like 'LOCATE*'
        if ($trying) {
            foreach ($w in $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
                if ($w.Current.ProcessId -eq $OwnPid) { continue }
                $wn = [string]$w.Current.Name
                if (-not $Hint -or $wn.Contains($Hint)) { [void]$scopes.Add($w) }
            }
            return , $scopes
        }
        $focused = $null
        try { $focused = $AE::FocusedElement } catch { $focused = $null }
        if ($null -ne $focused) {
            $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $node = $focused
            $top = $focused
            while ($null -ne $node -and -not [System.Windows.Automation.Automation]::Compare($node, $AE::RootElement)) {
                $top = $node
                $node = $walker.GetParent($node)
            }
            [void]$scopes.Add($top)
        }
        if ($Hint) {
            foreach ($w in $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
                $wn = $w.Current.Name
                if ($null -ne $wn -and $wn.Contains($Hint)) { [void]$scopes.Add($w) }
            }
        }
        return , $scopes
    }
    $editCond = New-TypeCondition @($CT::Edit, $CT::ComboBox, $CT::Document, $CT::Spinner)
    # The field Nth called Name: by name / automation id first, then the field next to a label
    function Find-Field($Scope) {
        $want = Get-Clean $Name
        $edits = @($Scope.FindAll($TS::Descendants, $editCond))
        $direct = @($edits | Where-Object { (Get-Clean $_.Current.Name) -ceq $want -or $_.Current.AutomationId -ceq $Name })
        if ($direct.Count -ge $Nth) { return $direct[$Nth - 1] }
        $labels = @($Scope.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
                $t = $_.Current.ControlType
                $t -ne $CT::Edit -and $t -ne $CT::ComboBox -and $t -ne $CT::Document -and (Get-Clean $_.Current.Name) -ceq $want })
        if ($labels.Count -lt $Nth) { return $null }
        $l = Get-Rect $labels[$Nth - 1]
        if ($null -eq $l) { return $null }
        $best = $null
        $bestScore = [double]::MaxValue
        foreach ($e in $edits) {
            $r = Get-Rect $e
            if ($null -eq $r) { continue }
            $score = [double]::MaxValue
            if ($r.Y -lt $l.Y + $l.H -and $r.Y + $r.H -gt $l.Y -and $r.X -ge $l.X + $l.W - 8) {
                # same row, to the right of the label
                $score = $r.X - ($l.X + $l.W)
            } elseif ($r.Y -ge $l.Y + $l.H - 4 -and [Math]::Abs($r.X - $l.X) -lt 400) {
                # below the label
                $score = 2000 + ($r.Y - ($l.Y + $l.H)) * 2 + [Math]::Abs($r.X - $l.X)
            }
            if ($score -lt $bestScore) { $bestScore = $score; $best = $e }
        }
        return $best
    }
    function Find-InScopes([scriptblock]$Finder) {
        foreach ($s in (Get-Scopes)) {
            $el = & $Finder $s
            if ($null -ne $el) { return $el }
        }
        return $null
    }
    function Get-ElementText($El) {
        $p = $null
        if ($El.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { return [string]$p.Current.Value }
        if ($El.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$p)) { return [string]$p.DocumentRange.GetText(-1) }
        return [string]$El.Current.Name
    }
    $tableCond = New-TypeCondition @($CT::DataGrid, $CT::Table, $CT::List)
    function Find-Table($Scope) {
        $tables = @($Scope.FindAll($TS::Descendants, $tableCond))
        if ($Name) { return @($tables | Where-Object { $_.Current.Name -ceq $Name -or $_.Current.AutomationId -ceq $Name })[0] }
        $best = $null
        $area = 0
        foreach ($t in $tables) {
            $r = Get-Rect $t
            if ($null -ne $r -and $r.W * $r.H -gt $area) { $area = $r.W * $r.H; $best = $t }
        }
        return $best
    }
    function Read-Table($Table) {
        $header = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $p = $null
        if ($Table.TryGetCurrentPattern([System.Windows.Automation.TablePattern]::Pattern, [ref]$p)) {
            foreach ($h in $p.Current.GetColumnHeaders()) { $header.Add([string]$h.Current.Name) }
        }
        if ($header.Count -eq 0) {
            $hdr = $Table.FindFirst($TS::Children, (New-TypeCondition @($CT::Header)))
            if ($null -ne $hdr) { foreach ($h in $hdr.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) { $header.Add([string]$h.Current.Name) } }
        }
        if ($Table.TryGetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern, [ref]$p)) {
            $rc = [Math]::Min($p.Current.RowCount, $maxRows)
            $cc = $p.Current.ColumnCount
            for ($r = 0; $r -lt $rc; $r++) {
                $cells = New-Object -TypeName 'System.Collections.Generic.List[string]'
                for ($c = 0; $c -lt $cc; $c++) {
                    $item = $null
                    try { $item = $p.GetItem($r, $c) } catch { $item = $null }
                    if ($null -eq $item) { $cells.Add('') } else { $cells.Add((Get-ElementText $item)) }
                }
                $rows.Add($cells.ToArray())
            }
        } else {
            $itemCond = New-TypeCondition @($CT::DataItem, $CT::ListItem, $CT::TreeItem)
            foreach ($item in $Table.FindAll($TS::Children, $itemCond)) {
                if ($rows.Count -ge $maxRows) { break }
                $cells = New-Object -TypeName 'System.Collections.Generic.List[string]'
                foreach ($c in $item.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) { $cells.Add((Get-ElementText $c)) }
                if ($cells.Count -eq 0) { $cells.Add([string]$item.Current.Name) }
                $rows.Add($cells.ToArray())
            }
        }
        return @{ Header = $header.ToArray(); Rows = $rows.ToArray() }
    }
    # What a pointed-at part should be called in a step: its name, else the label left of it, else its id
    function Get-NearLabel($El) {
        $r = Get-Rect $El
        if ($null -eq $r) { return '' }
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $parent = $walker.GetParent($El)
        if ($null -eq $parent) { return '' }
        $best = ''
        $bestScore = [double]::MaxValue
        foreach ($t in $parent.FindAll($TS::Descendants, (New-TypeCondition @($CT::Text)))) {
            $l = Get-Rect $t
            $n = Get-Clean $t.Current.Name
            if ($null -eq $l -or -not $n) { continue }
            $score = [double]::MaxValue
            if ($r.Y -lt $l.Y + $l.H -and $r.Y + $r.H -gt $l.Y -and $l.X + $l.W -le $r.X + 8) { $score = $r.X - ($l.X + $l.W) }
            elseif ($l.Y + $l.H -le $r.Y + 4 -and [Math]::Abs($r.X - $l.X) -lt 400) { $score = 2000 + ($r.Y - ($l.Y + $l.H)) * 2 + [Math]::Abs($r.X - $l.X) }
            if ($score -lt $bestScore) { $bestScore = $score; $best = $n }
        }
        return $best
    }

    switch ($Mode) {
        { $_ -in @('SET', 'FOCUS', 'GET', 'LOCATE') } {
            $el = Find-InScopes { param($s) Find-Field $s }
            if ($null -eq $el -and $Mode -in @('GET', 'LOCATE')) {
                # a read-only display text found by its automation id
                $byId = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $AE::AutomationIdProperty, $Name
                $el = Find-InScopes { param($s) $s.FindFirst($TS::Descendants, $byId) }
            }
            if ($null -eq $el) { $State.Result = 'NOTFOUND'; break }
            if ($Mode -eq 'GET') { $State.Result = @{ Text = (Get-ElementText $el) }; break }
            if ($Mode -eq 'LOCATE') { $State.Result = Get-Info $el; break }
            $p = $null
            if ($Mode -eq 'SET' -and $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p) -and -not $p.Current.IsReadOnly) {
                try {
                    $p.SetValue([string]$Text)
                    # the field also gets the focus, as if typed into: a following Enter or Tab goes there
                    try { $el.SetFocus() } catch { $null = $_ }
                    $State.Result = 'SET'
                    break
                } catch { $p = $null }
            }
            try {
                $el.SetFocus()
                $State.Result = 'FOCUSED'
            } catch {
                # some fields refuse the focus by automation: the window clicks their middle
                $r = Get-Rect $el
                if ($null -eq $r) { throw }
                $State.Result = @{ ClickX = $r.X + [int]($r.W / 2); ClickY = $r.Y + [int]($r.H / 2) }
            }
        }
        'TABLE' {
            $t = Find-InScopes { param($s) Find-Table $s }
            if ($null -eq $t) { $State.Result = 'NOTFOUND'; break }
            $State.Result = Read-Table $t
        }
        'LOCATETABLE' {
            $t = Find-InScopes { param($s) Find-Table $s }
            if ($null -eq $t) { $State.Result = 'NOTFOUND'; break }
            $info = Get-Info $t
            $info.Rows = (Read-Table $t).Rows.Count
            $State.Result = $info
        }
        'LOCATENAME' {
            # a button for "click by name": any part with exactly this name
            $byName = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $AE::NameProperty, $Name
            $el = Find-InScopes { param($s) $s.FindFirst($TS::Descendants, $byName) }
            if ($null -eq $el) { $State.Result = 'NOTFOUND'; break }
            $State.Result = Get-Info $el
        }
        { $_ -in @('PICK', 'PICKTABLE') } {
            $el = $AE::FromPoint((New-Object -TypeName System.Windows.Point -ArgumentList $X, $Y))
            if ($null -eq $el) { $State.Result = 'NOTFOUND'; break }
            if ($Mode -eq 'PICKTABLE') {
                $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                $node = $el
                while ($null -ne $node) {
                    $t = $node.Current.ControlType
                    if ($t -eq $CT::DataGrid -or $t -eq $CT::Table -or $t -eq $CT::List) { break }
                    $node = $walker.GetParent($node)
                    if ($null -ne $node -and [System.Windows.Automation.Automation]::Compare($node, $AE::RootElement)) { $node = $null }
                }
                if ($null -eq $node) { $State.Result = 'NOTABLE'; break }
                $el = $node
            }
            $info = Get-Info $el
            $info.Label = ''
            $t = $el.Current.ControlType
            if ($t -eq $CT::Edit -or $t -eq $CT::ComboBox -or $t -eq $CT::Document -or $t -eq $CT::Spinner) { $info.Label = Get-NearLabel $el }
            $State.Result = $info
        }
    }
} catch {
    $State.Error = $_.Exception.Message
} finally {
    $State.Ready = $true
}
'@

function Invoke-FujiUia {
    param([string]$Mode, [string]$Name = '', [int]$Nth = 1, [string]$Hint = '', [string]$Text = '', [int]$X = 0, [int]$Y = 0)
    return (Invoke-FujiBackground -Script $script:FujiUiaScript -TimeoutSec $script:FujiVisionLimits.NameTimeoutSec -Arguments @($Mode, $Name, $Nth, $Hint, $Text, $X, $Y, $PID))
}

# Io.SetField: 'SET' (the value went in) or 'FOCUSED' (the runner pastes)
function Set-FujiUiaField {
    param([hashtable]$Request)
    $mode = 'SET'
    if ($Request.Mode -eq 'PASTE') { $mode = 'FOCUS' }
    $r = Invoke-FujiUia -Mode $mode -Name $Request.Name -Nth $Request.Nth -Hint $Request.Window -Text $Request.Text
    if ($r -is [string] -and $r -eq 'NOTFOUND') { throw (Get-FujiText 'run.fieldNotFound' $Request.Name) }
    if ($r -is [hashtable]) {
        Invoke-FujiMouseClick -X $r.ClickX -Y $r.ClickY -Kind 'LEFT'
        [void](Wait-FujiUiRun -Ms 200)
        return 'FOCUSED'
    }
    if ($r -eq 'FOCUSED') { [void](Wait-FujiUiRun -Ms 150) }
    return [string]$r
}

function Get-FujiUiaField {
    param([hashtable]$Request)
    $r = Invoke-FujiUia -Mode 'GET' -Name $Request.Name -Nth $Request.Nth -Hint $Request.Window
    if ($r -is [string] -and $r -eq 'NOTFOUND') { throw (Get-FujiText 'run.fieldNotFound' $Request.Name) }
    return [string]$r.Text
}

function Read-FujiUiaTable {
    param([hashtable]$Request)
    $r = Invoke-FujiUia -Mode 'TABLE' -Name $Request.Name -Hint $Request.Window
    if ($r -is [string] -and $r -eq 'NOTFOUND') {
        if ($Request.Name) { throw (Get-FujiText 'run.tableNotFoundNamed' $Request.Name) }
        throw (Get-FujiText 'run.tableNotFound')
    }
    return $r
}

# ----------------------------------------------------------------- showing where a part is
# A red frame around Rect for a moment. The window is shown without being activated, so the focus
# stays where it was; inside the frame it is see-through (TransparencyKey)
function Show-FujiPartFrame {
    param([hashtable]$Rect)
    if ($null -eq $Rect) { return }
    $pad = Get-FujiScaled 3
    $f = New-Object -TypeName System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.BackColor = [System.Drawing.Color]::Magenta
    $f.TransparencyKey = [System.Drawing.Color]::Magenta
    $f.Bounds = New-Object -TypeName System.Drawing.Rectangle -ArgumentList ($Rect.X - $pad), ($Rect.Y - $pad), ($Rect.W + $pad * 2), ($Rect.H + $pad * 2)
    $f.Add_Paint({
            $e = $_
            $w = Get-FujiScaled 3
            $pen = New-Object -TypeName System.Drawing.Pen -ArgumentList (Get-FujiColor '#e53935'), $w
            try { $e.Graphics.DrawRectangle($pen, [int]($w / 2), [int]($w / 2), $this.ClientSize.Width - $w, $this.ClientSize.Height - $w) } finally { $pen.Dispose() }
        })
    $t = New-Object -TypeName System.Windows.Forms.Timer
    $t.Interval = 1800
    $t.Tag = $f
    $t.Add_Tick({ $this.Stop(); $this.Tag.Close(); $this.Tag.Dispose(); $this.Dispose() })
    # SW_SHOWNOACTIVATE: shown on top without taking the focus
    [void](Get-FujiNativeType)::ShowWindow($f.Handle, 4)
    $t.Start()
}
