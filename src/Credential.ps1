# ---------------------------------------------------------------------------------------------
#  Passwords in the Windows Credential Manager (generic credentials of the signed-in user)
#  The SECRET step reads them while a run types them; the step dialog (gui/Credential.ps1)
#  registers, changes and removes them. A password is never shown, logged or kept in a macro, a
#  CSV or a variable. The functions are declared at run time like Native.ps1 (no C# compiler):
#  CredReadW, CredWriteW, CredDeleteW and CredFree, with the CREDENTIALW structure read and
#  written by offsets.
# ---------------------------------------------------------------------------------------------

$script:FujiCredNative = $null
# Generic credentials are named after the service using them (CREDENTIALW TargetName)
$script:FujiCredPrefix = 'FujikyunRPA:'
$script:FujiCredLimits = @{ Type = 1; Persist = 2; MaxBlobBytes = 2560 }   # CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE, 5*512

function Get-FujiCredNativeType {
    if ($null -ne $script:FujiCredNative) { return $script:FujiCredNative }
    $name = New-Object -TypeName System.Reflection.AssemblyName -ArgumentList 'FujiCred'
    $asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $asm.DefineDynamicModule('FujiCred')
    $tb = $module.DefineType('FujiCred.Win32', [System.Reflection.TypeAttributes]'Public, Class, Abstract, Sealed')
    $wide = [System.Runtime.InteropServices.CharSet]::Unicode
    $a = 'advapi32.dll'
    # CredReadW's last parameter receives a pointer: a one-item IntPtr array is pinned and filled in
    $declarations = @(
        @($a, 'CredReadW', [bool], [type[]]@([string], [uint32], [uint32], [IntPtr[]])),
        @($a, 'CredWriteW', [bool], [type[]]@([IntPtr], [uint32])),
        @($a, 'CredDeleteW', [bool], [type[]]@([string], [uint32], [uint32])),
        @($a, 'CredFree', [void], [type[]]@([IntPtr]))
    )
    foreach ($d in $declarations) {
        $m = $tb.DefinePInvokeMethod($d[1], $d[0],
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl, HideBySig',
            [System.Reflection.CallingConventions]::Standard, $d[2], $d[3],
            [System.Runtime.InteropServices.CallingConvention]::Winapi, $wide)
        $m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    }
    $script:FujiCredNative = $tb.CreateType()
    return $script:FujiCredNative
}

# Byte offsets of the CREDENTIALW members used here, for this process (32 or 64 bit)
function Get-FujiCredLayout {
    $p = [IntPtr]::Size
    $blobSize = 16 + 2 * $p
    $blob = $blobSize + 4
    if ($p -eq 8) { $blob = $blobSize + 8 }
    $persist = $blob + $p
    $userName = $persist + 8 + 2 * $p
    return @{ Type = 4; TargetName = 8; Comment = 8 + $p; BlobSize = $blobSize; Blob = $blob; Persist = $persist; UserName = $userName; Size = $userName + $p }
}

# Where a password may be typed: kept in the credential's comment as "program|title part"
function ConvertTo-FujiSecretPlace {
    param([AllowEmptyString()][string]$Program, [AllowEmptyString()][string]$Window)
    return (([string]$Program).Trim().Replace('|', '') + '|' + ([string]$Window).Trim())
}

function ConvertFrom-FujiSecretPlace {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $t = [string]$Text
    $i = $t.IndexOf('|')
    if ($i -lt 0) { return @{ Program = ''; Window = '' } }
    return @{ Program = $t.Substring(0, $i); Window = $t.Substring($i + 1) }
}

# A password goes only into the window it was registered for: the window in front must have the
# registered text in its title AND belong to the registered program, compared by the full path of
# its .exe (a title is easy to imitate, a program name too: a copy of notepad.exe renamed app.exe)
function Test-FujiSecretPlace {
    param([hashtable]$Foreground, [AllowEmptyString()][string]$Program, [AllowEmptyString()][string]$Window)
    if (-not $Window -or -not $Program -or $null -eq $Foreground) { return $false }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    if (([string]$Foreground.Title).IndexOf($Window, $ic) -lt 0) { return $false }
    return [string]::Equals([string]$Foreground.Program, $Program, $ic)
}

# @{ User; Password; Program; Window } or $null when nothing is registered under Target
function Read-FujiCredential {
    param([Parameter(Mandatory)][string]$Target)
    $t = Get-FujiCredNativeType
    $out = New-Object -TypeName 'IntPtr[]' -ArgumentList 1
    if (-not $t::CredReadW($script:FujiCredPrefix + $Target, [uint32]$script:FujiCredLimits.Type, [uint32]0, $out)) { return $null }
    $ptr = $out[0]
    try {
        $l = Get-FujiCredLayout
        $user = [System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $l.UserName))
        $size = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr, $l.BlobSize)
        $password = ''
        if ($size -gt 0) {
            $bytes = New-Object -TypeName 'byte[]' -ArgumentList $size
            [System.Runtime.InteropServices.Marshal]::Copy([System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $l.Blob), $bytes, 0, $size)
            $password = [System.Text.Encoding]::Unicode.GetString($bytes)
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        $place = ConvertFrom-FujiSecretPlace ([System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $l.Comment)))
        return @{ User = [string]$user; Password = $password; Program = $place.Program; Window = $place.Window }
    } finally {
        $t::CredFree($ptr)
    }
}

# Account: the user name (may be empty). Secret: the password; its characters go from the
# SecureString's own unmanaged copy straight to Windows and that copy is wiped afterwards.
# Program / Window: the only window it may be typed into (Test-FujiSecretPlace).
function Write-FujiCredential {
    param([Parameter(Mandatory)][string]$Target, [AllowEmptyString()][string]$Account, [Parameter(Mandatory)][System.Security.SecureString]$Secret,
        [AllowEmptyString()][string]$Program = '', [Parameter(Mandatory)][string]$Window)
    $bytes = $Secret.Length * 2
    if ($bytes -gt $script:FujiCredLimits.MaxBlobBytes) { throw (Get-FujiText 'cred.tooLong') }
    $l = Get-FujiCredLayout
    $m = [System.Runtime.InteropServices.Marshal]
    $cred = $m::AllocHGlobal($l.Size)
    $name = $m::StringToHGlobalUni($script:FujiCredPrefix + $Target)
    $userPtr = $m::StringToHGlobalUni($Account)
    $comment = $m::StringToHGlobalUni((ConvertTo-FujiSecretPlace -Program $Program -Window $Window))
    $blob = $m::SecureStringToGlobalAllocUnicode($Secret)
    try {
        for ($i = 0; $i -lt $l.Size; $i++) { $m::WriteByte($cred, $i, 0) }
        $m::WriteInt32($cred, $l.Type, $script:FujiCredLimits.Type)
        $m::WriteIntPtr($cred, $l.TargetName, $name)
        $m::WriteIntPtr($cred, $l.Comment, $comment)
        $m::WriteInt32($cred, $l.BlobSize, $bytes)
        $m::WriteIntPtr($cred, $l.Blob, $blob)
        $m::WriteInt32($cred, $l.Persist, $script:FujiCredLimits.Persist)
        $m::WriteIntPtr($cred, $l.UserName, $userPtr)
        if (-not (Get-FujiCredNativeType)::CredWriteW($cred, [uint32]0)) { throw (Get-FujiText 'cred.writeFailed') }
    } finally {
        $m::ZeroFreeGlobalAllocUnicode($blob)
        $m::FreeHGlobal($comment)
        $m::FreeHGlobal($userPtr)
        $m::FreeHGlobal($name)
        $m::FreeHGlobal($cred)
    }
}

function Remove-FujiCredential {
    param([Parameter(Mandatory)][string]$Target)
    return [bool](Get-FujiCredNativeType)::CredDeleteW($script:FujiCredPrefix + $Target, [uint32]$script:FujiCredLimits.Type, [uint32]0)
}
