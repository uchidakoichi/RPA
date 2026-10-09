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
    $tb = $module.DefineType('FujiNative.User32', [System.Reflection.TypeAttributes]'Public, Class, Abstract, Sealed')
    # name, return type, parameter types, character set
    $declarations = @(
        @('SetProcessDPIAware', [bool], [type[]]@(), [System.Runtime.InteropServices.CharSet]::Auto),
        @('SendMessage', [IntPtr], [type[]]@([IntPtr], [int], [IntPtr], [string]), [System.Runtime.InteropServices.CharSet]::Unicode)
    )
    foreach ($d in $declarations) {
        $m = $tb.DefinePInvokeMethod($d[0], 'user32.dll',
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl, HideBySig',
            [System.Reflection.CallingConventions]::Standard, $d[1], $d[2],
            [System.Runtime.InteropServices.CallingConvention]::Winapi, $d[3])
        $m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    }
    $script:FujiNative = $tb.CreateType()
    return $script:FujiNative
}
