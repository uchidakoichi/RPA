# ---------------------------------------------------------------------------------------------
#  Text resources
#  Every Japanese text lives in fujikyun_ja.json (UTF-8): Windows PowerShell 5.1 reads a script
#  without a BOM in the ANSI code page, so the .ps1 files stay ASCII only.
# ---------------------------------------------------------------------------------------------

$script:FujiText = $null
# Raised whenever fujikyun_ja.json gets texts the scripts need: an older file is reported at start
$script:FujiTextVersion = 2

# Reads a UTF-8 file strictly: bytes that are not UTF-8 (for example a file saved as Shift_JIS)
# throw instead of turning into replacement characters. A UTF-8 BOM is accepted and dropped.
function Read-FujiUtf8File {
    param([Parameter(Mandatory)][string]$Path)
    $strict = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true
    $text = [System.IO.File]::ReadAllText($Path, $strict)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Import-FujiText {
    param([Parameter(Mandatory)][string]$Path)
    $script:FujiText = Read-FujiUtf8File -Path $Path | ConvertFrom-Json
    # "Fujikyun" built from code points so this file stays ASCII
    $expected = -join ([char[]](0x3075, 0x3058, 0x30AD, 0x30E5, 0x30F3))
    if ([string]$script:FujiText.sentinel -ne $expected) {
        throw ('Text resource {0} is not the expected UTF-8 file' -f $Path)
    }
}

# Get-FujiText 'calc.badChar' 'x'  ->  the text at that dotted path, formatted with the arguments
function Get-FujiText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(ValueFromRemainingArguments)][object[]]$FormatArgs
    )
    $node = $script:FujiText
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node) { break }
        $p = $node.PSObject.Properties[$part]
        if ($null -eq $p) { $node = $null; break }
        $node = $p.Value
    }
    if ($null -eq $node) { return $Key }
    if ($node -is [System.Array]) { return , $node }
    if ($node -is [System.Management.Automation.PSCustomObject]) { return $node }
    if ($FormatArgs -and $FormatArgs.Count -gt 0) { return ([string]$node -f $FormatArgs) }
    return [string]$node
}

# '' when fujikyun_ja.json is as new as this script, otherwise the message to show. A missing text
# is shown as its key (gui.schedule ...), so an old file next to a new script must be pointed out.
function Test-FujiTextVersion {
    $p = $script:FujiText.PSObject.Properties['textVersion']
    $have = 0
    if ($null -ne $p) { $have = [int]$p.Value }
    if ($have -ge $script:FujiTextVersion) { return '' }
    $message = Get-FujiText 'gui.textOld' $have $script:FujiTextVersion
    if ($message -eq 'gui.textOld') {
        $message = 'fujikyun_ja.json is older than fujikyun.ps1 (text version {0}, needed {1}). Please replace fujikyun_ja.json with the latest one.' -f $have, $script:FujiTextVersion
    }
    return $message
}
