#Requires -Version 5.1
<#
    VM screen check of the AI windows (run on the signed-in desktop with vmrun.sh): the AI settings,
    the window to pick the answer, and the copy window, each shown for a few seconds so it can be
    captured with vmrun.sh --shot.  -Zoom 1.5 shows them with larger text.
#>
param([double]$Zoom = 1.0, [int]$Seconds = 4, [string]$Only = '', [string]$OutDir = $env:TEMP)
$ErrorActionPreference = 'Stop'
$psRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($folder in @('src', 'gui')) { foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot $folder) -Filter '*.ps1' | Sort-Object Name) { . $f.FullName } }
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
Import-FujiCommand -Path (Join-Path $psRoot 'fujikyun_commands.json')
$work = Join-Path $env:TEMP 'fuji-ai-screens'
if (-not (Test-Path -LiteralPath $work)) { [void](New-Item -ItemType Directory -Path $work) }
$script:Settings = Read-FujiSetting -Directory $work
Set-FujiAiFolderSetting -Settings $script:Settings -Folder 'C:\llm\ai-share-test'
$script:Ed = @{ Directory = $work }
Initialize-FujiUi -Zoom $Zoom
$owner = New-Object -TypeName System.Windows.Forms.Form
$owner.Text = 'owner'; $owner.Width = 300; $owner.Height = 200; $owner.Show()
$script:Ui.Form = $owner
# closes the window that is open after Seconds
$timer = New-Object -TypeName System.Windows.Forms.Timer
$timer.Interval = $Seconds * 1000
$script:shot = 0
$timer.Add_Tick({
        foreach ($w in @([System.Windows.Forms.Application]::OpenForms)) {
            if ($w -eq $owner -or -not $w.Visible) { continue }
            # the window as it is on the screen, saved to OutDir, then closed
            $b = $w.Bounds
            $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $b.Width, $b.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
            $g.Dispose()
            $script:shot++
            $bmp.Save((Join-Path $OutDir ('ai_screen_{0}_{1}.png' -f $script:shot, ([string]$Zoom).Replace('.', ''))), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $w.Close()
        }
    })
$timer.Start()
if (-not $Only -or $Only -eq 'settings') { Show-FujiAiSettingDialog }
if (-not $Only -or $Only -eq 'pick') {
    $opts = @(@{ Value = 'CLOSE_ENTER'; P = 0.21 }, @{ Value = 'SKIP_ROW'; P = 0.43 }, @{ Value = 'ASK_HUMAN'; P = 0.37 })
    $r = Show-FujiRunAiPick -Caption 'AI' -Message ("which action`n`n" + ('The record you searched for was not found. ' * 6)) -Options $opts -Initial 'SKIP_ROW'
    Write-Output ('pick: ' + $r.Choice + ' ' + $r.Value)
}
if ($Only -eq 'review') {
    # a macro with one AI_CHOOSE step and a review list of 5 lines (low, spot, done, extract, old)
    $opts = "resident`ngarbage`nchild allowance`nother"
    $set = [ordered]@{ name = 'desk'; src = '{{1}}'; question = 'which desk'; options = $opts; threshold = '0.5'; low = 'REVIEW'; unknown = 'unknown' }
    $exSet = [ordered]@{ src = '{{1}}'; items = "name`nphone"; note = ''; strict = 'ON' }
    $script:ReviewMacro = [ordered]@{ id = 'm1'; name = 'inquiries'; targetWindow = ''; steps = @(
            [ordered]@{ cmd = 'AI_CHOOSE'; val = (ConvertTo-FujiStepValue -Cmd 'AI_CHOOSE' -Settings $set); label = '' },
            [ordered]@{ cmd = 'AI_EXTRACT'; val = (ConvertTo-FujiStepValue -Cmd 'AI_EXTRACT' -Settings $exSet); label = '' }) }
    function Get-FujiCurrentMacro { param($Editor) $null = $Editor; return $script:ReviewMacro }
    $script:Ed.Csv = @{ Rows = @(); Header = $null }
    $script:Ed.Data = @{ macros = @(, $script:ReviewMacro) }
    $key = Get-FujiAiStepKey -Cmd 'AI_CHOOSE' -MacroId 'm1' -Settings $set
    $exKey = Get-FujiAiStepKey -Cmd 'AI_EXTRACT' -MacroId 'm1' -Settings $exSet
    $logs = Join-Path $work 'fujikyun_logs'
    if (Test-Path -LiteralPath $logs) { Remove-Item -LiteralPath $logs -Recurse -Force }
    $now = Get-Date
    $rows = @(
        @('AI_CHOOSE', 'desk', 'I moved last month; what do I bring to change my address?', 'resident', '0.35', 'low', $key, ''),
        @('AI_CHOOSE', 'desk', 'When is the large garbage collected in my area?', 'garbage', '0.92', 'spot', $key, ''),
        @('AI_CHOOSE', 'desk', 'The allowance was not paid this month.', 'other', '0.28', 'low', $key, ''),
        @('AI_EXTRACT', 'phone', 'Name: Sample Taro, phone 000-0000-0001', '000-0000-0009', '', 'notInSource', $exKey, ''),
        @('AI_CHOOSE', 'desk', 'Tax certificate, please.', 'other', '0.45', 'low', $key, '2026-11-06 10:00:00'))
    $n = 0
    foreach ($r in $rows) {
        $n++
        [void](Add-FujiAiReviewRow -Directory $work -Now $now -Row ([ordered]@{ time = $now.ToString('yyyy-MM-dd HH:mm:ss'); macro = 'inquiries'; step = 1; row = $n; command = $r[0]; name = $r[1]; source = $r[2]; answer = $r[3]; p = $r[4]; probs = ''; reason = $r[5]; kind = $r[5]; macroId = 'm1'; key = $r[6]; hash = (Get-FujiAiTextHash $r[2]); done = $r[7] }))
    }
    Show-FujiAiReviewDialog
}
if ($Only -eq 'diag') { ConvertTo-FujiDiagnosticText -Result (Get-FujiDiagnostic) }
$timer.Stop()
$owner.Close()
