# Using Kimi K2.6 as an Agent in Cursor

A complete guide to enabling **tool-calling** with Moonshot's `kimi-k2.6` (Thinking model) from Cursor IDE.

Created: 2026-04-25
Working folder: `<repo-path>\`

---

## Table of Contents

1. [Symptoms](#1-symptoms)
2. [Root Cause](#2-root-cause)
3. [Affected Tools](#3-affected-tools)
4. [Solution Overview](#4-solution-overview)
5. [Architecture Diagram](#5-architecture-diagram)
6. [Created Files](#6-created-files)
7. [Launch Procedure](#7-launch-procedure)
8. [Cursor Settings](#8-cursor-settings)
9. [Verification](#9-verification)
10. [Operational Notes](#10-operational-notes)
11. [Cache Optimization Tips](#11-cache-optimization-tips)
12. [Known Limitations & Future Improvements](#12-known-limitations--future-improvements)

---

## 1. Symptoms

When setting Cursor's Settings → Models → Override OpenAI Base URL to Moonshot and registering `kimi-k2.6` as a Custom Model for Agent mode, the following error appears immediately after any tool call (codebase_search / read_file / edit_file etc. returns), killing the agent:

```
API Error: 400 thinking is enabled but reasoning_content is missing
in assistant tool call message at index N
```

Does not occur in simple Q&A without tools. Any single tool call in Agent mode causes a crash on the next turn.

## 2. Root Cause

Moonshot's Thinking models (Kimi K2.6 / DeepSeek-R1 etc.) require a non-standard mandatory field `reasoning_content` in the conversation history.

Specifically, Moonshot validates incoming requests as follows:

> If a message with `role: "assistant"` contains `tool_calls`, the **same message must also contain a non-empty string `reasoning_content`**. Missing / empty / wrong type → 400.

OpenAI's Chat Completions API has no `reasoning_content` field, so OpenAI-compatible clients (Cursor / openclaude / Cline etc.) do not preserve or echo-back this field by default. This leads to:

- Turn 1: User asks → model returns tool call (with `reasoning_content` attached)
- Client: executes tool → assembles new messages array → `reasoning_content` is dropped
- Turn 2: Client sends messages to Moonshot → 400

Additionally, Moonshot's validation only checks **field presence**, not content validity. This lax validation is what makes the shim workaround possible.

## 3. Affected Tools

| Tool | Status |
| --- | --- |
| Cursor IDE | Closed-source. Cannot modify internals. **This guide is required**. |
| openclaude | GitHub HEAD (commit `44f9cac`) has `preserveReasoningContent: true`. npm release v0.6.0 may lag; manual patch of `dist/cli.mjs` was applied during this work. |
| Cline | Same symptom. Waiting for plugin update. |
| Google Antigravity | Same symptom. Cannot modify internals. |
| Custom OpenAI client | Fixable by implementing `reasoning_content` preservation yourself. |

The same `reasoning_content` requirement applies to DeepSeek-R1, so this solution can be reused by changing the target URL to `https://api.deepseek.com/v1`.

## 4. Solution Overview

Since Cursor cannot be modified directly, the only viable approach is to **place an external proxy that injects the missing field**.

1. **Local shim (Node.js)**
   - Listens on `127.0.0.1:8787`
   - Scans incoming messages arrays, injects placeholder `" "` (single space) as `reasoning_content` for any assistant message with `tool_calls` that lacks it
   - Forwards to Moonshot
   - Responses (including SSE) pass through untouched
   - Authorization header is transparent

2. **Cloudflare Tunnel (cloudflared)**
   - Cursor's Override OpenAI Base URL is reached **via Cursor's cloud servers**, which block private IPs (`127.0.0.1`) via SSRF protection (`ssrf_blocked: connection to private IP is blocked`)
   - Therefore the shim must be exposed externally
   - cloudflared **quick tunnel** provides a temporary HTTPS URL like `https://*.trycloudflare.com`
   - Since this environment blocks UDP/443, `--protocol http2` forces TCP/443 fallback

The placeholder `" "` works because Moonshot does not validate content (see §2). If Moonshot ever tightens validation, this workaround will break and a full thinking-text preservation approach (like openclaude HEAD) will be needed.

## 5. Architecture Diagram

```
┌─────────────────┐
│  Cursor (UI)    │  On local PC
│  Agent mode     │
│  kimi-k2.6      │
└────────┬────────┘
         │ HTTPS (Override OpenAI Base URL value)
         ▼
┌──────────────────────────┐
│  Cursor cloud servers    │  Request relay / logging / billing
│  (SSRF blocks 127.0.0.1) │
└────────┬─────────────────┘
         │ HTTPS to https://<random>.trycloudflare.com/v1/...
         ▼
┌──────────────────────────────┐
│  Cloudflare edge             │  HTTP/2 connection
│  (trycloudflare.com)         │
└────────┬─────────────────────┘
         │ Tunnel (cloudflared process maintains outbound connection)
         ▼
┌──────────────────────────────────────┐
│  cloudflared.exe (on local PC)       │  PID xxxx
│  → forwards to http://127.0.0.1:8787 │
└────────┬─────────────────────────────┘
         │ HTTP (loopback)
         ▼
┌──────────────────────────────────────────────┐
│  moonshot-shim (Node.js, server.js)          │
│  - parses messages JSON                      │
│  - assistant && tool_calls && !rc            │
│      → injects reasoning_content = " "       │
│  - Authorization transparent                 │
│  - recalculates Content-Length               │
│  - SSE/normal responses piped through        │
└────────┬─────────────────────────────────────┘
         │ HTTPS to https://api.moonshot.ai/v1/...
         ▼
┌─────────────────────────────────┐
│  Moonshot Kimi K2.6 API         │
│  (original destination)         │
└─────────────────────────────────┘
```

## 6. Created Files

All under `<repo-path>\`.

| Path | Type | Role |
| --- | --- | --- |
| `package.json` | Config | Dependency declaration (`undici` only). `type: module` for ESM. |
| `package-lock.json` | Auto-generated | npm lockfile. |
| `node_modules/` | Auto-generated | Dependencies installed via `npm install`. |
| `server.js` | Main (~490 lines) | Shim core. HTTP server, patcher, proxy logic, resilience features. |
| `README.md` | Doc | Standalone usage instructions. |
| `test-echo.mjs` | Test | Spins up a local echo server to regression-test the patcher. |
| `cloudflared.exe` | Binary (~65 MB) | Cloudflare Tunnel client. Downloaded from GitHub Releases. |
| `CURSOR_KIMI_K26_FIX.md` | Doc | **This file (Japanese)**. Complete summary. |
| `CURSOR_KIMI_K26_FIX.en.md` | Doc | **This file (English)**. |

### 6.1 Core server.js Logic (excerpt)

```javascript
function patchMessagesForMoonshot(body) {
  if (!body || !Array.isArray(body.messages)) return 0;
  let patched = 0;
  for (const msg of body.messages) {
    if (!msg || msg.role !== 'assistant') continue;
    if (!Array.isArray(msg.tool_calls) || msg.tool_calls.length === 0) continue;
    const rc = msg.reasoning_content;
    if (typeof rc !== 'string' || rc.trim() === '') {
      msg.reasoning_content = ' ';   // ← minimum value satisfying Moonshot
      patched++;
    }
  }
  return patched;
}
```

- Intervenes only for **assistant + has tool_calls + rc empty**
- Intervention is **idempotent and deterministic** (same input → same output)
- Does not touch messages that already have valid `reasoning_content` (future-proof if Cursor adds native support)

### 6.2 Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `SHIM_PORT` | `8787` | Shim listen port |
| `SHIM_HOST` | `127.0.0.1` | Shim listen address |
| `SHIM_TARGET` | `https://api.moonshot.ai/v1` | Forward target. Can point to DeepSeek etc. |
| `SHIM_DEBUG` | (unset) | Set to `1` for verbose logging |
| `SHIM_KEEPALIVE_MS` | `15000` | SSE keepalive comment interval (milliseconds) |
| `SHIM_TCP_KEEPALIVE_MS` | `15000` | TCP keep-alive probe interval (milliseconds) |
| `SHIM_UPSTREAM_RETRIES` | `2` | Auto-retry count for upstream errors |
| `SHIM_RETRY_BASE_MS` | `250` | Base wait time for auto-retry (milliseconds) |

## 7. Launch Procedure

Open two PowerShell terminals.

### 7.1 Terminal 1: Launch shim

```powershell
cd <repo-path>
node server.js
```

Expected log:

```
2026-04-25T... moonshot-shim listening on http://127.0.0.1:8787 pid=...
2026-04-25T... forwarding to https://api.moonshot.ai/v1
2026-04-25T... log file: <repo-path>\moonshot-shim.log
2026-04-25T... reasoning_content patcher: enabled (assistant.tool_calls -> placeholder " ")
2026-04-25T... SSE keepalive: 15000ms  TCP keepalive: 15000ms
2026-04-25T... healthz: GET http://127.0.0.1:8787/healthz
2026-04-25T... point your client "Override OpenAI Base URL" at http://127.0.0.1:8787/v1
```

### 7.2 Terminal 2: Launch cloudflared

```powershell
cd <repo-path>
.\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787
```

Notes:
- `--protocol http2` is **required**. Default QUIC (UDP/443) may not pass in some environments; this forces TCP/443 fallback.
- In this environment, QUIC caused repeated `failed to serve tunnel connection` errors, so http2 is forced.

Expected log:

```
... INF Requesting new quick Tunnel on trycloudflare.com...
... INF |  Your quick Tunnel has been created! Visit it at:
... INF |  https://<random-words>.trycloudflare.com
... INF Registered tunnel connection ... protocol=http2
```

Copy the `https://...trycloudflare.com` URL. **This URL changes every time cloudflared is restarted**.

## 8. Cursor Settings

1. Launch Cursor → click gear icon → **Settings**
2. Left menu **Models**
3. **API Keys** section
   - Paste your Moonshot key (`sk-...`) into **OpenAI API Key**
4. Turn ON **Override OpenAI Base URL**, enter the cloudflared URL with `/v1` appended
   ```
   https://<random-words>.trycloudflare.com/v1
   ```
5. Click **+ Add Model** and add `kimi-k2.6` (Moonshot's model ID)
6. In the main Composer / Agent input, select `kimi-k2.6` from the model selector
7. Ask a question (e.g. "Understand this repository well")
8. If tool execution runs and returns a response without error, success

## 9. Verification

### 9.1 Unit Test (before reaching Moonshot)

Running `test-echo.mjs` starts a local echo server, sends a request through the shim, and verifies whether `reasoning_content` was injected.

```powershell
cd <repo-path>
node test-echo.mjs
```

Expected output (tail):

```
=== reasoning_content injected: PASS ===
```

### 9.2 Integration Test (does the tunnel reach Moonshot?)

Hit the cloudflared URL without auth; a 401 means the path is open.

```powershell
Invoke-WebRequest -Uri "https://<random-words>.trycloudflare.com/v1/models" -Method GET -UseBasicParsing
```

`HTTP 401` means full path OK (reached Moonshot and was rejected for missing auth).

### 9.3 Real Test from Cursor

In Agent mode, ask questions that **definitely trigger tools**:

- "Summarize the structure of this repository" (codebase_search)
- "Read server.js" (read_file)
- "Add 5 lines to launch_utils.py" (edit_file)

If the turn after tool execution returns a response without error, complete success.

## 10. Operational Notes

### 10.1 Startup Order

Start `shim` → then `cloudflared` (cloudflared can start before the forward target is listening, but requests that arrive first will get 502). For shutdown, reverse order (`cloudflared` → `shim`) is safer.

### 10.2 Quick Tunnel URL is Volatile

The cloudflared URL changes on every restart. Each restart requires updating Cursor's Override Base URL. For a solution, see §12.1.

### 10.3 Security

- cloudflared exposes the shim externally, but the shim forwards the `Authorization` header straight to Moonshot. **Third parties without a valid Moonshot key are rejected with 401 by Moonshot**.
- However, the shim's own resources (CPU / bandwidth) are consumed without authentication, so massive access could cause DoS. If concerned, add a shared-secret header check to the shim (§12.3).
- Tunnel URLs are long and hard to guess, but posting them on social media risks exposure. **Do not share the URL**.

### 10.4 When This Fix Stops Working

- If Moonshot tightens validation of `reasoning_content` content
- If Cursor natively supports `reasoning_content` and the shim becomes unnecessary (this would be welcome)
- If cloudflared / trycloudflare.com free tunnel service ends or changes (alternatives like ngrok exist)

### 10.5 Connection Stability During Long Thinking

The `server.js` (shim) is shared between Cloudflare and Tailscale methods, so the following mitigations are **also effective when using Cloudflare**:

- **SSE keepalive comments** (`: keepalive\n\n`) sent downstream every 15 seconds
- **TCP keep-alive** (`setKeepAlive(true, 15s)`) set on SSE sockets
- **HTTP headers** `X-Accel-Buffering: no` + `Cache-Control: no-cache, no-transform` added
- **Node.js timeout removal** (`requestTimeout=0` / `keepAliveTimeout=600s` etc.)
- **Upstream auto-retry** (`ECONNRESET` / `ETIMEDOUT` etc., 3 retries)

Cloudflare's edge is already tolerant of long SSE streams, so these mitigations are more visibly effective on the Tailscale side, but the code itself runs the same way with Cloudflare. Adjustable via `SHIM_KEEPALIVE_MS` / `SHIM_TCP_KEEPALIVE_MS`.

Cursor client's own SSE receive timeout cannot be changed from the shim. See Tailscale doc §11.1 for details.

## 11. Cache Optimization Tips

Moonshot prompt cache pricing:

- Cache HIT: $0.16 / 1M tokens
- Cache MISS: $0.95 / 1M tokens
- Output: $4.00 / 1M tokens (same in both cases)

That's about 6× difference. In a typical medium-scale (100k context) 10-turn conversation:

- **Same thread continued**: ~$0.27
- **New thread every turn**: ~$1.04

About **4×** difference.

### 3 Actions to Maximize Efficiency

1. **Load heavy context only once at the start**
   - "Understand this entire repository and summarize its structure" as the first message
   - Turn 1: all MISS, ~$0.10
   - After: nearly all HIT, ~$0.02/turn

2. **Pile on in the same thread**
   - Add all related questions to the same Agent thread
   - The moment you press `+ New Agent`, past cache is effectively invalidated

3. **When logically separated, summarize and start a new thread**
   - In the previous thread, ask "List the findings so far and open items in bullet points"
   - Paste only those bullets into a new thread → first-turn MISS shrinks from 100k to 5k

### Notes

- Moonshot prompt cache TTL is industry-standard 15 minutes to 1 hour. **Concentrate work in short bursts**.
- 1 thread = 1 model fixed (switching models mid-thread changes the cache key).
- shim placeholder must **always be the fixed value `" "`** (randomizing every time causes all MISS). Current implementation is fixed, so no problem.
- After Cursor updates, system prompts may change and invalidate all cache.

## 12. Known Limitations & Future Improvements

### 12.1 Quick Tunnel URL Volatility → Named Tunnel

Creating a free Cloudflare account and configuring a Named Tunnel gives you a **fixed URL** like `https://kimi.your-domain.com`:

1. Create Cloudflare account
2. Transfer domain to Cloudflare or delegate subdomain
3. `cloudflared tunnel login` (browser auth)
4. `cloudflared tunnel create kimi-shim`
5. Write hostname and service to `~/.cloudflared/config.yml`
6. `cloudflared tunnel run kimi-shim` to persist

### 12.2 Auto-Start on PC Boot

Register both of the following in Task Scheduler as "Run at logon":

- `node <repo-path>\server.js`
- `<repo-path>\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787`

However, since quick tunnel URLs change on every start, combining with Named Tunnel (§12.1) is practical.

### 12.3 Adding Shared-Secret Header Verification

If you want to harden the shim, add this at the top of the handler in `server.js`:

```javascript
const SHIM_SECRET = process.env.SHIM_SECRET;
if (SHIM_SECRET) {
  const got = req.headers['x-shim-secret'];
  if (got !== SHIM_SECRET) {
    res.writeHead(403, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'shim: forbidden', type: 'shim_auth' }}));
    return;
  }
}
```

However, Cursor cannot attach arbitrary request headers, so you'd need to switch to URL-parameter auth, which has compatibility issues with Cursor. In practice, the "don't share the URL" operation from §10.3 is sufficient.

### 12.4 Switching to Real Thinking Preservation

If Moonshot starts rejecting the placeholder in the future, the shim alone cannot handle it. The reason is that Cursor does not preserve `reasoning_content` from the response stream, so the shim has no real thinking text to reuse.

Options then:

- Shim reads response SSE, saves `reasoning_content` to a local DB, and retrieves it by `tool_call_id` on next request → feasible but heavy implementation.
- Wait for Cursor official support.
- Switch to a tool where you can modify internals, like openclaude.

### 12.5 Adapting for DeepSeek-R1

Just change `SHIM_TARGET`:

```powershell
$env:SHIM_TARGET = "https://api.deepseek.com/v1"
node server.js
```

Change Cursor's model name to `deepseek-reasoner` etc.

---

## Appendix A: Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Cursor shows `ssrf_blocked` | shim specified directly (cloudflared not used) | Start cloudflared and set the trycloudflare URL in Cursor |
| cloudflared repeatedly shows `failed to serve tunnel connection` | UDP/443 is blocked | Add `--protocol http2` to force TCP/443 |
| shim log shows patched=0 with no error | Simple Q&A chat without tool calls | Expected. No problem. |
| Cursor shows 401 | Wrong or expired API Key | Reissue on Moonshot side |
| Cursor shows 502 | shim has crashed | Restart Terminal 1 |
| Cursor shows `connection refused` | cloudflared has crashed | Restart Terminal 2 and update Cursor with the new URL |
| Extremely slow response | quick tunnel has no uptime guarantee, may be congested | Reissue URL or convert to Named Tunnel |
| Cursor shows `Network Error` (during long thinking) | Moonshot thinking time (60–150s) exceeded Cursor cloud timeout | shim's SSE keepalive / TCP keep-alive auto-mitigates. If `keepalive=N` is in the log, it's a Cursor-side issue. Consider migrating to Tailscale method. |

## 13. Full Auto-Reproduction Playbook (unattended execution)

The following requires no human judgment or contextual understanding; it can be reproduced purely through a sequence of commands and file operations. Uses copy-paste blocks and pass/fail conditions to minimize required knowledge.

### 13-1. Precondition Checks

Run sequentially. If any stop condition triggers, go back to the step before it.

```powershell
# A. Node.js installed? (Cursor-bundled node.exe also acceptable)
(Test-Path "C:\Program Files\nodejs\node.exe") -or (Get-Command node -ErrorAction SilentlyContinue)
# Stop: False → Install Node.js from https://nodejs.org/

# B. shim file exists?
Test-Path "<repo-path>\server.js"
# Stop: False → Create server.js per §13-2 below

# C. node_modules exists?
Test-Path "<repo-path>\node_modules\undici\package.json"
# Stop: False → cd <repo-path> && npm install

# D. cloudflared binary exists?
Test-Path "<repo-path>\cloudflared.exe"
# Stop: False → Download cloudflared-windows-amd64.exe from https://github.com/cloudflare/cloudflared/releases, rename, and place at above path
```

### 13-2. Place server.js (first time only)

Write the following to `<repo-path>\server.js`. Skip this step if the file already exists.

```javascript
// moonshot-shim/server.js
//
// Local HTTP proxy that sits between an OpenAI-compatible client (Cursor,
// Cline, etc.) and Moonshot's Kimi API. Its sole purpose is to satisfy
// Moonshot's "thinking model" validation rule:
//
//   400: thinking is enabled but reasoning_content is missing
//        in assistant tool call message at index N
//
// Moonshot's K2.6 (and other reasoning models) require that *every*
// assistant message in the conversation history that carries `tool_calls`
// also carries a non-empty string `reasoning_content`. Standard OpenAI
// SDK / OpenAI-compatible clients drop that field, so multi-turn tool
// conversations break.
//
// The patcher below walks `messages` and injects `reasoning_content: " "`
// into every offending assistant message. The Moonshot API only checks
// for the field's presence and non-emptiness; the placeholder value is
// accepted.
//
// Everything else (auth header, model id, streaming SSE, /v1/models,
// errors) is forwarded verbatim.
//
// --- Resilience features (added 2026-04-25) ------------------------------
//   * Persistent log file:  ./moonshot-shim.log  (append, rotated at start
//     when previous file > 5 MB)
//   * uncaughtException / unhandledRejection are CAUGHT and logged.
//     The process keeps running. (Previous version exited on EPIPE etc.)
//   * Per-minute summary line (req / err / patched / upstream-status mix).
//   * /healthz endpoint for external liveness checks.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { request } from 'undici';

const PORT = parseInt(process.env.SHIM_PORT || '8787', 10);
const HOST = process.env.SHIM_HOST || '127.0.0.1';
const TARGET = (process.env.SHIM_TARGET || 'https://api.moonshot.ai/v1').replace(/\/+$/, '');
const DEBUG = process.env.SHIM_DEBUG === '1';
const PLACEHOLDER = ' ';
const UPSTREAM_RETRIES = Math.max(0, parseInt(process.env.SHIM_UPSTREAM_RETRIES || '2', 10));
const RETRY_BASE_MS = Math.max(50, parseInt(process.env.SHIM_RETRY_BASE_MS || '250', 10));
const KEEPALIVE_INTERVAL_MS = Math.max(0, parseInt(process.env.SHIM_KEEPALIVE_MS || '15000', 10));
const TCP_KEEPALIVE_MS = Math.max(0, parseInt(process.env.SHIM_TCP_KEEPALIVE_MS || '15000', 10));

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOG_PATH = process.env.SHIM_LOG || path.join(__dirname, 'moonshot-shim.log');
const LOG_MAX_BYTES = 5 * 1024 * 1024;

function rotateIfBig() {
  try {
    const st = fs.statSync(LOG_PATH);
    if (st.size > LOG_MAX_BYTES) {
      const rotated = LOG_PATH + '.1';
      try { fs.unlinkSync(rotated); } catch {}
      fs.renameSync(LOG_PATH, rotated);
    }
  } catch {}
}
rotateIfBig();

const logStream = fs.createWriteStream(LOG_PATH, { flags: 'a' });
logStream.on('error', (err) => {
  console.error(new Date().toISOString(), 'LOG STREAM ERROR', err.message);
});

function ts() { return new Date().toISOString(); }

function log(...args) {
  const line = `${ts()} ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
  process.stdout.write(line);
  try { logStream.write(line); } catch {}
}

function dlog(...args) { if (DEBUG) log('[debug]', ...args); }

const stats = { req: 0, err: 0, patched: 0, byStatus: Object.create(null), windowStart: Date.now() };
function bumpStatus(code) {
  const k = String(code);
  stats.byStatus[k] = (stats.byStatus[k] || 0) + 1;
}
setInterval(() => {
  const elapsed = ((Date.now() - stats.windowStart) / 1000).toFixed(0);
  const statusStr = Object.entries(stats.byStatus).sort((a, b) => Number(a[0]) - Number(b[0])).map(([k, v]) => `${k}=${v}`).join(',') || '-';
  log(`[summary] window=${elapsed}s req=${stats.req} err=${stats.err} patched=${stats.patched} statuses=${statusStr}`);
  stats.req = 0; stats.err = 0; stats.patched = 0; stats.byStatus = Object.create(null); stats.windowStart = Date.now();
}, 60_000).unref();

function patchMessagesForMoonshot(body) {
  if (!body || !Array.isArray(body.messages)) return 0;
  let patched = 0;
  for (const msg of body.messages) {
    if (!msg || msg.role !== 'assistant') continue;
    if (!Array.isArray(msg.tool_calls) || msg.tool_calls.length === 0) continue;
    const rc = msg.reasoning_content;
    if (typeof rc !== 'string' || rc.trim() === '') {
      msg.reasoning_content = PLACEHOLDER;
      patched++;
    }
  }
  return patched;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const HOP_BY_HOP = new Set(['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailers','transfer-encoding','upgrade','host','content-length']);
function copyHeaders(src) {
  const out = {};
  for (const [k, v] of Object.entries(src)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function isRetryableUpstreamError(err) {
  if (!err) return false;
  const code = String(err.code || '');
  const msg = String(err.message || '');
  if (code === 'ECONNRESET' || code === 'ETIMEDOUT') return true;
  if (msg.includes('ECONNRESET') || msg.includes('ETIMEDOUT')) return true;
  if (msg.includes('UND_ERR_SOCKET') || msg.includes('UND_ERR_CONNECT_TIMEOUT') || msg.includes('UND_ERR_HEADERS_TIMEOUT')) return true;
  return false;
}

async function requestWithRetry(url, options, reqMeta) {
  let attempt = 0;
  while (true) {
    try {
      return await request(url, options);
    } catch (err) {
      const canRetry = isRetryableUpstreamError(err) && attempt < UPSTREAM_RETRIES;
      if (!canRetry) throw err;
      const waitMs = RETRY_BASE_MS * (attempt + 1);
      log('UPSTREAM RETRY', `attempt=${attempt + 1}/${UPSTREAM_RETRIES}`, reqMeta, String(err.code || ''), err.message, `wait=${waitMs}ms`);
      await sleep(waitMs);
      attempt++;
    }
  }
}

function safeWrite(res, chunk) {
  if (!res || res.destroyed || res.writableEnded) return false;
  try { return res.write(chunk); } catch (err) { log('RES WRITE ERROR', err.message); return false; }
}

function safeEnd(res) {
  if (!res || res.destroyed || res.writableEnded) return;
  try { res.end(); } catch (err) { log('RES END ERROR', err.message); }
}

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  stats.req++;
  res.on('error', (err) => { log('RES ERROR', err.code || '', err.message); });
  req.on('error', (err) => { log('REQ ERROR', err.code || '', err.message); });

  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || HOST + ':' + PORT}`);
  } catch (e) {
    safeWrite(res, '');
    res.writeHead(400, { 'content-type': 'text/plain' });
    safeEnd(res);
    return;
  }

  if (url.pathname === '/healthz' || url.pathname === '/_shim/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, uptimeSec: Math.round(process.uptime()), target: TARGET, pid: process.pid }));
    return;
  }

  let upstreamPath = url.pathname;
  if (upstreamPath.startsWith('/v1/')) upstreamPath = upstreamPath.slice(3);
  else if (upstreamPath === '/v1') upstreamPath = '';
  const upstreamUrl = TARGET + upstreamPath + url.search;

  let raw;
  try { raw = await readBody(req); } catch (err) {
    stats.err++;
    log('REQ READ ERROR', err.message);
    try { res.writeHead(400, { 'content-type': 'text/plain' }); res.end('shim: failed to read request body: ' + err.message); } catch {}
    return;
  }

  let bodyToSend = raw.length > 0 ? raw : undefined;
  let patchInfo = '';
  if (req.method === 'POST' && raw.length > 0) {
    let json = null;
    try { json = JSON.parse(raw.toString('utf8')); } catch {}
    if (json && Array.isArray(json.messages)) {
      const n = patchMessagesForMoonshot(json);
      stats.patched += n;
      try { bodyToSend = Buffer.from(JSON.stringify(json), 'utf8'); } catch (err) { log('JSON STRINGIFY ERROR', err.message); bodyToSend = raw; }
      patchInfo = ` model=${json.model || '?'} msgs=${json.messages.length} patched=${n} stream=${!!json.stream}`;
      if (DEBUG && n > 0) dlog(`patched ${n} assistant.tool_calls message(s)`);
    }
  }

  const upstreamHeaders = copyHeaders(req.headers);
  if (bodyToSend) upstreamHeaders['content-length'] = String(bodyToSend.length);

  let upstream;
  try {
    upstream = await requestWithRetry(upstreamUrl, { method: req.method, headers: upstreamHeaders, body: bodyToSend, maxRedirections: 0 }, `${req.method} ${upstreamUrl}`);
  } catch (err) {
    stats.err++;
    bumpStatus(502);
    log('UPSTREAM ERROR', req.method, upstreamUrl, err.message);
    try { res.writeHead(502, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'shim: upstream connect error: ' + err.message, type: 'shim_upstream_error' } })); } catch {}
    return;
  }

  bumpStatus(upstream.statusCode);
  const respHeaders = copyHeaders(upstream.headers);
  const ct = String(upstream.headers['content-type'] || '');
  const isSSE = ct.includes('text/event-stream');
  if (isSSE) {
    respHeaders['x-accel-buffering'] = 'no';
    respHeaders['cache-control'] = 'no-cache, no-transform';
  }
  try { res.writeHead(upstream.statusCode, respHeaders); } catch (err) {
    log('RES WRITEHEAD ERROR', err.message);
    try { upstream.body.destroy(); } catch {}
    return;
  }

  if (isSSE && TCP_KEEPALIVE_MS > 0) {
    try {
      const sock = res.socket || req.socket;
      if (sock && typeof sock.setKeepAlive === 'function') {
        sock.setKeepAlive(true, TCP_KEEPALIVE_MS);
        if (typeof sock.setNoDelay === 'function') sock.setNoDelay(true);
      }
    } catch (err) { log('TCP KEEPALIVE SET ERROR', err.message); }
  }

  let lastWriteAt = Date.now();
  let keepAliveTimer = null;
  let keepAliveCount = 0;
  function stopKeepAlive() { if (keepAliveTimer) { clearInterval(keepAliveTimer); keepAliveTimer = null; } }

  if (isSSE && KEEPALIVE_INTERVAL_MS > 0) {
    const tick = Math.max(1000, Math.floor(KEEPALIVE_INTERVAL_MS / 2));
    keepAliveTimer = setInterval(() => {
      if (!res || res.destroyed || res.writableEnded) { stopKeepAlive(); return; }
      if (Date.now() - lastWriteAt >= KEEPALIVE_INTERVAL_MS) {
        if (safeWrite(res, ': keepalive\n\n')) { lastWriteAt = Date.now(); keepAliveCount++; }
      }
    }, tick);
    keepAliveTimer.unref();
  }

  upstream.body.on('data', (c) => { if (safeWrite(res, c)) lastWriteAt = Date.now(); });
  upstream.body.on('end', () => {
    stopKeepAlive(); safeEnd(res);
    const ms = Date.now() - started;
    const ka = isSSE && keepAliveCount > 0 ? ` keepalive=${keepAliveCount}` : '';
    log(`${req.method} ${url.pathname} -> ${upstream.statusCode} ${ms}ms${patchInfo}${ka}`);
  });
  upstream.body.on('error', (err) => { stats.err++; stopKeepAlive(); log('UPSTREAM BODY ERROR', err.message); safeEnd(res); });
  req.on('close', () => { stopKeepAlive(); if (!res.writableEnded) { try { upstream.body.destroy(); } catch {} } });
});

server.on('clientError', (err, socket) => { log('CLIENT ERROR', err.code || '', err.message); try { socket.destroy(); } catch {} });
server.on('error', (err) => { log('SERVER ERROR', err.code || '', err.message); });

process.on('uncaughtException', (err) => { log('UNCAUGHT EXCEPTION', err && err.stack ? err.stack : String(err)); });
process.on('unhandledRejection', (reason) => { const s = reason && reason.stack ? reason.stack : String(reason); log('UNHANDLED REJECTION', s); });

server.requestTimeout = 0;
server.keepAliveTimeout = 600_000;
server.headersTimeout = 605_000;
server.timeout = 0;

server.listen(PORT, HOST, () => {
  log(`moonshot-shim listening on http://${HOST}:${PORT} pid=${process.pid}`);
  log(`forwarding to ${TARGET}`);
  log(`log file: ${LOG_PATH}`);
  log('reasoning_content patcher: enabled (assistant.tool_calls -> placeholder " ")');
  log(`SSE keepalive: ${KEEPALIVE_INTERVAL_MS}ms  TCP keepalive: ${TCP_KEEPALIVE_MS}ms`);
  log('healthz: GET http://' + HOST + ':' + PORT + '/healthz');
  log('point your client "Override OpenAI Base URL" at http://' + HOST + ':' + PORT + '/v1');
  if (DEBUG) log('debug mode ON (SHIM_DEBUG=1)');
});

function shutdown(sig) {
  log(`received ${sig}, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
```

**Pass condition**: The above content is written to `<repo-path>\server.js`. File size should be ~480+ lines.

### 13-3. Install Dependencies

```powershell
cd "<repo-path>"
npm install
```

**Pass condition**: `node_modules\undici\package.json` exists.

### 13-4. First Manual Test

```powershell
cd "<repo-path>"

# (A) shim standalone test
Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory "<repo-path>" -WindowStyle Hidden
Start-Sleep -Seconds 2
$r = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2
# Stop: $r.ok -ne $true → verify server.js content

# (B) cloudflared test (open another terminal and run)
# cd "<repo-path>"
# .\cloudflared.exe tunnel --url http://127.0.0.1:8787 --protocol http2
# → when https://<random>.trycloudflare.com appears, stop with Ctrl+C
```

### 13-5. Create Automation Files

#### start-all.cmd

Path: `<repo-path>\start-all.cmd`

Full content:

```batch
@echo off
REM Launch moonshot-shim + cloudflared quick tunnel for Cursor
setlocal
cd /d "%~dp0"

REM Start shim hidden
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden"

REM Wait for shim
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('shim OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host 'shim FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

REM Start cloudflared quick tunnel
echo.
echo === Cloudflare Quick Tunnel ===
echo URL will appear below. Copy it to Cursor -> Override OpenAI Base URL
echo.
.\cloudflared.exe tunnel --url http://127.0.0.1:8787 --protocol http2

endlocal
```

**Pass condition**: The above content is written accurately.

### 13-6. Create Cursor Skill (optional but recommended)

Path: `D:\.cursor\skills\start-moonshot-shim\SKILL.md`

Full content:

```markdown
---
name: start-moonshot-shim
description: Launch the local moonshot-shim and cloudflared quick tunnel so Cursor can talk to Moonshot's kimi-k2.6 thinking model. Use when the user asks to start, restart, relaunch, or bring up the moonshot shim, the quick tunnel, or the Cursor Kimi access path. Also triggers on Japanese phrasings such as "shim を起動して", "kimi を起動して", "cloudflared 起動", "PC 再起動したから shim 動かして".
---

# Start Moonshot Shim + Cloudflare Quick Tunnel

## Purpose

Bring up the two background services required for Cursor to use Moonshot's `kimi-k2.6` model:

1. **moonshot-shim** — local Node proxy on `127.0.0.1:8787`
2. **cloudflared quick tunnel** — exposes the shim via a temporary public HTTPS URL

## How to run

Execute the launcher batch:

```
"<repo-path>\start-all.cmd"
```

This opens a console window showing the trycloudflare URL. The user must copy that URL into Cursor themselves.

## What to tell the user

After the tunnel URL appears (e.g. `https://abc123.trycloudflare.com`), tell them:

```
Cursor -> Override OpenAI Base URL: <paste-url>/v1
```

The user handles clicking Verify manually.

## Absolute stop rules

- Do NOT modify Cursor settings.json, model list, API key, or Override URL. The user reserved that step.
- Do NOT start a second cloudflared if one is already running.
- Do NOT kill an already-running shim unless the user explicitly asks.
```

**Pass condition**: `D:\.cursor\skills\start-moonshot-shim\SKILL.md` exists.

### 13-7. Verification Flow

1. Run `start-all.cmd` by double-click or PowerShell
2. Copy the displayed `https://*.trycloudflare.com` URL
3. Paste `<URL>/v1` into Cursor → Settings → Models → Override OpenAI Base URL
4. Click Verify
5. Submit a task with tool calls in Agent mode and confirm no 400 error

**Pass condition**: `API Error: 400 thinking is enabled but reasoning_content is missing` does not appear.

### 13-8. Procedure After PC Reboot

Cloudflare quick tunnel URLs **change every time**, so after PC reboot:

1. Run `start-all.cmd` again
2. Paste the new URL into Cursor (same as §13-7)

To automate this, migrating to the Tailscale Funnel method (`CURSOR_KIMI_K26_TAILSCALE.md`) is recommended.

---

## Appendix B: Related Links

- Moonshot Kimi K2.6 pricing: <https://platform.kimi.ai/docs/pricing/chat-k26>
- openclaude (npm): <https://www.npmjs.com/package/@gitlawb/openclaude>
- openclaude (GitHub): <https://github.com/gitlawb/openclaude>
- Cloudflare Tunnel docs: <https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/>
- LiteLLM (alternative proxy): <https://github.com/BerriAI/litellm>
