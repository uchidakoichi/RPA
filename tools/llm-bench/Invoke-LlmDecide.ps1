<#
    Decision reading: instead of letting the model write a JSON answer, the answer is one option letter
    and the probability of every letter is read from that single token (max_tokens 1, logprobs). Only
    the prompt is computed, nothing is written, so it is quicker, and the probability says how sure the
    model is (below a threshold, a person can be asked). Cases: classify and judge from cases.json and
    match from cases2.json; the prompts and option letters are in decide.json.
    Usage: Invoke-LlmDecide.ps1 -Model qwen3.5-2b-q4_k_m.gguf [-Dir C:\llm] [-Bin bin-x64] [-Threads 4] [-Out result.json]
#>
param([string]$Model, [string]$Dir = 'C:\llm', [string]$Bin = 'bin-x64', [int]$Threads = 4, [int]$Port = 8091, [string]$Out = '',
    [int]$Ctx = 4096, [string]$ServerArgs = '--cache-ram 0 -ctxcp 4 -np 1 --no-repack')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$dec = [IO.File]::ReadAllText((Join-Path $here 'decide.json'), $utf8) | ConvertFrom-Json
$c1 = [IO.File]::ReadAllText((Join-Path $here 'cases.json'), $utf8) | ConvertFrom-Json
$c2 = [IO.File]::ReadAllText((Join-Path $here 'cases2.json'), $utf8) | ConvertFrom-Json
if (-not $Out) { $Out = Join-Path $here ('result_decide_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json') }

# one list of cases: task, user text, the right option values
$cases = New-Object System.Collections.ArrayList
foreach ($c in $c1.classify) { [void]$cases.Add(@{ Task = 'classify'; User = $c.text; Expect = @($c.expect) }) }
foreach ($c in $c1.judge) { [void]$cases.Add(@{ Task = 'judge'; User = ($c1.prompts.judgeUser -f $c.step, $c.title, $c.text, $c.buttons); Expect = @($c.expect) }) }
foreach ($c in $c2.cases | Where-Object { $_.cat -eq 'match' }) { [void]$cases.Add(@{ Task = 'match'; User = $c.user; Expect = @($c.checks[0].values) }) }

function Invoke-Decide($task, [string]$user) {
    $t = $dec.tasks.$task
    $body = [ordered]@{ messages = @(@{ role = 'system'; content = $t.system }, @{ role = 'user'; content = $user })
        temperature = 0; max_tokens = 1; logprobs = $true; top_logprobs = 20
        chat_template_kwargs = @{ enable_thinking = $false } }
    $bytes = $utf8.GetBytes(($body | ConvertTo-Json -Depth 20 -Compress))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300
    $ms = $sw.ElapsedMilliseconds
    $json = $utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    # add up the probability of each option letter among the top tokens, then share it out among the options
    $mass = [ordered]@{}
    foreach ($k in $t.options.PSObject.Properties.Name) { $mass[$k] = 0.0 }
    foreach ($lp in $json.choices[0].logprobs.content[0].top_logprobs) {
        $tok = ([string]$lp.token).Trim()
        if ($mass.Contains($tok)) { $mass[$tok] += [Math]::Exp([double]$lp.logprob) }
    }
    $sum = 0.0; foreach ($v in $mass.Values) { $sum += $v }
    $best = $null; $bestP = 0.0; $probs = [ordered]@{}
    foreach ($k in @($mass.Keys)) {
        $p = $(if ($sum -gt 0) { $mass[$k] / $sum } else { 0 })
        $probs[$t.options.$k] = [Math]::Round($p, 4)
        if ($p -gt $bestP) { $bestP = $p; $best = $k }
    }
    return @{ Choice = $(if ($best) { [string]$t.options.$best } else { '' }); P = $bestP; Covered = $sum; Probs = $probs; Ms = $ms
        Token = [string]$json.choices[0].message.content; PromptTokens = $json.timings.prompt_n; Cached = $json.timings.cache_n; PromptMs = $json.timings.prompt_ms }
}

$server = Join-Path (Join-Path $Dir $Bin) 'llama-server.exe'
$path = $Model
if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Dir $Model }
$log = Join-Path $env:TEMP 'llama-server-decide.log'
$p = Start-Process -FilePath $server -ArgumentList (@('-m', "`"$path`"", '--host', '127.0.0.1', '--port', $Port, '-c', $Ctx, '-t', $Threads, '--jinja') + @($ServerArgs -split ' ' | Where-Object { $_ })) -PassThru -WindowStyle Hidden -RedirectStandardError $log
$ready = $false
for ($i = 0; $i -lt 480 -and -not $p.HasExited; $i++) {
    Start-Sleep -Milliseconds 500
    try { if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { $null = $_ }
}
if (-not $ready) { 'server did not start'; Get-Content $log -Tail 20; if (-not $p.HasExited) { $p.Kill() }; return }

$rows = New-Object System.Collections.ArrayList
try {
    foreach ($c in $cases) {
        $r = Invoke-Decide $c.Task $c.User
        $ok = (@($c.Expect | ForEach-Object { ([string]$_).ToLower() }) -contains $r.Choice.ToLower())
        [void]$rows.Add([ordered]@{ task = $c.Task; input = $c.User; expect = $c.Expect; choice = $r.Choice; p = [Math]::Round($r.P, 4); ok = $ok; covered = [Math]::Round($r.Covered, 4)
            probs = $r.Probs; token = $r.Token; ms = $r.Ms; promptTokens = $r.PromptTokens; cached = $r.Cached; promptMs = $r.PromptMs })
        Write-Host ('  {0} {1} p={2:N2} {3} {4} ms (prompt {5}, cached {6})' -f $c.Task, $r.Choice, $r.P, $(if ($ok) { 'OK' } else { 'NG' }), $r.Ms, $r.PromptTokens, $r.Cached)
    }
} finally {
    $p.Refresh()
    $peakMb = [int]($p.PeakWorkingSet64 / 1MB)
    if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
}
$lines = @()
foreach ($task in @('classify', 'judge', 'match')) {
    $rs = @($rows | Where-Object { $_.task -eq $task })
    $ms = @($rs | ForEach-Object { $_.ms } | Sort-Object)
    $line = '{0}: {1}/{2} right, median {3} ms' -f $task, @($rs | Where-Object { $_.ok }).Count, $rs.Count, $ms[[int][Math]::Floor($ms.Count / 2)]
    foreach ($th in @(0.7, 0.9)) {
        $sure = @($rs | Where-Object { $_.p -ge $th })
        $line += ('; p>={0}: {1} answered, {2} right' -f $th, $sure.Count, @($sure | Where-Object { $_.ok }).Count)
    }
    $lines += $line
}
$all = @($rows)
$lines += ('all: {0}/{1} right; peakMb={2}' -f @($all | Where-Object { $_.ok }).Count, $all.Count, $peakMb)
$lines
[IO.File]::WriteAllLines([IO.Path]::ChangeExtension($Out, '.txt'), [string[]]$lines)
[IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject @{ model = $Model; summary = $lines; rows = $all } -Depth 20), $utf8)
"wrote $Out"
