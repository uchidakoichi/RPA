# ---------------------------------------------------------------------------------------------
#  One app per folder: a second start in the same folder would write the same temp and macros
#  files as the first one, so it is refused. Apps in different folders run side by side.
# ---------------------------------------------------------------------------------------------

# Named after the folder (full path, case ignored): Local\FujikyunRPA_<sha256 of the path>
function Get-FujiAppLockName {
    param([Parameter(Mandatory)][string]$Directory)
    $path = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/').ToUpperInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($path))
    } finally {
        $sha.Dispose()
    }
    return ('Local\FujikyunRPA_' + (-join ($hash | ForEach-Object { $_.ToString('x2') })))
}

# The lock (a mutex owned by this thread; keep it until the app ends) or $null when another app has it
function Enter-FujiAppLock {
    param([Parameter(Mandatory)][string]$Directory)
    $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, (Get-FujiAppLockName -Directory $Directory)
    try {
        if ($mutex.WaitOne(0)) { return $mutex }
    } catch [System.Threading.AbandonedMutexException] {
        # the app that had it ended without letting go (it was killed): the lock is ours now
        return $mutex
    }
    $mutex.Dispose()
    return $null
}
