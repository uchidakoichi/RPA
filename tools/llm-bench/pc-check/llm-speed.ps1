<#
    LLM speed check on a work PC. Run llm-check.bat first (it unpacks llama.cpp into .\llama-x64).
    Put llm-speed.bat, llm-speed.ps1 and the parts of one or more models in the same folder
    (qwen17_q4_01.txt .. qwen17_q4_16.txt for Qwen3-1.7B, qwen35_q4_01.txt .. qwen35_q4_19.txt for
    Qwen3.5-2B) and double-click llm-speed.bat. For every model whose parts are there, the parts are
    decoded one by one into one .gguf (so memory use stays small), checked against the SHA-256 below,
    and llama-bench measures how fast the model reads
    a prompt (pp) and writes an answer (tg) with several thread counts. Nothing outside this folder is
    changed. The report is written to llm-speed-result.txt (copy its text back).
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
function Done { [IO.File]::WriteAllLines((Join-Path $here 'llm-speed-result.txt'), $out); Say ('wrote ' + (Join-Path $here 'llm-speed-result.txt')) }
function Get-Sha([string]$path) {
    $s = [IO.File]::OpenRead($path)
    try { return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s)).Replace('-', '').ToLower() } finally { $s.Close() }
}
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$os = Get-CimInstance Win32_OperatingSystem
Say ('memory GB: ' + [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1) + ' (free ' + [Math]::Round($os.FreePhysicalMemory / 1MB, 1) + ')')
$power = (powercfg /getactivescheme) -join ' '
Say ('power: ' + $power + ' / on AC: ' + [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object { $_.BatteryStatus -eq 2 }))
$bench = Join-Path $here 'llama-x64\llama-bench.exe'
if (-not (Test-Path $bench)) { Say 'STOP: llama-x64\llama-bench.exe not found (run llm-check.bat in this folder first)'; Done; return }
$models = @(
    @{ Name = 'Qwen3-1.7B Q4_K_M'; Prefix = 'qwen17_q4_'; Parts = 16; File = 'qwen17-q4.gguf'; Sha = '54c0f1203a724e9f33e76916beab3bdfaffef56cf7b42a93b1bc21319fc0bf97'
      PartSha = @(
        '34e7fc6c6fefa5abd40ac48a1507f5fa39e3154508557d81b5662c2a16f117ad',
        '045fe9cfd69ff749286d2e8b7920357e55a70c75beb2367a55c3625a2ef07053',
        '800cff5e34867560eb2e49540eadd3ceb2f9d5139a186e4e538b649173b0503f',
        'f2b3164f127bf7e1db9de88ad13e25a4c34db299ef1c3df0d9b1b56a73add33b',
        '45055ef560041ec8408ae406728952841b28617dbdb91cffe15c122de0b46cb3',
        '6554aa207b7d3a81fe57befd125b352965a7743d00d5571bf779b2328f0883f9',
        '57f54fea526ab1ea1be0cff75228d9db8ec22edff121f53114511af8ff8806e9',
        '46784ee8d5e0705e2b474cf1a87a4bc0d4415781c967a87e5ea5c6ddc7653834',
        'ac439f528ca232f36c45e310d4bbfc0f87d4e17040706e34b0ceebf71e492060',
        'a49f3fe0590f3f5d1d880b18c51a83545a829d8114893e49f897d49d9d45740c',
        '9af8efc1c5314530b3d7ccc72ef86268c1d1559b931e5c3753dc23222939ca46',
        '73565574a92f16918bc585df80eee563634cdb2c4d45ff1c0223082b16fcc8f2',
        '2f442631d0385c6b8813275826868dcc8d333ed63fd4cda28a2da67a526546bf',
        '86c31b3cc6cab0612fc269a4ed38846d21fd857c81457f1fd422c2bd6b59d47f',
        'ef75912bc98315064a4abd2d8bdbe5de510f366e43536cea66fddcc3042878be',
        'be30d8f88e0e0a7b46e2dbefc8be82a3d207d85c3fad901155cc6985f23f9177') },
    @{ Name = 'Qwen3.5-2B Q4_K_M'; Prefix = 'qwen35_q4_'; Parts = 19; File = 'qwen35-q4.gguf'; Sha = 'e85e87a1ba5ca5d90aca625b300a24de2bbd808fd572a5080d8a1ce66f648448'
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
function Join-Model($m) {
    $model = Join-Path $here $m.File
    if ((Test-Path $model) -and (Get-Sha $model) -eq $m.Sha) { Say 'model: already joined, sha256 OK'; return $model }
    $parts = @(Get-ChildItem -LiteralPath $here -Filter ($m.Prefix + '*.txt') | Sort-Object Name)
    Say ('parts: ' + $parts.Count + ' (expected ' + $m.Parts + ')')
    # every part is checked on its own (SHA-256 of its decoded bytes), so only the bad ones need pasting again
    $bad = New-Object System.Collections.Generic.List[string]
    $sha256 = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Create($model)
    try {
        for ($i = 0; $i -lt $m.Parts; $i++) {
            $want = ('{0}{1:D2}.txt' -f $m.Prefix, ($i + 1))
            $p = Get-Item -LiteralPath (Join-Path $here $want) -ErrorAction SilentlyContinue
            if (-not $p) { Say ('  ' + $want + ': MISSING'); $bad.Add($want); continue }
            $t = [IO.File]::ReadAllText($p.FullName) -replace '\s', ''
            try { $b = [Convert]::FromBase64String($t) } catch { Say ('  ' + $p.Name + ': BROKEN, paste it again (' + $_.Exception.Message + ')'); $bad.Add($p.Name); continue }
            $h = [BitConverter]::ToString($sha256.ComputeHash($b)).Replace('-', '').ToLower()
            if ($h -ne $m.PartSha[$i]) { Say ('  ' + $p.Name + ': ' + $b.Length + ' bytes, BAD (sha256 differs), paste it again'); $bad.Add($p.Name) }
            else { Say ('  ' + $p.Name + ': ' + $b.Length + ' bytes, OK') }
            if ($bad.Count -eq 0) { $fs.Write($b, 0, $b.Length) }
            $t = $null; $b = $null; [GC]::Collect()
        }
    } finally { $fs.Close() }
    if ($bad.Count -gt 0) { Say ('SKIP: paste these again: ' + ($bad -join ', ')); Remove-Item -LiteralPath $model -ErrorAction SilentlyContinue; return $null }
    $sha = Get-Sha $model
    Say ('model sha256: ' + $sha + ' ' + $(if ($sha -eq $m.Sha) { 'OK' } else { 'MISMATCH (a part is missing, cut short or out of order)' }))
    if ($sha -ne $m.Sha) { return $null }
    return $model
}
$ran = 0
$found = 0
foreach ($m in $models) {
    if (-not (Get-ChildItem -LiteralPath $here -Filter ($m.Prefix + '*.txt')) -and -not (Test-Path (Join-Path $here $m.File))) { continue }
    $found++
    Say ''
    Say ('== ' + $m.Name)
    $model = Join-Model $m
    if (-not $model) { continue }
    $ran++
    $o = Join-Path $here 'bench_out.txt'
    $e = Join-Path $here 'bench_err.txt'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $bench -ArgumentList '-m', ('"' + $model + '"'), '-t', '2,4,6,8,10', '-p', '256', '-n', '64', '-r', '2' -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
    Say ("llama-bench: exit 0x{0:X}, {1:N0} s" -f $p.ExitCode, $sw.Elapsed.TotalSeconds)
    foreach ($l in @(Get-Content $o) | Where-Object { $_.Trim() }) { Say ('  ' + $l) }
    if ($p.ExitCode -ne 0) { foreach ($l in @(Get-Content $e) | Select-Object -Last 15) { Say ('  ' + $l) } }
}
if ($found -eq 0) { Say 'STOP: no model parts found in this folder (qwen17_q4_*.txt or qwen35_q4_*.txt)'; Done; return }
if ($ran -eq 0) { Say 'STOP: no model could be joined (see the parts above)'; Done; return }
Say 'notes: pp256 = tokens per second when reading a 256-token prompt; tg64 = tokens per second when writing'
Done
