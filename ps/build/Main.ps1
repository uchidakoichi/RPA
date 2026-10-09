#Requires -Version 5.1
<#
.SYNOPSIS
    Fujikyun RPA macro builder, PowerShell edition (Windows Forms).

.DESCRIPTION
    Start it with fujikyun.bat (Windows PowerShell 5.1, single-threaded apartment). The macros file
    and the other working files (fujikyun_macros.json, samples, rpa_images, macro_export ...) are
    kept in this folder, next to fujikyun_ja.json, fujikyun_commands.json and fujikyun_templates.json.

    fujikyun.ps1 is built from ps\build\Main.ps1 (this text) with the functions of ps\src and
    ps\gui put in place of the SOURCES mark, so the app is one script file:
        powershell -NoProfile -File ps\build\Build-FujiBundle.ps1
#>
[CmdletBinding()]
param(
    # Set by a Windows scheduled task: the id of the schedule to run
    [string]$AutoRun = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$script:StartWatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:StartMarks = New-Object -TypeName 'System.Collections.Generic.List[double]'
$textReady = $false
try {
    # @@SOURCES@@
    Import-FujiText -Path (Join-Path $here 'fujikyun_ja.json')
    $textReady = $true
    Import-FujiCommand -Path (Join-Path $here 'fujikyun_commands.json')
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    Initialize-FujiUi
    $script:AutoRunId = $AutoRun
    $script:AppScriptPath = $PSCommandPath
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    $script:Ed = New-FujiEditor -Directory $here -Log { param($Message, $Level) Write-FujiUiLog -Message $Message -Level $Level }
    # CSV step labels show the loaded CSV's column names
    $script:FujiCsvHeaderNameOf = { param($Column) Get-FujiCsvHeaderName -Editor $script:Ed -Column $Column }
    Write-FujiUiLog -Message (Get-FujiText 'gui.workDir' $here)
    Initialize-FujiEditorData -Editor $script:Ed -AskRestoreTemp {
        $ask = Get-FujiText 'editor.tempAsk' $script:FujiFileNames.Macro $script:FujiFileNames.DiscardedTemp
        (Show-FujiChoice -Title (Get-FujiText 'gui.tempTitle') -Message $ask -Buttons @((Get-FujiText 'gui.yes'), (Get-FujiText 'gui.no'))) -eq 0
    }
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    Show-FujiMainForm
} catch {
    $detail = $_.Exception.Message
    if ($_.InvocationInfo) { $detail += "`r`n" + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber }
    $message = 'Fujikyun could not start.' + "`r`n" + $detail
    if ($textReady) { $message = Get-FujiText 'gui.startupError' $detail }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Fujikyun', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        Write-Error -Message $message
    }
    exit 1
}
