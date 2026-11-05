<#
    Throwaway probe: can a small LLM do office tasks step by step with tools (close to what Claude
    Cowork does)? For each task in tasks.json, a fresh work folder is filled with the task's files and
    the model is asked for one tool call at a time (JSON held to a schema) until it finishes, asks a
    person, or runs out of steps. The tools only act inside the work folder; there is no delete tool.
    The screen is a stand-in (fields and buttons kept in this script), not a real window.
    Usage: Invoke-Agent.ps1 -Model qwen3.5-2b-q4_k_m.gguf [-Dir C:\llm] [-Bin bin-x64] [-Threads 4] [-MaxSteps 15] [-Ids a,b] [-Out result.json]
#>
param([string]$Model, [string]$Dir = 'C:\llm', [string]$Bin = 'bin-x64', [int]$Threads = 4, [int]$Port = 8090, [int]$MaxSteps = 15,
    [string[]]$Ids, [string]$Out = '', [int]$Ctx = 8192, [string]$ServerArgs = '--cache-ram 0 -np 1', [switch]$Think, [switch]$Assist, [switch]$Official)
# -Assist: show the work folder's files at the start, and say so when the model repeats the same action.
# -Official: the sampling the Qwen3.5 model card recommends instead of greedy (temperature 0), fixed seed.
$ErrorActionPreference = 'Stop'
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$bench = [IO.File]::ReadAllText((Join-Path $here 'tasks.json'), $utf8) | ConvertFrom-Json
if (-not $Out) { $Out = Join-Path $here ('result_agent_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.json') }
$workRoot = Join-Path $env:TEMP 'agent-probe'

function Get-Norm($v) { return (([string]$v).Normalize([Text.NormalizationForm]::FormKC) -replace '\s', '').ToLower() }

function Invoke-Llm($Messages) {
    $body = [ordered]@{ messages = $Messages; temperature = 0; max_tokens = 1200
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'action'; schema = $bench.schema } }
        chat_template_kwargs = @{ enable_thinking = [bool]$Think } }
    if ($Think) { $body.max_tokens = 4000 }
    if ($Official) {
        $body.seed = 42; $body.top_k = 20; $body.min_p = 0
        if ($Think) { $body.temperature = 1.0; $body.top_p = 0.95; $body.presence_penalty = 1.5 } else { $body.temperature = 1.0; $body.top_p = 1.0; $body.presence_penalty = 2.0 }
    }
    $bytes = $utf8.GetBytes(($body | ConvertTo-Json -Depth 30 -Compress))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 900
    $json = $utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    return @{ Text = [string]$json.choices[0].message.content; Ms = $sw.ElapsedMilliseconds; PromptTokens = $json.usage.prompt_tokens; OutTokens = $json.usage.completion_tokens }
}

# a path the model gave -> full path inside the work folder, or $null when it points outside
function Resolve-In([string]$root, [string]$p) {
    $p = ([string]$p).Trim().Trim('"').Replace('/', '\')
    if ($p -eq '' -or $p -eq '.') { return $root }
    if ([IO.Path]::IsPathRooted($p)) { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path $root $p))
    if ($full -ne $root -and -not $full.StartsWith($root + '\')) { return $null }
    return $full
}

function Invoke-Tool($state, $a) {
    $root = $state.Root
    $tool = [string]$a.tool
    if ($tool -in @('list', 'read', 'write', 'mkdir', 'move')) {
        $p = Resolve-In $root $a.path
        if (-not $p) { return 'error: the path is outside the work folder' }
    }
    switch ($tool) {
        'list' {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { return 'error: no such folder' }
            $items = @(Get-ChildItem -LiteralPath $p | ForEach-Object { if ($_.PSIsContainer) { $_.Name + '/' } else { $_.Name } })
            if ($items.Count -eq 0) { return '(empty)' }
            return ($items -join "`n")
        }
        'read' {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 'error: no such file' }
            $t = [IO.File]::ReadAllText($p, $utf8)
            if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) + "`n(cut)" }
            return $t
        }
        'write' {
            $parent = Split-Path -Parent $p
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($p, [string]$a.text, $utf8)
            return ('wrote ' + ([string]$a.text).Length + ' characters')
        }
        'mkdir' { New-Item -ItemType Directory -Path $p -Force | Out-Null; return 'ok' }
        'move' {
            $to = Resolve-In $root $a.to
            if (-not $to) { return 'error: the destination is outside the work folder' }
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 'error: no such file' }
            if (Test-Path -LiteralPath $to -PathType Container) { $to = Join-Path $to (Split-Path -Leaf $p) }
            if (Test-Path -LiteralPath $to) { return 'error: the destination already exists' }
            if (-not (Test-Path -LiteralPath (Split-Path -Parent $to))) { return 'error: the destination folder does not exist' }
            Move-Item -LiteralPath $p -Destination $to
            return 'ok'
        }
        'screen' {
            if (-not $state.Screen) { return 'error: no screen is open' }
            $lines = @('window: ' + $state.Screen.title)
            foreach ($f in $state.Screen.fields) { $lines += ('field ' + $f + ' = [' + $state.Fields[$f] + ']') }
            $lines += ('buttons: ' + (@($state.Screen.buttons) -join ', '))
            return ($lines -join "`n")
        }
        'set_field' {
            if (-not $state.Screen) { return 'error: no screen is open' }
            if (@($state.Screen.fields) -notcontains [string]$a.path) { return 'error: no such field' }
            $state.Fields[[string]$a.path] = [string]$a.text
            return 'ok'
        }
        'press' {
            if (-not $state.Screen) { return 'error: no screen is open' }
            if (@($state.Screen.buttons) -notcontains [string]$a.path) { return 'error: no such button' }
            $state.Pressed.Add([string]$a.path)
            return ('pressed; the screen is closed')
        }
        'ask' { $state.Asked = [string]$a.text; return 'stopped: waiting for a person' }
        'finish' { $state.Finished = [string]$a.text; return 'finished' }
    }
    return 'error: unknown tool'
}

function Test-Check($state, $c) {
    switch ($c.type) {
        'exists' { return (Test-Path -LiteralPath (Resolve-In $state.Root $c.path)) }
        'contains' {
            $p = Resolve-In $state.Root $c.path
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
            $t = Get-Norm ([IO.File]::ReadAllText($p, $utf8))
            foreach ($w in $c.values) { if (-not $t.Contains((Get-Norm $w))) { return $false } }
            return $true
        }
        'notContains' {
            $p = Resolve-In $state.Root $c.path
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
            $t = Get-Norm ([IO.File]::ReadAllText($p, $utf8))
            foreach ($w in $c.values) { if ($t.Contains((Get-Norm $w))) { return $false } }
            return $true
        }
        'field' { return ((Get-Norm $state.Fields[$c.field]) -eq (Get-Norm $c.value)) }
        'pressed' { return ($state.Pressed -contains $c.button) }
        'notPressed' { return ($state.Pressed -notcontains $c.button) }
        'asked' { return [bool]$state.Asked }
    }
    throw ('unknown check ' + $c.type)
}

$server = Join-Path (Join-Path $Dir $Bin) 'llama-server.exe'
$path = $Model
if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Dir $Model }
$log = Join-Path $env:TEMP 'llama-server-agent.log'
$argList = @('-m', "`"$path`"", '--host', '127.0.0.1', '--port', $Port, '-c', $Ctx, '-t', $Threads, '--jinja') + @($ServerArgs -split ' ' | Where-Object { $_ })
$p = Start-Process -FilePath $server -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardError $log
$ready = $false
for ($i = 0; $i -lt 480 -and -not $p.HasExited; $i++) {
    Start-Sleep -Milliseconds 500
    try { if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { $null = $_ }
}
if (-not $ready) { 'server did not start'; Get-Content $log -Tail 20; if (-not $p.HasExited) { $p.Kill() }; return }

$rows = New-Object System.Collections.ArrayList
$cats = [ordered]@{}
try {
    foreach ($task in $bench.tasks) {
        if ($Ids.Count -gt 0 -and $Ids -notcontains $task.id) { continue }
        $root = Join-Path $workRoot $task.id
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root = (Resolve-Path -LiteralPath $root).Path
        foreach ($f in $task.files.PSObject.Properties) {
            $fp = Join-Path $root ($f.Name.Replace('/', '\'))
            New-Item -ItemType Directory -Path (Split-Path -Parent $fp) -Force | Out-Null
            [IO.File]::WriteAllText($fp, [string]$f.Value, $utf8)
        }
        $state = @{ Root = $root; Screen = $task.screen; Fields = @{}; Pressed = New-Object System.Collections.Generic.List[string]; Asked = $null; Finished = $null }
        if ($task.screen) { foreach ($f in $task.screen.fields) { $state.Fields[$f] = '' } }
        $messages = New-Object System.Collections.ArrayList
        [void]$messages.Add(@{ role = 'system'; content = $bench.system })
        $first = $task.task
        if ($Assist) {
            $tree = @(Get-ChildItem -LiteralPath $root -Recurse | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') + $(if ($_.PSIsContainer) { '/' } else { '' }) })
            $first += "`n`n(files in the work folder)`n" + ($tree -join "`n")
            if ($task.screen) { $first += "`n(a screen is open: " + $task.screen.title + ')' }
        }
        $last = ''
        [void]$messages.Add(@{ role = 'user'; content = $first })
        $steps = New-Object System.Collections.ArrayList
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $invalid = 0
        $stop = 'maxSteps'
        for ($s = 1; $s -le $MaxSteps; $s++) {
            $r = Invoke-Llm @($messages)
            $a = $null
            try { $a = $r.Text | ConvertFrom-Json } catch { $a = $null }
            if (-not $a) { $invalid++; $result = 'error: the answer was not valid JSON' }
            else { try { $result = Invoke-Tool $state $a } catch { $result = 'error: ' + $_.Exception.Message } }
            $key = $(if ($a) { [string]$a.tool + '|' + [string]$a.path + '|' + [string]$a.to + '|' + [string]$a.text } else { '' })
            if ($Assist -and $a -and $key -eq $last) { $result += "`n(note: this is the same action as the one before; do something else next)" }
            $last = $key
            [void]$steps.Add([ordered]@{ n = $s; action = $r.Text; result = $result; ms = $r.Ms; promptTokens = $r.PromptTokens; outTokens = $r.OutTokens })
            Write-Host ('  {0} {1} {2} {3} ms' -f $task.id, $s, $(if ($a) { $a.tool + ' ' + $a.path } else { 'invalid' }), $r.Ms)
            [void]$messages.Add(@{ role = 'assistant'; content = $r.Text })
            if ($state.Asked) { $stop = 'ask'; break }
            if ($state.Finished) { $stop = 'finish'; break }
            [void]$messages.Add(@{ role = 'user'; content = ('result: ' + $result) })
        }
        $detail = @($task.checks | ForEach-Object { [bool](Test-Check $state $_) })
        $ok = (@($detail | Where-Object { -not $_ }).Count -eq 0)
        if (-not $cats.Contains($task.cat)) { $cats[$task.cat] = @{ ok = 0; n = 0 } }
        $cats[$task.cat].n++; if ($ok) { $cats[$task.cat].ok++ }
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) })
        [void]$rows.Add([ordered]@{ id = $task.id; cat = $task.cat; ok = $ok; checks = $detail; stop = $stop; steps = $steps.Count; ms = $sw.ElapsedMilliseconds
            invalid = $invalid; asked = $state.Asked; finished = $state.Finished; fields = $state.Fields; pressed = @($state.Pressed); files = $files; log = $steps })
        ('{0}: {1} ({2}/{3} checks) stop={4} steps={5} {6:N0} s' -f $task.id, $(if ($ok) { 'OK' } else { 'NG' }), @($detail | Where-Object { $_ }).Count, $detail.Count, $stop, $steps.Count, ($sw.ElapsedMilliseconds / 1000))
        [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject @{ model = $Model; think = [bool]$Think; assist = [bool]$Assist; official = [bool]$Official; rows = @($rows) } -Depth 30), $utf8)
    }
} finally {
    $p.Refresh()
    $peakMb = [int]($p.PeakWorkingSet64 / 1MB)
    if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
}
$okAll = @($rows | Where-Object { $_.ok }).Count
'model=' + $Model + ' think=' + [bool]$Think + ' assist=' + [bool]$Assist + ' official=' + [bool]$Official + ' ok=' + $okAll + '/' + $rows.Count + ' peakMb=' + $peakMb + ' ' + (($cats.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value.ok + '/' + $_.Value.n }) -join ' ')
"wrote $Out"
