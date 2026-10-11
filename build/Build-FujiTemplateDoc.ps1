# Generates samples/*.csv and docs/src/templates.md from fujikyun_templates.json, so the app,
# the sample CSVs and the docs never drift apart. The step texts come from the app's own label rules.
# The page's fixed wording is in template_doc_ja.json (this file stays ASCII for Windows PowerShell 5.1).
# Usage (maintainers only):  powershell -NoProfile -File build\Build-FujiTemplateDoc.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$psRoot = $repoRoot
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
Import-FujiCommand -Path (Join-Path $psRoot 'fujikyun_commands.json')
$data = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path (Join-Path $psRoot 'fujikyun_templates.json'))
$t = ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path (Join-Path $PSScriptRoot 'template_doc_ja.json'))

$templates = $data['templates']
$md = { param($s) ([string]$s).Replace('|', '\|') -replace "`r?`n", $t['newline'] }
# Settings column: nothing for block ends, the readable form for commands edited with a form, else the value
$setting = {
    param($Step)
    $def = Get-FujiCommandDef ([string]$Step[0])
    if ($def['format'] -eq 'none') { return '' }
    $v = ''
    if ($Step.Count -gt 1 -and $null -ne $Step[1]) { $v = [string]$Step[1] }
    if ($def.Contains('hideVal') -and $def['hideVal']) { return (Get-FujiStepLabel -Cmd ([string]$Step[0]) -Value $v) }
    return $v
}

$samples = Join-Path $repoRoot 'samples'
[void](New-Item -ItemType Directory -Path $samples -Force)
foreach ($tpl in $templates) {
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($r in $tpl['csv']) { $rows.Add([string[]]$r) }
    Write-FujiTextFile -Path (Join-Path $samples ([string]$tpl['csvFile'])) -Text (ConvertTo-FujiCsvText -Rows $rows.ToArray()) -Bom
}

$out = New-Object -TypeName 'System.Collections.Generic.List[string]'
$out.Add($t['title']); $out.Add('')
$out.Add($t['generated']); $out.Add('')
$out.Add(([string]$t['intro']).Replace('{count}', [string]$templates.Count)); $out.Add('')
foreach ($n in $t['notes']) { $out.Add('- ' + $n) }
$out.Add('')
$out.Add($t['listHeading']); $out.Add('')
$out.Add($t['listHeader'])
$out.Add('| --- | --- | --- | --- |')
foreach ($c in $data['categories']) {
    foreach ($tpl in $templates) {
        if ($tpl['category'] -ne $c) { continue }
        $out.Add('| ' + $c + ' | [' + $tpl['name'] + '](#' + $tpl['id'] + ') | ' + $t['levels'][[string]$tpl['level']] + ' | `samples/' + $tpl['csvFile'] + '` |')
    }
}
$out.Add('')
foreach ($c in $data['categories']) {
    $out.Add('## ' + $c); $out.Add('')
    foreach ($tpl in $templates) {
        if ($tpl['category'] -ne $c) { continue }
        $out.Add('<a id="' + $tpl['id'] + '"></a>'); $out.Add('')
        $out.Add('### ' + $tpl['name'] + ([char]0xFF08) + $t['levels'][[string]$tpl['level']] + ([char]0xFF09)); $out.Add('')
        $out.Add($tpl['summary']); $out.Add('')
        $out.Add($t['useCase'] + $tpl['useCase'])
        $target = $t['noTarget']
        if ($tpl['targetWindow']) { $target = '`' + $tpl['targetWindow'] + '`' }
        $out.Add($t['target'] + $target)
        $cols = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($h in $tpl['csv'][0]) { $cols.Add('`' + $h + '`') }
        $out.Add(([string]$t['sample']).Replace('{file}', [string]$tpl['csvFile']).Replace('{cols}', [string]::Join($t['colSep'], $cols.ToArray())))
        $out.Add('')
        $out.Add($t['prepare']); $out.Add('')
        foreach ($p in $tpl['prepare']) { $out.Add('- ' + $p) }
        $out.Add('')
        $out.Add($t['steps']); $out.Add('')
        $out.Add($t['stepHeader'])
        $out.Add('| --- | --- | --- | --- |')
        $i = 0
        foreach ($s in $tpl['steps']) {
            $i++
            $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
            if ($s.Count -gt 2) {
                $props = $s[2]
                if ($props.Contains('when') -and $props['when'] -eq 'first') { $notes.Add($t['first']) }
                if ($props.Contains('when') -and $props['when'] -eq 'last') { $notes.Add($t['last']) }
                if ($props.Contains('disabled') -and $props['disabled']) { $notes.Add($t['disabled']) }
            }
            $value = & $setting $s
            $cell = ''
            if ($value -ne '') { $cell = '`' + (& $md $value) + '`' }
            $title = [string](Get-FujiCommandDef ([string]$s[0]))['title']
            $out.Add('| ' + $i + ' | `' + $s[0] + '` ' + $title + ' | ' + $cell + ' | ' + [string]::Join($t['colSep'], $notes.ToArray()) + ' |')
        }
        $out.Add('')
        $out.Add($t['customize']); $out.Add('')
        foreach ($p in $tpl['customize']) { $out.Add('- ' + $p) }
        $out.Add('')
        $out.Add($t['ideas']); $out.Add('')
        foreach ($p in $tpl['ideas']) { $out.Add('- ' + $p) }
        $out.Add('')
        $out.Add($t['csvHead']); $out.Add('')
        $head = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $sep = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($h in $tpl['csv'][0]) { $head.Add((& $md $h)); $sep.Add('---') }
        $out.Add('| ' + [string]::Join(' | ', $head.ToArray()) + ' |')
        $out.Add('| ' + [string]::Join(' | ', $sep.ToArray()) + ' |')
        for ($r = 1; $r -lt [Math]::Min(4, $tpl['csv'].Count); $r++) {
            $cells = New-Object -TypeName 'System.Collections.Generic.List[string]'
            foreach ($v in $tpl['csv'][$r]) { $cells.Add((& $md $v)) }
            $out.Add('| ' + [string]::Join(' | ', $cells.ToArray()) + ' |')
        }
        $out.Add('')
    }
}
Write-FujiTextFile -Path (Join-Path $repoRoot 'docs\src\templates.md'.Replace('\', [IO.Path]::DirectorySeparatorChar)) -Text ([string]::Join("`n", $out.ToArray()))
Write-Output ('generated {0} sample CSVs and docs/src/templates.md' -f $templates.Count)
