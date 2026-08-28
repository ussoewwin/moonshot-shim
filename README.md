# moonshot-shim

A tiny local HTTP proxy that lets any **OpenAI-compatible client** (AutoClaw, Cline, etc.) use **reasoning models** — Moonshot's **Kimi** (`kimi-k2.x`, `kimi-k3`) and Z.ai's **GLM** (`glm-5.3`, `glm-5-turbo`) — with **tool calling**, while keeping the **context-cache hit rate** as high as possible.

```
client ──▶ http://127.0.0.1:8787/v1 ──▶ https://api.moonshot.ai/v1            (Kimi)
client ──▶ http://127.0.0.1:8789/v1 ──▶ https://api.z.ai/api/coding/paas/v4   (GLM)
                (one shim instance per provider)
```

## Why it exists

Moonshot's Kimi and Z.ai's GLM reasoning models require a non-standard field, `reasoning_content`, on **every assistant message that carries `tool_calls`** in the conversation history. Standard OpenAI SDK / OpenAI-compatible clients drop that field, so the **turn after any tool call fails with `400`**:

```
400: thinking is enabled but reasoning_content is missing
     in assistant tool call message at index N
```

This shim sits in front of the provider and patches the outgoing request so multi-turn tool conversations keep working — and does it in a way that keeps the provider's automatic prefix cache hitting.

## What it does

- **`reasoning_content` injection** — injects a placeholder (`" "`) into any assistant `tool_calls` message whose `reasoning_content` is missing or empty.
- **Reasoning echo (cache-first)** — captures the *real* `reasoning_content` from responses and re-injects it verbatim into later turns instead of the placeholder. This keeps the prefix cache maximally hit and preserves reasoning continuity across tool calls. Disable with `SHIM_REASONING_ECHO=0`.
- **Cache accounting** — parses the usage block and logs the cache hit rate per request and per minute. Reads both cache layouts: Moonshot's *top-level* `usage.cached_tokens` and Z.ai's/OpenAI's *nested* `prompt_tokens_details.cached_tokens`. Thinking tokens come from `completion_tokens_details.reasoning_tokens`.
- **Byte-stable forwarding** — re-serializes the request body with sorted object keys so the forwarded bytes are deterministic regardless of the client's key order (the prefix cache keys on exact bytes).
- **Cache-break detection** — detects when the shared history is edited or truncated between turns and logs a `[cache-break]` warning, making cache misses easy to diagnose.
- **Resilience** — retries transient upstream errors, keeps SSE streams alive with keepalive comments, and survives crashes.
- **Rate-limit (429/503) absorption** — when the upstream returns `429` (TPM window exceeded / engine overloaded) or `503`, the shim retries the **byte-identical** body with exponential backoff (default 30s / 60s / 120s / 240s, up to 4 attempts) so the client never sees the failure. Retrying the same bytes keeps the provider's prefix cache intact, and OpenClaw-style clients avoid tripping their auth-profile cooldown. Logged as `UPSTREAM RATE-LIMIT RETRY`.
- **GLM thinking injection** — Z.ai GLM reasoning models only emit `reasoning_content` when the request body carries `{"thinking": {"type": "enabled"}}` (GLM-5.3-Flash defaults to disabled). Instances forwarding to a Z.ai/bigmodel endpoint inject this automatically into bodies that lack it, so thinking works without client-side changes. Controlled by `SHIM_FORCE_THINKING`.

## Requirements

- Node.js ≥ 20 (tested on Node 22)
- A Moonshot and/or Z.ai API key

## Quick start

```bash
npm install        # installs undici
npm start          # node server.js → listens on 127.0.0.1:8787 (Moonshot)
```

On Windows, use the bundled launchers (each auto-restarts the process if it crashes):

- `start-shim.cmd` — Moonshot relay on port `8787` (`start-shim.ps1`).
- `start-shim-zai.cmd` — Z.ai (GLM) relay on port `8789` (`start-shim-zai.ps1`).
- `start-shim-hidden.vbs` — starts both relays hidden, then runs `set-reasoning.cmd` after 5s; place in `shell:startup` for logon auto-start.
- `set-reasoning.cmd` / `set-reasoning.mjs` — one-shot helper that flips `reasoning: false -> true` for every custom-provider model in AutoClaw's config files (`settings.json` `models.catalog`, `openclaw.json`, `openclaw.runtime.json`). AutoClaw's UI has no reasoning toggle for custom models, and a `reasoning: false` model hides thinking output even when the provider emits it. Run while AutoClaw is closed, then restart AutoClaw:

```bash
node set-reasoning.mjs --dry-run   # preview changes
node set-reasoning.mjs             # apply
```

Check it's up:

```bash
curl http://127.0.0.1:8787/healthz
# {"status":"ok"}
```

## Multiple providers (parallel)

The shim is target-agnostic — run one instance per provider, each on its own port:

| Provider | Launcher | Port | `SHIM_TARGET` |
|---|---|---|---|
| Moonshot (Kimi) | `start-shim.cmd` | `8787` | `https://api.moonshot.ai/v1` |
| Z.ai (GLM) | `start-shim-zai.cmd` | `8789` | `https://api.z.ai/api/coding/paas/v4` |

Both providers require `reasoning_content` on assistant messages, so the patcher applies unchanged. The only provider-specific difference is the cache-field layout, which the shim reads either way. To add another provider, copy `start-shim-zai.ps1` and change `SHIM_TARGET` + `SHIM_PORT`.

## Point your client at the shim

Set your client's **OpenAI base URL** to the shim's `/v1` endpoint and keep using the provider's own API key.

- Moonshot → `http://127.0.0.1:8787/v1`
- Z.ai (GLM) → `http://127.0.0.1:8789/v1`

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
| `SHIM_RETRY_429` | `1` | `1` = absorb upstream `429`/`503` with backoff; `0` = pass through |
| `SHIM_RETRY429_BASE_MS` | `30000` | First 429-retry backoff (ms); doubles each attempt |
| `SHIM_RETRY429_MAX_MS` | `240000` | Cap for 429-retry backoff (ms) |
| `SHIM_RETRY429_ATTEMPTS` | `4` | Max 429/503 retries per request |
| `SHIM_FORCE_THINKING` | *(auto)* | `enabled`/`disabled` = force `thinking:{type}` on every body; empty = auto (inject `enabled` only when `SHIM_TARGET` matches `z.ai`/`bigmodel`); `off` = never inject |
| `SHIM_LOG` | `./moonshot-shim.log` | Log file path |
| `SHIM_DEBUG` | *(unset)* | `1` = verbose patching logs |

## Cache hit rate

Both providers cache the conversation **prefix** automatically. Every request the shim logs a line like:

```
POST /v1/chat/completions -> 200 2553ms model=glm-5.3 msgs=5 patched=1 stream=false prompt=150 cached=120 fresh=30 reasoning=10 comp=20 hit=80.0%
```

- `prompt` — total input tokens
- `cached` — tokens served from cache
- `fresh` — `prompt - cached` (tokens billed at the full input rate)
- `reasoning` — thinking tokens (`completion_tokens_details.reasoning_tokens`)
- `comp` — completion tokens
- `hit` — cache hit rate = `cached / prompt`

A per-minute summary is also written:

```
[summary] window=60s req=3 patched=2 usage=3 prompt=500 cached=410 reasoning=120 comp=90 hit=82.0% lifetime[...]
```

The **reasoning echo** is what keeps `hit` high across turns: by echoing the model's own thinking back verbatim, the provider caches it as part of the prefix instead of re-reading a placeholder.

## Logging

All output goes to `moonshot-shim.log` in the repo root (or `SHIM_LOG`), rotated when it exceeds 5 MB. Check it first when diagnosing issues.

## Testing

```bash
node test-echo.mjs
```

Boots a mock Moonshot echo server, starts a fresh shim against it, sends a multi-turn tool-call conversation, and asserts `reasoning_content` is injected.

## How it works

- The **patcher** walks `messages` and, for each assistant message with `tool_calls` but an empty/missing `reasoning_content`, injects `" "` (or the echoed real reasoning when available).
- The **reasoning echo** keeps a small in-memory LRU (capped at `SHIM_REASONING_STORE_MAX`) keyed by a stable fingerprint of the assistant message (`content` + `tool_calls`). When a response carries `reasoning_content`, it is stored; when a later request re-sends the same assistant message without it, the stored value is injected.
- The **byte-stable serialization** sorts object keys recursively before forwarding, so the request prefix is deterministic.
- The **cache-break detector** compares the current request's `messages` against the previous one and logs when the shared prefix was edited or truncated.
- Everything else — auth header, model id, streaming SSE, `/v1/models`, errors — is forwarded verbatim.
- `/healthz` and `/_shim/healthz` return `{"status":"ok"}` without touching upstream.

## Security

- Binds to `127.0.0.1` by default — not exposed to the network.
- Optional shared secret (`SHIM_SECRET` + `X-Shim-Key` header) for defense-in-depth.
- Only allow-listed paths (`/chat/completions`, `/models`, `/completions`, `/embeddings`, `/healthz`, `/_shim/healthz`) and methods (`GET`, `POST`, `OPTIONS`) are proxied; everything else is rejected.
