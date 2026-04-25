# moonshot-shim

A lightweight local HTTP proxy (shim) that enables **Cursor IDE** (and other OpenAI-compatible clients) to use **Moonshot's `kimi-k2.6`** (and other reasoning models like DeepSeek-R1) with **tool calling**.

**Problem**: Kimi K2.6 requires a non-standard field `reasoning_content` in conversation history for every assistant message that carries `tool_calls`. Standard OpenAI-compatible clients drop this field, causing a `400` error on the next turn after any tool call.

**Solution**: This shim sits between your client and Moonshot's API, injecting a minimal placeholder (`" "`) into any assistant message that lacks `reasoning_content` before forwarding the request.

---

## Table of Contents

- [Features](#features)
- [Supported Clients](#supported-clients)
- [Prerequisites](#prerequisites)
- [Quick Start — Shim Only](#quick-start--shim-only)
- [Cloudflare vs Tailscale (Pros / Cons)](#cloudflare-vs-tailscale-pros--cons)
- [Method A: Cloudflare Quick Tunnel](#method-a-cloudflare-quick-tunnel)
  - [A-1. Install cloudflared](#a-1-install-cloudflared)
  - [A-2. Start shim + tunnel](#a-2-start-shim--tunnel)
  - [A-3. Cursor Settings](#a-3-cursor-settings)
  - [A-4. After reboot](#a-4-after-reboot)
- [Method B: Tailscale Funnel](#method-b-tailscale-funnel)
  - [B-1. Install Tailscale](#b-1-install-tailscale)
  - [B-2. Enable Funnel](#b-2-enable-funnel)
  - [B-3. Start shim + funnel](#b-3-start-shim--funnel)
  - [B-4. Cursor Settings](#b-4-cursor-settings)
  - [B-5. Auto-start on logon](#b-5-auto-start-on-logon)
- [Environment Variables](#environment-variables)
- [Verification](#verification)
- [Resilience Features](#resilience-features)
- [Operational Notes](#operational-notes)
- [Troubleshooting](#troubleshooting)
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

Regardless of which tunnel method you choose, you need:

- [Node.js](https://nodejs.org/) (v18+ recommended)
- A [Moonshot AI](https://platform.kimi.ai/) API key

Then choose **one** of the two methods below.

---

## Quick Start — Shim Only

```bash
# 1. Clone or copy this folder
cd moonshot-shim

# 2. Install dependencies
npm install

# 3. Start the shim
node server.js
# → listening on http://127.0.0.1:8787
```

Since Cursor's cloud servers block private IPs (`127.0.0.1`) via SSRF protection, you need to expose the shim externally. Choose **Method A** or **Method B** below.

---

## Cloudflare vs Tailscale (Pros / Cons)

| Method | Pros | Cons |
|---|---|---|
| **Cloudflare Quick Tunnel** | Fast to start for one-off tests; no domain required; easy command-line launch (`cloudflared tunnel --url ...`) | URL changes every restart; manual Cursor URL update required after reboot; relies on Cloudflare quick-tunnel availability |
| **Tailscale Funnel** | Fixed URL; best for daily use; supports fully hidden auto-start on Windows logon; no repeated URL copy/paste | Requires Tailscale client installation and account login; Funnel must be enabled in admin console; first-time setup is slightly longer |

**Recommended choice**:
- Use **Cloudflare** for quick experiments and temporary sessions.
- Use **Tailscale** for stable day-to-day operation and automation.

---

## Method A: Cloudflare Quick Tunnel

Best for quick tests. The URL changes on every restart.

### A-1. Install cloudflared

`cloudflared.exe` is **not** included in this repo (see `.gitignore`). Download it manually:

1. Go to [cloudflared releases](https://github.com/cloudflare/cloudflared/releases)
2. Download `cloudflared-windows-amd64.exe`
3. Rename to `cloudflared.exe` and place it in the `moonshot-shim` folder

### A-2. Start shim + tunnel

Open two terminals.

**Terminal 1 — shim:**
```bash
node server.js
```

**Terminal 2 — tunnel:**
```bash
.\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787
```

Copy the `https://*.trycloudflare.com` URL.

Alternatively, use the launcher batch:
```bash
start-all.cmd
```

### A-3. Cursor Settings

1. Open Cursor → Settings → Models
2. Paste your Moonshot API key into **OpenAI API Key**
3. Turn ON **Override OpenAI Base URL**, enter the tunnel URL with `/v1`:
   ```
   https://<random>.trycloudflare.com/v1
   ```
4. Click **+ Add Model** and add `kimi-k2.6`
5. Select `kimi-k2.6` from the model picker in Agent mode

### A-4. After reboot

Cloudflare quick tunnel URLs change on every restart. After reboot:
1. Run `start-all.cmd` again
2. Copy the new URL into Cursor's Override OpenAI Base URL

---

## Method B: Tailscale Funnel

Best for daily use. The URL never changes, and setup is fully automated after the first run.

### B-1. Install Tailscale

1. Download and install [Tailscale for Windows](https://tailscale.com/download/windows)
2. Launch Tailscale and sign in with your account (Microsoft, Google, GitHub, or email)
3. Wait until the system tray icon shows **Connected**

### B-2. Enable Funnel

1. Open the [Tailscale admin console](https://login.tailscale.com/admin/settings/features)
2. Find **Funnel** and turn it **ON**
3. (Optional but recommended) Set `tailscaled` Windows service to **Automatic (Delayed Start)**:
   ```powershell
   Set-Service tailscaled -StartupType Automatic
   ```

### B-3. Start shim + funnel

```bash
start-tailscale.cmd
```

This will:
1. Start the shim on `127.0.0.1:8787` (if not already running)
2. Register `tailscale funnel --bg 8787`
3. Verify the public URL is reachable

Your fixed URL will be `https://<machine>.<tail-XXXX>.ts.net/`.

### B-4. Cursor Settings

1. Open Cursor → Settings → Models
2. Paste your Moonshot API key into **OpenAI API Key**
3. Turn ON **Override OpenAI Base URL**, enter the funnel URL with `/v1`:
   ```
   https://<machine>.<tail-XXXX>.ts.net/v1
   ```
4. Click **+ Add Model** and add `kimi-k2.6`
5. Select `kimi-k2.6` from the model picker in Agent mode

### B-5. Auto-start on logon

Use `start-tailscale-hidden.vbs` in your Windows startup folder (`shell:startup`). This launches both the shim and Tailscale Funnel completely hidden (zero console windows).

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "C:\path\to\moonshot-shim\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "C:\path\to\moonshot-shim"
$shortcut.WindowStyle = 7
$shortcut.Save()
```

After setup, PC reboots are fully automatic: Tailscale service starts → Funnel restores → shim starts → Cursor works with the same URL forever.

---

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

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `400 reasoning_content is missing` | Shim not running or not reached | Start shim; verify `healthz` |
| `ssrf_blocked` in Cursor | Using `127.0.0.1` directly in Cursor | Use a tunnel (Cloudflare or Tailscale) |
| `Network Error` during long thinking | Moonshot thinking time (60–150s) exceeds proxy/client timeout | SSE keepalive and TCP keep-alive are active by default; check `moonshot-shim.log` for `keepalive=N` |
| `connection refused` | cloudflared crashed | Restart `cloudflared` and update Cursor URL |
| `502` from shim | shim crashed | Restart `node server.js` |

## License

MIT
