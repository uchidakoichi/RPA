<#
    Checks where this PC keeps per-user local files, and whether they survive sign-out and restart.
    Double-click local-check.bat. It shows the user folders (LOCALAPPDATA, APPDATA, TEMP ...), whether
    they exist (AppData is hidden, so Explorer does not show it by default), whether they are on this
    PC or on the network, the free space, and the profile type. It writes a small marker file in
    %LOCALAPPDATA%\fujikyun-check. Run it again after signing out or restarting: if the marker from the
    first run is still there, files kept in %LOCALAPPDATA% survive. The report is local-check-result.txt.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$os = Get-CimInstance Win32_OperatingSystem
Say ('last restart: ' + $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))
Say ('user: ' + $env:USERNAME + ' / computer: ' + $env:COMPUTERNAME)
Say ''
foreach ($n in @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'HOMEDRIVE', 'HOMEPATH')) {
    Say ($n + ' = ' + [Environment]::GetEnvironmentVariable($n))
}
Say ('LocalApplicationData (from .NET) = ' + [Environment]::GetFolderPath('LocalApplicationData'))
Say ''
$local = [Environment]::GetFolderPath('LocalApplicationData')
if (-not $local) { $local = $env:LOCALAPPDATA }
foreach ($p in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'AppData'), $local, $env:APPDATA, $env:TEMP)) {
    if (-not $p) { continue }
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) { Say ($p + ': NOT FOUND'); continue }
    $where = 'this PC'
    if ($p.StartsWith('\\')) { $where = 'network' }
    else {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $p.Substring(0, 2) + "'") -ErrorAction SilentlyContinue
        if ($d -and $d.DriveType -eq 4) { $where = 'network drive' }
        if ($d) { $where += (', free GB ' + [Math]::Round($d.FreeSpace / 1GB, 1)) }
    }
    $hidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
    Say ($p + ': exists, ' + $where + $(if ($hidden) { ', hidden folder' } else { '' }))
}
Say ''
$prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -eq $env:USERPROFILE }
if ($prof) {
    $status = @()
    if ($prof.Status -band 1) { $status += 'temporary' }
    if ($prof.Status -band 2) { $status += 'roaming' }
    if ($prof.Status -band 4) { $status += 'mandatory (changes are thrown away at sign-out)' }
    if ($prof.Status -band 8) { $status += 'corrupted' }
    if ($status.Count -eq 0) { $status = @('local') }
    Say ('profile: ' + ($status -join ', ') + ' / roaming set: ' + $prof.RoamingConfigured)
}
Say ''
$dir = Join-Path $local 'fujikyun-check'
$marker = Join-Path $dir 'marker.txt'
if (Test-Path -LiteralPath $marker) {
    Say ('marker from an earlier run: FOUND, written ' + ([IO.File]::ReadAllText($marker)).Trim())
    Say '  -> if you signed out or restarted since then, files in LOCALAPPDATA survive'
} else {
    Say 'marker from an earlier run: none (first run, or it was removed)'
}
try {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [IO.File]::WriteAllText($marker, $now)
    Say ('write test: OK (' + $marker + ' = ' + $now + ')')
} catch { Say ('write test: FAILED (' + $_.Exception.Message + ')') }
Say 'next: sign out (or restart), sign in, and run local-check.bat again'
[IO.File]::WriteAllLines((Join-Path $here 'local-check-result.txt'), $out)
Write-Host ('wrote ' + (Join-Path $here 'local-check-result.txt'))
