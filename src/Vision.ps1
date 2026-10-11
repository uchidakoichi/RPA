# ---------------------------------------------------------------------------------------------
#  Seeing the screen: image matching (CLICK_IMG) and reading OCR results (CLICK_TEXT / READ_TEXT)
#  Only the parts that need no screen live here, so they are tested anywhere. The window side
#  (gui/Vision.ps1) captures the screen, runs the OCR engine and clicks.
# ---------------------------------------------------------------------------------------------

# Template matcher (the HTA's): comparing every screen position pixel by pixel is far too slow in
# PowerShell, so this one small class is compiled, on the first image click only. Pixels are ARGB
# ints; template pixels with alpha < 128 are ignored; a pixel matches when every RGB channel is
# within tol. Template pixels are compared in a shuffled order, so a wrong position is given up
# after a few of them.
$script:FujiMatchSource = @'
using System;
using System.Collections.Generic;
public static class FujiImageMatch {
    static bool Near(int a, int b, int tol) {
        int d = ((a >> 16) & 255) - ((b >> 16) & 255);
        if (d > tol || d < -tol) { return false; }
        d = ((a >> 8) & 255) - ((b >> 8) & 255);
        if (d > tol || d < -tol) { return false; }
        d = (a & 255) - (b & 255);
        return d <= tol && d >= -tol;
    }
    // "left,top,score(0-1000)" of the best place in the screen pixels, "" when none reaches the
    // threshold, "TIMEOUT" when maxMillis ran out before any place was found
    public static string Find(int[] spx, int sw, int sh, int[] tpx, int tw, int th, double threshold, int tol, int maxMillis) {
        System.Diagnostics.Stopwatch watch = System.Diagnostics.Stopwatch.StartNew();
        if (tw > sw || th > sh) { return ""; }
        List<int> offList = new List<int>();
        List<int> colList = new List<int>();
        for (int ty = 0; ty < th; ty++) {
            for (int tx = 0; tx < tw; tx++) {
                int c = tpx[ty * tw + tx];
                if (((c >> 24) & 255) < 128) { continue; }
                offList.Add(ty * sw + tx);
                colList.Add(c);
            }
        }
        int n = offList.Count;
        if (n == 0) { return ""; }
        int[] off = offList.ToArray();
        int[] col = colList.ToArray();
        Random rnd = new Random(20240601);
        for (int i = n - 1; i > 0; i--) {
            int j = rnd.Next(i + 1);
            int t = off[i]; off[i] = off[j]; off[j] = t;
            t = col[i]; col[i] = col[j]; col[j] = t;
        }
        int sampleN = Math.Min(n, 64);
        int sampleAllowed = Math.Min(sampleN - 1, (int)Math.Floor((1.0 - threshold) * sampleN * 2.0 + 1e-9) + 1);
        int allowed = (int)Math.Floor((1.0 - threshold) * n + 1e-9);
        int bestMiss = allowed + 1, bestX = -1, bestY = -1;
        for (int y = 0; y <= sh - th && bestMiss > 0; y++) {
            if (watch.ElapsedMilliseconds > maxMillis) { if (bestX >= 0) { break; } return "TIMEOUT"; }
            int row = y * sw;
            for (int x = 0; x <= sw - tw; x++) {
                int b = row + x;
                int miss = 0;
                int k;
                for (k = 0; k < sampleN; k++) {
                    if (!Near(spx[b + off[k]], col[k], tol) && ++miss > sampleAllowed) { break; }
                }
                if (miss > sampleAllowed) { continue; }
                int limit = bestMiss - 1;
                miss = 0;
                for (k = 0; k < n; k++) {
                    if (!Near(spx[b + off[k]], col[k], tol) && ++miss > limit) { break; }
                }
                if (miss <= limit) {
                    bestMiss = miss;
                    bestX = x;
                    bestY = y;
                    if (miss == 0) { break; }
                }
            }
        }
        if (bestX < 0) { return ""; }
        int score = (int)Math.Round((1.0 - (double)bestMiss / n) * 1000.0);
        return bestX + "," + bestY + "," + score;
    }
}
'@
$script:FujiImageLimits = @{ ColorTolerance = 24; Retry = 3; DeadlineSec = 60 }

# Compiles the matcher once per session. Returns $true when it was compiled now (first use).
function Initialize-FujiImageMatch {
    if ('FujiImageMatch' -as [type]) { return $false }
    Add-Type -TypeDefinition $script:FujiMatchSource -Language CSharp
    return $true
}

# @{ X; Y; Score (0-1) } of the template's centre in screen coordinates, or $null / 'TIMEOUT'
function Find-FujiTemplate {
    param([int[]]$Screen, [int]$ScreenWidth, [int]$ScreenHeight, [int[]]$Template, [int]$TemplateWidth, [int]$TemplateHeight,
        [double]$Threshold, [int]$Left = 0, [int]$Top = 0, [int]$MaxMillis = 60000)
    $r = [FujiImageMatch]::Find($Screen, $ScreenWidth, $ScreenHeight, $Template, $TemplateWidth, $TemplateHeight, $Threshold, $script:FujiImageLimits.ColorTolerance, $MaxMillis)
    return (ConvertFrom-FujiMatchResult -Result $r -Left $Left -Top $Top -TemplateWidth $TemplateWidth -TemplateHeight $TemplateHeight)
}

# The matcher's "left,top,score" -> @{ X; Y; Score } (centre on the screen), $null or 'TIMEOUT'
function ConvertFrom-FujiMatchResult {
    param([AllowEmptyString()][string]$Result, [int]$Left, [int]$Top, [int]$TemplateWidth, [int]$TemplateHeight)
    if ($Result -eq '') { return $null }
    if ($Result -eq 'TIMEOUT') { return 'TIMEOUT' }
    $p = $Result.Split(',')
    return @{ X = $Left + [int]$p[0] + [int][Math]::Floor($TemplateWidth / 2); Y = $Top + [int]$p[1] + [int][Math]::Floor($TemplateHeight / 2); Score = [int]$p[2] / 1000.0 }
}

# ----------------------------------------------------------------- OCR results
# A recognised line: @{ Words = @(@{ Text; X; Y; W; H }, ...) } in the captured image's pixels.

# Words joined the way people write them: no space between two non-ASCII (Japanese) words
function Join-FujiOcrWord {
    param([AllowEmptyCollection()][object[]]$Words)
    $sb = New-Object -TypeName System.Text.StringBuilder
    $prev = ''
    foreach ($w in $Words) {
        $t = [string]$w.Text
        if ($sb.Length -gt 0 -and -not ($prev -match '[^\x00-\x7F]$' -and $t -match '^[^\x00-\x7F]')) { [void]$sb.Append(' ') }
        [void]$sb.Append($t)
        $prev = $t
    }
    return $sb.ToString()
}

function ConvertTo-FujiOcrText {
    param([AllowEmptyCollection()][object[]]$Lines)
    $out = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($l in $Lines) { $out.Add((Join-FujiOcrWord -Words $l.Words)) }
    return [string]::Join("`r`n", $out.ToArray())
}

# Full-width letters and digits as half-width, all spaces removed: OCR splits Japanese into words
function Get-FujiOcrKey {
    param([AllowEmptyString()][string]$Text)
    $s = [regex]::Replace([string]$Text, '[\uFF01-\uFF5E]', { param($m) [string][char]([int][char]$m.Value - 0xFEE0) })
    return ($s -replace '[\s\u3000]', '')
}

# Screen point of the Nth place (1 = first, top to bottom) where Find appears, or $null.
# Offset / Scale: where the captured image was on the screen and how much it was enlarged.
function Find-FujiOcrText {
    param([AllowEmptyCollection()][object[]]$Lines, [string]$Find, [int]$Nth = 1, [int]$OffsetX = 0, [int]$OffsetY = 0, [double]$Scale = 1.0)
    $target = Get-FujiOcrKey $Find
    if ($target -eq '') { return $null }
    $found = 0
    foreach ($line in $Lines) {
        $words = $line.Words
        $chars = New-Object -TypeName System.Text.StringBuilder
        $owner = New-Object -TypeName 'System.Collections.Generic.List[int]'
        for ($k = 0; $k -lt $words.Count; $k++) {
            $wt = Get-FujiOcrKey ([string]$words[$k].Text)
            [void]$chars.Append($wt)
            for ($c = 0; $c -lt $wt.Length; $c++) { $owner.Add($k) }
        }
        $all = $chars.ToString()
        $pos = $all.IndexOf($target, [System.StringComparison]::Ordinal)
        while ($pos -ge 0) {
            $found++
            if ($found -eq $Nth) {
                $first = $owner[$pos]
                $last = $owner[$pos + $target.Length - 1]
                $l = [double]::MaxValue; $t = [double]::MaxValue; $r = [double]::MinValue; $b = [double]::MinValue
                for ($k = $first; $k -le $last; $k++) {
                    $w = $words[$k]
                    $l = [Math]::Min($l, [double]$w.X); $t = [Math]::Min($t, [double]$w.Y)
                    $r = [Math]::Max($r, [double]$w.X + $w.W); $b = [Math]::Max($b, [double]$w.Y + $w.H)
                }
                return @{ X = [int]($OffsetX + ($l + $r) / 2 / $Scale); Y = [int]($OffsetY + ($t + $b) / 2 / $Scale) }
            }
            $pos = $all.IndexOf($target, $pos + 1, [System.StringComparison]::Ordinal)
        }
    }
    return $null
}

# The screen rectangle to read: @{ X; Y; Width; Height }. Screen / Foreground: rectangles of the
# whole desktop and of the window in front ($null when there is none).
function Get-FujiOcrRect {
    param([System.Collections.IDictionary]$Settings, [hashtable]$Screen, [hashtable]$Foreground = $null)
    switch ([string]$Settings['area']) {
        'RECT' {
            return @{ X = (Get-FujiInt -Text $Settings['x'] -Default 0); Y = (Get-FujiInt -Text $Settings['y'] -Default 0)
                Width = (Get-FujiInt -Text $Settings['w'] -Default 0); Height = (Get-FujiInt -Text $Settings['h'] -Default 0) }
        }
        'FULL' { return $Screen }
    }
    if ($null -ne $Foreground -and $Foreground.Width -gt 0 -and $Foreground.Height -gt 0) { return $Foreground }
    return $Screen
}

# Small text is read better enlarged: up to 2x, within the OCR engine's largest image side
function Get-FujiOcrScale {
    param([int]$Width, [int]$Height, [int]$MaxDimension)
    return [Math]::Min(2.0, $MaxDimension / [double]([Math]::Max(1, [Math]::Max($Width, $Height))))
}
