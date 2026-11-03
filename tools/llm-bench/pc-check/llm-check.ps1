<#
    LLM check on a work PC: can llama.cpp (x64 CPU build) run here, and with which CPU support.
    Put llm-check.bat, llm-check.ps1 and llama_x64_01.txt .. llama_x64_NN.txt in one folder and
    double-click llm-check.bat. The parts are joined, checked against the SHA-256 below, unpacked
    into .\llama-x64 and started with --version and --list-devices. Nothing outside this folder is
    changed. The report is written to llm-check-result.txt (copy its text back).
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$expect = '4e3766c32a517cdd66ea28f57c862d6b83582ba5d1354f9db585b34f7ad8cf62'
$out = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $out.Add($s); Write-Host $s }
Say ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$os = Get-CimInstance Win32_OperatingSystem
Say ('os: ' + $os.Caption + ' ' + $os.Version + ' ' + $os.OSArchitecture)
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Say ('cpu: ' + $cpu.Name + ' / cores ' + $cpu.NumberOfCores + ' / threads ' + $cpu.NumberOfLogicalProcessors)
Say ('memory GB: ' + [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1) + ' (free ' + [Math]::Round($os.FreePhysicalMemory / 1MB, 1) + ')')
Add-Type -Name K -Namespace LlmCheck -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f);'
# winnt.h: 10 SSE3, 39 AVX, 40 AVX2, 41 AVX512F
Say ('cpu features: AVX=' + [LlmCheck.K]::IsProcessorFeaturePresent(39) + ' AVX2=' + [LlmCheck.K]::IsProcessorFeaturePresent(40) + ' AVX512F=' + [LlmCheck.K]::IsProcessorFeaturePresent(41))
foreach ($d in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    $p = Join-Path $env:windir ('System32\' + $d)
    if (Test-Path $p) { Say ('runtime ' + $d + ': ' + (Get-Item $p).VersionInfo.FileVersion) } else { Say ('runtime ' + $d + ': MISSING') }
}
$parts = @(Get-ChildItem -LiteralPath $here -Filter 'llama_x64_*.txt' | Sort-Object Name)
Say ('parts: ' + $parts.Count)
if ($parts.Count -eq 0) { Say 'STOP: no llama_x64_NN.txt here'; [IO.File]::WriteAllLines((Join-Path $here 'llm-check-result.txt'), $out); return }
$sb = New-Object System.Text.StringBuilder
foreach ($p in $parts) { [void]$sb.Append(([IO.File]::ReadAllText($p.FullName) -replace '\s', '')) }
try { $bytes = [Convert]::FromBase64String($sb.ToString()) } catch { Say ('STOP: base64 broken (' + $_.Exception.Message + ')'); [IO.File]::WriteAllLines((Join-Path $here 'llm-check-result.txt'), $out); return }
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
Say ('zip sha256: ' + $sha + ' ' + $(if ($sha -eq $expect) { 'OK' } else { 'MISMATCH (a part is missing or cut short)' }))
if ($sha -ne $expect) { [IO.File]::WriteAllLines((Join-Path $here 'llm-check-result.txt'), $out); return }
$zip = Join-Path $here 'llama-x64.zip'
[IO.File]::WriteAllBytes($zip, $bytes)
$dir = Join-Path $here 'llama-x64'
try { Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force; Say 'unpacked: OK' } catch { Say ('STOP: unpack failed (' + $_.Exception.Message + ')'); [IO.File]::WriteAllLines((Join-Path $here 'llm-check-result.txt'), $out); return }
$exe = Join-Path $dir 'llama-server.exe'
foreach ($a in @('--version', '--list-devices')) {
    $o = Join-Path $here 'run_out.txt'
    $e = Join-Path $here 'run_err.txt'
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $a -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
        Say ("run $a : exit 0x{0:X}" -f $p.ExitCode)
        foreach ($l in (@(Get-Content $o) + @(Get-Content $e) | Where-Object { $_.Trim() } | Select-Object -First 12)) { Say ('  ' + $l) }
    } catch { Say ("run $a : could not start (" + $_.Exception.Message + ')') }
}
Say 'notes: exit 0xC0000135 = a DLL is missing (Visual C++ runtime); 0xC000001D = CPU instruction not supported; "could not start" = blocked by policy or antivirus'
[IO.File]::WriteAllLines((Join-Path $here 'llm-check-result.txt'), $out)
Say ('wrote ' + (Join-Path $here 'llm-check-result.txt'))
