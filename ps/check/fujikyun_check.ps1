#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-check for the PowerShell edition of the Fujikyun RPA Macro Builder.

.DESCRIPTION
    Checks whether this PC can run the Windows Forms / PowerShell 5.1 port: language mode,
    Windows Forms, C# interop (Add-Type), UI Automation, screen capture, Windows OCR, COM for
    Excel / Outlook, scheduled tasks, clipboard and SendKeys. Results are shown in a window and
    saved to fujikyun_check_result.txt next to this script.

    Nothing is changed on the PC: the clipboard text is restored, keys are only sent to this
    tool's own text box, and the temporary files are deleted.

    This file is ASCII only on purpose. Windows PowerShell 5.1 reads a script without a BOM in
    the ANSI code page, so every Japanese text lives in fujikyun_check_strings.json (UTF-8),
    which is read with an explicit encoding.

    Start it with fujikyun_check.bat (powershell.exe -STA -File ...).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$stringsPath = Join-Path -Path $here -ChildPath 'fujikyun_check_strings.json'
$resultPath = Join-Path -Path $here -ChildPath 'fujikyun_check_result.txt'
$results = New-Object -TypeName 'System.Collections.Generic.List[object]'
$nativeReady = $false

# ----------------------------------------------------------------- strings (UTF-8 JSON)
$S = $null
$stringsError = ''
try {
    # Strict decoder: invalid UTF-8 (for example a file saved as Shift_JIS) throws instead of
    # silently turning into replacement characters
    $utf8Strict = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true
    $S = [System.IO.File]::ReadAllText($stringsPath, $utf8Strict) | ConvertFrom-Json
} catch {
    $stringsError = $_.Exception.Message
}

function Get-Text {
    param([string]$Key, [string]$Fallback = '')
    if ($null -eq $S) { if ($Fallback) { return $Fallback } else { return $Key } }
    $p = $S.PSObject.Properties[$Key]
    if ($null -eq $p) { return $Key }
    return [string]$p.Value
}

function Get-SubText {
    param([string]$Group, [string]$Key)
    if ($null -eq $S) { return $Key }
    $g = $S.PSObject.Properties[$Group]
    if ($null -eq $g) { return $Key }
    $p = $g.Value.PSObject.Properties[$Key]
    if ($null -eq $p) { return $Key }
    return [string]$p.Value
}

# ----------------------------------------------------------------- results
# State: 'OK', 'NG', 'INFO' or 'SKIP'
function Add-Result {
    param([string]$Id, [string]$State, [string]$Detail)
    $results.Add([pscustomobject]@{ Id = $Id; State = $State; Detail = $Detail })
}

function Invoke-Check {
    param([string]$Id, [scriptblock]$Body)
    try {
        $r = & $Body
        Add-Result -Id $Id -State $r[0] -Detail ([string]$r[1])
    } catch {
        Add-Result -Id $Id -State 'NG' -Detail $_.Exception.Message
    }
}

# ----------------------------------------------------------------- checks without a window
Invoke-Check 'psVersion' {
    $v = $PSVersionTable.PSVersion
    $state = 'NG'
    if ($v.Major -eq 5 -and $v.Minor -ge 1) { $state = 'OK' }
    $clr = ''
    if ($PSVersionTable.ContainsKey('CLRVersion')) { $clr = ' / CLR ' + $PSVersionTable.CLRVersion }
    @($state, ('{0} ({1}){2}' -f $v, $PSVersionTable.PSEdition, $clr))
}

Invoke-Check 'is64' {
    @('INFO', ('process {0} bit / OS {1} bit' -f ([IntPtr]::Size * 8), $(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 })))
}

Invoke-Check 'sta' {
    $a = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    @($(if ($a -eq 'STA') { 'OK' } else { 'NG' }), [string]$a)
}

Invoke-Check 'languageMode' {
    $m = [string]$ExecutionContext.SessionState.LanguageMode
    @($(if ($m -eq 'FullLanguage') { 'OK' } else { 'NG' }), $m)
}

Invoke-Check 'execPolicy' {
    $list = Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope, $_.ExecutionPolicy }
    @('INFO', ($list -join ', '))
}

Invoke-Check 'resources' {
    if ($null -eq $S) { return @('NG', $stringsError) }
    # "Fujikyun" in katakana/hiragana, built from code points so this file stays ASCII
    $expected = -join ([char[]](0x3075, 0x3058, 0x30AD, 0x30E5, 0x30F3))
    if ([string]$S.sentinel -ne $expected) { return @('NG', 'sentinel mismatch: ' + [string]$S.sentinel) }
    @('OK', $stringsPath)
}

Invoke-Check 'scriptAscii' {
    $bytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
    $bad = 0
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $bad++ } }
    if ($bad -eq 0) { @('OK', ('{0} bytes' -f $bytes.Length)) } else { @('INFO', ('{0} non-ASCII bytes' -f $bad)) }
}

Invoke-Check 'motw' {
    $marked = @()
    foreach ($f in Get-ChildItem -LiteralPath $here -File) {
        $zone = Get-Item -LiteralPath $f.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
        if ($null -ne $zone) { $marked += $f.Name }
    }
    if ($marked.Count -eq 0) { @('OK', '-') } else { @('NG', ($marked -join ', ')) }
}

Invoke-Check 'writeAccess' {
    $probe = Join-Path -Path $here -ChildPath ('fujikyun_check_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'probe')
    Remove-Item -LiteralPath $probe -Force
    @('OK', $here)
}

Invoke-Check 'winforms' {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    @('OK', [System.Windows.Forms.Application]::ProductVersion)
}

Invoke-Check 'csharp' {
    if (-not ('FujiCheckNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FujiCheckNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int max);

    // "process.exe 'title'" of a window, for the report
    public static string Describe(IntPtr h) {
        if (h == IntPtr.Zero) { return "(none)"; }
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        string name = "?";
        try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch (Exception) { }
        var sb = new System.Text.StringBuilder(256);
        GetWindowText(h, sb, sb.Capacity);
        return name + " '" + sb.ToString() + "'";
    }

    // Brings a window to the front, trying the plain call first and then the two usual ways around
    // the foreground lock. Returns the name of the way that worked, or "" when none did.
    public static string BringToFront(IntPtr h) {
        if (IsIconic(h)) { ShowWindow(h, 9); }
        SetForegroundWindow(h);
        if (GetForegroundWindow() == h) { return "SetForegroundWindow"; }
        uint pid;
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint me = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true)) {
            try { BringWindowToTop(h); SetForegroundWindow(h); } finally { AttachThreadInput(me, fgThread, false); }
            if (GetForegroundWindow() == h) { return "AttachThreadInput"; }
        }
        keybd_event(0x12, 0, 0, UIntPtr.Zero);      // Alt down: the system then allows a foreground change
        keybd_event(0x12, 0, 2, UIntPtr.Zero);      // Alt up
        SetForegroundWindow(h);
        if (GetForegroundWindow() == h) { return "AltKey"; }
        return "";
    }
}
'@
    }
    $p = New-Object -TypeName FujiCheckNative+POINT
    [void][FujiCheckNative]::GetCursorPos([ref]$p)
    $script:nativeReady = $true
    @('OK', ('cursor {0},{1}' -f $p.X, $p.Y))
}

if ($nativeReady) {
    # Sharp text on scaled displays; must happen before the first window is created
    [void][FujiCheckNative]::SetProcessDPIAware()
}

Invoke-Check 'uia' {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $top = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    @('OK', ('{0} top-level windows' -f $top.Count))
}

Invoke-Check 'screenCapture' {
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList 32, 32
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size) } finally { $g.Dispose() }
    } finally { $bmp.Dispose() }
    @('OK', '32x32')
}

Invoke-Check 'ocr' {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $await = {
        param($Operation, [Type]$ResultType)
        $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
        [void]$task.Wait(-1)
        $task.Result
    }
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) { return @('NG', 'no OCR language') }
    $sample = Get-Text -Key 'ocrSample' -Fallback 'OCR 12345'
    $png = Join-Path -Path $env:TEMP -ChildPath ('fujikyun_check_{0}.png' -f [guid]::NewGuid().ToString('N'))
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList 480, 120
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::White)
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $font = New-Object -TypeName System.Drawing.Font -ArgumentList 'Yu Gothic UI', 36
            try { $g.DrawString($sample, $font, [System.Drawing.Brushes]::Black, 16, 24) } finally { $font.Dispose() }
        } finally { $g.Dispose() }
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose() }
    try {
        $file = & $await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
        $stream = & $await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        try {
            $decoder = & $await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $soft = & $await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $res = & $await ($engine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])
        } finally { $stream.Dispose() }
    } finally {
        Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
    }
    $text = ([string]$res.Text) -replace '\s', ''
    $want = $sample -replace '\s', ''
    $state = 'NG'
    if ($text -eq $want) { $state = 'OK' } elseif ($text -match '12345') { $state = 'INFO' }
    @($state, ('{0}: "{1}"' -f $engine.RecognizerLanguage.LanguageTag, $res.Text))
}

function Test-ComProgId {
    param([string]$ProgId)
    $clsid = "Registry::HKEY_CLASSES_ROOT\$ProgId\CLSID"
    if (Test-Path -LiteralPath $clsid) { @('OK', $ProgId) } else { @('INFO', ('{0} not registered' -f $ProgId)) }
}
Invoke-Check 'excel' { Test-ComProgId 'Excel.Application' }
Invoke-Check 'outlook' { Test-ComProgId 'Outlook.Application' }

Invoke-Check 'scheduledTasks' {
    $c = Get-Command -Name Register-ScheduledTask -ErrorAction Stop
    @('OK', $c.Source)
}

Invoke-Check 'dpi' {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $dpi = $g.DpiX } finally { $g.Dispose() }
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    @('INFO', ('{0} dpi ({1}%) / primary {2}x{3} / screens {4}' -f $dpi, [int]($dpi / 96 * 100), $b.Width, $b.Height, [System.Windows.Forms.Screen]::AllScreens.Count))
}

# ----------------------------------------------------------------- window
if (-not ('System.Windows.Forms.Form' -as [type])) {
    # Windows Forms itself is missing: report on the console and stop
    $results | ForEach-Object { '[{0}] {1}: {2}' -f $_.State, $_.Id, $_.Detail } | Write-Output
    exit 1
}

[System.Windows.Forms.Application]::EnableVisualStyles()
$uiFont = New-Object -TypeName System.Drawing.Font -ArgumentList 'Yu Gothic UI', 9

$form = New-Object -TypeName System.Windows.Forms.Form
$form.Text = Get-Text -Key 'title' -Fallback 'Fujikyun pre-check'
$form.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 980, 640
$form.StartPosition = 'CenterScreen'
$form.Font = $uiFont

$header = New-Object -TypeName System.Windows.Forms.Label
$header.Dock = 'Top'
$header.Height = 48
$header.Padding = New-Object -TypeName System.Windows.Forms.Padding -ArgumentList 8
$header.Text = Get-Text -Key 'header'

$list = New-Object -TypeName System.Windows.Forms.ListView
$list.Dock = 'Fill'
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
[void]$list.Columns.Add((Get-Text -Key 'colResult'), 70)
[void]$list.Columns.Add((Get-Text -Key 'colName'), 280)
[void]$list.Columns.Add((Get-Text -Key 'colDetail'), 580)

$advice = New-Object -TypeName System.Windows.Forms.TextBox
$advice.Dock = 'Bottom'
$advice.Height = 110
$advice.Multiline = $true
$advice.ReadOnly = $true
$advice.ScrollBars = 'Vertical'

$probe = New-Object -TypeName System.Windows.Forms.TextBox
$probe.Width = 120
# Japanese IME would turn the test keys into an uncommitted composition
$probe.ImeMode = [System.Windows.Forms.ImeMode]::Disable

$buttons = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'
$buttons.Height = 40
$buttons.FlowDirection = 'RightToLeft'
$closeButton = New-Object -TypeName System.Windows.Forms.Button
$closeButton.Text = Get-Text -Key 'btnClose'
$closeButton.AutoSize = $true
$closeButton.Add_Click({ $form.Close() })
$copyButton = New-Object -TypeName System.Windows.Forms.Button
$copyButton.Text = Get-Text -Key 'btnCopy'
$copyButton.AutoSize = $true
$buttons.Controls.AddRange(@($closeButton, $copyButton, $probe))

$form.Controls.Add($list)
$form.Controls.Add($header)
$form.Controls.Add($advice)
$form.Controls.Add($buttons)

function Get-StateText {
    param([string]$State)
    switch ($State) {
        'OK' { Get-Text -Key 'ok' -Fallback 'OK' }
        'NG' { Get-Text -Key 'ng' -Fallback 'NG' }
        'SKIP' { Get-Text -Key 'skip' -Fallback 'SKIP' }
        default { Get-Text -Key 'info' -Fallback 'INFO' }
    }
}

function Get-ReportText {
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add(('{0}  {1}' -f (Get-Text -Key 'title'), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    foreach ($r in $results) {
        $lines.Add(('[{0}] {1} ({2}): {3}' -f $r.State, (Get-SubText -Group 'labels' -Key $r.Id), $r.Id, $r.Detail))
    }
    $ng = @($results | Where-Object { $_.State -eq 'NG' })
    if ($ng.Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-Text -Key 'adviceTitle'))
        foreach ($r in $ng) { $lines.Add(('- {0}: {1}' -f (Get-SubText -Group 'labels' -Key $r.Id), (Get-SubText -Group 'advice' -Key $r.Id))) }
    }
    return ($lines -join "`r`n")
}

function Show-CheckResult {
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($r in $results) {
        $item = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList (Get-StateText -State $r.State)
        [void]$item.SubItems.Add((Get-SubText -Group 'labels' -Key $r.Id))
        [void]$item.SubItems.Add($r.Detail)
        switch ($r.State) {
            'OK' { $item.BackColor = [System.Drawing.Color]::FromArgb(232, 245, 233) }
            'NG' { $item.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 238) }
            default { $item.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245) }
        }
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    $ng = @($results | Where-Object { $_.State -eq 'NG' })
    $text = Get-ReportText
    try {
        # UTF-8 with BOM so Notepad on any Windows version opens it correctly
        [System.IO.File]::WriteAllText($resultPath, $text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
        $saved = (Get-Text -Key 'savedTo') + $resultPath
    } catch {
        $saved = (Get-Text -Key 'saveFailed') + $_.Exception.Message
    }
    if ($ng.Count -eq 0) {
        $summary = Get-Text -Key 'summaryAllOk'
    } else {
        $summary = (Get-Text -Key 'summaryNg') -f $ng.Count
    }
    $adviceLines = @($summary, $saved)
    foreach ($r in $ng) { $adviceLines += ('- {0}: {1}' -f (Get-SubText -Group 'labels' -Key $r.Id), (Get-SubText -Group 'advice' -Key $r.Id)) }
    $advice.Text = $adviceLines -join "`r`n"
}

$copyButton.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText((Get-ReportText))
    [void][System.Windows.Forms.MessageBox]::Show((Get-Text -Key 'copied'), $form.Text)
})

# ----------------------------------------------------------------- checks that need the window
$form.Add_Shown({
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()

    Invoke-Check 'foreground' {
        # Also the ability SWITCH needs: bring a window to the front despite the foreground lock
        if (-not $nativeReady) { return @('SKIP', 'C#') }
        $before = [FujiCheckNative]::GetForegroundWindow()
        if ($before -eq $form.Handle) { return @('OK', 'already in front') }
        $how = [FujiCheckNative]::BringToFront($form.Handle)
        [System.Windows.Forms.Application]::DoEvents()
        $parent = ''
        try {
            $ppid = (Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $PID)).ParentProcessId
            $parent = (Get-Process -Id $ppid -ErrorAction Stop).ProcessName
        } catch { $parent = '?' }
        $detail = 'front before: {0} / started from: {1} / brought by: {2}' -f [FujiCheckNative]::Describe($before), $parent, $(if ($how) { $how } else { '-' })
        @($(if ($how) { 'OK' } else { 'NG' }), $detail)
    }

    Invoke-Check 'clipboard' {
        # Only plain text is restored afterwards, so leave any other clipboard content untouched
        $hadText = [System.Windows.Forms.Clipboard]::ContainsText()
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        $empty = -not $hadText -and ($null -eq $data -or $data.GetFormats().Count -eq 0)
        if (-not $hadText -and -not $empty) { return @('SKIP', 'clipboard holds non-text data (kept as is)') }
        $before = ''
        if ($hadText) { $before = [System.Windows.Forms.Clipboard]::GetText() }
        $mark = 'fujikyun-' + [guid]::NewGuid().ToString('N')
        try {
            [System.Windows.Forms.Clipboard]::SetText($mark)
            $back = [System.Windows.Forms.Clipboard]::GetText()
        } finally {
            if ($hadText) { [System.Windows.Forms.Clipboard]::SetText($before) } else { [System.Windows.Forms.Clipboard]::Clear() }
        }
        @($(if ($back -eq $mark) { 'OK' } else { 'NG' }), 'round trip')
    }

    Invoke-Check 'sendKeys' {
        # Keys go only to this tool's own text box: never send while another window is in front
        if (-not $nativeReady) { return @('SKIP', 'C#') }
        $probe.Text = ''
        [void]$probe.Focus()
        [System.Windows.Forms.Application]::DoEvents()
        if ([FujiCheckNative]::GetForegroundWindow() -ne $form.Handle -or -not $probe.Focused) {
            return @('SKIP', 'this window was not in front')
        }
        [System.Windows.Forms.SendKeys]::SendWait('fuji123')
        # SendWait may return before every injected key reached this window's message queue:
        # keep pumping messages for a while (up to 3 s) before judging
        $deadline = (Get-Date).AddSeconds(3)
        $waitedMs = 0
        while ($probe.Text -ne 'fuji123' -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
            $waitedMs += 50
        }
        @($(if ($probe.Text -eq 'fuji123') { 'OK' } else { 'NG' }), ('"{0}" (waited {1} ms)' -f $probe.Text, $waitedMs))
    }

    Show-CheckResult
})

[void]$form.ShowDialog()
$form.Dispose()
$uiFont.Dispose()
