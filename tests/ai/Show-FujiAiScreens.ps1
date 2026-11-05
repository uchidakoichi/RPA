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
$timer.Stop()
$owner.Close()
