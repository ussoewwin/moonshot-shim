# moonshot-shim

A tiny local HTTP proxy that lets any **OpenAI-compatible client** — AutoClaw, Cline, etc. — use **Moonshot's Kimi reasoning models** (`kimi-k2.x`, `kimi-k3`) with **tool calling**, while keeping the **context-cache hit rate** as high as possible.

```
client  ──►  http://127.0.0.1:8787/v1  ──►  https://api.moonshot.ai/v1
                    (this shim)
```

## Why it exists

Moonshot's reasoning models require a non-standard field, `reasoning_content`, on **every assistant message that carries `tool_calls`** in the conversation history. Standard OpenAI SDK / OpenAI-compatible clients drop that field, so the **turn after any tool call fails with `400`**:

```
400: thinking is enabled but reasoning_content is missing
     in assistant tool call message at index N
```

This shim sits in front of Moonshot and patches the outgoing request so multi-turn tool conversations keep working.

## What it does

- **`reasoning_content` injection** — injects a placeholder (`" "`) into any assistant `tool_calls` message whose `reasoning_content` is missing or empty. Moonshot's validation checks for the field's presence; the placeholder value is accepted.
- **Reasoning echo (cache-first)** — captures the *real* `reasoning_content` from Moonshot's responses and re-injects it verbatim into later turns instead of the placeholder. This keeps Moonshot's automatic prefix cache maximally hit and preserves the model's reasoning continuity across tool calls. Disable with `SHIM_REASONING_ECHO=0`.
- **Cache accounting** — parses Moonshot's usage block and logs the cache hit rate per request and per minute. Moonshot reports cache reads as a *top-level* `usage.cached_tokens` (not OpenAI's nested `prompt_tokens_details.cached_tokens`); thinking tokens appear under `completion_tokens_details.reasoning_tokens`.
- **Byte-stable forwarding** — re-serializes the request body with sorted object keys, so the bytes sent to Moonshot are deterministic regardless of the client's key order. Moonshot's implicit prefix cache keys on exact bytes, so any key-order drift would otherwise invalidate it.
- **Cache-break detection** — detects when the shared message history is edited or truncated between turns and logs a `[cache-break]` warning, making cache misses easy to diagnose.
- **Resilience** — retries transient upstream errors, keeps SSE streams alive with keepalive comments, and survives crashes.

## Requirements

- Node.js ≥ 20 (tested on Node 22)
- A [Moonshot](https://platform.moonshot.ai) API key

## Quick start

```bash
npm install        # installs undici
npm start          # node server.js → listens on 127.0.0.1:8787
```

On Windows, double-click `start-shim.cmd` (runs `start-shim.ps1`, which auto-restarts the process if it crashes). For logon auto-start, place `start-shim-hidden.vbs` in your `shell:startup` folder.

Check it's up:

```bash
curl http://127.0.0.1:8787/healthz
# {"status":"ok"}
```

## Point your client at the shim

Set your client's **OpenAI base URL** to `http://127.0.0.1:8787/v1`, and keep using your Moonshot API key.

- **AutoClaw** — model provider `baseUrl` → `http://127.0.0.1:8787/v1`
- **Cline / others** — override the base URL the same way.

No tunnel is required. The shim binds to `127.0.0.1` and is meant for a single machine.

## Configuration

All settings are environment variables:

| Variable | Default | Description |
|---|---|---|
| `SHIM_PORT` | `8787` | Listen port |
| `SHIM_HOST` | `127.0.0.1` | Listen address |
| `SHIM_TARGET` | `https://api.moonshot.ai/v1` | Upstream API base URL |
| `SHIM_FORCE_MODEL` | *(empty)* | If set, overrides the requested model id (empty = pass through) |
| `SHIM_REASONING_ECHO` | `1` | `1` = capture + re-inject real reasoning; `0` = placeholder only |
| `SHIM_REASONING_STORE_MAX` | `500` | Max reasoning entries kept in memory |
| `SHIM_SECRET` | *(empty)* | Optional shared secret (≥ 32 chars). If set, requests must send `X-Shim-Key: <secret>` |
| `SHIM_UPSTREAM_RETRIES` | `2` | Retry count for transient upstream errors |
| `SHIM_RETRY_BASE_MS` | `250` | Retry backoff base (ms) |
| `SHIM_KEEPALIVE_MS` | `10000` | SSE keepalive comment interval (ms) |
| `SHIM_TCP_KEEPALIVE_MS` | `15000` | OS-level TCP keepalive (ms) |
| `SHIM_DEBUG` | *(unset)* | `1` = verbose patching logs |

## Cache hit rate

Moonshot caches the conversation **prefix** automatically. Every request the shim logs a line like:

```
POST /v1/chat/completions -> 200 2553ms model=kimi-k3 msgs=5 patched=1 stream=false prompt=150 cached=120 fresh=30 reasoning=10 comp=20 hit=80.0%
```

- `prompt` — total input tokens
- `cached` — tokens served from cache (Moonshot's top-level `cached_tokens`)
- `fresh` — `prompt - cached` (tokens billed at the full input rate)
- `reasoning` — thinking tokens (`completion_tokens_details.reasoning_tokens`)
- `comp` — completion tokens
- `hit` — cache hit rate = `cached / prompt`

A per-minute summary is also written:

```
[summary] window=60s req=3 patched=2 usage=3 prompt=500 cached=410 reasoning=120 comp=90 hit=82.0% lifetime[...]
```

The **reasoning echo** is what keeps `hit` high across turns: by echoing the model's own thinking back verbatim, Moonshot caches it as part of the prefix instead of re-reading a placeholder.

## Logging

All output goes to `moonshot-shim.log` in the repo root (rotated when it exceeds 5 MB). Check it first when diagnosing issues.

## Testing

```bash
node test-echo.mjs
```

Boots a mock Moonshot echo server, starts a fresh shim against it, sends a multi-turn tool-call conversation, and asserts `reasoning_content` is injected.

## How it works

- The **patcher** walks `messages` and, for each assistant message with `tool_calls` but an empty/missing `reasoning_content`, injects `" "` (or the echoed real reasoning when available).
- The **reasoning echo** keeps a small in-memory LRU (capped at `SHIM_REASONING_STORE_MAX`) keyed by a stable fingerprint of the assistant message (`content` + `tool_calls`). When a response carries `reasoning_content`, it is stored; when a later request re-sends the same assistant message without it, the stored value is injected.
- Everything else — auth header, model id, streaming SSE, `/v1/models`, errors — is forwarded verbatim.
- `/healthz` and `/_shim/healthz` return `{"status":"ok"}` without touching upstream.

## Security

- Binds to `127.0.0.1` by default — not exposed to the network.
- Optional shared secret (`SHIM_SECRET` + `X-Shim-Key` header) for defense-in-depth.
- Only allow-listed paths (`/chat/completions`, `/models`, `/completions`, `/embeddings`, `/healthz`, `/_shim/healthz`) and methods (`GET`, `POST`, `OPTIONS`) are proxied; everything else is rejected.
