# ---------------------------------------------------------------------------------------------
#  Environment check: what this PC lets the app do (shown in a list, also written to the log)
# ---------------------------------------------------------------------------------------------

# Each check: @(ok, name key, detail); returns @{ Items; Hints }
function Get-FujiDiagnostic {
    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $hints = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $add = { param($Ok, $Key, $Detail) $items.Add(@([bool]$Ok, (Get-FujiText ('diag.' + $Key)), [string]$Detail)) }

    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    & $add $true 'powershell' ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    & $add ($mode -eq 'FullLanguage') 'languageMode' $mode
    if ($mode -ne 'FullLanguage') { $hints.Add((Get-FujiText 'diag.hintLanguage' $mode)) }

    $probe = Join-Path $script:Ed.Directory ('fujikyun_probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-FujiTextFile -Path $probe -Text 'ok'
        Remove-Item -LiteralPath $probe -Force
        & $add $true 'folder' $script:Ed.Directory
    } catch {
        & $add $false 'folder' ($script:Ed.Directory + ' ... ' + $_.Exception.Message)
        $hints.Add((Get-FujiText 'diag.hintFolder'))
    }

    # clipboard round trip; the user's text is put back
    $before = Get-FujiClipboard
    $ok = (Set-FujiClipboard -Text 'fujikyun') -and (Get-FujiClipboard) -eq 'fujikyun'
    if ($before) { [void](Set-FujiClipboard -Text $before) } else { [void](Set-FujiClipboard -Text '') }
    & $add $ok 'clipboard' ''

    foreach ($wav in @('Alarm01.wav', 'tada.wav')) {
        $p = Join-Path $env:SystemRoot ('Media\' + $wav)
        & $add (Test-Path -LiteralPath $p -PathType Leaf) 'sound' $p
    }

    # registered, without starting the program
    foreach ($app in @(@('Excel.Application', 'excel'), @('Outlook.Application', 'outlook'))) {
        $found = Test-Path -LiteralPath ('Registry::HKEY_CLASSES_ROOT\' + $app[0])
        & $add $found $app[1] $app[0]
    }

    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        & $add $true 'uia' ''
    } catch {
        & $add $false 'uia' $_.Exception.Message
    }

    # image click and recording compile a small C# class on first use
    try {
        if (-not ('FujiDiagProbe' -as [type])) { Add-Type -TypeDefinition 'public static class FujiDiagProbe { public static int One() { return 1; } }' -Language CSharp }
        & $add ([FujiDiagProbe]::One() -eq 1) 'csharp' ''
    } catch {
        & $add $false 'csharp' $_.Exception.Message
        $hints.Add((Get-FujiText 'diag.hintCsharp'))
    }

    try {
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $langs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.DisplayName })
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        & $add ($null -ne $engine) 'ocr' ($langs -join ', ')
        if ($null -eq $engine) { $hints.Add((Get-FujiText 'diag.hintOcr')) }
    } catch {
        & $add $false 'ocr' $_.Exception.Message
        $hints.Add((Get-FujiText 'diag.hintOcr'))
    }

    $tasks = $null -ne (Get-Module -ListAvailable -Name ScheduledTasks)
    & $add $tasks 'tasks' ''

    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    & $add $true 'screen' ('{0}x{1} ({2}%)' -f $vs.Width, $vs.Height, [int]($script:Ui.Scale * 100))
    & $add $true 'windows' (Get-FujiText 'diag.windowCount' (Get-FujiTopWindow).Count)
    return @{ Items = $items; Hints = $hints }
}

function Show-FujiDiagnostic {
    Write-FujiUiLog -Message (Get-FujiText 'diag.running')
    $r = Get-FujiDiagnostic
    $ngCount = 0
    $f = New-FujiDialogForm -Title (Get-FujiText 'diag.title') -Width (Get-FujiScaled 820) -Height (Get-FujiScaled 560)
    $lv = New-Object -TypeName System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    [void]$lv.Columns.Add((Get-FujiText 'diag.colResult'), (Get-FujiScaled 70))
    [void]$lv.Columns.Add((Get-FujiText 'diag.colItem'), (Get-FujiScaled 300))
    [void]$lv.Columns.Add((Get-FujiText 'diag.colDetail'), (Get-FujiScaled 420))
    foreach ($i in $r.Items) {
        $mark = 'OK'
        if (-not $i[0]) { $mark = 'NG'; $ngCount++ }
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList $mark
        [void]$item.SubItems.Add($i[1])
        [void]$item.SubItems.Add($i[2])
        if (-not $i[0]) { $item.ForeColor = Get-FujiColor '#c62828' }
        [void]$lv.Items.Add($item)
        $level = 'info'
        if (-not $i[0]) { $level = 'warn' }
        Write-FujiUiLog -Message ('{0} {1} {2}' -f $mark, $i[1], $i[2]) -Level $level
    }
    $text = Get-FujiText 'diag.allOk'
    if ($r.Hints.Count -gt 0) { $text = [string]::Join("`r`n`r`n", $r.Hints.ToArray()) } elseif ($ngCount -gt 0) { $text = Get-FujiText 'diag.someNg' }
    $hint = New-Object -TypeName System.Windows.Forms.TextBox
    $hint.Multiline = $true
    $hint.ReadOnly = $true
    $hint.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $hint.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $hint.Height = Get-FujiScaled 110
    $hint.Text = $text
    $bar = New-FujiButtonBar
    $close = New-FujiButton -Text (Get-FujiText 'gui.close')
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void]$bar.Controls.Add($close)
    $f.CancelButton = $close
    [void]$f.Controls.Add($lv)
    [void]$f.Controls.Add($hint)
    [void]$f.Controls.Add($bar)
    [void](Show-FujiDialog -Form $f)
    $f.Dispose()
}
