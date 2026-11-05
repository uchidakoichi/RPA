<#
    Memory and load time check on a work PC, with Qwen3.5-2B Q4_K_M (follows llm-bench-pc).
    Put llm-mem-pc.bat and llm-mem-pc.ps1 in the llm-bench-pc folder (it already has .\llama-x64,
    qwen35-q4.gguf, Invoke-LlmBench.ps1 and cases.json) and double-click llm-mem-pc.bat.
    Bench 1 (extract, classify, judge) is run with the memory saving options, three times:
      1. the model in this folder (as llm-bench-pc did)
      2. the model copied to the local disk (%LOCALAPPDATA%\llm-mem-test)
      3. the same, with --no-repack (llama.cpp does not keep a rearranged copy of the weights)
    The copy on the local disk is deleted at the end. The report is llm-mem-pc-result.txt.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
function Done { [IO.File]::WriteAllLines((Join-Path $here 'llm-mem-pc-result.txt'), $out); Write-Host ('wrote ' + (Join-Path $here 'llm-mem-pc-result.txt')) }
function Free { $os = Get-CimInstance Win32_OperatingSystem; return ('memory GB: ' + [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1) + ' (free ' + [Math]::Round($os.FreePhysicalMemory / 1MB, 1) + ')') }
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say (Free)
Say ('folder: ' + $here)
$model = Join-Path $here 'qwen35-q4.gguf'
$need = @('llama-x64\llama-server.exe', 'qwen35-q4.gguf', 'Invoke-LlmBench.ps1', 'cases.json')
$miss = @($need | Where-Object { -not (Test-Path (Join-Path $here $_)) })
if ($miss.Count -gt 0) { Say ('STOP: not in this folder: ' + ($miss -join ', ')); Done; return }
$local = Join-Path $env:LOCALAPPDATA 'llm-mem-test'
$drive = (Get-Item $env:LOCALAPPDATA).PSDrive
$size = (Get-Item $model).Length
Say ('local disk ' + $drive.Name + ': free GB ' + [Math]::Round($drive.Free / 1GB, 1))
$lean = '--cache-ram 0 -ctxcp 4 -np 1'
function Run([string]$name, [string]$path, [string]$extra) {
    Say ''
    Say ('== ' + $name + ' (' + $path + ' ' + $lean + ' ' + $extra + ') ' + (Free))
    $a = @{ V2 = $true; Models = @($path); Dir = $here; Bin = 'llama-x64'; Threads = 8; Out = (Join-Path $here ('result_mem_' + $name + '.json')); Ctx = 4096; ServerArgs = ($lean + ' ' + $extra).Trim() }
    try { & (Join-Path $here 'Invoke-LlmBench.ps1') @a | ForEach-Object { Say ('  ' + $_) } } catch { Say ('  failed: ' + $_.Exception.Message) }
}
Run 'folder' $model ''
if ($drive.Free -lt $size + 1GB) { Say 'SKIP: not enough room on the local disk for the copy'; Done; return }
New-Item -ItemType Directory -Path $local -Force | Out-Null
$copy = Join-Path $local 'qwen35-q4.gguf'
$sw = [Diagnostics.Stopwatch]::StartNew()
Copy-Item -LiteralPath $model -Destination $copy -Force
Say ''
Say ("copied to {0}: {1:N0} s" -f $local, $sw.Elapsed.TotalSeconds)
try {
    Run 'local' $copy ''
    Run 'local-norepack' $copy '--no-repack'
} finally {
    Remove-Item -LiteralPath $local -Recurse -Force -ErrorAction SilentlyContinue
    Say ''
    Say ('deleted ' + $local + ': ' + (-not (Test-Path $local)))
}
Say 'notes: loadMs = time to load the model; peakMb = most memory used, counting model file pages; peakPrivateMb = most memory the process holds by itself; medianMs = time per question'
Done
