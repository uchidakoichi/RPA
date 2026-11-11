# ---------------------------------------------------------------------------------------------
#  AI: the copy on this PC and llama-server (Windows processes and HTTP; see src/Ai.ps1)
#  The shared AI folder (read only, one for the office) is copied to %LOCALAPPDATA%\fujikyun\ai the
#  first time and again when its ai.json version changes: reading the model from a network drive
#  takes about two minutes, from the local disk about six seconds. llama-server is started when a
#  run reaches its first AI step and stopped when the run ends or the app closes.
# ---------------------------------------------------------------------------------------------
$script:FujiAiServer = $null
$script:FujiAiChunk = 1MB
# set when the AI showed a window of its own during a run (Io.AiTookFocus reads and clears it)
$script:FujiAiShowedWindow = $false

function Get-FujiAiLocalDir {
    return (Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'fujikyun') 'ai')
}

# Windows may hold llama-server's files a moment after the process ended: tries again for about 3 s
function Invoke-FujiAiFileRetry {
    param([Parameter(Mandatory)][scriptblock]$Do)
    for ($i = 1; ; $i++) {
        try { & $Do; return } catch { if ($i -ge 10) { throw }; Start-Sleep -Milliseconds 300 }
    }
}

# Removes the copy on this PC (the AI settings' "delete the copy")
function Remove-FujiAiCopy {
    param([string]$LocalDir = (Get-FujiAiLocalDir))
    if (-not (Test-Path -LiteralPath $LocalDir)) { return }
    Invoke-FujiAiFileRetry { Remove-Item -LiteralPath $LocalDir -Recurse -Force -ErrorAction Stop }
}

# The copy's ai.json, or $null when there is no usable copy
function Get-FujiAiLocalManifest {
    param([Parameter(Mandatory)][string]$LocalDir)
    $path = Join-Path $LocalDir 'ai.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Read-FujiAiManifest -Path $path) } catch { return $null }
}

# Copies every file listed in the shared ai.json: each to <name>.part with its SHA-256 worked out on
# the way, then all put in place, ai.json last (a copy stopped halfway is never taken as complete).
# Progress {Done; Total} in bytes; Cancel {} -> $true to stop. Returns 'copied' | 'canceled'.
function Copy-FujiAiLocal {
    param([Parameter(Mandatory)][string]$SharedDir, [string]$LocalDir = (Get-FujiAiLocalDir), [scriptblock]$Progress = { param($Done, $Total) }, [scriptblock]$Cancel = { $false }, [long]$MinFreeBytes = 2GB)
    $manifest = Read-FujiAiManifest -Path (Join-Path $SharedDir 'ai.json')
    if (-not (Test-Path -LiteralPath $LocalDir)) { [void](New-Item -ItemType Directory -Path $LocalDir) }
    $free = (New-Object -TypeName System.IO.DriveInfo -ArgumentList ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $LocalDir).Path))).AvailableFreeSpace
    if ($free -lt $MinFreeBytes) { throw (Get-FujiText 'run.aiDiskShort' ([Math]::Round($free / 1GB, 1))) }
    $total = [long]0
    foreach ($k in $manifest.Files.Keys) { $total += [long]$manifest.Files[$k]['size'] }
    $localJson = Join-Path $LocalDir 'ai.json'
    # the files of the copy there is now (taken away after the new ones are in place, when the new
    # version does not have them: a model of another name)
    $before = Get-FujiAiLocalManifest -LocalDir $LocalDir
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $done = [long]0
    $buffer = New-Object -TypeName 'byte[]' -ArgumentList $script:FujiAiChunk
    try {
        foreach ($rel in @($manifest.Files.Keys)) {
            $src = Join-Path $SharedDir ($rel.Replace('/', '\'))
            $dest = Join-Path $LocalDir ($rel.Replace('/', '\'))
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) { [void](New-Item -ItemType Directory -Path $destDir) }
            $part = $dest + '.part'
            $parts.Add($part)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $in = [System.IO.File]::Open($src, 'Open', 'Read', 'Read')
            $out = [System.IO.File]::Open($part, 'Create', 'Write', 'None')
            try {
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $n)
                    [void]$sha.TransformBlock($buffer, 0, $n, $null, 0)
                    $done += $n
                    & $Progress $done $total
                    if (& $Cancel) { return 'canceled' }
                }
                [void]$sha.TransformFinalBlock($buffer, 0, 0)
            } finally { $in.Dispose(); $out.Dispose() }
            $want = ''
            if ($manifest.Files[$rel].Contains('sha256')) { $want = ([string]$manifest.Files[$rel]['sha256']).ToLowerInvariant() }
            $got = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
            if ($want -and $got -ne $want) { throw (Get-FujiText 'run.aiCopyBad' $rel) }
        }
        # every new file is here and right: only now is the copy there was taken as incomplete (until
        # then, a copy that was stopped or failed leaves the old copy as it was, still usable)
        if (Test-Path -LiteralPath $localJson) { Remove-Item -LiteralPath $localJson -Force }
        foreach ($part in $parts) {
            $dest = $part.Substring(0, $part.Length - 5)
            try {
                Invoke-FujiAiFileRetry {
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction Stop }
                    Move-Item -LiteralPath $part -Destination $dest -ErrorAction Stop
                }
            } catch { throw (Get-FujiText 'run.aiCopyBusy' $dest) }
        }
        $parts.Clear()
        Copy-Item -LiteralPath (Join-Path $SharedDir 'ai.json') -Destination $localJson
        if ($null -ne $before) {
            foreach ($rel in @($before.Files.Keys)) {
                if ($manifest.Files.Contains($rel)) { continue }
                # a file left behind takes room only: the copy works without it taken away
                try { Invoke-FujiAiFileRetry { Remove-Item -LiteralPath (Join-Path $LocalDir ($rel.Replace('/', '\'))) -Force -ErrorAction Stop } } catch { $null = $_ }
            }
        }
        return 'copied'
    } finally {
        foreach ($part in $parts) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
}

# The folder to start llama-server from: the copy, made or renewed first when the shared folder has
# a new version (Copy {} -> 'copied' | 'canceled', shows the copy window). When the shared folder
# cannot be reached but there is a copy, the copy is used (Log {Message} says so).
function Resolve-FujiAiReady {
    param([AllowEmptyString()][string]$SharedDir, [string]$LocalDir = (Get-FujiAiLocalDir), [Parameter(Mandatory)][scriptblock]$Copy, [scriptblock]$Log = { param($Message) })
    $aiReadyLocal = Get-FujiAiLocalManifest -LocalDir $LocalDir
    $aiReadyShared = $null
    if ($SharedDir) { try { $aiReadyShared = Read-FujiAiManifest -Path (Join-Path $SharedDir 'ai.json') } catch { $aiReadyShared = $null } }
    if ($null -eq $aiReadyShared) {
        if ($null -ne $aiReadyLocal -and (Test-Path -LiteralPath (Join-Path $LocalDir $aiReadyLocal.Model) -PathType Leaf)) {
            & $Log (Get-FujiText 'run.aiSharedOffline' $SharedDir)
            return $LocalDir
        }
        if (-not $SharedDir) { throw (New-FujiStopException (Get-FujiText 'run.aiNoFolder')) }
        throw (Get-FujiText 'run.aiSharedMissing' $SharedDir)
    }
    if ((Test-FujiAiCopyNeeded -Shared $aiReadyShared -Local $aiReadyLocal -LocalDir $LocalDir) -eq 'copy') {
        # the person called it off: the run stops (rather than asking again on every row)
        if ((& $Copy) -ne 'copied') { throw (New-FujiStopException (Get-FujiText 'run.aiCopyCanceled')) }
    }
    return $LocalDir
}

function Get-FujiFreeMemoryMb {
    return [int]((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
}

# Starts llama-server from the copy on a free local port and waits until it answers /health.
# Returns @{ Process; Port; LogDir }.
function Start-FujiAiServer {
    param([Parameter(Mandatory)][string]$LocalDir, [Parameter(Mandatory)][string]$LogDir, [int]$MinFreeMb = 1024, [int]$TimeoutSec = 60)
    $manifest = Get-FujiAiLocalManifest -LocalDir $LocalDir
    if ($null -eq $manifest) { throw (Get-FujiText 'run.aiNoCopy' $LocalDir) }
    $free = Get-FujiFreeMemoryMb
    if ($free -lt $MinFreeMb) { throw (Get-FujiText 'run.aiMemoryShort' $free $MinFreeMb) }
    if (-not (Test-Path -LiteralPath $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir) }
    $listener = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $exe = Join-Path $LocalDir 'llama-x64\llama-server.exe'
    $argList = @('-m', ('"' + (Join-Path $LocalDir $manifest.Model) + '"'), '--host', '127.0.0.1', '--port', [string]$port) + @($manifest.ServerArgs -split ' ' | Where-Object { $_ })
    $log = Join-Path $LogDir ('llama-server_' + (Get-Date).ToString('yyyy-MM-dd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture) + '.log')
    $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardError $log
    $server = @{ Process = $p; Port = $port; LogDir = $LogDir }
    [System.IO.File]::WriteAllText((Join-Path $LogDir 'llama-server.pid'), [string]$p.Id)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($p.HasExited) {
            Stop-FujiAiServer -Server $server
            $tail = ''
            try { $tail = (@(Get-Content -LiteralPath $log -Tail 5) -join ' / ') } catch { $tail = '' }
            throw (Get-FujiText 'run.aiServerExited' $tail)
        }
        try {
            if ((Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:{0}/health' -f $port) -TimeoutSec 2).StatusCode -eq 200) { return $server }
        } catch { $null = $_ }
        Start-Sleep -Milliseconds 300
    }
    Stop-FujiAiServer -Server $server
    throw (Get-FujiText 'run.aiServerSlow' $TimeoutSec)
}

# One request to llama-server's chat endpoint; returns the answer (ConvertFrom-Json)
function Invoke-FujiAiChat {
    param([Parameter(Mandatory)][hashtable]$Server, [Parameter(Mandatory)][System.Collections.IDictionary]$Body, [int]$TimeoutSec = 60)
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 30 -Compress))
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ('http://127.0.0.1:{0}/v1/chat/completions' -f $Server.Port) -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec
    return ($utf8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json)
}

# Stops the server (any number of times) and removes its pid file
function Stop-FujiAiServer {
    param([hashtable]$Server = $script:FujiAiServer)
    if ($null -eq $Server) { return }
    try { if (-not $Server.Process.HasExited) { $Server.Process.Kill(); [void]$Server.Process.WaitForExit(5000) } } catch { $null = $_ }
    Remove-Item -LiteralPath (Join-Path $Server.LogDir 'llama-server.pid') -Force -ErrorAction SilentlyContinue
    if ($Server -eq $script:FujiAiServer) { $script:FujiAiServer = $null }
}

# A llama-server left by an app that did not close normally (its pid file is still there)
function Clear-FujiAiLeftover {
    param([Parameter(Mandatory)][string]$LogDir)
    $pidFile = Join-Path $LogDir 'llama-server.pid'
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return }
    $id = 0
    if ([int]::TryParse(([System.IO.File]::ReadAllText($pidFile)).Trim(), [ref]$id)) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $p -and $p.ProcessName -eq 'llama-server') { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { $null = $_ } }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# Io.AiChat of a run: the first AI step copies when needed (copy window) and starts
# llama-server; later steps ask the same server. Without a chosen AI folder the run stops (the
# folder is chosen in the AI settings, not in the middle of a run)
function Invoke-FujiAiRunChat {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Body)
    $srv = $script:FujiAiServer
    if ($null -eq $srv -or $srv.Process.HasExited) {
        $folder = Get-FujiAiFolderSetting -Settings $script:Settings
        if (-not $folder) { throw (New-FujiStopException (Get-FujiText 'run.aiNoFolder')) }
        # the AI that cannot be made ready or started stops the run: the next row would try again
        # (wait for a minute or copy 1.3 GB) and fail the same way on every row
        try {
            $dir = Resolve-FujiAiReady -SharedDir $folder -Copy { $script:FujiAiShowedWindow = $true; Show-FujiAiCopyDialog -SharedDir $folder } -Log { param($Message) Write-FujiUiLog -Message $Message -Level 'warn' }
            $script:Ui.Progress.Text = Get-FujiText 'run.aiStarting'
            [System.Windows.Forms.Application]::DoEvents()
            $script:FujiAiServer = Start-FujiAiServer -LocalDir $dir -LogDir (Join-Path $script:Ed.Directory $script:FujiLogFolder)
        } catch [System.OperationCanceledException] {
            throw
        } catch {
            throw (New-FujiStopException (Get-FujiText 'run.aiStartFailed' $_.Exception.Message))
        }
        $srv = $script:FujiAiServer
    }
    return (Invoke-FujiAiChat -Server $srv -Body $Body)
}
