# FA2 Implementation Plan - moonshot-shim local LLM path

Status: planning. Nothing in this document has been built or measured yet.
All figures below marked "measured" come from an earlier session; figures marked
"target" are goals, not results.

## 1. Problem

`moonshot-shim` forwards OpenAI-shaped requests to whatever `SHIM_TARGET` points
at. For the local model (`gemma-4-31B-it-ARA-heretic.Q2_K.gguf`, served by
Ollama), the attention kernel is chosen inside `llama.cpp`, not inside the shim.
The shim itself cannot choose a kernel; it can only choose which engine to talk
to.

Measured context for `gemma-4-31B` on the RTX 5060 Ti (16 GB):

| Component | Measured |
|---|---|
| model buffer on GPU (all 60 layers) | 11349 MiB |
| KV cache f16, ctx 8192 | 1840 MiB (640 full + 1200 sliding-window) |
| KV cache q8_0, ctx 8192 | 978 MiB (340 + 637.5) |
| compute buffer | 177 MiB |
| total, f16 | 13366 MiB |

KV memory scales with context, so longer contexts are where quantisation and a
faster attention kernel matter most:

| ctx | KV f16 | KV q8_0 | saved |
|---|---|---|---|
| 4096 | 1520 MiB | 808 MiB | 712 MiB |
| 8192 | 1840 MiB | 978 MiB | 862 MiB |
| 16384 | 2480 MiB | 1318 MiB | 1162 MiB |
| 32768 | 3760 MiB | 1998 MiB | 1762 MiB |
| 65536 | 6320 MiB | 3358 MiB | 2962 MiB |

(These are scaled from the measured ctx-8192 split; the sliding-window part is
fixed at 1536 cells and the full-attention part scales with ctx.)

## 2. What is already on the machine

Measured:

| Item | Value |
|---|---|
| nvcc | 13.4.92 (CUDA 13.4) |
| MSVC | 14.44.35207 (VS2022 Community) |
| CMake | 4.5.0-rc1 |
| git | 2.52.0 |
| Ninja | absent (use the VS generator) |
| GPU | RTX 5060 Ti, compute capability 12.0 (sm_120, Blackwell) |
| Free space on D: | 65.7 GB |
| llama.cpp source | not present |

Ollama 0.40.16 ships its own llama.cpp build:

| File | Size | Contains FA kernel |
|---|---|---|
| `llama-server.exe` | 23,944 B | wrapper only |
| `libllama.dll` | 3.9 MB | yes (fattn strings) |
| `llama-server-impl.dll` | 2.9 MB | no |
| `cuda_v13\ggml-cuda.dll` | 139.6 MB | yes (`fattn_kernel`) |

Measured startup log from that binary: `CUDA : ARCHS = 750,800,860,890,1000,1200`,
`llama_context: flash_attn = enabled`. The MMA kernel dispatches through
`ampere_mma_available(cc)` for sm_80 and above, so the card already runs the
tensor-core online-softmax path.

## 3. Why a build is still needed

The runtime already uses a flash-attention kernel. A local build is required for
the parts that Ollama does not expose:

1. `-fa on` as the default instead of `auto`, so KV quantisation is always active.
2. Control over `--cache-type-k/-v` on the server side rather than through Ollama's
   environment plumbing (Ollama only reads its environment at server start, which
   makes the setting easy to lose).
3. Access to `-ngl` layer splitting and `--fit off` in one place, so the VRAM
   budget can be tuned without negotiating with Ollama's scheduler.
4. A build we can instrument, so the actual kernel choice is provable rather than
   inferred from a log line.

## 4. Plan

### Step 1 - fetch the source

```
git clone https://github.com/ggml-org/llama.cpp D:\USERFILES\GitHub\llama.cpp
cd D:\USERFILES\GitHub\llama.cpp
git submodule update --init --recursive
```

### Step 2 - configure

```
cmake -B build -G "Visual Studio 17 2022" -A x64 ^
  -DGGML_CUDA=ON ^
  -DCMAKE_CUDA_ARCHITECTURES="120" ^
  -DLLAMA_CURL=OFF
```

`CMAKE_CUDA_ARCHITECTURES=120` is mandatory; without it the Blackwell FA kernel is
not compiled and the build falls back to a generic path.

### Step 3 - build

```
cmake --build build --config Release -j 12
```

Expected artefacts in `build\bin\Release\`: `llama-server.exe`, `llama-cli.exe`,
`ggml-cuda.dll`, `ggml-base.dll`, `llama.dll`.

Build time is unknown on this machine. Disk usage during the build is also
unknown; 65.7 GB free is the constraint to watch.

### Step 4 - verify the binary on its own, before touching Ollama

1. Run the new `llama-server.exe` against the GGUF blob directly, with the same
   library path setup Ollama uses (`PATH` plus `GGML_BACKEND_PATH` pointing at the
   CUDA backend directory), otherwise it reports `no usable GPU found` and runs
   CPU-only - this was measured earlier.
2. Confirm from its own log: `flash_attn = enabled`, `K (q8_0)` in the KV cache
   lines, and the CUDA0 buffer sizes.
3. Confirm the HTTP API answers on `/health` and `/v1/chat/completions`.

### Step 5 - decide the integration shape

Two options, to be chosen only after Step 4 passes:

**Option A - replace the runner DLLs inside Ollama.**
Copy the new DLLs over `...\Programs\Ollama\lib\ollama\` (and `cuda_v13\`).
Ollama's Go side keeps spawning `llama-server.exe`.

Risk: Ollama passes its own argument set. Measured from a live run:
`--no-jinja --chat-template chatml --log-verbosity 4 --no-log-prefix`.
A matching upstream build must still accept every one of them, and the ABI must
line up. A mismatch here breaks the whole local relay, not just one model.

**Option B - run the new llama-server as its own service on port 8810.**
Point a dedicated shim instance at it (`SHIM_TARGET=http://127.0.0.1:8810/v1`).
Ollama stays untouched for every other model.

Trade-off: an extra process to manage, but no risk to the Ollama installation and
full control over `-ngl`, `-fa`, `--cache-type-*`, and `--fit`.
`start-llama-vram.ps1` in this repository already covers this shape; it needs the
`-fa on` default and a wrapper that keeps it alive.

Option B is the safer path and matches what is already scripted here.

### Step 6 - wire the shim

A separate shim instance so the existing relays keep their current targets:

```
SHIM_PORT=8802
SHIM_TARGET=http://127.0.0.1:8810/v1
SHIM_LOOPBACK_ONLY=1
SHIM_REDACT_TAIL=1
```

No `SHIM_FORCE_THINKING` for this target: the local server handles the model's own
thinking format.

### Step 7 - measure and record

For each of ctx 8192 / 16384 / 32768, record:

- `llama_kv_cache: size = ... K (q8_0)` lines from the server log
- CUDA0 model / KV / compute buffer sizes
- tokens per second for a fixed prompt
- peak VRAM from `nvidia-smi`

Then compare against the Ollama baseline numbers in section 1 and write the
result into this document as a new section. No figure goes in without a log line
behind it.

## 5. Open questions

- Whether Ollama's argument set is accepted by a matching upstream build. Must be
  tested with the actual binary, not assumed.
- Actual build time and peak disk usage on this machine.
- Whether the `auto` to `on` default changes measured throughput at all, or only
  changes which KV type is allowed.

## 6. What this plan does not do

- It does not make the shim itself run FA2. The shim is a relay; the kernel lives
  in the inference engine.
- It does not use the Dao-AILab `flash_attn` package. That package needs a model
  loadable by transformers/vLLM, and `gemma4` fails there: `AutoConfig` rejects the
  per-layer KV head list (`num_key_value_heads` expected int, got list).
- It does not promise a speedup. The measured bottleneck so far is VRAM contention
  with ComfyUI (8.7 GB) and Topaz, not the attention kernel.
