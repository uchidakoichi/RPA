#Requires -Version 5.1
<#
    VM check of the AI review window (run on the signed-in desktop with vmrun.sh; no AI needed).
    A timer presses the buttons of the real window; the files are looked at after each window.
    Checked: answers kept under the step key of before are moved to today's key, a row given to a
    re-run CSV is left out the next time (and comes back with the box ticked), an answer picked in
    the run is not run again until it is changed, "forget this step" erases the memory and
    un-checks the lines. -OutDir gets two pictures of the window.
#>
param([string]$OutDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$psRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($folder in @('src', 'gui')) { foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot $folder) -Filter '*.ps1' | Sort-Object Name) { . $f.FullName } }
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
Import-FujiCommand -Path (Join-Path $psRoot 'fujikyun_commands.json')
$work = Join-Path $env:TEMP ('fuji-ai-review-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work)
$script:Settings = Read-FujiSetting -Directory $work
$set = [ordered]@{ name = 'desk'; src = '{{1}}'; question = 'which desk'; options = "resident`ngarbage`nother"; threshold = '0.5'; low = 'REVIEW'; unknown = 'unknown' }
$macro = [ordered]@{ id = 'm1'; name = 'inquiries'; targetWindow = ''; steps = @(, [ordered]@{ cmd = 'AI_CHOOSE'; val = (ConvertTo-FujiStepValue -Cmd 'AI_CHOOSE' -Settings $set); label = '' }) }
$texts = @('I moved last month; what do I bring to change my address?', 'The allowance was not paid this month.', 'When is the large garbage collected in my area?', 'Tax certificate, please.')
$csv = New-Object -TypeName 'System.Collections.Generic.List[object]'
foreach ($t in $texts) { $csv.Add([string[]]@($t)) }
$script:Ed = @{ Directory = $work; Data = @{ macros = @(, $macro) }; MacroIndex = 0; Csv = @{ Rows = $csv.ToArray(); Header = $null } }
$oldKey = Get-FujiAiStepKey -Cmd 'AI_CHOOSE' -MacroId 'm1' -Settings $set -Legacy
$newKey = Get-FujiAiStepKey -Cmd 'AI_CHOOSE' -MacroId 'm1' -Settings $set
# row 4 was picked by a person in the run (2026.11.10 kept it under the key of before)
$memory = [ordered]@{}
Add-FujiAiRemembered -Memory $memory -Key $oldKey -Hash (Get-FujiAiTextHash $texts[3]) -Answer 'garbage' -ExampleText $texts[3]
Save-FujiAiMemory -Directory $work -Memory $memory
$now = Get-Date
$stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
$rows = @(@(1, 'resident', '0.35', 'low', ''), @(2, 'other', '0.28', 'low', ''), @(3, 'garbage', '0.92', 'spot', ''), @(4, 'resident', '0.40', 'asked', $stamp))
foreach ($r in $rows) {
    $text = $texts[$r[0] - 1]
    [void](Add-FujiAiReviewRow -Directory $work -Now $now -Row ([ordered]@{ time = $stamp; macro = 'inquiries'; step = 1; row = $r[0]; command = 'AI_CHOOSE'; name = 'desk'; source = $text; answer = $r[1]; p = $r[2]; probs = ''; reason = $r[3]; kind = $r[3]; macroId = 'm1'; key = $oldKey; hash = (Get-FujiAiTextHash $text); done = $r[4]; rerun = $r[4] }))
}

Initialize-FujiUi -Zoom 1.0
$owner = New-Object -TypeName System.Windows.Forms.Form
$owner.Text = 'owner'; $owner.Width = 300; $owner.Height = 200; $owner.Show()
$script:Ui.Form = $owner
$script:Ui.CsvPath = New-Object -TypeName System.Windows.Forms.TextBox
$script:imported = 0
$script:uiLog = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:trouble = New-Object -TypeName 'System.Collections.Generic.List[string]'
# the parts of the main window the review window calls
function Import-FujiCsvUi { $script:imported++ }
function Write-FujiUiLog { param([string]$Message, [string]$Level = 'info', [hashtable]$Link = $null) $null = $Link; $script:uiLog.Add($Level + ' ' + $Message) }
function Write-FujiUnexpectedError { param($ErrorObject) $script:trouble.Add('unexpected: ' + $ErrorObject.Exception.Message + ' ' + $ErrorObject.ScriptStackTrace) }

function Find-UiText {
    param($Root, [string]$Text)
    foreach ($c in $Root.Controls) {
        if ($c.Text -eq $Text) { return $c }
        $r = Find-UiText -Root $c -Text $Text
        if ($null -ne $r) { return $r }
    }
    return $null
}
function Find-UiType {
    param($Root, [type]$Type)
    foreach ($c in $Root.Controls) {
        if ($c -is $Type) { return $c }
        $r = Find-UiType -Root $c -Type $Type
        if ($null -ne $r) { return $r }
    }
    return $null
}
function Get-UiTop {
    $top = $null
    foreach ($w in @([System.Windows.Forms.Application]::OpenForms)) { if ($w -ne $owner -and $w.Visible) { $top = $w } }
    return $top
}
function Invoke-UiStep {
    param($Window, [hashtable]$Step)
    switch ($Step.Do) {
        'click' {
            $c = Find-UiText -Root $Window -Text (Get-FujiText $Step.Text)
            if ($null -eq $c) { throw ('no control ' + $Step.Text + ' in ' + $Window.Text) }
            $c.PerformClick()
        }
        'tick' { (Find-UiText -Root $Window -Text (Get-FujiText $Step.Text)).Checked = $true }
        'pick' {
            $list = Find-UiType -Root $Window -Type ([System.Windows.Forms.ListView])
            foreach ($lvi in $list.Items) { if ($lvi.Tag.Kind -eq $Step.Kind) { $lvi.Selected = $true } }
        }
        'choose' { (Find-UiType -Root $Window -Type ([System.Windows.Forms.ListBox])).SelectedIndex = $Step.Index }
        'shot' {
            $b = $Window.Bounds
            $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $b.Width, $b.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
            $g.Dispose()
            $bmp.Save((Join-Path $OutDir ($Step.Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
    }
}
$script:plan = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
$script:idle = 0
$timer = New-Object -TypeName System.Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
        try {
            $top = Get-UiTop
            if ($null -eq $top) { return }
            if ($script:plan.Count -eq 0) {
                # nothing left to press and a window is still open: close it, so the check ends
                $script:idle++
                if ($script:idle -gt 8) { $script:idle = 0; $script:trouble.Add('left open: ' + $top.Text); $top.Close() }
                return
            }
            $script:idle = 0
            $step = $script:plan.Dequeue()
            Invoke-UiStep -Window $top -Step $step
        } catch {
            $script:trouble.Add('tick: ' + $_.Exception.Message)
        }
    })
$script:fail = 0
function Assert-Ui { param([bool]$Ok, [string]$Name) if ($Ok) { Write-Output ('ok   ' + $Name) } else { $script:fail++; Write-Output ('FAIL ' + $Name) } }
function Show-UiReview {
    param([object[]]$Steps)
    foreach ($s in $Steps) { $script:plan.Enqueue($s) }
    Show-FujiAiReviewDialog
    if ($script:plan.Count -gt 0) { $script:trouble.Add(('{0} steps not done' -f $script:plan.Count)); $script:plan.Clear() }
}
function Get-UiItem { $map = @{}; foreach ($it in @(Read-FujiAiReviewItem -Directory $work -MacroId 'm1' -MacroName 'inquiries' -Days 1)) { $map[[int]$it.Row] = $it }; return $map }
function Get-UiRerunRow {
    # the texts of the rows in the re-run CSV, as their row numbers
    $recs = (ConvertFrom-FujiCsv -Text (Read-FujiCsvText -Path (Join-Path $work 'fujikyun_ai_rerun.csv')).Text).Records
    $nos = @(for ($i = 1; $i -lt $recs.Count; $i++) { [array]::IndexOf($texts, [string]$recs[$i][0]) + 1 })
    return ($nos -join ',')
}
$timer.Start()
try {
    # 1: check the two unchecked low answers as the AI said, then make the re-run CSV
    Show-UiReview -Steps @(@{ Do = 'shot'; Name = 'ai_review_ui_1' }, @{ Do = 'click'; Text = 'gui.aiReviewCheck' }, @{ Do = 'click'; Text = 'gui.aiReviewCheck' }, @{ Do = 'click'; Text = 'gui.aiReviewRerun' })
    $m = Read-FujiAiMemory -Directory $work
    Assert-Ui ($m.Contains($newKey) -and -not $m.Contains($oldKey) -and $m[$newKey]['answers'].Count -eq 3) '1 memory moved to the key of today, two answers added'
    $it = Get-UiItem
    Assert-Ui ($it[1].Done -and $it[2].Done -and -not $it[3].Done -and $it[1].Rerun -and $it[2].Rerun -and $it[3].Rerun -eq '' -and $it[4].Rerun -eq $stamp) '1 the two rows are checked and marked as given to the re-run'
    Assert-Ui ($script:imported -eq 1 -and (Get-UiRerunRow) -eq '1,2') '1 re-run CSV has rows 1 and 2 (not the spot check, not the answer picked in the run)'
    Remove-Item -LiteralPath (Join-Path $work 'fujikyun_ai_rerun.csv') -Force
    # 2: nothing to run again (a message); with the box ticked, rows 1 and 2 again
    Show-UiReview -Steps @(@{ Do = 'click'; Text = 'gui.aiReviewRerun' }, @{ Do = 'click'; Text = 'gui.ok' }, @{ Do = 'tick'; Text = 'gui.aiReviewRerunAll' }, @{ Do = 'click'; Text = 'gui.aiReviewRerun' })
    Assert-Ui ($script:imported -eq 2 -and (Get-UiRerunRow) -eq '1,2') '2 no rows without the box (message), rows 1 and 2 with the box'
    # 3: the answer picked in the run is changed: only that row is run again
    Show-UiReview -Steps @(@{ Do = 'pick'; Kind = 'asked' }, @{ Do = 'choose'; Index = 2 }, @{ Do = 'click'; Text = 'gui.aiReviewCheck' }, @{ Do = 'click'; Text = 'gui.aiReviewRerun' })
    $it = Get-UiItem
    $m = Read-FujiAiMemory -Directory $work
    Assert-Ui ($script:imported -eq 3 -and (Get-UiRerunRow) -eq '4' -and (Get-FujiAiRemembered -Memory $m -Key $newKey -Hash (Get-FujiAiTextHash $texts[3])) -eq 'other') '3 the changed answer is remembered and its row alone is in the re-run CSV'
    Assert-Ui ($it[4].Rerun -ne '' -and $it[4].Done -ne $stamp) '3 the row is marked as given to the re-run'
    # 4: forget the step
    Show-UiReview -Steps @(@{ Do = 'click'; Text = 'gui.aiReviewForget' }, @{ Do = 'click'; Text = 'gui.aiReviewForgetYes' }, @{ Do = 'shot'; Name = 'ai_review_ui_2' }, @{ Do = 'click'; Text = 'gui.close' })
    $m = Read-FujiAiMemory -Directory $work
    $it = Get-UiItem
    Assert-Ui (-not $m.Contains($newKey)) '4 the memory of the step is erased'
    Assert-Ui (-not $it[1].Done -and -not $it[2].Done -and -not $it[4].Done -and $it[1].Rerun -and $it[4].Rerun) '4 the lines are not checked any more, their re-run times stay'
    Assert-Ui (@($script:uiLog | Where-Object { $_.StartsWith('ok ') }).Count -eq 4 -and @($script:uiLog | Where-Object { $_.StartsWith('warn') }).Count -eq 0) '4 three re-run lines and one forget line in the log, no warning'
    Assert-Ui ($script:trouble.Count -eq 0) 'every step found its button'
    foreach ($t in $script:trouble) { Write-Output ('  ' + $t) }
} finally {
    $timer.Stop()
    $owner.Close()
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Output ('{0} FAILED' -f $script:fail); exit 1 }
Write-Output 'AI REVIEW WINDOW: ALL OK'
