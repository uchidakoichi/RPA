# ---------------------------------------------------------------------------------------------
#  Windows API functions without a C# compiler
#  Add-Type with C# source starts csc.exe on Windows PowerShell 5.1, which takes seconds (more
#  when antivirus checks it) on every start. The same declarations are made here at run time
#  with System.Reflection.Emit (DefinePInvokeMethod): nothing is compiled or written to disk.
# ---------------------------------------------------------------------------------------------

$script:FujiNative = $null

# The type holding the functions: [type] with static methods, e.g. ($t)::SetProcessDPIAware()
function Get-FujiNativeType {
    if ($null -ne $script:FujiNative) { return $script:FujiNative }
    $name = New-Object -TypeName System.Reflection.AssemblyName -ArgumentList 'FujiNative'
    $asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $asm.DefineDynamicModule('FujiNative')
    $tb = $module.DefineType('FujiNative.Win32', [System.Reflection.TypeAttributes]'Public, Class, Abstract, Sealed')
    # library, name, return type, parameter types, character set
    $u = 'user32.dll'
    $auto = [System.Runtime.InteropServices.CharSet]::Auto
    $wide = [System.Runtime.InteropServices.CharSet]::Unicode
    $declarations = @(
        @($u, 'SetProcessDPIAware', [bool], [type[]]@(), $auto),
        @($u, 'SendMessage', [IntPtr], [type[]]@([IntPtr], [int], [IntPtr], [string]), $wide),
        @($u, 'GetAsyncKeyState', [int16], [type[]]@([int]), $auto),
        @($u, 'FindWindowEx', [IntPtr], [type[]]@([IntPtr], [IntPtr], [string], [string]), $wide),
        @($u, 'GetWindowTextLength', [int], [type[]]@([IntPtr]), $wide),
        @($u, 'GetWindowText', [int], [type[]]@([IntPtr], [System.Text.StringBuilder], [int]), $wide),
        @($u, 'IsWindowVisible', [bool], [type[]]@([IntPtr]), $auto),
        @($u, 'IsIconic', [bool], [type[]]@([IntPtr]), $auto),
        @($u, 'ShowWindow', [bool], [type[]]@([IntPtr], [int]), $auto),
        @($u, 'SetForegroundWindow', [bool], [type[]]@([IntPtr]), $auto),
        @($u, 'GetForegroundWindow', [IntPtr], [type[]]@(), $auto),
        @($u, 'BringWindowToTop', [bool], [type[]]@([IntPtr]), $auto),
        @($u, 'GetWindowThreadProcessId', [uint32], [type[]]@([IntPtr], [IntPtr]), $auto),
        @($u, 'AttachThreadInput', [bool], [type[]]@([uint32], [uint32], [bool]), $auto),
        @($u, 'keybd_event', [void], [type[]]@([byte], [byte], [uint32], [UIntPtr]), $auto),
        @($u, 'SetCursorPos', [bool], [type[]]@([int], [int]), $auto),
        @($u, 'mouse_event', [void], [type[]]@([uint32], [uint32], [uint32], [uint32], [UIntPtr]), $auto),
        # rect: int[4] left, top, right, bottom (a blittable array is pinned, so it is filled in)
        @($u, 'GetWindowRect', [bool], [type[]]@([IntPtr], [int[]]), $auto),
        @('kernel32.dll', 'GetCurrentThreadId', [uint32], [type[]]@(), $auto)
    )
    foreach ($d in $declarations) {
        $m = $tb.DefinePInvokeMethod($d[1], $d[0],
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl, HideBySig',
            [System.Reflection.CallingConventions]::Standard, $d[2], $d[3],
            [System.Runtime.InteropServices.CallingConvention]::Winapi, $d[4])
        $m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    }
    $script:FujiNative = $tb.CreateType()
    return $script:FujiNative
}

# The window a title means, the WScript AppActivate way: a title equal to it, else one starting
# with it, else one ending with it (case ignored). Windows: @(@{ Handle; Title }, ...). $null if none.
function Select-FujiWindow {
    param([AllowEmptyCollection()][object[]]$Windows, [AllowEmptyString()][string]$Title)
    if (-not $Title) { return $null }
    $ic = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($test in @('equal', 'start', 'end')) {
        foreach ($w in $Windows) {
            $t = [string]$w.Title
            $hit = $false
            switch ($test) {
                'equal' { $hit = [string]::Equals($t, $Title, $ic) }
                'start' { $hit = $t.StartsWith($Title, $ic) }
                'end' { $hit = $t.EndsWith($Title, $ic) }
            }
            if ($hit) { return $w }
        }
    }
    return $null
}
