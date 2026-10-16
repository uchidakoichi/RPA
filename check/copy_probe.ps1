<#
    Investigation aid: sends Ctrl+C to a window you choose many times, the way the app's COPY step
    does (clear the clipboard, Ctrl+C, read it), and compares two ways of reading:
      OLD: read 400 ms after Ctrl+C (what the app does now)
      NEW: read as soon as the clipboard sequence number has changed, the clipboard is closed
           again and text is on it (gives up after 3 s)
    After each try the clipboard is read once more at 3 s; that value counts as the right one.
    Only the length of the copied text is written down, never the text itself.
    Usage: select what to copy in the target window first, then copy_probe.bat and pick the window
    by number. Do not touch the PC while it runs. Results also go to copy_probe_log.txt
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FujiCopy {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string ProcessOf(IntPtr h) {
        if (h == IntPtr.Zero) return "(none)";
        uint pid; GetWindowThreadProcessId(h, out pid);
        try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return "?"; }
    }
}
'@
$log = Join-Path $PSScriptRoot 'copy_probe_log.txt'
Set-Content -LiteralPath $log -Value ('Started ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
function Write-ProbeLog([string]$Line) {
    $Line = (Get-Date).ToString('HH:mm:ss.fff') + '  ' + $Line
    Write-Host $Line
    Add-Content -LiteralPath $log -Value $Line -Encoding UTF8
}

$trials = 20          # per way, the two ways take turns
$oldMs = 400
$limitMs = 3000
$cfUnicodeText = 13

# Clipboard.GetText; $null while another program has the clipboard open
function Read-ProbeClipboard {
    try { return [System.Windows.Forms.Clipboard]::GetText() } catch { return $null }
}

function Clear-ProbeClipboard {
    for ($i = 0; $i -lt 10; $i++) {
        try { [System.Windows.Forms.Clipboard]::Clear(); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Invoke-ProbeTry([IntPtr]$Target, [string]$Mode, [int]$No) {
    if ([FujiCopy]::GetForegroundWindow() -ne $Target) {
        Write-ProbeLog ('  front was ' + [FujiCopy]::ProcessOf([FujiCopy]::GetForegroundWindow()) + ', bringing the target back')
        [void][FujiCopy]::SetForegroundWindow($Target)
        Start-Sleep -Milliseconds 300
    }
    if (-not (Clear-ProbeClipboard)) { Write-ProbeLog ('  ' + $Mode + $No + ': clipboard could not be cleared'); return $null }
    Start-Sleep -Milliseconds 100
    $last = [FujiCopy]::GetClipboardSequenceNumber()
    $changes = 0; $firstChange = -1; $readyAt = -1; $readMs = -1; $got = $null
    $openers = @{}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [System.Windows.Forms.SendKeys]::SendWait('^c')
    while ($sw.ElapsedMilliseconds -lt $limitMs) {
        $seq = [FujiCopy]::GetClipboardSequenceNumber()
        if ($seq -ne $last) {
            $changes++; $last = $seq
            if ($firstChange -lt 0) { $firstChange = $sw.ElapsedMilliseconds }
        }
        $open = [FujiCopy]::GetOpenClipboardWindow()
        if ($open -ne [IntPtr]::Zero) { $openers[[FujiCopy]::ProcessOf($open)] = $true }
        if ($null -eq $got) {
            if ($Mode -eq 'OLD' -and $sw.ElapsedMilliseconds -ge $oldMs) {
                $t = $sw.ElapsedMilliseconds; $got = Read-ProbeClipboard; $readMs = $sw.ElapsedMilliseconds - $t
                if ($null -eq $got) { $got = '' }
            }
            if ($Mode -eq 'NEW' -and $firstChange -ge 0 -and $open -eq [IntPtr]::Zero -and [FujiCopy]::IsClipboardFormatAvailable($cfUnicodeText)) {
                $t = $sw.ElapsedMilliseconds; $got = Read-ProbeClipboard; $readMs = $sw.ElapsedMilliseconds - $t
                if ($null -ne $got) { $readyAt = $t }
            }
        }
        Start-Sleep -Milliseconds 5
    }
    $final = Read-ProbeClipboard
    if ($null -eq $final) { $final = '' }
    $line = '  {0}{1,-3}' -f $Mode, $No
    if ($null -eq $got) { $line += ' NO TEXT within ' + $limitMs + ' ms' ; $ok = ($final -eq '') }
    else {
        $ok = ($got -ceq $final -and $final -ne '')
        if ($ok) { $line += ' OK   ' } else { $line += ' WRONG' }
        $line += (' got {0} chars' -f $got.Length)
        if ($Mode -eq 'NEW') { $line += (' at {0} ms' -f $readyAt) }
        $line += (' (reading took {0} ms)' -f $readMs)
    }
    $line += (' / right one {0} chars / first change {1} ms, {2} changes' -f $final.Length, $firstChange, $changes)
    if ($openers.Count -gt 0) { $line += ' / opened by ' + (@($openers.Keys) -join ',') }
    Write-ProbeLog $line
    return @{ Ok = $ok; ReadyAt = $readyAt; Final = $final.Length }
}

do {
    $windows = @(Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle } | Sort-Object ProcessName)
    for ($i = 0; $i -lt $windows.Count; $i++) { Write-Host ('{0,3}: {1} - {2}' -f ($i + 1), $windows[$i].ProcessName, $windows[$i].MainWindowTitle) }
    $pick = Read-Host 'Number of the window to copy from (select what to copy in it first)'
    $n = 0
    if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $windows.Count) { Write-Host 'No such number'; $again = 'y'; continue }
    $target = $windows[$n - 1]
    Write-ProbeLog ('Target: ' + $target.ProcessName + ' - ' + $target.MainWindowTitle)
    Write-Host 'Starting in 3 seconds. Do not touch the PC until it says Done.'
    [void][FujiCopy]::SetForegroundWindow($target.MainWindowHandle)
    Start-Sleep -Seconds 3
    $sum = @{ OLD = @{ Bad = 0; Count = 0 }; NEW = @{ Bad = 0; Count = 0; Times = New-Object System.Collections.Generic.List[long] } }
    for ($k = 1; $k -le $trials; $k++) {
        foreach ($mode in @('OLD', 'NEW')) {
            $r = Invoke-ProbeTry -Target $target.MainWindowHandle -Mode $mode -No $k
            if ($null -eq $r) { continue }
            $sum[$mode].Count++
            if (-not $r.Ok) { $sum[$mode].Bad++ }
            if ($mode -eq 'NEW' -and $r.ReadyAt -ge 0) { $sum.NEW.Times.Add($r.ReadyAt) }
        }
    }
    Write-ProbeLog ('OLD (400 ms): {0} of {1} wrong' -f $sum.OLD.Bad, $sum.OLD.Count)
    $t = $sum.NEW.Times
    $timing = 'no read'
    if ($t.Count -gt 0) { $timing = 'read after {0}-{1} ms, average {2:0} ms' -f ($t | Measure-Object -Minimum).Minimum, ($t | Measure-Object -Maximum).Maximum, ($t | Measure-Object -Average).Average }
    Write-ProbeLog ('NEW (sequence number): {0} of {1} wrong, {2}' -f $sum.NEW.Bad, $sum.NEW.Count, $timing)
    $again = Read-Host 'Done. Try another window? (y/n)'
} while ($again -eq 'y')
Write-ProbeLog 'Finished'
