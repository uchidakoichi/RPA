# ---------------------------------------------------------------------------------------------
#  Seeing the screen during a run: click by image, OCR (read / click text), click by name
#  The slow parts run in a second PowerShell runspace while the window waits with Wait-FujiUiRun,
#  so Pause, Stop and Esc keep working. Clicks are always made here, never in the background: a
#  search that is stopped never clicks.
# ---------------------------------------------------------------------------------------------

$script:FujiBackgroundLeft = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:FujiVisionLimits = @{ NameTimeoutSec = 30; ImageTimeoutSec = 90; OcrTimeoutSec = 90; OcrRetry = 3 }

# Runs Script (text, so it carries nothing from this runspace) as param($State, <Arguments>) in a
# new runspace. The script sets $State.Result, or $State.Error, then $State.Ready = $true (it may
# set Ready before it finishes, as a click by name does before pressing). Returns $State.Result.
function Invoke-FujiBackground {
    param([string]$Script, [object[]]$Arguments = @(), [int]$TimeoutSec = 30)
    $state = [hashtable]::Synchronized(@{ Ready = $false; Result = $null; Error = '' })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script).AddArgument($state)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $state.Ready -and -not $handle.IsCompleted) {
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { throw (Get-FujiText 'run.bgTimeout' $TimeoutSec) }
            [void](Wait-FujiUiRun -Ms 50)
        }
        if (-not $state.Ready) {
            # ended without handing over: a failure the script did not catch
            try {
                [void]$ps.EndInvoke($handle)
            } catch {
                $inner = $_.Exception
                while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
                throw $inner.Message
            }
            if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception.Message }
        }
        if ($state.Error) { throw [string]$state.Error }
        return $state.Result
    } finally {
        if ($handle.IsCompleted) {
            $ps.Dispose()
            $rs.Dispose()
        } else {
            # still busy (stopped, or a button whose press waits for a dialog): closed after the run
            $script:FujiBackgroundLeft.Add(@($ps, $rs, $handle))
        }
    }
}

function Clear-FujiBackground {
    foreach ($b in @($script:FujiBackgroundLeft.ToArray())) {
        if ($b[2].IsCompleted) {
            $b[0].Dispose()
            $b[1].Dispose()
            [void]$script:FujiBackgroundLeft.Remove($b)
        }
    }
}

# ----------------------------------------------------------------- pixels
function Get-FujiBitmapPixel {
    param([System.Drawing.Bitmap]$Bitmap)
    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $rect = New-Object -TypeName System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $px = New-Object -TypeName 'int[]' -ArgumentList ($w * $h)
        if ($data.Stride -eq $w * 4) {
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
        } else {
            for ($y = 0; $y -lt $h; $y++) {
                [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + [long]$y * $data.Stride), $px, $y * $w, $w)
            }
        }
    } finally {
        $Bitmap.UnlockBits($data)
    }
    return @{ Pixels = $px; Width = $w; Height = $h }
}

function Read-FujiImageFilePixel {
    param([string]$Path)
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $Path
    try { return (Get-FujiBitmapPixel -Bitmap $bmp) } finally { $bmp.Dispose() }
}

function Get-FujiScreenPixel {
    param([System.Drawing.Rectangle]$Rect)
    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $Rect.Width, $Rect.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { $g.CopyFromScreen($Rect.X, $Rect.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
        return (Get-FujiBitmapPixel -Bitmap $bmp)
    } finally {
        $bmp.Dispose()
    }
}

# ----------------------------------------------------------------- click by image
$script:FujiFindScript = @'
param($State, $Screen, $Sw, $Sh, $Template, $Tw, $Th, $Threshold, $Tolerance, $MaxMillis)
try { $State.Result = [FujiImageMatch]::Find($Screen, $Sw, $Sh, $Template, $Tw, $Th, $Threshold, $Tolerance, $MaxMillis) }
catch { $State.Error = $_.Exception.Message }
finally { $State.Ready = $true }
'@

# Up to three looks at the screen, a second apart, within one minute. Returns @{ X; Y; Score }.
function Invoke-FujiImageClick {
    param([string]$Path, [double]$Threshold)
    if (-not ('FujiImageMatch' -as [type])) {
        Write-FujiUiLog -Message (Get-FujiText 'run.imgPrepare')
        [void](Initialize-FujiImageMatch)
    }
    $tpl = Read-FujiImageFilePixel -Path $Path
    $deadline = (Get-Date).AddSeconds($script:FujiImageLimits.DeadlineSec)
    for ($i = 0; $i -lt $script:FujiImageLimits.Retry; $i++) {
        if ($i -gt 0) { [void](Wait-FujiUiRun -Ms 1000) }
        $left = [int](($deadline - (Get-Date)).TotalMilliseconds)
        if ($left -le 0) { throw (Get-FujiText 'run.imgTimeout') }
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $scr = Get-FujiScreenPixel -Rect $vs
        $r = Invoke-FujiBackground -Script $script:FujiFindScript -TimeoutSec $script:FujiVisionLimits.ImageTimeoutSec -Arguments @(
            $scr.Pixels, $scr.Width, $scr.Height, $tpl.Pixels, $tpl.Width, $tpl.Height, $Threshold, $script:FujiImageLimits.ColorTolerance, $left)
        $hit = ConvertFrom-FujiMatchResult -Result ([string]$r) -Left $vs.X -Top $vs.Y -TemplateWidth $tpl.Width -TemplateHeight $tpl.Height
        if ($hit -eq 'TIMEOUT') { throw (Get-FujiText 'run.imgTimeout') }
        if ($null -ne $hit) {
            Invoke-FujiMouseClick -X $hit.X -Y $hit.Y -Kind 'LEFT'
            return $hit
        }
    }
    throw (Get-FujiText 'run.imgNotFoundScreen' ([Math]::Round($Threshold * 100)) $script:FujiImageLimits.Retry)
}

# ----------------------------------------------------------------- OCR
# Captures X, Y, W, H enlarged for small text, reads it with the OCR engine of Windows (offline,
# the user's languages) and hands back plain lines: @{ Lines; X; Y; Scale } or 'NOLANG'
$script:FujiOcrScript = @'
param($State, $X, $Y, $W, $H, $Png, $ScaleRule)
try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Wait-FujiOp($Op, [Type]$Type) { $t = $asTask.MakeGenericMethod($Type).Invoke($null, @($Op)); [void]$t.Wait(-1); $t.Result }
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) {
        $State.Result = 'NOLANG'
    } else {
        $scale = & ([scriptblock]::Create($ScaleRule)) -Width $W -Height $H -MaxDimension ([Windows.Media.Ocr.OcrEngine]::MaxImageDimension)
        $src = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $W, $H
        try {
            $g = [System.Drawing.Graphics]::FromImage($src)
            try { $g.CopyFromScreen($X, $Y, 0, 0, $src.Size) } finally { $g.Dispose() }
            $dw = [Math]::Max(1, [int]($W * $scale))
            $dh = [Math]::Max(1, [int]($H * $scale))
            $dst = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $dw, $dh
            try {
                $g = [System.Drawing.Graphics]::FromImage($dst)
                try {
                    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.DrawImage($src, 0, 0, $dw, $dh)
                } finally { $g.Dispose() }
                $dst.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $dst.Dispose() }
        } finally { $src.Dispose() }
        $file = Wait-FujiOp ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Png)) ([Windows.Storage.StorageFile])
        $stream = Wait-FujiOp ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        try {
            $decoder = Wait-FujiOp ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bmp = Wait-FujiOp ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $res = Wait-FujiOp ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        } finally { $stream.Dispose() }
        $lines = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($line in $res.Lines) {
            $words = New-Object -TypeName 'System.Collections.Generic.List[object]'
            foreach ($w in $line.Words) {
                $b = $w.BoundingRect
                $words.Add(@{ Text = [string]$w.Text; X = [double]$b.X; Y = [double]$b.Y; W = [double]$b.Width; H = [double]$b.Height })
            }
            $lines.Add(@{ Words = $words.ToArray() })
        }
        $State.Result = @{ Lines = $lines.ToArray(); X = $X; Y = $Y; Scale = $scale }
    }
} catch {
    $State.Error = $_.Exception.Message
} finally {
    if (Test-Path -LiteralPath $Png) { Remove-Item -LiteralPath $Png -Force -ErrorAction SilentlyContinue }
    $State.Ready = $true
}
'@

function Get-FujiForegroundRect {
    $native = Get-FujiNativeType
    $a = New-Object -TypeName 'int[]' -ArgumentList 4
    if ($native::GetWindowRect($native::GetForegroundWindow(), $a) -and $a[2] -gt $a[0] -and $a[3] -gt $a[1]) {
        return @{ X = $a[0]; Y = $a[1]; Width = ($a[2] - $a[0]); Height = ($a[3] - $a[1]) }
    }
    return $null
}

# Find '': read the area and return its text. Otherwise find the text (three looks, a second
# apart), click the Nth place and return "x,y".
function Invoke-FujiOcr {
    param([System.Collections.IDictionary]$Settings, [string]$Find, [int]$Nth)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $screen = @{ X = $vs.X; Y = $vs.Y; Width = $vs.Width; Height = $vs.Height }
    $tries = 1
    if ($Find) { $tries = $script:FujiVisionLimits.OcrRetry }
    # The scale rule travels as text: the background runspace has none of these functions
    $scaleRule = [string]${function:Get-FujiOcrScale}
    for ($i = 0; $i -lt $tries; $i++) {
        if ($i -gt 0) { [void](Wait-FujiUiRun -Ms 1000) }
        $rect = Get-FujiOcrRect -Settings $Settings -Screen $screen -Foreground (Get-FujiForegroundRect)
        $png = Join-Path ([System.IO.Path]::GetTempPath()) ('fujikyun_ocr_' + [guid]::NewGuid().ToString('N') + '.png')
        $res = Invoke-FujiBackground -Script $script:FujiOcrScript -TimeoutSec $script:FujiVisionLimits.OcrTimeoutSec -Arguments @($rect.X, $rect.Y, $rect.Width, $rect.Height, $png, $scaleRule)
        if ($res -is [string] -and $res -eq 'NOLANG') { throw (Get-FujiText 'run.ocrNoLanguage') }
        if (-not $Find) { return (ConvertTo-FujiOcrText -Lines $res.Lines) }
        $p = Find-FujiOcrText -Lines $res.Lines -Find $Find -Nth $Nth -OffsetX $res.X -OffsetY $res.Y -Scale $res.Scale
        if ($null -ne $p) {
            Invoke-FujiMouseClick -X $p.X -Y $p.Y -Kind 'LEFT'
            return ('{0},{1}' -f $p.X, $p.Y)
        }
    }
    throw (Get-FujiText 'run.ocrNotFound' $Find $tries)
}

# ----------------------------------------------------------------- click by name (UI Automation)
# Looks in the window that has the focus, then in the windows whose title contains the target
# window's title. The result is handed over before the press: a button that opens a dialog may not
# return from Invoke() until that dialog is closed.
$script:FujiNameScript = @'
param($State, $Name, $Hint)
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    $cond = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList $AE::NameProperty, $Name
    $scopes = New-Object -TypeName System.Collections.ArrayList
    $focused = $null
    try { $focused = $AE::FocusedElement } catch { $focused = $null }
    if ($null -ne $focused) {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $node = $focused
        $top = $focused
        while ($null -ne $node -and -not [System.Windows.Automation.Automation]::Compare($node, $AE::RootElement)) {
            $top = $node
            $node = $walker.GetParent($node)
        }
        [void]$scopes.Add($top)
    }
    if ($Hint) {
        foreach ($w in $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
            $wn = $w.Current.Name
            if ($null -ne $wn -and $wn.Contains($Hint)) { [void]$scopes.Add($w) }
        }
    }
    $el = $null
    foreach ($s in $scopes) {
        $el = $s.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($null -ne $el) { break }
    }
    if ($null -eq $el) {
        $State.Result = 'NOTFOUND'
    } else {
        $p = $null
        $patterns = @(
            @('Invoke', [System.Windows.Automation.InvokePattern]::Pattern),
            @('Toggle', [System.Windows.Automation.TogglePattern]::Pattern),
            @('Select', [System.Windows.Automation.SelectionItemPattern]::Pattern),
            @('Expand', [System.Windows.Automation.ExpandCollapsePattern]::Pattern))
        $State.Result = 'NOPATTERN'
        foreach ($pt in $patterns) {
            if ($el.TryGetCurrentPattern($pt[1], [ref]$p)) {
                $State.Result = $pt[0]
                $State.Ready = $true
                switch ($pt[0]) {
                    'Invoke' { $p.Invoke() }
                    'Toggle' { $p.Toggle() }
                    'Select' { $p.Select() }
                    'Expand' { $p.Expand() }
                }
                break
            }
        }
    }
} catch {
    if (-not $State.Ready) { $State.Error = $_.Exception.Message }
} finally {
    $State.Ready = $true
}
'@

function Invoke-FujiNameClick {
    param([string]$Name, [string]$WindowTitle)
    $r = [string](Invoke-FujiBackground -Script $script:FujiNameScript -TimeoutSec $script:FujiVisionLimits.NameTimeoutSec -Arguments @($Name, $WindowTitle))
    if ($r -eq 'NOTFOUND') { throw (Get-FujiText 'run.uiaNotFound' $Name) }
    if ($r -eq 'NOPATTERN') { throw (Get-FujiText 'run.uiaNoPattern') }
    return $r
}
