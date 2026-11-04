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
    @{ Name = 'Qwen3-1.7B Q4_K_M'; Prefix = 'qwen17_q4_'; Parts = 16; File = 'qwen17-q4.gguf'; Sha = '54c0f1203a724e9f33e76916beab3bdfaffef56cf7b42a93b1bc21319fc0bf97' },
    @{ Name = 'Qwen3.5-2B Q4_K_M'; Prefix = 'qwen35_q4_'; Parts = 19; File = 'qwen35-q4.gguf'; Sha = 'e85e87a1ba5ca5d90aca625b300a24de2bbd808fd572a5080d8a1ce66f648448' })
function Join-Model($m) {
    $model = Join-Path $here $m.File
    if ((Test-Path $model) -and (Get-Sha $model) -eq $m.Sha) { Say 'model: already joined, sha256 OK'; return $model }
    $parts = @(Get-ChildItem -LiteralPath $here -Filter ($m.Prefix + '*.txt') | Sort-Object Name)
    Say ('parts: ' + $parts.Count + ' (expected ' + $m.Parts + ')')
    if ($parts.Count -ne $m.Parts) { Say 'SKIP: a part is missing'; return $null }
    $fs = [IO.File]::Create($model)
    try {
        foreach ($p in $parts) {
            $t = [IO.File]::ReadAllText($p.FullName) -replace '\s', ''
            try { $b = [Convert]::FromBase64String($t) } catch { Say ('SKIP: ' + $p.Name + ' is broken (' + $_.Exception.Message + ')'); return $null }
            $fs.Write($b, 0, $b.Length)
            Say ('  ' + $p.Name + ': ' + $b.Length + ' bytes')
            $t = $null; $b = $null; [GC]::Collect()
        }
    } finally { $fs.Close() }
    $sha = Get-Sha $model
    Say ('model sha256: ' + $sha + ' ' + $(if ($sha -eq $m.Sha) { 'OK' } else { 'MISMATCH (a part is missing, cut short or out of order)' }))
    if ($sha -ne $m.Sha) { return $null }
    return $model
}
$ran = 0
foreach ($m in $models) {
    if (-not (Get-ChildItem -LiteralPath $here -Filter ($m.Prefix + '*.txt')) -and -not (Test-Path (Join-Path $here $m.File))) { continue }
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
if ($ran -eq 0) { Say 'STOP: no model parts found in this folder (qwen17_q4_*.txt or qwen35_q4_*.txt)'; Done; return }
Say 'notes: pp256 = tokens per second when reading a 256-token prompt; tg64 = tokens per second when writing'
Done
