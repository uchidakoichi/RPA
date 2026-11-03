<#
    Checks the pasted test files (paste_32MB.txt ...) in this folder: did each arrive whole?
    Double-click check-paste.bat. For each file: the size, OK or where it breaks (the first line
    that is missing or changed). The result is also written to check-paste-result.txt.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$expected = @{
    '32' = '27ad8d01ff912f35c4765e6ad26d620865bf3e6ace2dacf3dc76089096c51958'
    '48' = 'e02045f1a108f9cbe73a8e8f953335e1369e2432ec1be0a8f4f6fdd0b3a4e653'
    '64' = '9de528813c84c214fbbfff4e7d96134035a136aa69fe8e66884cded22d62f598'
    '96' = 'eaeb2a72847f1e4e1ed2ff4d06174044414a681e6141f6ec445691e2f273b77a'
}
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  memory GB: ' + [Math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1))
$files = @(Get-ChildItem -LiteralPath $here -Filter 'paste_*MB.txt' | Sort-Object Name)
if ($files.Count -eq 0) { Say 'no paste_NNMB.txt here' }
foreach ($f in $files) {
    $mb = [regex]::Match($f.Name, 'paste_0*([0-9]+)MB').Groups[1].Value
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $text = [Text.Encoding]::ASCII.GetString($bytes).Replace("`r`n", "`n")
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($text))).Replace('-', '').ToLower()
    if ($expected.ContainsKey($mb) -and $sha -eq $expected[$mb]) { Say ('{0}: OK ({1:N0} bytes)' -f $f.Name, $bytes.Length); continue }
    # where it breaks: line numbers must run 1, 2, 3 ... and each line be 78 characters
    $lines = $text.Split("`n")
    $why = 'changed somewhere (line numbers are in order)'
    $want = 1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.StartsWith('END')) { break }
        if ($l.Length -ne 78 -or $l -notmatch ('^L{0:D8} ' -f $want)) { $why = ('breaks at line {0} (expected L{1:D8}, got "{2}")' -f ($i + 1), $want, $(if ($l.Length -gt 20) { $l.Substring(0, 20) + '...' } else { $l })); break }
        $want++
    }
    if ($lines.Count -gt 0 -and -not ($text.TrimEnd("`n").Split("`n")[-1]).StartsWith('END')) { $why += '; the END line is missing (cut short)' }
    Say ('{0}: NG ({1:N0} bytes) {2}' -f $f.Name, $bytes.Length, $why)
}
[IO.File]::WriteAllLines((Join-Path $here 'check-paste-result.txt'), $out)
