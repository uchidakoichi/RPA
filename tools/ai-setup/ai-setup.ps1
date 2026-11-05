<#
    Puts the AI for fujikyun's AI commands in a shared folder (done once by one person).
    Put ai-setup.bat, ai-setup.ps1 and the base64 parts in one folder:
      llama_x64_01.txt .. llama_x64_03.txt   llama.cpp b12063 win-cpu-x64 (branch llm-pc-test, tools/llm-bench/pc-check)
      qwen35_q4_01.txt .. qwen35_q4_19.txt   Qwen3.5-2B Q4_K_M (branch llm-model-qwen35, tools/llm-bench/pc-check/model)
    Double-click ai-setup.bat and choose the shared folder to make (for example a folder named AI on
    the office's shared drive). Every part is checked on its own (SHA-256), so only the bad ones
    need pasting again. The folder gets llama-x64\, qwen35-q4.gguf and ai.json (the version, every
    file's size and SHA-256, and llama-server's options); ai.json is written last. Each person then
    chooses this folder in fujikyun's AI settings. The report is ai-setup-result.txt.
    Usage: ai-setup.ps1 [-Target <folder>]
#>
param([string]$Target = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
function Done { [IO.File]::WriteAllLines((Join-Path $here 'ai-setup-result.txt'), $out); Write-Host ('wrote ' + (Join-Path $here 'ai-setup-result.txt')) }
$sets = @(
    @{ Name = 'llama.cpp b12063 x64'; Prefix = 'llama_x64_'; Parts = 3; Sha = '4e3766c32a517cdd66ea28f57c862d6b83582ba5d1354f9db585b34f7ad8cf62'
      PartSha = @(
        'a90a06f2073bb8e4968c1587769ae04315d7920172442506a3ea464926f3ca0b',
        '90c634e0fb5d4f714c545a0af1d78b9a1e2fce0906d576c85977ea108ea694c9',
        '85fb605f38e6d44c27bb7ed5d5393fe69218d70c5e16d30d838b5531a0b3843d') },
    @{ Name = 'Qwen3.5-2B Q4_K_M'; Prefix = 'qwen35_q4_'; Parts = 19; Sha = 'e85e87a1ba5ca5d90aca625b300a24de2bbd808fd572a5080d8a1ce66f648448'
      PartSha = @(
        '53425de8aa8b1409dab5c87733a799fa9082d0036bdf01c3dcc050928b1d856e',
        'b753d14593469424e3ffdc3cc2970b67a95e8d9663fac7e61461ed98e8aa584b',
        '5ebfe49a525429849d5377d2294e195600458aee73c319756699dbe243fe9644',
        '787c804bbec8129a057695577a969bfee3885d040bd9efa69b34ff078f098f03',
        'cb6d162db803769ecf3d31d52a10c2091ac91506b03d1e5e4f67558f5e0700e2',
        '8d0b612c4bf9ac057d62915fd4bf3d9438a55a675f025efc2b25f730ca2777d5',
        '79bf7b2708ff9e4a1b426dd5204c9a9e2da7c73f5b8622989b6159c479e73ed1',
        '28b73b5dbe9a3010f6605db39745de820cff09ad7f591a30e596745d73069997',
        'ed9638bbe4b60b43c4ba68c79a750272c58765c51d271c554b6ceb9700537342',
        '510b8304451ad4b5cd54f3b7ea3862ac7ca1a0c870d5572b82ac78400145c5e3',
        '3743172177f0f5330f29ba2b28728449307b976481806f5517bf8df541afe6cc',
        'bd1c92d9a4de32923eb614b5b5079099e1e81cd0ecf4ffb15cf0b2b7aec48fd4',
        '8aa488ef7f01d0757ec6c485468baae1061d84ce22e17039ba84d2715bcc5ffe',
        'f5418c6579abe4ce315d77fbaf1206f0c47a965dcbe56e128b8612a09af87229',
        '1ea8c401e2f2f936326c91c0e90e3fd2a99e50975950e569a1b9f0ff87c578e8',
        '2096b5bf22c9dc32235223d666b2ba4aa3011844a38705354272387f964b4e15',
        '67c55df1cd92017e1fbf513142d36282cfccc038ff910623262dfeaa7ee784c9',
        '9ecf962b4e87ea0310de1aaac54bbf0937048447fb14c66428102f2e6d772a59',
        'dba8f6678373427c19ac0e01e541102e56dd0647150f79c39e352b3aae101557') })
$serverArgs = '-c 4096 -t 8 --cache-ram 0 -ctxcp 4 -np 1 --no-repack --jinja'
$sha256 = [Security.Cryptography.SHA256]::Create()
function Get-Hex([byte[]]$h) { return ([BitConverter]::ToString($h).Replace('-', '').ToLower()) }
function Get-FileSha([string]$path) { $s = [IO.File]::OpenRead($path); try { return (Get-Hex $sha256.ComputeHash($s)) } finally { $s.Close() } }
# Decodes the parts of one set into Path (one part at a time, so memory stays small); returns the names to paste again
function Join-Part($set, [string]$path) {
    $bad = New-Object System.Collections.Generic.List[string]
    $fs = [IO.File]::Create($path)
    try {
        for ($i = 0; $i -lt $set.Parts; $i++) {
            $name = '{0}{1:D2}.txt' -f $set.Prefix, ($i + 1)
            $p = Join-Path $here $name
            if (-not (Test-Path -LiteralPath $p)) { Say ('  ' + $name + ': MISSING'); $bad.Add($name); continue }
            $t = [IO.File]::ReadAllText($p) -replace '\s', ''
            try { $b = [Convert]::FromBase64String($t) } catch { Say ('  ' + $name + ': BROKEN, paste it again'); $bad.Add($name); continue }
            if ((Get-Hex $sha256.ComputeHash($b)) -ne $set.PartSha[$i]) { Say ('  ' + $name + ': BAD (sha256 differs), paste it again'); $bad.Add($name) }
            else { Say ('  ' + $name + ': OK') }
            if ($bad.Count -eq 0) { $fs.Write($b, 0, $b.Length) }
            $t = $null; $b = $null; [GC]::Collect()
        }
    } finally { $fs.Close() }
    return , $bad
}

Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if (-not $Target) {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'AI folder on the shared drive (a new empty folder, for example AI)'
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Say 'STOP: no folder chosen'; Done; return }
    $Target = $d.SelectedPath
}
Say ('target: ' + $Target)
if (-not (Test-Path -LiteralPath $Target)) { [void](New-Item -ItemType Directory -Path $Target) }
$work = Join-Path $Target ('setup_' + (Get-Date -Format 'yyyyMMddHHmmss'))
[void](New-Item -ItemType Directory -Path $work)
$bad = New-Object System.Collections.Generic.List[string]
try {
    $zip = Join-Path $work 'llama-x64.zip'
    $model = Join-Path $work 'qwen35-q4.gguf'
    foreach ($pair in @(@($sets[0], $zip), @($sets[1], $model))) {
        Say ('== ' + $pair[0].Name)
        foreach ($b in (Join-Part $pair[0] $pair[1])) { $bad.Add($b) }
    }
    if ($bad.Count -gt 0) { Say ('STOP: paste these again: ' + ($bad -join ', ')); return }
    foreach ($pair in @(@($sets[0], $zip), @($sets[1], $model))) {
        $sha = Get-FileSha $pair[1]
        if ($sha -ne $pair[0].Sha) { Say ('STOP: ' + $pair[0].Name + ' sha256 ' + $sha + ' MISMATCH (parts out of order?)'); $bad.Add($pair[0].Name); return }
    }
    Say 'joined: sha256 OK'
    $llama = Join-Path $work 'llama-x64'
    Expand-Archive -LiteralPath $zip -DestinationPath $llama -Force
    Remove-Item -LiteralPath $zip -Force
    # replace what an earlier setup left, then the list of files (ai.json is written last)
    $old = Join-Path $Target 'ai.json'
    $version = 1
    if (Test-Path -LiteralPath $old) {
        try { $version = [int]((Get-Content -LiteralPath $old -Raw -Encoding UTF8 | ConvertFrom-Json).aiVersion) + 1 } catch { $version = 1 }
        Remove-Item -LiteralPath $old -Force
    }
    foreach ($n in @('llama-x64', 'qwen35-q4.gguf')) {
        $dest = Join-Path $Target $n
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath (Join-Path $work $n) -Destination $dest
    }
    $files = [ordered]@{}
    foreach ($f in @(Get-Item -LiteralPath (Join-Path $Target 'qwen35-q4.gguf')) + @(Get-ChildItem -LiteralPath (Join-Path $Target 'llama-x64') -Recurse -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Target.TrimEnd('\').Length + 1).Replace('\', '/')
        $sha = $sets[1].Sha
        if ($rel -ne 'qwen35-q4.gguf') { $sha = Get-FileSha $f.FullName }
        $files[$rel] = [ordered]@{ size = $f.Length; sha256 = $sha }
    }
    $manifest = [ordered]@{ aiVersion = $version; model = 'qwen35-q4.gguf'; files = $files; serverArgs = $serverArgs }
    $json = ConvertTo-Json -InputObject $manifest -Depth 5
    [IO.File]::WriteAllText((Join-Path $Target 'ai.json.part'), $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath (Join-Path $Target 'ai.json.part') -Destination (Join-Path $Target 'ai.json')
    Say ('done: aiVersion ' + $version + ', ' + $files.Count + ' files. Each person chooses this folder in fujikyun: ' + $Target)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Done
}
