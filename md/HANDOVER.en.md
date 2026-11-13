# Handover - moonshot-shim session state

Last updated: 2026-11-13 (session closed with a successful connection test).
Repository: `D:\USERFILES\GitHub\moonshot-shim`, `main = origin/main = 294c5e9`.
Everything below was measured on this machine in this session unless marked otherwise.

## 1. Relays currently running

Ten processes, all answering `/healthz` with `ok` at handover time:

| Port | Model line | Launcher | Upstream |
|---|---|---|---|
| 8789 | Z.ai GLM | `start-shim-zai.ps1` | `https://api.z.ai/api/coding/paas/v4` |
| 8793 | go-GLM-5.3-Flash | `start-shim-opencode-glm.ps1` | `https://opencode.ai/zen/go/v1` |
| 8794 | go-Kimi (kimi-k3.1-pro) | `start-shim-opencode-kimi.ps1` | `https://opencode.ai/zen/go/v1` |
| 8795 | go-qwen3.8-flash | `start-shim-opencode-qwen.ps1` | `https://opencode.ai/zen/go/v1` |
| 8796 | go-GLM-5.3 | `start-shim-opencode-glm53.ps1` | `https://opencode.ai/zen/go/v1` |
| 8797 | Z.ai GLM-5.3-Flash low | `start-shim-zai-low.ps1` | `https://api.z.ai/api/coding/paas/v4` |
| 8798 | go-deepseek-v4.1-flash | `start-shim-opencode-dsv41-flash.ps1` | `https://opencode.ai/zen/go/v1` |
| 8800 | go-minimax-m3.1-flash | `start-shim-opencode-minimax31.ps1` | `https://opencode.ai/zen/go/v1` |
| 8801 | local Ollama gemma4 | `start-ollama-bridge.cmd` (runs `ollama-bridge.mjs`) | `http://127.0.0.1:11434/v1` via native `/api/chat` |
| 8802 | go-beam-free | `start-shim-beam-free.ps1` | `https://opencode.ai/zen/go/v1` |

`start-shim-hidden.vbs` starts the relays hidden at logon. Registered lines at handover:
the eight original lines, the img-mcp server, `start-ollama-bridge.cmd` (line 31),
`start-shim-beam-free.cmd` (line 32).

## 2. Work done in this session

### 2-1. Local GGUF served through the shim (port 8801)

`D:\USERFILES\GitHub\moonshot-shim\llm\gemma-4-31B-it-ARA-heretic.Q2_K.gguf`
(11.9 GB, gemma4 arch, 60 layers, 30.7B params) was imported into Ollama:

```
ollama create gemma4-31b-ara-heretic -f llm/Modelfile.gemma4-ara
```

Ollama 0.40.16 serves it, but its own `/v1` OpenAI-compatible layer mangles
gemma4 responses: content came back empty while the native `/api/chat` answer was
correct. `ollama-bridge.mjs` was written to convert OpenAI requests to the native
API and back:

- request mapping: `max_tokens` to `options.num_predict`, `temperature`/`top_p`/`stop` to `options.*`, plus a `num_ctx` cap
- response mapping: `message.thinking` to `reasoning_content`, `message.tool_calls` to OpenAI tool calls
- streaming: Ollama NDJSON to OpenAI SSE
- measured: `POST /v1/chat/completions` returned `200` with `content=GEMMA4-BRIDGE-TEST`

Two bugs were found and fixed in that file:

1. the handler read `openaiBody` while the parsed variable was named `openai` (requests hung)
2. `require('node:child_process')` inside an ESM module left the `/vram` handler unresolved; `execFile` is now imported at module scope

### 2-2. VRAM measurements for the local model

All from `server.log` and live runs on the RTX 5060 Ti 16 GB.

Model fully offloaded (Ollama default):

| Component | Measured |
|---|---|
| model buffer CUDA0 | 11349 MiB |
| KV f16, ctx 8192 (10 full + 50 SWA layers) | 640 + 1200 = 1840 MiB |
| compute buffer | 177 MiB |
| total | 13366 MiB |

KV quantisation to q8_0 needs flash attention on:

| KV | f16 | q8_0 |
|---|---|---|
| full (10 layers, 8192 cells) | 640.0 MiB | 340.0 MiB |
| sliding window (50 layers, 1536 cells) | 1200.0 MiB | 637.5 MiB |
| total | 1840.0 MiB | 977.5 MiB |

Scaling with context (derived from the measured ctx-8192 split):

| ctx | f16 | q8_0 | saved |
|---|---|---|---|
| 4096 | 1520 MiB | 808 MiB | 712 MiB |
| 8192 | 1840 MiB | 978 MiB | 862 MiB |
| 16384 | 2480 MiB | 1318 MiB | 1162 MiB |
| 32768 | 3760 MiB | 1998 MiB | 1762 MiB |
| 65536 | 6320 MiB | 3358 MiB | 2962 MiB |

Layer split with a standalone `llama-server` (`-ngl 42 --fit off`):

| Component | all 60 on GPU | -ngl 42 |
|---|---|---|
| CUDA0 model buffer | 11349 MiB | 8107.7 MiB |
| KV q8_0 | 977.5 MiB | 671.5 MiB |
| compute | 177 MiB | 242.9 MiB |
| GPU total | ~12504 MiB | ~9038 MiB |

Without `--fit off` the layer count is ignored and everything lands on the CPU
(measured `CPU_REPACK model buffer size = 5684 MiB`). A standalone launch also
needs `PATH` plus `GGML_BACKEND_PATH` pointing at `lib\ollama\cuda_v13`,
otherwise it reports `no usable GPU found` and runs CPU-only.

Throughput is dominated by VRAM contention, not by the kernel: with ComfyUI
holding 8.7 GB, 134 tokens took 228 s. ComfyUI (python, 8714 MiB), dwm
(3557 MiB), Topaz Video and Brave all hold the GPU at the same time.

### 2-3. VRAM-first controls in the bridge

`ollama-bridge.mjs` now carries, all env-tunable:

| Variable | Default | Effect |
|---|---|---|
| `BRIDGE_NUM_CTX` | 8192 | hard cap on `options.num_ctx` per request |
| `BRIDGE_KEEP_ALIVE` | 120 | seconds the model stays resident; `0` unloads right after each reply |
| `BRIDGE_IDLE_UNLOAD` | 300 | seconds of bridge idleness before the model is unloaded |
| `BRIDGE_VRAM_FLOOR` | 2048 | if free VRAM drops below this while a peer GPU app runs, release the model |
| `BRIDGE_GPU_PEERS` | `python,ffmpeg,Topaz Video,brave` | processes whose presence triggers the floor check |

`start-ollama-bridge.cmd` launches it with `BRIDGE_KEEP_ALIVE=0`,
`BRIDGE_VRAM_FLOOR=2048`, `BRIDGE_NUM_CTX=8192`.

`GET /vram` reports the settings plus live state:

```
{"numCtxCap":8192,"vramFloorMiB":2048,"gpuPeers":["python","ffmpeg","topaz video","brave"],
 "keepAliveSeconds":0,"idleUnloadSeconds":300,"idleForSeconds":338,
 "modelNeedMiB":13500,"freeVramMiB":3467,"loaded":[]}
```

Measured with keep-alive 0: VRAM 4407 MiB before a request, 4401 MiB after, and
`ollama ps` empty.

### 2-4. Ollama environment handling

Ollama reads its environment only when the server starts, so a live server keeps
old values. `start-ollama-optimized.cmd` stops any running server, sets
`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`,
`OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=120s`,
`OLLAMA_CONTEXT_LENGTH=8192` in its own process, then starts `ollama serve`.

Measured after that restart: `--flash-attn on` and
`--cache-type-k q8_0 --cache-type-v q8_0` appear on the llama-server command
line. Before the restart they were `auto` and absent.

An old launcher (`start-shim-ollama-gemma4.ps1`) was in a restart loop that kept
grabbing port 8801 (411 attempts in its wrapper log). It was stopped.

### 2-5. FA2 investigation

Findings, all measured or read from the binaries:

- llama.cpp's own FA lives in `cuda_v13\ggml-cuda.dll` (139.6 MB, contains
  `fattn_kernel`). The shipped build has `ARCHS = 750,800,860,890,1000,1200`, so
  the sm_120 Blackwell path is compiled in, and `flash_attn = enabled` is reported
  at load.
- `llama_server` dispatches through `ampere_mma_available(cc)` for sm_80 and above,
  i.e. the tensor-core online-softmax kernel.
- The Dao-AILab `flash_attn` package (2.9.2.post2, installed in
  `D:\USERFILES\ComfyUI\python_embeded`) does work on this card: a
  `(1,2048,32,128)` fp16 call returned finite output in 7.22 ms, against 12.38 ms
  for torch SDPA's flash backend and 22.44 ms for the efficient backend.
- That package cannot be used for this model: `transformers 5.22.2` fails to build
  a config from the GGUF because `num_key_value_heads` is a per-layer list
  (`[16,16,16,16,16,4,...]`), and vLLM/SGLang go through the same path. vLLM and
  SGLang are not installed.
- The shim is a relay; it has no kernel of its own. Choosing FA2 means choosing
  which engine `SHIM_TARGET` points at.

Build prerequisites measured as present: nvcc 13.4.92, MSVC 14.44.35207
(VS2022 Community), CMake 4.5.0-rc1, git 2.52.0, no Ninja, 65.7 GB free on D:,
llama.cpp source not yet fetched.

Plan written to `md/FA2_IMPLEMENTATION_PLAN.en.md`.

### 2-6. Go and Zen catalogs

`GET /v1/models` through 8794 returns 30 ids (Go catalog). Ids ending in `-free`:
`beam-free`, `iceman-contributor-free`, `longcat-2.5-free`.

Via the shim, a chat request without a key returns
`401 OpenCode Go requires an API key`, because the shim forwards the client's
`Authorization` upstream.

OpenCode Go page, read this session:

| Model | Requests / 5h | Monthly cap | Training | Retention |
|---|---|---|---|---|
| Beam Free | unbounded | unbounded | not used | 30 days |
| Iceman Contributor Free | unbounded | unbounded | **used** | not ZDR |
| LongCat 2.5 Free | not in the limit table | - | - | - |

The owner is on Go Plus ($40/month).

`mimo-v2.6-flash-free` exists only on Zen. A direct Zen request (no shim) returned
in 0.5 s:

```
429 {"error":{"type":"FreeUsageLimitError","message":"Free usage limit reached. ..."}}
```

so the Zen free allowance is used up for this account. The Zen relay built for it
was removed again at the owner's instruction (commits `0e0ea8c` added, `a886a14`
removed).

### 2-7. beam-free relay (port 8802)

`start-shim-beam-free.ps1` / `.cmd`: `SHIM_TARGET=https://opencode.ai/zen/go/v1`,
`SHIM_FORCE_MODEL=beam-free`, loopback only, tail redaction on, no thinking
injection. `SHIM_FORCE_MODEL` rewrites the request body's `model` (server.js
L943-944) and advertises the id in `/v1/models` (L1076).

Registered in `start-shim-hidden.vbs` at line 32 for logon start.

## 3. Commit log from this session

| Commit | Summary |
|---|---|
| `0794c32` | add `ollama-bridge.mjs` (OpenAI to Ollama native conversion) |
| `4bbc144` | auto-start the bridge at logon; persist VRAM env vars |
| `37195fc` | VRAM-first control in the bridge, `start-ollama-optimized.cmd`, `start-llama-vram.ps1`, measured figures in `md/OLLAMA_VRAM_OPTIMIZATION.en.md` |
| `8332c10` | `md/FA2_IMPLEMENTATION_PLAN.en.md` |
| `0e0ea8c` | (later removed) Zen free-model relay on 8802 |
| `a886a14` | remove the Zen relay |
| `79d0268` | add the beam-free relay on 8802 |
| `294c5e9` | auto-start the beam-free relay at logon |

Earlier in the session the repository history was rewritten so that 22 commits
recorded as `zwork <zwork@local>` became
`ussoewwin <136552381+ussoewwin@users.noreply.github.com>`, and the backup refs
were dropped. `origin/main` now has 97 commits, all under the owner's identity.

## 4. Traps that cost time

- The shell environment carries `GIT_AUTHOR_NAME=zwork` and the matching
  committer variables. They override the repository config, so a commit lands as
  `zwork` unless those variables are removed first.
- Ollama ignores environment changes while a server is running; stop the server
  first.
- `require()` does not exist inside `ollama-bridge.mjs` (ESM). Using it left the
  handler unresolved instead of throwing.
- The shim's 429 absorption (`SHIM_RETRY_429`, default on, 30 s base delay,
  4 attempts) makes a rate-limited upstream look like a hang. Set
  `SHIM_RETRY_429=0` on relays where the 429 itself is the answer.
- A standalone `llama-server` needs Ollama's library environment, otherwise it
  silently runs on the CPU.
- Writing files under `D:\USERFILES\...` from the workspace requires `exec`;
  the write tool is limited to the workspace.
- Japanese text stays out of repository documents. `.gitignore` ignores `*.md`
  except `*.en.md`, `README.md`, `MCP.md` and `md/CHANGELOG.md`.

## 5. Open items

- The llama.cpp build itself has not been started. Plan is in
  `md/FA2_IMPLEMENTATION_PLAN.en.md`; option A (replace the runner DLLs inside
  Ollama) versus option B (standalone `llama-server` on 8810 plus a dedicated shim)
  is still undecided.
- Whether Beam Free produces usable code output has not been tested: every chat
  request from this side stops at the 401 because the client key is not present
  in the shim.
- ComfyUI currently runs with `--use-sage-attention`; switching it to
  `--use-flash-attention` was not done.
- Untracked leftovers in the repository working tree: `README.md.20260910-*.bak`,
  `restart-ollama-optimized.cmd`, `start-ollama-optimized.cmd` (tracked),
  `shim-wrapper-opencode.log.retired-*`, `start-shim-hidden.vbs.20260910-*`,
  `start-shim-opencode.*.retired-*`.
