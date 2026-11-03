<#
    Downloads llama.cpp (CPU build) and the candidate models for the LLM comparison into -Dir
    (default C:\llm), from the official places only, and checks each file against the SHA-256 the
    publisher lists (GitHub release digest, Hugging Face LFS id). Files already there and matching
    are kept. Gemma needs its terms accepted on Hugging Face, so it is not fetched here.
#>
param([string]$Dir = 'C:\llm')
$ErrorActionPreference = 'Stop'
$files = @(
    @('llama-b12063-bin-win-cpu-arm64.zip', 'https://github.com/ggml-org/llama.cpp/releases/download/b12063/llama-b12063-bin-win-cpu-arm64.zip', 'f43d15a78ebac6d7ce96cb16a75469c094cfc328684b3889396bac26447749d4'),
    @('llama-b12063-bin-win-cpu-x64.zip', 'https://github.com/ggml-org/llama.cpp/releases/download/b12063/llama-b12063-bin-win-cpu-x64.zip', '4e3766c32a517cdd66ea28f57c862d6b83582ba5d1354f9db585b34f7ad8cf62'),
    @('Qwen3-0.6B-Q8_0.gguf', 'https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf', '9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031'),
    @('Qwen3-1.7B-Q8_0.gguf', 'https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf', '061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a'),
    @('tinyswallow-1.5b-instruct-q5_k_m.gguf', 'https://huggingface.co/SakanaAI/TinySwallow-1.5B-Instruct-GGUF/resolve/main/tinyswallow-1.5b-instruct-q5_k_m.gguf', '85aab0b1776d358eb04e79f47af7856f21ffc60514dad072c97debb94b7782f2'),
    @('LFM2.5-1.2B-JP-Q4_K_M.gguf', 'https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP-GGUF/resolve/main/LFM2.5-1.2B-JP-Q4_K_M.gguf', '608beed14e975a4edd8932c42ac3e64cf1c97da4ee2c5f2c7b6bfbcdb1a90680')
)
New-Item -ItemType Directory -Force $Dir | Out-Null
foreach ($f in $files) {
    $path = Join-Path $Dir $f[0]
    if ((Test-Path $path) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $f[2]) { "kept $($f[0])"; continue }
    & curl.exe -sSfL -o $path $f[1]
    if ($LASTEXITCODE -ne 0) { throw "download failed: $($f[0])" }
    $h = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($h -ne $f[2]) { Remove-Item $path; throw "SHA-256 mismatch: $($f[0]) $h" }
    "ok $($f[0]) $((Get-Item $path).Length)"
}
$bin = Join-Path $Dir 'bin-arm64'
if (-not (Test-Path (Join-Path $bin 'llama-server.exe'))) { Expand-Archive -Force (Join-Path $Dir 'llama-b12063-bin-win-cpu-arm64.zip') $bin }
'llama-server: ' + (Test-Path (Join-Path $bin 'llama-server.exe'))
