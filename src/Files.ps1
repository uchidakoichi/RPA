# ---------------------------------------------------------------------------------------------
#  Files
# ---------------------------------------------------------------------------------------------

# PowerShell 7 (.NET) needs the code pages provider for Shift_JIS; Windows PowerShell 5.1 has it
function Get-FujiEncoding {
    param([Parameter(Mandatory)][ValidateSet('utf-8', 'shift_jis', 'unicode')][string]$Name)
    switch ($Name) {
        'utf-8' { return (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false) }
        'unicode' { return [System.Text.Encoding]::Unicode }
        'shift_jis' {
            if ($PSVersionTable.PSEdition -eq 'Core' -and -not $script:FujiCodePagesReady) {
                [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
                $script:FujiCodePagesReady = $true
            }
            return [System.Text.Encoding]::GetEncoding(932)
        }
    }
}
$script:FujiCodePagesReady = $false

# Decodes bytes; a byte order mark wins over the requested encoding and is dropped
function ConvertFrom-FujiByteArray {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [Parameter(Mandatory)][string]$Encoding)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return (Get-FujiEncoding -Name 'utf-8').GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    return (Get-FujiEncoding -Name $Encoding).GetString($Bytes)
}

# CSV text with the HTA's rules: "auto" tries UTF-8 and falls back to Shift_JIS when the bytes are
# not valid UTF-8. Returns @{ Text; Encoding }.
function Read-FujiCsvText {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('auto', 'utf-8', 'shift_jis', 'unicode')][string]$Encoding = 'auto')
    $bytes = Read-FujiSharedFileByte -Path $Path
    if ($Encoding -ne 'auto') {
        return @{ Text = (ConvertFrom-FujiByteArray -Bytes $bytes -Encoding $Encoding); Encoding = $Encoding }
    }
    $text = ConvertFrom-FujiByteArray -Bytes $bytes -Encoding 'utf-8'
    if ($text.IndexOf([char]0xFFFD) -lt 0) {
        return @{ Text = $text; Encoding = 'utf-8' }
    }
    return @{ Text = (ConvertFrom-FujiByteArray -Bytes $bytes -Encoding 'shift_jis'); Encoding = 'shift_jis' }
}

# UTF-8 (BOM only when asked: CSV files for Excel)
function Write-FujiTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Bom)
    $enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList ([bool]$Bom)
    try {
        [System.IO.File]::WriteAllText($Path, $Text, $enc)
    } catch {
        if (Test-FujiFileBusy -Exception $_.Exception) { throw (Get-FujiText 'data.fileBusy' $Path) }
        throw
    }
}

# The file is open in another program that keeps others from it (Excel keeps an open book or CSV
# locked): ERROR_SHARING_VIOLATION 32 or ERROR_LOCK_VIOLATION 33, possibly wrapped by PowerShell
function Test-FujiFileBusy {
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.IO.IOException] -and @(32, 33) -contains ($e.HResult -band 0xFFFF)) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# The bytes of a file another program may have open for writing (a CSV open in Excel can still be read)
function Read-FujiSharedFileByte {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = New-Object -TypeName System.IO.FileStream -ArgumentList $Path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    } catch {
        if (Test-FujiFileBusy -Exception $_.Exception) { throw (Get-FujiText 'data.fileBusy' $Path) }
        throw
    }
    try {
        $ms = New-Object -TypeName System.IO.MemoryStream
        $fs.CopyTo($ms)
        return , $ms.ToArray()
    } finally {
        $fs.Dispose()
    }
}

# FILE_OP: copies, moves or renames files. Source: a full path; its name may hold * and ? (copy and
# move: every matching file of that folder). Dest: a folder (ends with \ or exists as one; made when
# missing) or a full path; for RENAME the new name only. Every target is checked before anything is
# done, so an error leaves all files as they were. The app's own files (fujikyun* in AppDirectory)
# are never touched. Returns @(@{ From; To }, ...).
function Invoke-FujiFileOperation {
    param([Parameter(Mandatory)][ValidateSet('COPY', 'MOVE', 'RENAME')][string]$Op, [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest, [bool]$Overwrite = $false, [string]$AppDirectory = '')
    $folder = [System.IO.Path]::GetDirectoryName($Source)
    $pattern = [System.IO.Path]::GetFileName($Source)
    $wild = $pattern -match '[*?]'
    if ($wild -and $Op -eq 'RENAME') { throw (Get-FujiText 'validate.fileRenameWild') }
    $files = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($wild) {
        if (-not $folder -or -not [System.IO.Directory]::Exists($folder)) { throw (Get-FujiText 'run.fileNoFolder' $folder) }
        # GetFiles("*.pdf") also returns .pdfx (8.3 names): match the names again exactly
        $re = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList @(('^' + ([regex]::Escape($pattern) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'), [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
        foreach ($f in [System.IO.Directory]::GetFiles($folder)) { if ($re.IsMatch([System.IO.Path]::GetFileName($f))) { $files.Add($f) } }
        if ($files.Count -eq 0) { throw (Get-FujiText 'run.fileNoMatch' $pattern $folder) }
    } else {
        if (-not [System.IO.File]::Exists($Source)) { throw (Get-FujiText 'run.fileNotFound' $Source) }
        $files.Add([System.IO.Path]::GetFullPath($Source))
    }
    $toFolder = ''
    if ($Op -ne 'RENAME' -and ($wild -or $Dest.EndsWith('\') -or $Dest.EndsWith('/') -or [System.IO.Directory]::Exists($Dest))) { $toFolder = $Dest }
    $pairs = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($f in $files) {
        if ($Op -eq 'RENAME') { $to = Join-Path ([System.IO.Path]::GetDirectoryName($f)) $Dest }
        elseif ($toFolder) { $to = Join-Path $toFolder ([System.IO.Path]::GetFileName($f)) }
        else { $to = $Dest }
        $to = [System.IO.Path]::GetFullPath($to)
        foreach ($p in @($f, $to)) { if (Test-FujiAppFile -Path $p -AppDirectory $AppDirectory) { throw (Get-FujiText 'run.fileProtected' $p) } }
        if ([string]::Equals($f, $to, [System.StringComparison]::Ordinal)) { throw (Get-FujiText 'run.fileSame' $f) }
        # only the case of the name changes (a.pdf -> A.pdf): the same file, not one in the way
        $caseOnly = [string]::Equals($f, $to, [System.StringComparison]::OrdinalIgnoreCase)
        if ($caseOnly -and $Op -eq 'COPY') { throw (Get-FujiText 'run.fileSame' $f) }
        if ([System.IO.Directory]::Exists($to)) { throw (Get-FujiText 'run.fileIsFolder' $to) }
        if (-not $caseOnly -and [System.IO.File]::Exists($to) -and -not $Overwrite) { throw (Get-FujiText 'run.fileExists' $to) }
        foreach ($q in $pairs) { if ([string]::Equals($q.To, $to, [System.StringComparison]::OrdinalIgnoreCase)) { throw (Get-FujiText 'run.fileExists' $to) } }
        $pairs.Add(@{ From = $f; To = $to; CaseOnly = $caseOnly })
    }
    try {
        foreach ($p in $pairs) {
            $parent = [System.IO.Path]::GetDirectoryName($p.To)
            if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
            if ($Op -eq 'COPY') {
                [System.IO.File]::Copy($p.From, $p.To, $Overwrite)
            } elseif (-not $p.CaseOnly -and [System.IO.File]::Exists($p.To)) {
                # File.Move never replaces a file: copy over it, then remove the original
                [System.IO.File]::Copy($p.From, $p.To, $true)
                [System.IO.File]::Delete($p.From)
            } else {
                [System.IO.File]::Move($p.From, $p.To)
            }
        }
    } catch {
        if (Test-FujiFileBusy -Exception $_.Exception) { throw (Get-FujiText 'run.fileBusy') }
        throw
    }
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($p in $pairs) { $out.Add(@{ From = $p.From; To = $p.To }) }
    return , $out.ToArray()
}

# The app itself, its settings and macros: fujikyun* directly in the app's folder
function Test-FujiAppFile {
    param([string]$Path, [string]$AppDirectory)
    if (-not $AppDirectory) { return $false }
    $dir = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [string]::Equals($dir, ([string]$parent).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return [System.IO.Path]::GetFileName($Path).StartsWith('fujikyun', [System.StringComparison]::OrdinalIgnoreCase)
}

# The only good copy is never overwritten in place: write a sibling file, read it back, keep the
# previous version as BackupPath, then replace the target
function Write-FujiFileSafely {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$BackupPath)
    $tmp = $Path + '.saving'
    try {
        Write-FujiTextFile -Path $tmp -Text $Text
        if ((Read-FujiUtf8File -Path $tmp) -cne $Text) { throw (Get-FujiText 'data.verifyFailed') }
        if ($BackupPath -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
        }
        Copy-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        # the target is untouched (or the copy failed): no half-written sibling is left behind
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if (Test-FujiFileBusy -Exception $_.Exception) { throw (Get-FujiText 'data.fileBusy' $Path) }
        throw
    }
    Remove-Item -LiteralPath $tmp -Force
}
