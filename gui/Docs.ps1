# ---------------------------------------------------------------------------------------------
#  Opening the manuals from the window: the "Manuals" menu, F1, and the help buttons of dialogs
#  (src/Docs.ps1 finds the page). A place in a page goes through a small forwarding page in the
#  temp folder, because a file opened by Windows drops the #anchor of its address.
# ---------------------------------------------------------------------------------------------

function Open-FujiDoc {
    param([Parameter(Mandatory)][string]$Page, [string]$Anchor = '')
    $path = Find-FujiDocFile -Directory $script:Ed.Directory -Page $Page -FileExists { param($p) return (Test-Path -LiteralPath $p -PathType Leaf) }
    if (-not $path) {
        $answer = Show-FujiChoice -Title (Get-FujiText 'gui.docTitle') -Message (Get-FujiText 'gui.docMissing' $script:Ed.Directory) -Buttons @((Get-FujiText 'gui.docOnline'), (Get-FujiText 'gui.close'))
        if ($answer -eq 0) { Start-Process -FilePath (Get-FujiDocOnlineUrl -Page $Page) }
        return
    }
    try {
        if ($Anchor) {
            $forward = Join-Path ([System.IO.Path]::GetTempPath()) 'fujikyun_doc_open.html'
            [System.IO.File]::WriteAllText($forward, (New-FujiDocForwardHtml -Url (ConvertTo-FujiDocUrl -Path $path -Anchor $Anchor)), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
            Start-Process -FilePath $forward
        } else {
            Start-Process -FilePath $path
        }
        Write-FujiUiLog -Message (Get-FujiText 'gui.docOpened' (Split-Path -Path $path -Leaf))
    } catch {
        Write-FujiUiLog -Message (Get-FujiText 'gui.docFailed' $_.Exception.Message) -Level 'error'
    }
}

# The "Manuals" button: a menu of the pages
function New-FujiDocMenuButton {
    $b = New-FujiButton -Text (Get-FujiText 'gui.docs') -Tip (Get-FujiText 'gui.docsTip')
    $menu = New-Object -TypeName System.Windows.Forms.ContextMenuStrip
    $menu.Font = $script:Ui.Font
    foreach ($p in $script:FujiDocPages) {
        $item = New-Object -TypeName System.Windows.Forms.ToolStripMenuItem -ArgumentList (Get-FujiText ('gui.docPages.' + $p))
        $item.Tag = $p
        $item.Add_Click({ $page = [string]$this.Tag; Invoke-FujiUi { Open-FujiDoc -Page $page } })
        [void]$menu.Items.Add($item)
    }
    $b.Tag = $menu
    $b.Add_Click({ $this.Tag.Show($this, (New-Object -TypeName System.Drawing.Point -ArgumentList 0, $this.Height)) })
    return $b
}

# A "read about it" button for a dialog's button bar
function New-FujiDocButton {
    param([Parameter(Mandatory)][string]$Page, [string]$Anchor = '', [string]$TextKey = 'gui.docHelp')
    $b = New-FujiButton -Text (Get-FujiText $TextKey) -Tip (Get-FujiText 'gui.docHelpTip') -Tag @($Page, $Anchor)
    $b.Add_Click({ $where = $this.Tag; Invoke-FujiUi { Open-FujiDoc -Page $where[0] -Anchor $where[1] } })
    return $b
}

# F1 in the main window: the selected step's command, or the manual
function Open-FujiContextDoc {
    $steps = Get-FujiCurrentStepList $script:Ed
    if ($script:Ed.Selected -ge 0 -and $script:Ed.Selected -lt $steps.Count) {
        Open-FujiDoc -Page 'manual' -Anchor (Get-FujiCommandDocAnchor -Cmd ([string]$steps[$script:Ed.Selected].cmd))
    } else {
        Open-FujiDoc -Page 'manual'
    }
}
