#Requires -Version 5.1
<#
.SYNOPSIS
    VM check of the AI parts that need Windows and the real llama-server (copy, start, ask, stop).

.DESCRIPTION
    Uses llama.cpp in C:\llm\bin-x64 and the model C:\llm\qwen3.5-2b-q4_k_m.gguf (the VM's bench
    files). A stand-in for the shared AI folder is made in %TEMP%. Prints OK / NG per check.
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\ai\Invoke-FujiAiVmTest.ps1
#>
param([string]$Bin = 'C:\llm\bin-x64', [string]$Model = 'C:\llm\qwen3.5-2b-q4_k_m.gguf')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$psRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $psRoot 'src') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
. (Join-Path $psRoot 'gui\AiServer.ps1')
Import-FujiText -Path (Join-Path $psRoot 'fujikyun_ja.json')
$script:ng = 0
function Check([bool]$Ok, [string]$What) { if ($Ok) { Write-Output ('OK ' + $What) } else { $script:ng++; Write-Output ('NG ' + $What) } }

$root = Join-Path $env:TEMP ('fuji-ai-vm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$shared = Join-Path $root 'share'
$local = Join-Path $root 'local'
$logs = Join-Path $root 'logs'
[void](New-Item -ItemType Directory -Path $shared, $logs)
try {
    # the stand-in shared folder: llama-x64, the model, ai.json with every file's size and SHA-256
    Copy-Item -LiteralPath $Bin -Destination (Join-Path $shared 'llama-x64') -Recurse
    Copy-Item -LiteralPath $Model -Destination (Join-Path $shared 'qwen35-q4.gguf')
    $files = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath $shared -Recurse -File) {
        $rel = $f.FullName.Substring($shared.Length + 1).Replace('\', '/')
        $files[$rel] = [ordered]@{ size = $f.Length; sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $manifest = [ordered]@{ aiVersion = 1; model = 'qwen35-q4.gguf'; files = $files; serverArgs = '-c 4096 -t 4 --cache-ram 0 -ctxcp 4 -np 1 --no-repack --jinja' }
    Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $manifest -Indent 2)

    # copy: cancel halfway leaves no part file
    $r = Copy-FujiAiLocal -SharedDir $shared -LocalDir $local -Progress { param($Done, $Total) } -Cancel { $true }
    Check ($r -eq 'canceled' -and @(Get-ChildItem -LiteralPath $local -Recurse -Filter '*.part' -ErrorAction SilentlyContinue).Count -eq 0) 'copy: canceled, no part file left'
    $seen = @{ Done = 0; Total = 0 }
    $r = Copy-FujiAiLocal -SharedDir $shared -LocalDir $local -Progress { param($Done, $Total) $seen.Done = $Done; $seen.Total = $Total } -Cancel { $false }
    Check ($r -eq 'copied') 'copy: copied'
    Check ($seen.Total -gt 1GB -and $seen.Done -eq $seen.Total) 'copy: progress reaches the total'
    Check ((Get-FileHash -LiteralPath (Join-Path $local 'qwen35-q4.gguf') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $files['qwen35-q4.gguf'].sha256) 'copy: model SHA-256 matches'
    Check ((Test-FujiAiCopyNeeded -Shared (Read-FujiAiManifest -Path (Join-Path $shared 'ai.json')) -Local (Get-FujiAiLocalManifest -LocalDir $local) -LocalDir $local) -eq 'none') 'copy: nothing more to copy'
    $m2 = $manifest; $m2.aiVersion = 2
    Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $m2 -Indent 2)
    Check ((Test-FujiAiCopyNeeded -Shared (Read-FujiAiManifest -Path (Join-Path $shared 'ai.json')) -Local (Get-FujiAiLocalManifest -LocalDir $local) -LocalDir $local) -eq 'copy') 'copy: a new version is copied again'
    $m2.aiVersion = 1
    Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $m2 -Indent 2)

    # ready: the shared folder offline, the copy is used
    $logged = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $dir = Resolve-FujiAiReady -SharedDir (Join-Path $root 'no-such-share') -LocalDir $local -Copy { 'copied' } -Log { param($m) $logged.Add($m) }
    Check ($dir -eq $local -and $logged.Count -eq 1) 'ready: shared folder offline, the copy is used'
    $threw = $false; try { [void](Resolve-FujiAiReady -SharedDir (Join-Path $root 'no-such-share') -LocalDir (Join-Path $root 'empty') -Copy { 'copied' } -Log { param($m) }) } catch { $threw = $true }
    Check $threw 'ready: no share and no copy is an error'

    # start: not enough memory
    $threw = $false; try { [void](Start-FujiAiServer -LocalDir $local -LogDir $logs -MinFreeMb 1048576) } catch { $threw = $true }
    Check $threw 'start: refused when memory is short'
    # start, ask, stop
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $srv = Start-FujiAiServer -LocalDir $local -LogDir $logs
    Check ($null -ne $srv -and -not $srv.Process.HasExited) ('start: running in {0:N1} s' -f $sw.Elapsed.TotalSeconds)
    Check (Test-Path -LiteralPath (Join-Path $logs 'llama-server.pid')) 'start: pid file written'
    $opts = Read-FujiAiOption -Text "resident`ngarbage"
    $body = New-FujiAiChooseBody -Question 'Which desk handles this' -Options $opts -Source 'When is the garbage collected on my street?'
    $body.Remove('Truncated')
    $resp = Invoke-FujiAiChat -Server $srv -Body $body
    $c = Read-FujiAiChoice -Response $resp -Options $opts
    Check ($c.Covered -gt 0.5 -and $c.Value -ne '') ('ask: answered {0} p={1:N2}' -f $c.Value, $c.P)
    $ex = New-FujiAiExtractBody -Items (Read-FujiAiItem -Text "name`nphone") -Note '' -Source 'Name: Nakamura Sakura, phone 0466-12-3456'
    $ex.Remove('Truncated')
    $er = Invoke-FujiAiChat -Server $srv -Body $ex
    $ans = ConvertFrom-FujiJson -Json ([string]$er.choices[0].message.content)
    Check ($ans -is [System.Collections.IDictionary] -and $ans.Contains('phone')) ('ask: extract JSON ' + [string]$er.choices[0].message.content)
    $procId = $srv.Process.Id
    Stop-FujiAiServer -Server $srv
    Start-Sleep -Milliseconds 500
    Check ($null -eq (Get-Process -Id $procId -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $logs 'llama-server.pid'))) 'stop: process and pid file gone'
    Stop-FujiAiServer -Server $srv
    Check $true 'stop: twice is fine'
    # right after a stop the files are replaced (Windows may hold the DLLs a moment after the process ends)
    foreach ($round in 1..3) {
        $s3 = Start-FujiAiServer -LocalDir $local -LogDir $logs
        Stop-FujiAiServer -Server $s3
        $m3 = $manifest; $m3.aiVersion = 10 + $round
        Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $m3 -Indent 2)
        $ok3 = $true; try { [void](Copy-FujiAiLocal -SharedDir $shared -LocalDir $local) } catch { $ok3 = $false; Write-Output $_.Exception.Message }
        Check $ok3 ('copy: right after a stop, round ' + $round)
        $ok4 = $true; try { Remove-FujiAiCopy -LocalDir $local; [void](Copy-FujiAiLocal -SharedDir $shared -LocalDir $local) } catch { $ok4 = $false; Write-Output $_.Exception.Message }
        Check ($ok4 -and (Test-Path -LiteralPath (Join-Path $local 'ai.json'))) ('delete the copy and copy again, round ' + $round)
    }
    # a leftover from a crash is cleared at the next start
    $left = Start-Process -FilePath (Join-Path $local 'llama-x64\llama-server.exe') -ArgumentList '--version' -PassThru -WindowStyle Hidden
    $left2 = Start-FujiAiServer -LocalDir $local -LogDir $logs
    $leftId = $left2.Process.Id
    $null = $left
    Clear-FujiAiLeftover -LogDir $logs
    Start-Sleep -Milliseconds 500
    Check ($null -eq (Get-Process -Id $leftId -ErrorAction SilentlyContinue)) 'leftover: stopped by its pid file'
    # chat timeout / server gone
    $threw = $false; try { [void](Invoke-FujiAiChat -Server $left2 -Body $body -TimeoutSec 5) } catch { $threw = $true }
    Check $threw 'ask: a stopped server is an error'
} finally {
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ($root + '*') } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:ng -gt 0) { Write-Output ('{0} NG' -f $script:ng); exit 1 }
Write-Output 'ALL OK'
