# Local LLM VRAM optimization - measurements and implementation

Target: `gemma-4-31B-it-ARA-heretic.Q2_K.gguf` (30.7B params, Q2_K, 11.09 GiB)
Hardware: RTX 5060 Ti 16 GB, sharing the GPU with ComfyUI (8.7 GB), dwm (3.5 GB),
Topaz Video and Brave.

## 1. Where the VRAM goes (measured)

`server.log` memory breakdown with all 60 layers on the GPU:

| Component | Measured |
|---|---|
| model buffer (CUDA0) | 11349 MiB |
| KV cache, full attention (10 layers) | 640 MiB |
| KV cache, sliding window (50 layers, 1536 cells) | 1200 MiB |
| compute buffer | 177 MiB |
| **total** | **13366 MiB** |

The loader leaves 1805 MiB headroom. On a 16 GB card that is already competing
with other GPU users, so the model does not fit unless something is released.

## 2. What actually reduced it (all measured)

### 2-1. KV cache f16 to q8_0 - measured -862.5 MiB

Ollama passes `--cache-type-k/-v q8_0` to llama-server when
`OLLAMA_KV_CACHE_TYPE=q8_0` is set. The quantisation only takes effect when
flash attention is on; with `--flash-attn auto` the cache stays f16.

| KV cache | f16 | q8_0 |
|---|---|---|
| full (10 layers, 8192 cells) | 640.0 MiB | 340.0 MiB |
| sliding window (50 layers, 1536 cells) | 1200.0 MiB | 637.5 MiB |
| total | 1840.0 MiB | 977.5 MiB |

Measured log lines with q8_0 active:

```
llama_kv_cache: size =  340.00 MiB ( 8192 cells, 10 layers), K (q8_0): 170.00 MiB
llama_kv_cache: size =  637.50 MiB ( 1536 cells, 50 layers), K (q8_0): 318.75 MiB
```

### 2-2. Moving layers to the CPU - measured -3241 MiB, at a speed cost

`-ngl 42` (42 of 60 layers on the GPU):

| Component | all 60 on GPU | -ngl 42 |
|---|---|---|
| CUDA0 model buffer | 11349 MiB | 8107.7 MiB |
| KV q8_0 | 977.5 MiB | 671.5 MiB |
| compute | 177 MiB | 242.9 MiB |
| **GPU total** | **~12504 MiB** | **~9038 MiB** |

Without `--fit off`, the layer count is overridden and everything falls back to
the CPU (measured: `CPU_REPACK model buffer size = 5684 MiB`). A standalone
launch also needs the same `PATH` and `GGML_BACKEND_PATH` Ollama sets, otherwise
it reports `no usable GPU found` and runs CPU-only.

### 2-3. Unload right after use - measured 4407 MiB before, 4401 MiB after

`BRIDGE_KEEP_ALIVE=0` unloads the model as soon as a reply is produced.

## 3. Files

| File | Role |
|---|---|
| `ollama-bridge.mjs` | OpenAI-compatible to Ollama native conversion plus VRAM control (context cap, keep-alive, idle unload, VRAM floor, `/vram`) |
| `start-ollama-bridge.cmd` | starts the bridge with `BRIDGE_KEEP_ALIVE=0`, `BRIDGE_VRAM_FLOOR=2048`, `BRIDGE_NUM_CTX=8192` |
| `start-ollama-optimized.cmd` | starts Ollama with `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0` and the related limits |
| `start-llama-vram.ps1` | starts llama-server directly so `-ngl` can set the layer split |

## 4. `/vram` endpoint

```
GET http://127.0.0.1:8801/vram
{"numCtxCap":8192,"vramFloorMiB":2048,"gpuPeers":["python","ffmpeg","topaz video","brave"],
 "keepAliveSeconds":0,"idleUnloadSeconds":300,"idleForSeconds":6,
 "modelNeedMiB":13500,"freeVramMiB":12220,"loaded":[]}
```

## 5. Pitfalls found by measurement

- Ollama reads its environment when the server starts. If an older server
  process is still alive, the new values are ignored; `start-ollama-optimized.cmd`
  stops the running server first.
- `require()` is not available inside this ESM bridge. Using it inside
  `freeVramMiB` made `/vram` hang; `execFile` is now imported at module scope.
- Throughput is dominated by VRAM contention. With ComfyUI holding 8.7 GB,
  134 tokens took 228 s; with the GPU free, Ollama's full offload reached about
  4 tokens/s.
