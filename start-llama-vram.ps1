# Launch llama-server with an explicit GPU-layer split for a VRAM budget.
#
# Measured on this machine with gemma-4-31B Q2_K (60 layers, RTX 5060 Ti 16 GB):
#   model weights on GPU : 11349 MiB for all 60 layers  -> ~189 MiB per layer
#   KV q8_0 ctx 8192     : 340 MiB (10 full layers) + 637.5 MiB (50 SWA layers)
#   compute              : ~180 MiB
#
# Ollama always offloads every layer, so a partial split is only possible by
# running llama-server directly. The CUDA backend DLLs are not on PATH for a
# plain launch - Ollama itself sets PATH + GGML_BACKEND_PATH before spawning,
# and the same is required here (otherwise: "no usable GPU found").

param(
  [int]$GpuLayers = 42,
  [int]$Ctx = 8192,
  [int]$Port = 8810
)

$lib  = 'C:\Users\ussoe\AppData\Local\Programs\Ollama\lib\ollama'
$cuda = Join-Path $lib 'cuda_v13'
$exe  = Join-Path $lib 'llama-server.exe'
$blob = 'C:\Users\ussoe\.ollama\models\blobs\sha256-d2309a709dc4b3aa1caeac59fbe749ab7e9bb77ef35086524f0b7d67e78c5b75'
$out  = 'D:\USERFILES\GitHub\moonshot-shim\llama-server-vram.log'

# Same library resolution Ollama uses for its own runner processes.
$env:PATH = "$lib;$cuda;$env:PATH"
$env:GGML_BACKEND_PATH = (Get-ChildItem $cuda -Filter 'ggml-cuda.dll' | Select-Object -First 1).FullName
$env:CUDA_VISIBLE_DEVICES = '0'

$args = @(
  '--model', $blob,
  '--port', "$Port",
  '--host', '127.0.0.1',
  '--no-webui',
  '--offline',
  '-c', "$Ctx",
  '-np', '1',
  '-ngl', "$GpuLayers",
  '--fit', 'off',
  '--cache-type-k', 'q8_0',
  '--cache-type-v', 'q8_0',
  '--flash-attn', 'on',
  '-b', '512',
  '-ub', '512',
  '--log-verbosity', '4',
  '--no-log-prefix',
  '--no-log-timestamps'
)

Write-Host "llama-server: port=$Port ctx=$Ctx gpuLayers=$GpuLayers (KV q8_0, fit off)"
Start-Process -FilePath $exe -ArgumentList $args -RedirectStandardOutput "$out.out" -RedirectStandardError $out -WindowStyle Hidden
