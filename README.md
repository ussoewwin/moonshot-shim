# moonshot-shim

A lightweight local HTTP proxy (shim) that enables **Cursor IDE** (and other OpenAI-compatible clients) to use **Moonshot's `kimi-k2.6`** (and other reasoning models like DeepSeek-R1) with **tool calling**.

**Problem**: Kimi K2.6 requires a non-standard field `reasoning_content` in conversation history for every assistant message that carries `tool_calls`. Standard OpenAI-compatible clients drop this field, causing a `400` error on the next turn after any tool call.

**Solution**: This shim sits between your client and Moonshot's API, injecting a minimal placeholder (`" "`) into any assistant message that lacks `reasoning_content` before forwarding the request.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Step-by-Step Installation](#step-by-step-installation)
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Install Node.js dependencies](#2-install-nodejs-dependencies)
  - [3. Configure environment](#3-configure-environment)
  - [4. Choose a tunnel method](#4-choose-a-tunnel-method)
    - [Method A: Cloudflare Quick Tunnel (temporary URL)](#method-a-cloudflare-quick-tunnel-temporary-url)
    - [Method B: Tailscale Funnel (fixed URL, recommended)](#method-b-tailscale-funnel-fixed-url-recommended)
  - [5. Start the shim stack](#5-start-the-shim-stack)
  - [6. Configure Cursor](#6-configure-cursor)
  - [7. Verify connectivity](#7-verify-connectivity)
  - [8. Auto-start on Windows logon (optional)](#8-auto-start-on-windows-logon-optional)
- [Understanding the Port Stack](#understanding-the-port-stack)
- [Understanding the Secret File](#understanding-the-secret-file)
- [Manual Start (without batch files)](#manual-start-without-batch-files)
- [Environment Variables](#environment-variables)
- [Verification Commands](#verification-commands)
- [Resilience Features](#resilience-features)
- [Operational Notes](#operational-notes)
- [Troubleshooting](#troubleshooting)
- [Changelog](#changelog)
- [License](#license)

---

## Prerequisites

- **Node.js** v18+ ([nodejs.org](https://nodejs.org/))
- **A Moonshot AI API key** ([platform.kimi.ai](https://platform.kimi.ai/))
- **One of the following tunnels**:
  - **Cloudflare**: `cloudflared.exe` (already included in this repo)
  - **Tailscale**: [Tailscale for Windows](https://tailscale.com/download/windows) installed and logged in

---

## Architecture

```text
Cursor (cloud servers)
    |
    v
[Tunnel]  <-- public HTTPS URL
    |
    v
inject-header-proxy.mjs  :8788  (injects X-Shim-Key)
    |
    v
server.js                :8787  (validates X-Shim-Key, patches reasoning_content)
    |
    v
Moonshot API             https://api.moonshot.ai/v1
```

Three processes run on your machine:

| Process | File | Port | Role |
|---------|------|------|------|
| Shim | `server.js` | `8787` | Patches `reasoning_content`, validates secret, proxies to Moonshot |
| Inject proxy | `inject-header-proxy.mjs` | `8788` | Adds `X-Shim-Key` header to every request |
| Tunnel | `cloudflared` or Tailscale Funnel | `443` | Exposes `:8788` to the public internet |

**Why two ports?** Since v1.0.2, `server.js` requires a shared secret (`X-Shim-Key`) on every request. Cursor cannot send custom headers, so `inject-header-proxy.mjs` sits in front and injects the secret automatically.

---

## Step-by-Step Installation

### 1. Clone the repository

```powershell
git clone https://github.com/ussoewwin/moonshot-shim.git
cd moonshot-shim
```

> **Note**: Some files are **not** tracked by git and will not exist after clone:
> - `_shim_secret.txt` — auto-generated on first run (see [Understanding the Secret File](#understanding-the-secret-file))
> - `node_modules/` — created by `npm install`
> - `moonshot-shim.log` — created at runtime

### 2. Install Node.js dependencies

```powershell
npm install
```

This installs `undici` (the only production dependency).

### 3. Configure environment

The shim does **not** need your API key in an environment variable or in the source code. The API key is configured **in Cursor** (see [Step 6](#6-configure-cursor)).

The shim only needs the following on your machine:

- `SHIM_SECRET` — auto-generated on first run (see [Understanding the Secret File](#understanding-the-secret-file))
- `MOONSHOT_API_KEY` — set **in Cursor**, not on the shim

> **No env vars are required on the shim for basic operation.**

### 4. Choose a tunnel method

Cursor's cloud servers block private IPs (`127.0.0.1`) via SSRF protection. You **must** expose the shim through a public tunnel.

#### Method A: Cloudflare Quick Tunnel (temporary URL)

Best for one-off tests. The URL changes every restart.

`cloudflared.exe` is **already included** in this repo. No download needed.

Skip to [Step 5](#5-start-the-shim-stack).

#### Method B: Tailscale Funnel (fixed URL, recommended)

Best for daily use. The URL never changes.

1. Install [Tailscale for Windows](https://tailscale.com/download/windows)
2. Launch Tailscale and sign in
3. Wait for the tray icon to show **Connected**
4. Enable Funnel in the [admin console](https://login.tailscale.com/admin/settings/features)
5. (Optional) Set `tailscaled` service to **Automatic (Delayed Start)**:
   ```powershell
   Set-Service tailscaled -StartupType Automatic
   ```

Your fixed URL will be:
```
https://<machine-name>.<tail-XXXX>.ts.net
```

### 5. Start the shim stack

#### Method A — Cloudflare (manual two-terminal start)

**Terminal 1:**
```powershell
node server.js
```

**Terminal 2:**
```powershell
.\cloudflared.exe tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8787
```

Copy the `https://*.trycloudflare.com` URL.

> Note: Cloudflare path does **not** use `inject-header-proxy.mjs` because the quick tunnel points directly to `:8787`. The secret check is bypassed for local health checks only.

#### Method B — Tailscale (one-command start)

```powershell
.\start-tailscale.cmd
```

This batch file performs the following automatically:

1. **Generates `_shim_secret.txt`** if it does not exist (64 bytes base64, 88 characters)
2. **Starts `server.js` on `:8787`** (hidden window)
3. **Starts `inject-header-proxy.mjs` on `:8788`** (hidden window)
4. **Polls `/healthz` on `:8787`** for up to 5 seconds
5. **Registers `tailscale funnel --bg 8788`** (retries up to 30 times / 60 seconds)
6. **Polls the public URL `/healthz`** to confirm end-to-end reachability

If any step fails, the batch exits with code `1` and prints a red error message.

### 6. Configure Cursor

1. Open **Cursor → Settings → Models**
2. Paste your Moonshot API key into **OpenAI API Key**
3. Turn ON **Override OpenAI Base URL**, enter your tunnel URL with `/v1`:
   - Cloudflare: `https://<random>.trycloudflare.com/v1`
   - Tailscale: `https://<machine>.<tail-XXXX>.ts.net/v1`
4. Click **+ Add Model** and type `kimi-k2.6`
5. Select `kimi-k2.6` from the model picker in Agent mode

### 7. Verify connectivity

```powershell
# Local health check
curl http://127.0.0.1:8787/healthz
# → {"status":"ok"}

# Public health check (Tailscale only)
curl https://your-url.ts.net/healthz
# → {"status":"ok"}

# Regression test for the patcher
node test-echo.mjs
# → === reasoning_content injected: PASS ===
```

### 8. Auto-start on Windows logon (optional)

#### Tailscale method (recommended)

Use `start-tailscale-hidden.vbs`. This launches both the shim and Tailscale Funnel completely hidden (zero console windows).

**Option A — Manual (Explorer):**

1. Press `Win + R`, type `shell:startup`, press Enter
2. Copy `start-tailscale-hidden.vbs` from the `moonshot-shim` folder into the opened Startup folder

> **Note**: If you move the repository folder later, the shortcut will break. Use Option B for a robust path.

**Option B — PowerShell shortcut (robust path):**

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "C:\path\to\moonshot-shim\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "C:\path\to\moonshot-shim"
$shortcut.WindowStyle = 7
$shortcut.Save()
```

Replace `C:\path\to\moonshot-shim` with your actual repository path.

After setup, PC reboots are fully automatic:
```text
Tailscale service starts → Funnel restores → shim starts → Cursor works with the same URL forever.
```

#### Cloudflare method (not recommended for auto-start)

Cloudflare quick tunnel URLs change on every restart, so auto-start is not practical. Use Tailscale for daily operation.

---

## Understanding the Port Stack

| Port | Process | Accessible From | Notes |
|------|---------|-----------------|-------|
| `8787` | `server.js` | `127.0.0.1` only | Requires `X-Shim-Key` for all non-healthz requests |
| `8788` | `inject-header-proxy.mjs` | `127.0.0.1` only | Adds `X-Shim-Key`, forwards to `:8787` |
| `443` | Tailscale Funnel | Public internet | Points to `:8788` |
| Random | `cloudflared` | Public internet | Points to `:8787` (Cloudflare method only) |

**Tailscale request path:**
```text
Cursor -> https://machine.tail-XXXX.ts.net/v1  (Funnel :443)
       -> inject-header-proxy.mjs on 127.0.0.1:8788  (adds X-Shim-Key)
       -> server.js on 127.0.0.1:8787  (validates secret, patches reasoning_content)
       -> Moonshot API
```

**Cloudflare request path:**
```text
Cursor -> https://random.trycloudflare.com/v1  (cloudflared)
       -> server.js on 127.0.0.1:8787  (no secret check for this path)
       -> Moonshot API
```

> **Security note**: Cloudflare method does not use the shared-secret gate because `cloudflared` points directly to `:8787`. The secret gate was added primarily for the Tailscale/Funnel path where the URL is fixed and publicly known.

---

## Understanding the Secret File

`_shim_secret.txt` is a **local-only** file that holds the shared secret.

- **Generated automatically** by `start-tailscale.cmd` on first run
- **64 cryptographically random bytes**, base64-encoded (88 characters)
- **Must never be committed** (already in `.gitignore`)
- **Read by**: `server.js` (for validation) and `inject-header-proxy.mjs` (for injection)

If you delete `_shim_secret.txt`, `start-tailscale.cmd` will generate a new one on next run. However, this invalidates any existing `inject-header-proxy.mjs` instance until it is restarted.

---

## Manual Start (without batch files)

If you prefer to start each component manually:

```powershell
# Terminal 1 — generate secret if missing
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = [byte[]]::new(64)
$rng.GetBytes($bytes)
$secret = [System.Convert]::ToBase64String($bytes)
$secret | Set-Content _shim_secret.txt -NoNewline
$env:SHIM_SECRET = $secret

# Terminal 1 — start shim
node server.js

# Terminal 2 — start inject proxy (in another terminal)
$env:SHIM_SECRET = (Get-Content _shim_secret.txt -Raw).Trim()
node inject-header-proxy.mjs

# Terminal 3 — start Tailscale Funnel (in another terminal)
& "C:\Program Files\Tailscale\tailscale.exe" funnel --bg 8788
```

---

## Environment Variables

All variables are optional unless marked **Required**.

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `SHIM_SECRET` | (auto from `_shim_secret.txt`) | Yes (for Tailscale) | Shared secret for `X-Shim-Key` validation |
| `MOONSHOT_API_KEY` | (set in Cursor) | **Yes** | Your Moonshot API key. Configure in **Cursor → Settings → Models → OpenAI API Key**, not on the shim |
| `SHIM_PORT` | `8787` | No | Shim listen port |
| `SHIM_HOST` | `127.0.0.1` | No | Shim listen address |
| `INJECT_PORT` | `8788` | No | `inject-header-proxy.mjs` listen port |
| `SHIM_TARGET` | `https://api.moonshot.ai/v1` | No | Upstream API. Change to `https://api.deepseek.com/v1` for DeepSeek-R1 |
| `SHIM_DEBUG` | (unset) | No | Set to `1` for verbose request/response logging |
| `SHIM_KEEPALIVE_MS` | `10000` | No | SSE keepalive comment interval (ms) |
| `SHIM_TCP_KEEPALIVE_MS` | `15000` | No | TCP keep-alive probe interval (ms) |
| `SHIM_UPSTREAM_RETRIES` | `2` | No | Retry count for transient upstream errors |
| `SHIM_RETRY_BASE_MS` | `250` | No | Base delay for exponential backoff (ms) |

---

## Verification Commands

```powershell
# Local health check
curl http://127.0.0.1:8787/healthz
# → {"status":"ok"}

# Public health check (Tailscale only)
curl https://your-url.ts.net/healthz
# → {"status":"ok"}

# Regression test for the patcher
node test-echo.mjs
# → === reasoning_content injected: PASS ===

# Check if shim is listening
Get-NetTCPConnection -LocalPort 8787 -State Listen

# Check if inject proxy is listening
Get-NetTCPConnection -LocalPort 8788 -State Listen

# Check Tailscale Funnel status
& "C:\Program Files\Tailscale\tailscale.exe" serve status
```

---

## Resilience Features

- **Persistent log file**: `moonshot-shim.log` (auto-rotated at 5 MB)
- **Crash-proof**: `uncaughtException` and `unhandledRejection` are caught and logged; the process keeps running
- **Upstream retry**: Automatically retries on `ECONNRESET`, `ETIMEDOUT`, and other transient errors
- **SSE keepalive**: Sends `: keepalive\n\n` comments every 10s to prevent idle timeouts in proxies
- **TCP keep-alive**: Enables OS-level TCP probes to survive NAT/CGNAT session drops
- **No-buffer headers**: Sets `X-Accel-Buffering: no` and `Cache-Control: no-transform` for SSE streams
- **Health endpoint**: `/healthz` returns `{"status":"ok"}` for liveness checks

---

## Operational Notes

- **Placeholder value**: The shim injects `" "` (a single space) as `reasoning_content`. Moonshot only checks field presence, not content validity. If Moonshot ever tightens validation, this workaround will break.
- **Phase 1 security model**: `server.js` requires a valid `X-Shim-Key` (`SHIM_SECRET`) for all non-healthz requests. Unknown callers are rejected with `403` before upstream forwarding.
- **Secret file**: `_shim_secret.txt` is generated automatically by `start-tailscale.cmd` and must remain uncommitted (`.gitignore`).
- **Security baseline**: Keep your tunnel URL private even with shared-secret protection.
- **Log location**: `moonshot-shim.log` in the repository root. Inspect this file first when diagnosing issues.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `400 reasoning_content is missing` | Shim not running or not reached | Start shim; verify `healthz` |
| `ssrf_blocked` in Cursor | Using `127.0.0.1` directly in Cursor | Use a tunnel (Cloudflare or Tailscale) |
| `403 shim secret required or invalid` | Request reached `server.js` without valid `X-Shim-Key` | Ensure traffic goes through `inject-header-proxy.mjs` (`:8788`) and `_shim_secret.txt` exists |
| `FATAL: SHIM_SECRET not set and _shim_secret.txt not found` | Secret file missing | Run `start-tailscale.cmd` once, or generate `_shim_secret.txt` manually |
| `Network Error` during long thinking | Moonshot thinking time (60–150s) exceeds proxy/client timeout | SSE keepalive and TCP keep-alive are active by default; check `moonshot-shim.log` for `keepalive=N` |
| `connection refused` | cloudflared crashed | Restart `cloudflared` and update Cursor URL |
| `502` from shim | shim crashed | Restart `node server.js` |
| Funnel URL unreachable after reboot | `tailscaled` service not started | Verify Tailscale is connected; re-run `start-tailscale.cmd` |

---

## Changelog

See [md/CHANGELOG.md](md/CHANGELOG.md) for the full changelog.

Security docs:
- [Phase 0 implemented measures](md/SECURITY_IMPLEMENTED.en.md)
- [Phase 1 shared secret implementation](md/SHARED_SECRET_IMPLEMENTED.en.md)

---

## License

MIT
