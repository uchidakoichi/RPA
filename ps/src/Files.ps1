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
    $bytes = [System.IO.File]::ReadAllBytes($Path)
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
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# The only good copy is never overwritten in place: write a sibling file, read it back, keep the
# previous version as BackupPath, then replace the target
function Write-FujiFileSafely {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$BackupPath)
    $tmp = $Path + '.saving'
    Write-FujiTextFile -Path $tmp -Text $Text
    if ((Read-FujiUtf8File -Path $tmp) -cne $Text) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw (Get-FujiText 'data.verifyFailed')
    }
    if ($BackupPath -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    }
    Copy-Item -LiteralPath $tmp -Destination $Path -Force
    Remove-Item -LiteralPath $tmp -Force
}
