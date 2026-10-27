#Requires -Version 5.1
<#
.SYNOPSIS
    Fujikyun RPA macro builder, PowerShell edition (Windows Forms).

.DESCRIPTION
    Start it with fujikyun.bat (Windows PowerShell 5.1, single-threaded apartment). The macros file
    and the other working files (fujikyun_macros.json, samples, rpa_images, macro_export ...) are
    kept in this folder, next to fujikyun_ja.json, fujikyun_commands.json and fujikyun_templates.json.

    fujikyun.ps1 is built from build\Main.ps1 (this text) with the functions of src and
    gui put in place of the SOURCES mark, so the app is one script file:
        powershell -NoProfile -File build\Build-FujiBundle.ps1

.NOTES
    MIT License

    Copyright (c) 2026 Koichi Uchida

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
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
    [void](Initialize-FujiLogFile -Directory $here)
    # one app per folder (kept until the app ends)
    $script:AppLock = Enter-FujiAppLock -Directory $here
    if ($null -eq $script:AppLock) {
        if ($AutoRun) {
            # the open app runs the schedule itself (it watches the same schedules)
            [void](Write-FujiLogFile -Message (Get-FujiText 'schedule.autoAlreadyOpen' $AutoRun) -Level 'warn')
            exit 0
        }
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show((Get-FujiText 'gui.alreadyOpen' $here), (Get-FujiText 'gui.title'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        exit 0
    }
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    # this PC's settings first: the text size is needed before any window is made
    $script:Settings = Read-FujiSetting -Directory $here
    Initialize-FujiUi -Zoom (Get-FujiZoom -Settings $script:Settings)
    $script:AutoRunId = $AutoRun
    $script:AppScriptPath = $PSCommandPath
    $script:StartMarks.Add($script:StartWatch.Elapsed.TotalSeconds)
    $script:Ed = New-FujiEditor -Directory $here -Log { param($Message, $Level) Write-FujiUiLog -Message $Message -Level $Level }
    # CSV step labels show the loaded CSV's column names
    $script:FujiCsvHeaderNameOf = { param($Column) Get-FujiCsvHeaderName -Editor $script:Ed -Column $Column }
    # An Excel book in the CSV box: Excel reads its first sheet
    $script:FujiWorkbookReader = { param($Path) Read-FujiWorkbookCsv -Path $Path }
    Write-FujiUiLog -Message (Get-FujiText 'gui.started' $script:FujiAppVersion)
    Write-FujiUiLog -Message (Get-FujiText 'gui.workDir' $here)
    if ($script:FujiSettingsNotice) {
        Write-FujiUiLog -Message $script:FujiSettingsNotice -Level 'error'
        $script:Ed.Notices.Add($script:FujiSettingsNotice)
    }
    foreach ($old in @((Test-FujiTextVersion), (Test-FujiCommandsVersion))) {
        if ($old) {
            Write-FujiUiLog -Message $old -Level 'error'
            $script:Ed.Notices.Add($old)
        }
    }
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
    # kept in the log file too (when it is set up), for a question about it later
    try { [void](Write-FujiLogFile -Message $message -Level 'error') } catch { $null = $_ }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Fujikyun', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        Write-Error -Message $message
    }
    exit 1
}
