# ---------------------------------------------------------------------------------------------
#  Recording: normal work on the PC becomes steps (clicks, keys, typed text, window switches)
#  The recorder (the HTA's) is a small C# class compiled on the first recording only. It watches
#  the keyboard / mouse state and the window in front from a second runspace; this app's own
#  windows are never recorded. ConvertFrom-FujiRecording (src/Recording.ps1) turns its lines into steps.
# ---------------------------------------------------------------------------------------------

$script:Rec = $null

$script:FujiRecorderSource = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Automation;
public struct FujiRecPoint { public int X; public int Y; }
public class FujiRecorder {
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out FujiRecPoint p);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int size, uint flags, IntPtr hkl);
    public static volatile bool StopRequested;
    public static volatile int Count;
    List<string> ev = new List<string>();
    StringBuilder text = new StringBuilder();
    int lastTick = Environment.TickCount;
    int lastClickTick = 0, lastClickX = -9999, lastClickY = -9999, lastClickIndex = -1;
    bool imeNoted = false;
    int textStart = 0;
    static string Clean(string s) { return (s ?? "").Replace("\t", " ").Replace("\r", " ").Replace("\n", " "); }
    static string Title(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
    void Add(string line) { AddAt(line, Environment.TickCount); }
    void AddAt(string line, int when) {
        int gap = when - lastTick;
        if (gap > 1200 && ev.Count > 0) { ev.Add("W\t" + Math.Min(10000, (gap / 100) * 100)); }
        ev.Add(line);
        lastTick = Environment.TickCount;
        Count = ev.Count;
    }
    void FlushText() { if (text.Length > 0) { AddAt("T\t" + Clean(text.ToString()), textStart); text.Length = 0; } }
    static string Named(int vk) {
        switch (vk) {
            case 8: return "{BS}"; case 9: return "{TAB}"; case 13: return "{ENTER}"; case 27: return "{ESC}";
            case 33: return "{PGUP}"; case 34: return "{PGDN}"; case 35: return "{END}"; case 36: return "{HOME}";
            case 37: return "{LEFT}"; case 38: return "{UP}"; case 39: return "{RIGHT}"; case 40: return "{DOWN}";
            case 45: return "{INSERT}"; case 46: return "{DELETE}";
        }
        if (vk >= 112 && vk <= 123) { return "{F" + (vk - 111) + "}"; }
        return null;
    }
    // The name of a button under the point, when it can be pressed by name
    static string InvokableName(int x, int y) {
        try {
            AutomationElement el = AutomationElement.FromPoint(new System.Windows.Point(x, y));
            if (el == null) { return ""; }
            object p;
            if (!el.TryGetCurrentPattern(InvokePattern.Pattern, out p)) { return ""; }
            string n = el.Current.Name;
            return string.IsNullOrEmpty(n) || n.Length > 40 ? "" : Clean(n);
        } catch { return ""; }
    }
    void Click(bool right) {
        FujiRecPoint p; GetCursorPos(out p);
        FlushText(); imeNoted = false;
        int now = Environment.TickCount;
        if (!right && now - lastClickTick < 500 && Math.Abs(p.X - lastClickX) < 5 && Math.Abs(p.Y - lastClickY) < 5 && lastClickIndex == ev.Count - 1) {
            ev[lastClickIndex] = "C\t" + lastClickX + "\t" + lastClickY + "\tDOUBLE"; lastClickTick = 0; return;
        }
        string name = right ? "" : InvokableName(p.X, p.Y);
        Add(name != "" ? "N\t" + name + "\t" + p.X + "\t" + p.Y : "C\t" + p.X + "\t" + p.Y + "\t" + (right ? "RIGHT" : "LEFT"));
        lastClickTick = now; lastClickX = p.X; lastClickY = p.Y; lastClickIndex = ev.Count - 1;
    }
    void Key(int vk, IntPtr fg) {
        bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0, ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0, alt = (GetAsyncKeyState(0x12) & 0x8000) != 0;
        if (vk == 229) { if (!imeNoted) { FlushText(); Add("J"); imeNoted = true; } return; }
        string named = Named(vk);
        if (ctrl || alt) {
            string k = named;
            if (k == null && vk >= 65 && vk <= 90) { k = ((char)(vk + 32)).ToString(); }
            if (k == null && vk >= 48 && vk <= 57) { k = ((char)vk).ToString(); }
            if (k == null && vk == 32) { k = " "; }
            if (k == null) { return; }
            FlushText(); imeNoted = false;
            Add("K\t" + (ctrl ? "^" : "") + (alt ? "%" : "") + (shift ? "+" : "") + k);
            return;
        }
        if (named != null) { FlushText(); imeNoted = false; Add("K\t" + (shift ? "+" : "") + named); return; }
        byte[] state = new byte[256];
        if (shift) { state[0x10] = 0x80; state[0xA0] = 0x80; }
        StringBuilder buf = new StringBuilder(8);
        uint ignored;
        IntPtr hkl = GetKeyboardLayout(GetWindowThreadProcessId(fg, out ignored));
        int n = ToUnicodeEx((uint)vk, MapVirtualKey((uint)vk, 0), state, buf, 8, 0, hkl);
        if (n > 0) { string s = buf.ToString(0, n); if (s[0] >= ' ') { if (text.Length == 0) { textStart = Environment.TickCount; } text.Append(s); imeNoted = false; } }
    }
    // Records until StopRequested (or maxMinutes); windows of process ownPid are ignored
    public static string Run(int ownPid, int maxMinutes) {
        FujiRecorder r = new FujiRecorder();
        Count = 0;
        bool[] down = new bool[256];
        IntPtr lastWin = IntPtr.Zero;
        DateTime start = DateTime.Now;
        for (int vk = 1; vk < 255; vk++) { down[vk] = (GetAsyncKeyState(vk) & 0x8000) != 0; }
        while (!StopRequested && (DateTime.Now - start).TotalMinutes <= maxMinutes) {
            IntPtr fg = GetForegroundWindow();
            uint pid;
            GetWindowThreadProcessId(fg, out pid);
            bool ignore = pid == (uint)ownPid;
            string title = Title(fg);
            if (fg != lastWin && !ignore && title.Length > 0) { r.FlushText(); r.imeNoted = false; r.Add("S\t" + Clean(title)); lastWin = fg; }
            for (int vk = 1; vk < 255; vk++) {
                bool now = (GetAsyncKeyState(vk) & 0x8000) != 0;
                if (now && !down[vk] && !ignore) {
                    if (vk == 1) { r.Click(false); }
                    else if (vk == 2) { r.Click(true); }
                    else if (vk < 7 || (vk >= 16 && vk <= 18) || vk == 20 || vk == 91 || vk == 92 || (vk >= 160 && vk <= 165)) { }
                    else { r.Key(vk, fg); }
                }
                down[vk] = now;
            }
            Thread.Sleep(15);
        }
        r.FlushText();
        return string.Join("\n", r.ev.ToArray());
    }
}
'@

$script:FujiRecordScript = @'
param($State, $OwnId)
try { $State.Result = [FujiRecorder]::Run($OwnId, 240) } catch { $State.Error = $_.Exception.Message } finally { $State.Ready = $true }
'@

function Initialize-FujiRecorder {
    if ('FujiRecorder' -as [type]) { return }
    Write-FujiUiLog -Message (Get-FujiText 'rec.prepare')
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName WindowsBase
    $refs = @([System.Windows.Automation.AutomationElement].Assembly.Location, [System.Windows.Automation.ControlType].Assembly.Location, [System.Windows.Point].Assembly.Location)
    Add-Type -ReferencedAssemblies $refs -TypeDefinition $script:FujiRecorderSource -Language CSharp
}

function Switch-FujiRecording {
    if ($null -ne $script:Rec) {
        [FujiRecorder]::StopRequested = $true
        Write-FujiUiLog -Message (Get-FujiText 'rec.stopping')
        return
    }
    if ($script:RunCtl.Running) { return }
    Initialize-FujiRecorder
    [FujiRecorder]::StopRequested = $false
    $state = [hashtable]::Synchronized(@{ Ready = $false; Result = $null; Error = '' })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:FujiRecordScript).AddArgument($state).AddArgument($PID)
    $handle = $ps.BeginInvoke()
    $macro = Get-FujiCurrentMacro $script:Ed
    $script:Rec = @{ State = $state; Ps = $ps; Rs = $rs; Handle = $handle; MacroId = [string]$macro.id; At = (Get-FujiInsertionIndex $script:Ed); Timer = $null }
    $t = New-Object -TypeName System.Windows.Forms.Timer
    $t.Interval = 500
    $t.Add_Tick({ Invoke-FujiUi { Update-FujiRecording } })
    $script:Rec.Timer = $t
    $t.Start()
    Update-FujiRecordUi
    Write-FujiUiLog -Message (Get-FujiText 'rec.start') -Level 'run'
}

function Update-FujiRecording {
    $r = $script:Rec
    if ($null -eq $r) { return }
    if (-not $r.State.Ready -and -not $r.Handle.IsCompleted) {
        $n = [FujiRecorder]::Count
        $count = ''
        if ($n -gt 0) { $count = Get-FujiText 'rec.count' $n }
        $script:Ui.RecordButton.Text = Get-FujiText 'rec.stopButton' $count
        return
    }
    $r.Timer.Stop()
    $r.Timer.Dispose()
    $script:Rec = $null
    $payload = [string]$r.State.Result
    $failure = [string]$r.State.Error
    if ($r.Handle.IsCompleted) { $r.Ps.Dispose(); $r.Rs.Dispose() }
    Update-FujiRecordUi
    if ($failure) {
        Write-FujiUiLog -Message (Get-FujiText 'rec.failed' $failure) -Level 'error'
        return
    }
    if ((Add-FujiRecordedStep -Editor $script:Ed -MacroId $r.MacroId -At $r.At -Payload $payload) -gt 0) { Update-FujiAll }
}

function Update-FujiRecordUi {
    $recording = $null -ne $script:Rec
    $b = $script:Ui.RecordButton
    if ($recording) {
        $b.Text = Get-FujiText 'rec.stopButton' ''
        $b.BackColor = Get-FujiColor '#ffd6dc'
    } else {
        $b.Text = Get-FujiText 'rec.button'
        $b.UseVisualStyleBackColor = $true
    }
    $script:Ui.RunButton.Enabled = -not $recording -and -not $script:RunCtl.Running
}
