# ---------------------------------------------------------------------------------------------
#  AI commands (AI_CHOOSE, AI_EXTRACT): the parts that need no window and no llama-server
#  The question for AI_CHOOSE is built so the answer is one option letter, and the probability of
#  every letter is read from that one token (logprobs): nothing is written, only the prompt is
#  computed, and the probability says how sure the model is. AI_EXTRACT asks for a JSON answer held
#  to a schema. Answers that are unsure or not in the source text go to a review list
#  (fujikyun_logs\ai_review_<date>.csv) so a run does not have to stop for them.
#  The shared AI folder holds ai.json (version, files and sizes, SHA-256, llama-server options);
#  it is copied to %LOCALAPPDATA%\fujikyun\ai once and again when the version changes.
# ---------------------------------------------------------------------------------------------
$script:FujiAiLetters = 'ABCDEFGHIJ'
# tokens one AI_EXTRACT item may take: its name and quotes, and a value of 100 characters
$script:FujiAiExtractItemTokens = 130
$script:FujiAiSourceMax = 3000
$script:FujiAiReviewSourceMax = 100

# "value" or "value: note" per line (half or full width colon); blank lines are skipped
function Read-FujiAiLine {
    param([AllowEmptyString()][string]$Text)
    $list = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        $i = $t.IndexOfAny([char[]]@(':', [char]0xFF1A))
        if ($i -ge 0) { $list.Add(@{ Head = $t.Substring(0, $i).Trim(); Note = $t.Substring($i + 1).Trim() }) }
        else { $list.Add(@{ Head = $t; Note = '' }) }
    }
    return , $list
}

# The first value that appears twice (width, case and spaces aside), or ''
function Get-FujiAiDuplicate {
    param([AllowEmptyCollection()][string[]]$Values)
    $seen = @{}
    foreach ($v in $Values) {
        $k = (ConvertTo-FujiAiPlain -Text $v).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { return $v }
        $seen[$k] = $true
    }
    return ''
}

function Read-FujiAiOption {
    param([AllowEmptyString()][string]$Text)
    $list = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
    foreach ($x in (Read-FujiAiLine -Text $Text)) { $list.Add(@{ Value = $x.Head; Note = $x.Note }) }
    return , $list
}

function Read-FujiAiItem {
    param([AllowEmptyString()][string]$Text)
    $list = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
    foreach ($x in (Read-FujiAiLine -Text $Text)) { $list.Add(@{ Name = $x.Head; Note = $x.Note }) }
    return , $list
}

function Limit-FujiAiSource {
    param([AllowEmptyString()][string]$Source)
    $s = [string]$Source
    if ($s.Length -gt $script:FujiAiSourceMax) { return @{ Text = $s.Substring(0, $script:FujiAiSourceMax); Cut = $true } }
    return @{ Text = $s; Cut = $false }
}

# The request for AI_CHOOSE (Truncated is for the caller and is taken out before sending)
function New-FujiAiChooseBody {
    param([AllowEmptyString()][string]$Question, [Parameter(Mandatory)][System.Collections.IList]$Options, [AllowEmptyString()][string]$Source, [AllowNull()][object[]]$Examples = $null)
    $lines = for ($i = 0; $i -lt $Options.Count; $i++) {
        $line = [string]$script:FujiAiLetters[$i] + ': ' + $Options[$i].Value
        if ($Options[$i].Note) { $line += ([string][char]0xFF08 + $Options[$i].Note + [char]0xFF09) }
        $line
    }
    $q = ([string]$Question).Trim() -replace '[\u3002\uFF0E.\uFF1F?]+$', ''
    $src = Limit-FujiAiSource -Source $Source
    $system = Get-FujiText 'run.aiChoosePrompt' $q (@($lines) -join "`n")
    # answers a person checked for similar texts (only those that are still options)
    $shown = 0
    $exLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($e in @($Examples | Where-Object { $null -ne $_ })) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ([string]$Options[$i].Value -eq [string]$e['answer']) { $exLines.Add('- ' + (([string]$e['text']) -replace '\s+', ' ') + ' -> ' + $script:FujiAiLetters[$i]); $shown++; break }
        }
    }
    if ($shown -gt 0) { $system += "`n" + (Get-FujiText 'run.aiExamplesHead') + "`n" + ($exLines -join "`n") }
    return [ordered]@{
        messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $src.Text })
        temperature = 0; max_tokens = 1; logprobs = $true; top_logprobs = 20
        chat_template_kwargs = @{ enable_thinking = $false }
        Truncated = $src.Cut; ExamplesUsed = $shown
    }
}

# The probability of each option letter among the top tokens of the one answer token, shared out
# among the options. Returns @{ Value; P; Covered; Probs } (Value '' when no letter was answered).
function Read-FujiAiChoice {
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][System.Collections.IList]$Options)
    $mass = New-Object -TypeName 'double[]' -ArgumentList $Options.Count
    $top = @()
    try { $top = @($Response.choices[0].logprobs.content[0].top_logprobs) } catch { $top = @() }
    foreach ($lp in $top) {
        $tok = ([string]$lp.token).Trim().ToUpperInvariant()
        if ($tok.Length -ne 1) { continue }
        $i = $script:FujiAiLetters.IndexOf($tok, [System.StringComparison]::Ordinal)
        if ($i -ge 0 -and $i -lt $Options.Count) { $mass[$i] += [Math]::Exp([double]$lp.logprob) }
    }
    $sum = 0.0
    foreach ($v in $mass) { $sum += $v }
    $probs = [ordered]@{}
    $best = -1; $bestP = 0.0
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $p = 0.0
        if ($sum -gt 0) { $p = $mass[$i] / $sum }
        $probs[[string]$Options[$i].Value] = $p
        if ($p -gt $bestP) { $bestP = $p; $best = $i }
    }
    $value = ''
    if ($best -ge 0) { $value = [string]$Options[$best].Value }
    return @{ Value = $value; P = $bestP; Covered = $sum; Probs = $probs }
}

# The request for AI_EXTRACT: one string per item, all required, nothing else
function New-FujiAiExtractBody {
    param([Parameter(Mandatory)][System.Collections.IList]$Items, [AllowEmptyString()][string]$Note, [AllowEmptyString()][string]$Source)
    $props = [ordered]@{}
    $names = @()
    $lines = foreach ($it in $Items) {
        $props[[string]$it.Name] = [ordered]@{ type = 'string'; maxLength = 100 }
        $names += [string]$it.Name
        if ($it.Note) { '- ' + $it.Name + ': ' + $it.Note } else { '- ' + $it.Name }
    }
    $extra = ''
    if (([string]$Note).Trim()) { $extra = "`n" + ([string]$Note).Trim() }
    $src = Limit-FujiAiSource -Source $Source
    return [ordered]@{
        messages = @(@{ role = 'system'; content = (Get-FujiText 'run.aiExtractPrompt' (@($lines) -join "`n") $extra) }, @{ role = 'user'; content = $src.Text })
        # room for every value at its longest (100 characters, about one token each in Japanese) and
        # the JSON around it: a value cut off would leave JSON that cannot be read
        temperature = 0; max_tokens = 20 + $script:FujiAiExtractItemTokens * $Items.Count
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'answer'; schema = [ordered]@{ type = 'object'; required = $names; additionalProperties = $false; properties = $props } } }
        chat_template_kwargs = @{ enable_thinking = $false }
        Truncated = $src.Cut
    }
}

function ConvertTo-FujiAiPlain {
    param([AllowEmptyString()][string]$Text)
    return (([string]$Text).Normalize([System.Text.NormalizationForm]::FormKC) -replace '\s', '')
}

# The value (width and spaces aside) is found in the source text; an empty value always is
function Test-FujiAiInSource {
    param([AllowEmptyString()][string]$Value, [AllowEmptyString()][string]$Source)
    $v = ConvertTo-FujiAiPlain -Text $Value
    if ($v -eq '') { return $true }
    return (ConvertTo-FujiAiPlain -Text $Source).Contains($v)
}

# Tokens of one request (read + written) as llama-server counted them; 0 when it did not say
function Get-FujiAiTokenCount {
    param($Response)
    $n = 0
    try {
        $u = $Response.usage
        if ($null -ne $u) { $n = [int]$u.prompt_tokens + [int]$u.completion_tokens }
    } catch { $n = 0 }
    return $n
}

# One line in fujikyun_logs\ai_review_<date>.csv (UTF-8 with BOM, header on the first line); returns the path
function Add-FujiAiReviewRow {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][datetime]$Now, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    $dir = Join-Path $Directory $script:FujiLogFolder
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $day = $Now.ToString('yyyy-MM-dd')
    $src = [string]$Row['source']
    if ($src.Length -gt $script:FujiAiReviewSourceMax) { $src = $src.Substring(0, $script:FujiAiReviewSourceMax) }
    $cells = foreach ($k in $script:FujiAiReviewColumns) {
        $v = [string]$Row[$k]
        if ($k -eq 'source') { $v = $src }
        ConvertTo-FujiSafeCsvValue -Value $v
    }
    $line = ConvertTo-FujiCsvText -Rows @(, @($cells))
    # the day's list may be open in Excel (locked): then the next name, ai_review_<date>_2.csv ...
    for ($n = 1; ; $n++) {
        $name = 'ai_review_' + $day + '.csv'
        if ($n -gt 1) { $name = 'ai_review_' + $day + '_' + $n + '.csv' }
        $path = Join-Path $dir $name
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [System.IO.File]::AppendAllText($path, $line, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
            } else {
                $head = ConvertTo-FujiCsvText -Rows @(, @((Get-FujiText 'run.aiReviewHeader') -split ','))
                Write-FujiTextFile -Path $path -Text ($head + $line) -Bom
            }
            return $path
        } catch {
            # the next name only for a file in use; anything else (the folder cannot be written) at once
            if ($n -ge 9 -or (-not (Test-FujiFileBusy -Exception $_.Exception) -and -not ([string]$_.Exception.Message).Contains($path))) { throw }
        }
    }
}

# The shared AI folder this PC uses (fujikyun_settings.json "ai": { "folder" }), '' when not chosen
function Get-FujiAiFolderSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    if ($Settings.Contains('ai') -and $Settings['ai'] -is [System.Collections.IDictionary] -and $Settings['ai'].Contains('folder')) { return ([string]$Settings['ai']['folder']).Trim() }
    return ''
}

# whether this person has chosen an AI folder (the AI commands are gray without one)
function Test-FujiAiAvailable {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    return [bool](Get-FujiAiFolderSetting -Settings $Settings)
}

function Set-FujiAiFolderSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [AllowEmptyString()][string]$Folder)
    if (-not $Settings.Contains('ai') -or $Settings['ai'] -isnot [System.Collections.IDictionary]) { $Settings['ai'] = [ordered]@{} }
    $Settings['ai']['folder'] = ([string]$Folder).Trim()
}

# How many of the sure answers also go to the review list, in percent (0..20, 5 when not set)
function Get-FujiAiSpotSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $n = 5
    if ($Settings.Contains('ai') -and $Settings['ai'] -is [System.Collections.IDictionary] -and $Settings['ai'].Contains('spot')) {
        $v = 0
        if ([int]::TryParse([string]$Settings['ai']['spot'], [ref]$v)) { $n = $v }
    }
    return [Math]::Min(20, [Math]::Max(0, $n))
}

function Set-FujiAiSpotSetting {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [int]$Percent)
    if (-not $Settings.Contains('ai') -or $Settings['ai'] -isnot [System.Collections.IDictionary]) { $Settings['ai'] = [ordered]@{} }
    $Settings['ai']['spot'] = [Math]::Min(20, [Math]::Max(0, $Percent))
}

# ai.json of a shared or copied AI folder -> @{ AiVersion; Model; Files; ServerArgs }; throws when it cannot be used
function Read-FujiAiManifest {
    param([Parameter(Mandatory)][string]$Path)
    $j = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $Path)
    if ($j -isnot [System.Collections.IDictionary] -or -not $j.Contains('aiVersion') -or -not $j.Contains('model') -or -not $j['model'] -or
        -not $j.Contains('files') -or $j['files'] -isnot [System.Collections.IDictionary] -or -not $j['files'].Contains($j['model'])) {
        throw (Get-FujiText 'run.aiManifestBad' $Path)
    }
    $serverArgs = ''
    if ($j.Contains('serverArgs')) { $serverArgs = [string]$j['serverArgs'] }
    return @{ AiVersion = [int]$j['aiVersion']; Model = [string]$j['model']; Files = $j['files']; ServerArgs = $serverArgs }
}

# 'copy' when there is no copy yet, the version differs, or the model file is not the full size
function Test-FujiAiCopyNeeded {
    param([Parameter(Mandatory)][hashtable]$Shared, [AllowNull()][hashtable]$Local, [Parameter(Mandatory)][string]$LocalDir)
    if ($null -eq $Local -or [int]$Local.AiVersion -ne [int]$Shared.AiVersion -or [string]$Local.Model -ne [string]$Shared.Model) { return 'copy' }
    $model = Join-Path $LocalDir $Shared.Model
    if (-not (Test-Path -LiteralPath $model -PathType Leaf)) { return 'copy' }
    $want = [long]$Shared.Files[$Shared.Model]['size']
    if ((Get-Item -LiteralPath $model).Length -ne $want) { return 'copy' }
    return 'none'
}
