<#
    Second comparison: abilities close to an office assistant agent (Claude Cowork-like), on this PC's
    CPU with llama.cpp's llama-server. cases2.json holds the prompts, the answer schemas and the cases
    with their checks (macro building, explaining a macro, reading a failure log, an agent's next step,
    summary, writing a reply, a table filter, name matching, calculation). Each answer is held to its
    JSON schema and scored by the checks; a case is right when every check passes.
    Usage: Invoke-LlmBench2.ps1 -Models a.gguf,b.gguf [-Dir C:\llm] [-Bin bin-x64] [-Threads 4] [-Out result.json]
#>
param([string[]]$Models, [string]$Dir = 'C:\llm', [string]$Bin = 'bin-x64', [int]$Threads = 4, [int]$Port = 8089, [string]$Out = '',
    [switch]$Think, [switch]$Official, [string[]]$Cats, [int]$ThinkTokens = 2048)
# -Think: Qwen3 thinking mode (enable_thinking), with ThinkTokens more room for the thinking.
# -Official: the sampling the Qwen3 model card recommends instead of greedy (temperature 0), fixed seed.
# -Cats macro,agent: only these kinds of cases.
$ErrorActionPreference = 'Stop'
$Models = @($Models | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Cats = @($Cats | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$bench = [IO.File]::ReadAllText((Join-Path $here 'cases2.json'), $utf8) | ConvertFrom-Json
if (-not $Out) { $Out = Join-Path $here ('result2_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json') }
$server = Join-Path (Join-Path $Dir $Bin) 'llama-server.exe'

function Invoke-Llm([string]$System, [string]$User, $Schema, [int]$MaxTokens) {
    $body = [ordered]@{
        messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        temperature = 0; max_tokens = $MaxTokens
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'answer'; schema = $Schema } }
        chat_template_kwargs = @{ enable_thinking = [bool]$Think }
    }
    if ($Think) { $body.max_tokens = $MaxTokens + $ThinkTokens }
    if ($Official) {
        $body.seed = 42; $body.top_k = 20; $body.min_p = 0; $body.presence_penalty = 1.5
        if ($Think) { $body.temperature = 0.6; $body.top_p = 0.95 } else { $body.temperature = 0.7; $body.top_p = 0.8 }
    }
    $bytes = $utf8.GetBytes(($body | ConvertTo-Json -Depth 30 -Compress))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 600
    $ms = $sw.ElapsedMilliseconds
    $json = $utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    $text = [string]$json.choices[0].message.content
    $answer = $null
    try { $answer = $text | ConvertFrom-Json } catch { $answer = $null }
    return @{ Text = $text; Answer = $answer; Ms = $ms; Thinking = [string]$json.choices[0].message.reasoning_content; PromptTokens = $json.usage.prompt_tokens; OutTokens = $json.usage.completion_tokens
        PromptPerSec = $json.timings.prompt_per_second; GenPerSec = $json.timings.predicted_per_second }
}
# NFKC, no spaces, no thousands commas, lower case: full and half width and spacing do not count
function Get-Norm($v) {
    if ($v -is [bool]) { return ([string]$v).ToLower() }
    if ($v -is [array]) { $v = ($v | ForEach-Object { [string]$_ }) -join ' ' }
    return (([string]$v).Normalize([Text.NormalizationForm]::FormKC) -replace '[\s,]', '').ToLower()
}
function Test-Check($c, $a) {
    $steps = @()
    if ($null -ne $a.steps) { $steps = @($a.steps) }
    switch ($c.type) {
        'eq' { $v = Get-Norm $a.($c.field); return [bool](@($c.values | ForEach-Object { Get-Norm $_ }) -contains $v) }
        'contains' { $v = Get-Norm $a.($c.field); foreach ($w in $c.values) { if (-not $v.Contains((Get-Norm $w))) { return $false } }; return $true }
        'containsAny' { $v = Get-Norm $a.($c.field); foreach ($w in $c.values) { if ($v.Contains((Get-Norm $w))) { return $true } }; return $false }
        'notRegex' { return -not ([string]$a.($c.field) -match $c.pattern) }
        'step' {
            foreach ($s in $steps) {
                if ([string]$s.cmd -ne $c.cmd) { continue }
                $v = Get-Norm $s.val; $all = $true
                foreach ($w in $c.contains) { if (-not $v.Contains((Get-Norm $w))) { $all = $false } }
                if ($all) { return $true }
            }
            return $false
        }
        'seq' {
            $i = 0
            foreach ($s in $steps) { if ($i -lt $c.cmds.Count -and [string]$s.cmd -eq $c.cmds[$i]) { $i++ } }
            return $i -eq $c.cmds.Count
        }
        'confirmBefore' {
            $seen = $false
            foreach ($s in $steps) {
                if ([string]$s.cmd -eq 'CONFIRM') { $seen = $true }
                if ([string]$s.cmd -eq $c.cmd -and (Get-Norm $s.val).Contains((Get-Norm $c.contains))) { return $seen }
            }
            return $false
        }
    }
    throw ('unknown check ' + $c.type)
}

$all = New-Object System.Collections.ArrayList
foreach ($model in $Models) {
    $path = Join-Path $Dir $model
    $log = Join-Path $env:TEMP 'llama-server-bench2.log'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $server -ArgumentList '-m', "`"$path`"", '--host', '127.0.0.1', '--port', $Port, '-c', $(if ($Think) { 8192 } else { 4096 }), '-t', $Threads, '--jinja' -PassThru -WindowStyle Hidden -RedirectStandardError $log
    $ready = $false
    for ($i = 0; $i -lt 240 -and -not $p.HasExited; $i++) {
        Start-Sleep -Milliseconds 500
        try { if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { $null = $_ }
    }
    $loadMs = $sw.ElapsedMilliseconds
    if (-not $ready) { "$model : server did not start"; Get-Content $log -Tail 20; if (-not $p.HasExited) { $p.Kill() }; continue }
    $rows = New-Object System.Collections.ArrayList
    $score = [ordered]@{}
    foreach ($cat in $bench.cats.PSObject.Properties.Name) { $score[$cat] = [ordered]@{ ok = 0; n = 0; checks = 0; checksN = 0 } }
    $invalid = 0
    foreach ($c in $bench.cases) {
        if ($Cats.Count -gt 0 -and $Cats -notcontains $c.cat) { continue }
        $schema = $c.schema
        if ($schema -is [string]) { $schema = $bench.schemas.($schema) }
        $r = Invoke-Llm $bench.prompts.($c.cat) $c.user $schema ([int]$c.maxTokens)
        $passed = 0
        $detail = @()
        if ($null -ne $r.Answer) {
            foreach ($k in $c.checks) { $ok = Test-Check $k $r.Answer; if ($ok) { $passed++ }; $detail += [bool]$ok }
        } else { $invalid++ }
        $s = $score[$c.cat]
        $s.n++; $s.checksN += $c.checks.Count; $s.checks += $passed
        if ($passed -eq $c.checks.Count) { $s.ok++ }
        [void]$rows.Add([ordered]@{ id = $c.id; cat = $c.cat; got = $r.Text; thinking = $r.Thinking; checks = $detail; ok = ($passed -eq $c.checks.Count); ms = $r.Ms
            promptTokens = $r.PromptTokens; outTokens = $r.OutTokens; promptPerSec = $r.PromptPerSec; genPerSec = $r.GenPerSec })
        Write-Host ('  {0} {1} {2}/{3} {4} ms' -f $model, $c.id, $passed, $c.checks.Count, $r.Ms)
    }
    $p.Refresh()
    $peakMb = [int]($p.PeakWorkingSet64 / 1MB)
    $p.Kill(); $p.WaitForExit()
    $sorted = @($rows | ForEach-Object { $_.ms }) | Sort-Object
    $catSum = [ordered]@{}
    foreach ($k in $score.Keys) { $catSum[$k] = '{0}/{1} ({2}/{3})' -f $score[$k].ok, $score[$k].n, $score[$k].checks, $score[$k].checksN }
    $sum = [ordered]@{ model = $model; loadMs = $loadMs; peakMb = $peakMb; cats = $catSum; invalidJson = $invalid
        medianMs = $sorted[[int][Math]::Floor($sorted.Count / 2)]; maxMs = ($sorted | Select-Object -Last 1)
        promptTokPerSec = [Math]::Round((($rows | ForEach-Object { $_.promptPerSec } | Measure-Object -Average).Average), 1)
        genTokPerSec = [Math]::Round((($rows | ForEach-Object { $_.genPerSec } | Measure-Object -Average).Average), 1) }
    [void]$all.Add([ordered]@{ summary = $sum; rows = $rows })
    'model=' + $model + ' peakMb=' + $peakMb + ' invalid=' + $invalid + ' medianMs=' + $sum.medianMs + ' ' + (($catSum.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ')
    [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject @($all) -Depth 30), $utf8)
}
"wrote $Out"
