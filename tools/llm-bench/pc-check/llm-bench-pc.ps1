<#
    LLM accuracy, memory and time check on a work PC, with Qwen3.5-2B Q4_K_M.
    Run llm-check.bat and llm-speed.bat first in this folder (they leave .\llama-x64 and qwen35-q4.gguf).
    Put these in the same folder: llm-bench-pc.bat, llm-bench-pc.ps1, Invoke-LlmBench.ps1,
    Invoke-LlmBench2.ps1, cases.json, cases2.json. Double-click llm-bench-pc.bat.
    Both benches (the ones run on the VM) are run three times with llama-server:
      1. -c 4096 as on the VM
      2. -c 4096 with less memory (no prompt cache in RAM, 4 context checkpoints, one slot)
      3. -c 2048 with less memory
    Nothing outside this folder is changed. The report is llm-bench-pc-result.txt (copy its text back);
    the answers are in result_pc_*.json.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
function Done { [IO.File]::WriteAllLines((Join-Path $here 'llm-bench-pc-result.txt'), $out); Write-Host ('wrote ' + (Join-Path $here 'llm-bench-pc-result.txt')) }
function Free { $os = Get-CimInstance Win32_OperatingSystem; return ('memory GB: ' + [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1) + ' (free ' + [Math]::Round($os.FreePhysicalMemory / 1MB, 1) + ')') }
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say (Free)
$model = 'qwen35-q4.gguf'
$need = @('llama-x64\llama-server.exe', $model, 'Invoke-LlmBench.ps1', 'Invoke-LlmBench2.ps1', 'cases.json', 'cases2.json')
$miss = @($need | Where-Object { -not (Test-Path (Join-Path $here $_)) })
if ($miss.Count -gt 0) { Say ('STOP: not in this folder: ' + ($miss -join ', ')); Done; return }
$lean = '--cache-ram 0 -ctxcp 4 -np 1'
$runs = @(
    @{ Name = 'c4096'; Ctx = 4096; Args = '' },
    @{ Name = 'c4096-lean'; Ctx = 4096; Args = $lean },
    @{ Name = 'c2048-lean'; Ctx = 2048; Args = $lean })
$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($r in $runs) {
    Say ''
    Say ('== ' + $r.Name + ' (-c ' + $r.Ctx + ' ' + $r.Args + ') ' + (Free))
    foreach ($b in @(@{ Script = 'Invoke-LlmBench.ps1'; Out = 'result_pc_' + $r.Name + '.json'; V2 = $true }, @{ Script = 'Invoke-LlmBench2.ps1'; Out = 'result2_pc_' + $r.Name + '.json'; V2 = $false })) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $a = @{ Models = @($model); Dir = $here; Bin = 'llama-x64'; Threads = 8; Out = (Join-Path $here $b.Out); Ctx = $r.Ctx; ServerArgs = $r.Args }
        if ($b.V2) { $a.V2 = $true }
        try { & (Join-Path $here $b.Script) @a | ForEach-Object { Say ('  ' + $_) } } catch { Say ('  ' + $b.Script + ' failed: ' + $_.Exception.Message) }
        Say ("  {0}: {1:N0} s" -f $b.Script, $sw.Elapsed.TotalSeconds)
    }
}
Say ''
Say ("total: {0:N0} min" -f $total.Elapsed.TotalMinutes)
Say 'notes: peakMb = most memory llama-server used; medianMs = time per question (half took less); extract/classify/judge and macro..calc = right answers'
Done
