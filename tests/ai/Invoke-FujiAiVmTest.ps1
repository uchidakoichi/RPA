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
    $kind = ''; try { [void](Resolve-FujiAiReady -SharedDir $shared -LocalDir (Join-Path $root 'empty2') -Copy { 'canceled' } -Log { param($m) }) } catch { $kind = $_.Exception.GetType().Name }
    Check ($kind -eq 'OperationCanceledException') 'ready: a cancelled copy stops the run'

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
    # a long Japanese value (the room was 60 tokens per item before 2026.11.12.2: cut, JSON unreadable)
    $addr = -join [char[]]@(0x795E,0x5948,0x5DDD,0x770C,0x85E4,0x6CA2,0x5E02,0x7247,0x702C,0x6D77,0x5CB8,0x4E09,0x4E01,0x76EE,0x4E8C,0x5341,0x56DB,0x756A,0x5341,0x53F7,0x30B5,0x30F3,0x30D7,0x30EB,0x30DE,0x30F3,0x30B7,0x30E7,0x30F3,0x7247,0x702C,0x6D77,0x5CB8,0x30A6,0x30A8,0x30B9,0x30C8,0x30BF,0x30EF,0x30FC,0x5343,0x4E8C,0x767E,0x4E09,0x5341,0x56DB,0x53F7,0x5BA4,0x5185,0x7530,0x65B9,0x69D8,0x5B9B,0x3066,0x5348,0x524D,0x4E2D,0x5728,0x5B85,0x5E73,0x65E5,0x306F,0x4E0D,0x5728,0x306E,0x305F,0x3081,0x5B85,0x914D,0x30DC,0x30C3,0x30AF,0x30B9,0x3078,0x304A,0x9858,0x3044,0x3057,0x307E,0x3059)
    $ex2 = New-FujiAiExtractBody -Items (Read-FujiAiItem -Text "name`naddress") -Note '' -Source ('Name: Nakamura Sakura' + [char]10 + 'Address: ' + $addr)
    $ex2.Remove('Truncated')
    $er2 = Invoke-FujiAiChat -Server $srv -Body $ex2
    $ans2 = $null; try { $ans2 = ConvertFrom-FujiJson -Json ([string]$er2.choices[0].message.content) } catch { $ans2 = $null }
    Check ($ans2 -is [System.Collections.IDictionary] -and ([string]$ans2['address']).Length -ge 80) ('ask: a long value is read whole ({0} of {1} characters, {2} tokens)' -f $(if ($ans2 -is [System.Collections.IDictionary]) { ([string]$ans2['address']).Length } else { -1 }), $addr.Length, (Get-FujiAiTokenCount -Response $er2))
    # ten items (the most a step takes): every value comes back in readable JSON (the VM reads about
    # 10 tokens a second, a tenth of the office PC: hence the long wait)
    $ten = (1..10 | ForEach-Object { 'item' + $_ }) -join "`n"
    $ex3 = New-FujiAiExtractBody -Items (Read-FujiAiItem -Text $ten) -Note '' -Source (('Name: Nakamura Sakura, phone 0466-12-3456. ' + $addr + ' ') * 10)
    $ex3.Remove('Truncated')
    $er3 = $null; $err3 = ''; try { $er3 = Invoke-FujiAiChat -Server $srv -Body $ex3 -TimeoutSec 300 } catch { $err3 = $_.Exception.Message }
    $ans3 = $null; if ($null -ne $er3) { try { $ans3 = ConvertFrom-FujiJson -Json ([string]$er3.choices[0].message.content) } catch { $ans3 = $null } }
    Check ($ans3 -is [System.Collections.IDictionary] -and $ans3.Count -eq 10) ('ask: ten items (max_tokens {0}) {1}' -f $ex3['max_tokens'], $err3)
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
    # an update stopped halfway: the copy there was is still used (it was taken as gone before 2026.11.12.2)
    $m4 = $manifest; $m4.aiVersion = 20
    Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $m4 -Indent 2)
    $r = Copy-FujiAiLocal -SharedDir $shared -LocalDir $local -Progress { param($Done, $Total) } -Cancel { $true }
    $kept = Get-FujiAiLocalManifest -LocalDir $local
    Check ($r -eq 'canceled' -and $null -ne $kept -and $kept.AiVersion -eq 13 -and (Test-Path -LiteralPath (Join-Path $local 'qwen35-q4.gguf'))) 'copy: an update called off leaves the old copy usable'
    $ks = Start-FujiAiServer -LocalDir $local -LogDir $logs
    Check (-not $ks.Process.HasExited) 'copy: the old copy still starts'
    Stop-FujiAiServer -Server $ks
    # a model of another name: the old model is taken away from the copy
    Rename-Item -LiteralPath (Join-Path $shared 'qwen35-q4.gguf') -NewName 'qwen35-new.gguf'
    $files5 = [ordered]@{}
    foreach ($k in $files.Keys) { if ($k -eq 'qwen35-q4.gguf') { $files5['qwen35-new.gguf'] = $files[$k] } else { $files5[$k] = $files[$k] } }
    $m5 = [ordered]@{ aiVersion = 21; model = 'qwen35-new.gguf'; files = $files5; serverArgs = $manifest.serverArgs }
    Write-FujiTextFile -Path (Join-Path $shared 'ai.json') -Text (ConvertTo-FujiJson -InputObject $m5 -Indent 2)
    $r = Copy-FujiAiLocal -SharedDir $shared -LocalDir $local
    Check ($r -eq 'copied' -and (Test-Path -LiteralPath (Join-Path $local 'qwen35-new.gguf')) -and -not (Test-Path -LiteralPath (Join-Path $local 'qwen35-q4.gguf')) -and (Get-FujiAiLocalManifest -LocalDir $local).Model -eq 'qwen35-new.gguf') 'copy: the model of the old name is taken away'
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
