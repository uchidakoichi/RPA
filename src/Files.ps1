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
