#Requires -Version 5.1
<#
    VM check: the two AI templates run from start to end with the real llama-server (the runner with
    a recording Io for the screen, and the real AI parts). Uses the shared folder made by
    tools/ai-setup (default C:\llm\ai-share-test) and copies it to a temporary folder.
#>
param([string]$Shared = 'C:\llm\ai-share-test')
$ErrorActionPreference = 'Stop'
$psRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
. (Join-Path $psRoot 'gui\AiServer.ps1')
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
Import-FujiCommand -Path (Join-Path $psRoot 'fujikyun_commands.json')
$templates = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path (Join-Path $psRoot 'fujikyun_templates.json'))
$work = Join-Path $env:TEMP ('fuji-ai-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$local = Join-Path $work 'ai'
[void](New-Item -ItemType Directory -Path $work)
$logs = New-Object System.Collections.Generic.List[string]
$reviews = New-Object System.Collections.Generic.List[object]
try {
    $dir = Resolve-FujiAiReady -SharedDir $Shared -LocalDir $local -Copy { Copy-FujiAiLocal -SharedDir $Shared -LocalDir $local } -Log { param($m) $logs.Add($m) }
    $srv = Start-FujiAiServer -LocalDir $dir -LogDir (Join-Path $work 'fujikyun_logs')
    $script:screenText = 'The record you searched for was not found. [OK]'
    $io = @{}
    # the screen side does nothing here (as the tests' fake Io); only the AI is real
    foreach ($k in @('Wait', 'FocusSelf', 'SendKeys', 'Progress', 'Highlight', 'Watch', 'Alarm', 'Notify', 'EndRun')) { $io[$k] = { } }
    foreach ($k in @('Activate', 'WindowExists', 'SetClipboard', 'ClipboardReady')) { $io[$k] = { $true } }
    foreach ($k in @('SelfHasFocus', 'InputBlocked')) { $io[$k] = { $false } }
    $io.GetClipboard = { '' }
    $io.ClipboardSeq = { 0 }
    $io.Log = { param($Message, $Level) $logs.Add(([string]$Level + ' ' + $Message)) }
    $io.Now = { Get-Date }
    $io.Ocr = { param($Settings, $Find, $Nth) $script:screenText }
    $io.Confirm = { param($Caption, $Message) $logs.Add('CONFIRM ' + $Message); 'continue' }
    $io.AiChat = { param($Body) Invoke-FujiAiChat -Server $srv -Body $Body }
    $io.AiTookFocus = { $false }
    $io.AiPick = { param($Caption, $Message, $Options, $Initial) $logs.Add('PICK ' + $Initial); @{ Choice = 'continue'; Value = $Initial } }
    $io.AiReview = { param($Row) $reviews.Add($Row); [void](Add-FujiAiReviewRow -Directory $work -Now (Get-Date) -Row $Row) }
    foreach ($id in @('ai-sort-inquiry', 'ai-unexpected-window')) {
        $t = @($templates['templates'] | Where-Object { $_['id'] -eq $id })[0]
        $steps = New-Object System.Collections.Generic.List[object]
        foreach ($s in $t['steps']) { $steps.Add([ordered]@{ cmd = $s[0]; val = [string]$s[1]; label = '' }) }
        $macro = [ordered]@{ id = $id; name = $t['name']; targetWindow = ''; steps = $steps }
        # the template's CSV is a generic List (no @() around it: that fails on PowerShell 5.1)
        $csv = $t['csv']
        $header = [string[]]($csv[0].ToArray())
        $data = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -lt $csv.Count; $i++) { $data.Add([string[]]($csv[$i].ToArray())) }
        $rows = (Get-FujiRunRow -CsvRows $data.ToArray() -Header $header).Rows
        $run = New-FujiRun -Macro $macro -Macros @($macro) -Rows $rows -Header $header -Io $io -Interval 0 -Directory $work
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $status = Invoke-FujiRun -Run $run
        ('{0}: {1} in {2:N0} s' -f $id, $status, $sw.Elapsed.TotalSeconds)
        foreach ($r in $run.ResultRows) { '  row ' + (($r.Values.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ', ') }
    }
    '--- log (AI lines)'
    $logs | Where-Object { $_ -match 'AI|PICK|CONFIRM' } | ForEach-Object { '  ' + $_ }
    ('reviews: {0}' -f $reviews.Count)
    Stop-FujiAiServer -Server $srv
} finally {
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ($work + '*') } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
