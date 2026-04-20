# moonshot-shim

A lightweight local HTTP proxy (shim) that enables **Cursor IDE** (and other OpenAI-compatible clients) to use **Moonshot's `kimi-k2.6`** (and other reasoning models like DeepSeek-R1) with **tool calling**.

**Problem**: Kimi K2.6 requires a non-standard field `reasoning_content` in conversation history for every assistant message that carries `tool_calls`. Standard OpenAI-compatible clients drop this field, causing a `400` error on the next turn after any tool call.

**Solution**: This shim sits between your client and Moonshot's API, injecting a minimal placeholder (`" "`) into any assistant message that lacks `reasoning_content` before forwarding the request.

---

## Table of Contents

- [Features](#features)
- [Supported Clients](#supported-clients)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Two Tunnel Methods](#two-tunnel-methods)
  - [A. Cloudflare Quick Tunnel (temporary URL)](#a-cloudflare-quick-tunnel-temporary-url)
  - [B. Tailscale Funnel (fixed URL)](#b-tailscale-funnel-fixed-url)
- [Cursor Settings](#cursor-settings)
- [Environment Variables](#environment-variables)
- [Verification](#verification)
- [Resilience Features](#resilience-features)
- [Operational Notes](#operational-notes)
- [Troubleshooting](#troubleshooting)
- [Prompt Cache Optimization](#prompt-cache-optimization)
- [License](#license)

---

## Features

- **Field injection**: Automatically patches `reasoning_content: " "` into assistant tool-call messages
- **Idempotent**: Same input → same output; doesn't touch messages that already have valid `reasoning_content`
- **Transparent**: Forwards auth headers, SSE streaming, errors, and all other API features unchanged
- **Resilient**: Persistent logging, auto-retry on upstream errors, SSE keepalive, TCP keep-alive, and graceful error handling
- **Dual tunnel support**: Works with both Cloudflare quick tunnels and Tailscale Funnel

## Supported Clients

| Client | Status | Notes |
|--------|--------|-------|
| **Cursor IDE** | ✅ Supported | This shim is primarily designed for Cursor |
| **openclaude** | ✅ Natively supported | GitHub HEAD has `preserveReasoningContent`; shim is optional |
| **Cline** | ❌ Waiting | Plugin update needed |
| **Google Antigravity** | ❌ Unsupported | Closed-source; cannot be modified |
| **Custom clients** | ✅ Supported | Implement `reasoning_content` preservation yourself, or use this shim |

## Prerequisites

- [Node.js](https://nodejs.org/) (v18+ recommended)
- A [Moonshot AI](https://platform.kimi.ai/) API key
- For external exposure: either [Cloudflare Tunnel (`cloudflared`)](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/) or [Tailscale](https://tailscale.com/) with Funnel enabled

## Quick Start

```bash
# 1. Clone or copy this folder
cd moonshot-shim

# 2. Install dependencies
npm install

# 3. Start the shim
node server.js
# → listening on http://127.0.0.1:8787
```

Since Cursor's cloud servers block private IPs (`127.0.0.1`) via SSRF protection, you need to expose the shim externally. Choose one of the two methods below.

---

## Two Tunnel Methods

### A. Cloudflare Quick Tunnel (temporary URL)

Best for quick tests. The URL changes on every restart.

```bash
# In a second terminal, from the same folder
.\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787
```

Copy the `https://*.trycloudflare.com` URL and append `/v1` for Cursor's **Override OpenAI Base URL**.

**Launcher**: Use `start-all.cmd` (opens a visible console showing the tunnel URL).

### B. Tailscale Funnel (fixed URL)

Best for daily use. The URL never changes, and setup is fully automated after the first run.

1. Install [Tailscale for Windows](https://tailscale.com/download/windows) and log in
2. Enable Funnel in the [Tailscale admin console](https://login.tailscale.com/admin/settings/features)
3. Run the launcher:
   ```bash
   .\start-tailscale.cmd
   ```

Your fixed URL will be `https://<machine>.<tail-XXXX>.ts.net/`.

**Auto-start on logon**: Use `start-tailscale-hidden.vbs` in your Windows startup folder (`shell:startup`). This launches both the shim and Tailscale Funnel completely hidden (zero console windows).

---

## Cursor Settings

1. Open Cursor → Settings → Models
2. Paste your Moonshot API key into **OpenAI API Key**
3. Turn ON **Override OpenAI Base URL**, enter your tunnel URL with `/v1`:
   ```
   https://your-url.trycloudflare.com/v1     # Cloudflare
   https://your-machine.tailXXXX.ts.net/v1   # Tailscale
   ```
4. Click **+ Add Model** and add `kimi-k2.6`
5. Select `kimi-k2.6` from the model picker in Agent mode

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SHIM_PORT` | `8787` | Shim listen port |
| `SHIM_HOST` | `127.0.0.1` | Shim listen address |
| `SHIM_TARGET` | `https://api.moonshot.ai/v1` | Upstream API. Change to `https://api.deepseek.com/v1` for DeepSeek-R1 |
| `SHIM_DEBUG` | (unset) | Set to `1` for verbose request/response logging |
| `SHIM_KEEPALIVE_MS` | `15000` | SSE keepalive comment interval (ms) |
| `SHIM_TCP_KEEPALIVE_MS` | `15000` | TCP keep-alive probe interval (ms) |
| `SHIM_UPSTREAM_RETRIES` | `2` | Retry count for transient upstream errors |
| `SHIM_RETRY_BASE_MS` | `250` | Base delay for exponential backoff (ms) |

## Verification

```bash
# Local health check
curl http://127.0.0.1:8787/healthz
# → {"ok":true,"uptimeSec":...,"target":"...","pid":...}

# Public health check (via your tunnel URL)
curl https://your-url.ts.net/healthz
# → same response

# Regression test for the patcher
node test-echo.mjs
# → === reasoning_content injected: PASS ===
```

## Resilience Features

- **Persistent log file**: `moonshot-shim.log` (auto-rotated at 5 MB)
- **Crash-proof**: `uncaughtException` and `unhandledRejection` are caught and logged; the process keeps running
- **Upstream retry**: Automatically retries on `ECONNRESET`, `ETIMEDOUT`, and other transient errors
- **SSE keepalive**: Sends `: keepalive\n\n` comments every 15s to prevent idle timeouts in proxies
- **TCP keep-alive**: Enables OS-level TCP probes to survive NAT/CGNAT session drops
- **No-buffer headers**: Sets `X-Accel-Buffering: no` and `Cache-Control: no-transform` for SSE streams

## Operational Notes

- **Placeholder value**: The shim injects `" "` (a single space) as `reasoning_content`. Moonshot only checks field presence, not content validity. If Moonshot ever tightens validation, this workaround will break.
- **Security**: The shim forwards your `Authorization` header directly to Moonshot. Requests without a valid Moonshot key are rejected with 401 by Moonshot itself. Keep your tunnel URL private.
- **Cache efficiency**: Use the same thread, same model, and a fixed placeholder value to maximize Moonshot's prompt cache hit rate (6× cheaper than misses).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `400 reasoning_content is missing` | Shim not running or not reached | Start shim; verify `healthz` |
| `ssrf_blocked` in Cursor | Using `127.0.0.1` directly in Cursor | Use a tunnel (Cloudflare or Tailscale) |
| `Network Error` during long thinking | Moonshot thinking time (60–150s) exceeds proxy/client timeout | SSE keepalive and TCP keep-alive are active by default; check `moonshot-shim.log` for `keepalive=N` |
| `connection refused` | cloudflared crashed | Restart `cloudflared` and update Cursor URL |
| `502` from shim | shim crashed | Restart `node server.js` |

## Prompt Cache Optimization

Moonshot prompt cache pricing:
- Cache HIT: $0.16 / 1M tokens
- Cache MISS: $0.95 / 1M tokens

Tips:
1. Load heavy context once at the start of a thread
2. Continue in the same thread; avoid `+ New Agent` mid-conversation
3. When switching topics, ask the model to summarize, then paste only the summary into a new thread

## License

MIT
