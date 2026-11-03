<#
    Compares small LLMs on this PC's CPU with llama.cpp's llama-server: for each model, starts the
    server, asks every case in cases.json (A extract, B classify, C judge an unexpected window) with
    the answer held to a JSON schema, scores the answers and times them, then stops the server.
    The questions go through Invoke-WebRequest the way fujikyun (PowerShell 5.1) would ask.
    Usage: Invoke-LlmBench.ps1 -Models a.gguf,b.gguf [-Dir C:\llm] [-Threads 4] [-Out result.json]
#>
param([switch]$V2, [string[]]$Models, [string]$Dir = 'C:\llm', [string]$Bin = 'bin-arm64', [int]$Threads = 4, [int]$Port = 8089, [string]$Out = '')
$ErrorActionPreference = 'Stop'
# powershell -File passes -Models a,b as one string
$Models = @($Models | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$cases = [IO.File]::ReadAllText((Join-Path $here 'cases.json'), $utf8) | ConvertFrom-Json
if (-not $Out) { $Out = Join-Path $here ('result_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json') }
$server = Join-Path (Join-Path $Dir $Bin) 'llama-server.exe'

function Invoke-Llm([string]$System, [string]$User, [hashtable]$Schema) {
    $body = [ordered]@{
        messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        temperature = 0; max_tokens = 256
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'answer'; schema = $Schema } }
        chat_template_kwargs = @{ enable_thinking = $false }
    }
    $bytes = $utf8.GetBytes(($body | ConvertTo-Json -Depth 20 -Compress))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300
    $ms = $sw.ElapsedMilliseconds
    $json = $utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    $text = [string]$json.choices[0].message.content
    $answer = $null
    try { $answer = $text | ConvertFrom-Json } catch { $answer = $null }
    return @{ Text = $text; Answer = $answer; Ms = $ms; PromptTokens = $json.usage.prompt_tokens; OutTokens = $json.usage.completion_tokens
        PromptPerSec = $json.timings.prompt_per_second; GenPerSec = $json.timings.predicted_per_second }
}
function Get-Norm([string]$s) { return ([string]$s -replace '[\s\u3000\-]', '') }
# A date as written (wareki or western) -> yyyy-MM-dd, '' when none. -V2 lets the model copy the date
# and this converts it, the way fujikyun would. Era first years: Meiji 1868, Taisho 1912, Showa 1926,
# Heisei 1989, Reiwa 2019 (the era names come from cases.json, so this file stays ASCII).
function ConvertTo-Ymd([string]$s) {
    $t = ([string]$s).Normalize([Text.NormalizationForm]::FormKC) -replace '\s', ''
    if (-not $t) { return '' }
    $eras = $cases.eras
    foreach ($e in $eras.PSObject.Properties) {
        $m = [regex]::Match($t, [regex]::Escape($e.Name) + '([0-9]+|' + [regex]::Escape($cases.gannen) + ')' + '\D+([0-9]+)\D+([0-9]+)')
        if ($m.Success) {
            $n = 1; if ($m.Groups[1].Value -ne $cases.gannen) { $n = [int]$m.Groups[1].Value }
            return ('{0:0000}-{1:00}-{2:00}' -f ([int]$e.Value + $n - 1), [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
        }
    }
    $m = [regex]::Match($t, '([0-9]{4})\D+([0-9]{1,2})\D+([0-9]{1,2})')
    if ($m.Success) { return ('{0:0000}-{1:00}-{2:00}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value) }
    return $t
}

$kindEnum = @($cases.kinds)
$schemaExtract = @{ type = 'object'; required = @('name', 'birth', 'phone', 'kind'); additionalProperties = $false
    properties = @{ name = @{ type = 'string'; maxLength = 20 }; birth = @{ type = 'string'; maxLength = 10 }; phone = @{ type = 'string'; maxLength = 15 }; kind = @{ type = 'string'; enum = $kindEnum } } }
$schemaClassify = @{ type = 'object'; required = @('kind'); additionalProperties = $false; properties = @{ kind = @{ type = 'string'; enum = $kindEnum } } }
$schemaJudge = @{ type = 'object'; required = @('reason', 'action'); additionalProperties = $false
    properties = [ordered]@{ reason = @{ type = 'string'; maxLength = 60 }; action = @{ type = 'string'; enum = @($cases.actions) } } }
$schemaExtract.properties = [ordered]@{ name = $schemaExtract.properties.name; birth = @{ type = 'string'; maxLength = 20 }; phone = $schemaExtract.properties.phone; kind = $schemaExtract.properties.kind }
$promptExtract = $cases.prompts.extract; $promptJudge = $cases.prompts.judge
if ($V2) { $promptExtract = $cases.prompts.extract2; $promptJudge = $cases.prompts.judge2 }

$all = New-Object System.Collections.ArrayList
foreach ($model in $Models) {
    $path = Join-Path $Dir $model
    $log = Join-Path $env:TEMP 'llama-server-bench.log'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $server -ArgumentList '-m', "`"$path`"", '--host', '127.0.0.1', '--port', $Port, '-c', 4096, '-t', $Threads, '--jinja' -PassThru -WindowStyle Hidden -RedirectStandardError $log
    $ready = $false
    for ($i = 0; $i -lt 240 -and -not $p.HasExited; $i++) {
        Start-Sleep -Milliseconds 500
        try { if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { $null = $_ }
    }
    $loadMs = $sw.ElapsedMilliseconds
    if (-not $ready) { "$model : server did not start"; Get-Content $log -Tail 20; if (-not $p.HasExited) { $p.Kill() }; continue }
    $rows = New-Object System.Collections.ArrayList
    $score = @{ extract = 0; extractFields = 0; classify = 0; judge = 0; invalid = 0 }
    foreach ($c in $cases.extract) {
        $r = Invoke-Llm $promptExtract $c.text $schemaExtract
        $ok = 0
        if ($null -ne $r.Answer) {
            if ((Get-Norm $r.Answer.name) -eq (Get-Norm $c.expect.name)) { $ok++ }
            $birth = [string]$r.Answer.birth
            if ($V2) { $birth = ConvertTo-Ymd $birth }
            if ($birth -eq $c.expect.birth) { $ok++ }
            if ((Get-Norm $r.Answer.phone) -eq $c.expect.phone) { $ok++ }
            if ([string]$r.Answer.kind -eq $c.expect.kind) { $ok++ }
        } else { $score.invalid++ }
        $score.extractFields += $ok
        if ($ok -eq 4) { $score.extract++ }
        [void]$rows.Add([ordered]@{ task = 'extract'; input = $c.text; expect = $c.expect; got = $r.Text; ok = $ok; ms = $r.Ms; promptTokens = $r.PromptTokens; outTokens = $r.OutTokens; promptPerSec = $r.PromptPerSec; genPerSec = $r.GenPerSec })
    }
    foreach ($c in $cases.classify) {
        $r = Invoke-Llm $cases.prompts.classify $c.text $schemaClassify
        $ok = $null -ne $r.Answer -and [string]$r.Answer.kind -eq $c.expect
        if ($null -eq $r.Answer) { $score.invalid++ }
        if ($ok) { $score.classify++ }
        [void]$rows.Add([ordered]@{ task = 'classify'; input = $c.text; expect = $c.expect; got = $r.Text; ok = $ok; ms = $r.Ms; promptTokens = $r.PromptTokens; outTokens = $r.OutTokens; promptPerSec = $r.PromptPerSec; genPerSec = $r.GenPerSec })
    }
    foreach ($c in $cases.judge) {
        $user = $cases.prompts.judgeUser -f $c.step, $c.title, $c.text, $c.buttons
        $r = Invoke-Llm $promptJudge $user $schemaJudge
        $ok = $null -ne $r.Answer -and (@($c.expect) -contains [string]$r.Answer.action)
        if ($null -eq $r.Answer) { $score.invalid++ }
        if ($ok) { $score.judge++ }
        [void]$rows.Add([ordered]@{ task = 'judge'; input = $user; expect = $c.expect; got = $r.Text; ok = $ok; ms = $r.Ms; promptTokens = $r.PromptTokens; outTokens = $r.OutTokens; promptPerSec = $r.PromptPerSec; genPerSec = $r.GenPerSec })
    }
    $p.Refresh()
    $peakMb = [int]($p.PeakWorkingSet64 / 1MB)
    $p.Kill(); $p.WaitForExit()
    $times = @($rows | ForEach-Object { $_.ms })
    $sorted = $times | Sort-Object
    $median = $sorted[[int][Math]::Floor($sorted.Count / 2)]
    $gen = ($rows | ForEach-Object { $_.genPerSec } | Measure-Object -Average).Average
    $pp = ($rows | ForEach-Object { $_.promptPerSec } | Measure-Object -Average).Average
    $sum = [ordered]@{ model = $model; loadMs = $loadMs; peakMb = $peakMb; extract = "$($score.extract)/$($cases.extract.Count)"; extractFields = "$($score.extractFields)/$($cases.extract.Count * 4)"
        classify = "$($score.classify)/$($cases.classify.Count)"; judge = "$($score.judge)/$($cases.judge.Count)"; invalidJson = $score.invalid
        medianMs = $median; maxMs = ($sorted | Select-Object -Last 1); promptTokPerSec = [Math]::Round($pp, 1); genTokPerSec = [Math]::Round($gen, 1) }
    [void]$all.Add([ordered]@{ summary = $sum; rows = $rows })
    ($sum.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
}
[IO.File]::WriteAllText($Out, ($all | ConvertTo-Json -Depth 20), $utf8)
"wrote $Out"
