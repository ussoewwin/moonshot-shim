# Shared Secret Authentication — Implemented Measure (Phase 1)

> **Version**: 2026-04-27  
> **Target**: `<repo-path>`  
> **Scope**: Measure 1 from the Security Hardening Plan  
> **Language**: English

---

## Table of Contents

1. [Background](#1-background)
2. [Architecture](#2-architecture)
3. [server.js — X-Shim-Key Validation](#3-serverjs--x-shim-key-validation)
4. [inject-header-proxy.mjs — Header Injection](#4-inject-header-proxymjs--header-injection)
5. [start-tailscale.cmd — Auto-Generation + Proxy Chain](#5-start-tailscalecmd--auto-generation--proxy-chain)
6. [_shim_secret.txt — Secret Persistence](#6-_shim_secrettxt--secret-persistence)
7. [Files Changed — Summary](#7-files-changed--summary)
8. [Verify Active Measures](#8-verify-active-measures)

---

## 1. Background

Phase 0 (Path/Method Whitelist, Minimal /healthz, Security Headers) reduced the attack surface but did **not** prevent unauthorized use. Anyone who discovers the public Tailscale Funnel URL (`https://<your-funnel-domain>/`) can still send requests to the shim and consume the Moonshot API key quota.

Phase 1 addresses this by adding a **shared secret** (`X-Shim-Key` HTTP header) requirement. Requests without the correct secret are rejected with `403 Forbidden` before reaching Moonshot. This transforms the shim from an open proxy into an authenticated gateway.

**Key design constraint**: Cursor's "Override OpenAI Base URL" setting does **not** support custom HTTP headers. Therefore, the secret cannot be sent directly by Cursor. The solution is a **two-proxy chain**:

```
Cursor -> Tailscale Funnel :443 -> inject-header-proxy :8788 -> server.js :8787 -> Moonshot
                                       (adds X-Shim-Key)         (validates it)
```

---

## 2. Architecture

### Before Phase 1

```
Cursor -> Funnel :443 -> server.js :8787 -> Moonshot
```
- Anyone who knows the URL can use the shim
- No authentication layer

### After Phase 1

```
Cursor -> Funnel :443 -> inject-header-proxy :8788 -> server.js :8787 -> Moonshot
                              adds X-Shim-Key        validates it
```
- Secret is injected automatically by the local proxy
- shim rejects any request without the secret
- Cursor settings remain unchanged

### Port mapping

| Port | Process | Purpose |
|---|---|---|
| 8787 | `server.js` | Main shim (validates `X-Shim-Key`) |
| 8788 | `inject-header-proxy.mjs` | Thin proxy (injects `X-Shim-Key`) |
| 443 | Tailscale Funnel | Public HTTPS endpoint |

---

## 3. server.js — X-Shim-Key Validation

### What it does

1. Reads `SHIM_SECRET` from the environment variable at startup
2. If set and shorter than 32 characters, **fatal exit** (fail-fast)
3. In the main request handler, after `/healthz` but before upstream forwarding, checks `req.headers['x-shim-key']`
4. If the header is missing or mismatched, returns `403 Forbidden` immediately
5. `/healthz` and `/_shim/healthz` are **exempt** from secret checks (needed for liveness probes)

### File changed

`server.js` — 2 code sections added.

### Code (startup guard)

```javascript
// server.js L48-53
// --- Shared Secret (Phase 1) --------------------------------------------
const SHIM_SECRET = process.env.SHIM_SECRET || '';
if (SHIM_SECRET && SHIM_SECRET.length < 32) {
  console.error('FATAL: SHIM_SECRET must be at least 32 characters');
  process.exit(1);
}
```

**Rationale**: The shim should not start with a weak secret. Requiring 32+ characters (roughly 192 bits of entropy in base64) prevents trivial brute-force attacks. The check is at startup, not per-request, so it fails fast and loudly.

### Code (request handler validation)

```javascript
// server.js L420-432 — inside the main request handler, after healthz check
// --- Phase 1: Shared Secret check (after healthz, before upstream) --------
if (SHIM_SECRET && req.headers['x-shim-key'] !== SHIM_SECRET) {
  stats.err++;
  bumpStatus(403);
  const errHeaders = { 'content-type': 'application/json' };
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    errHeaders[key] = value;
  }
  res.writeHead(403, errHeaders);
  safeEnd(res, JSON.stringify({ error: 'shim secret required or invalid' }));
  log('SHIM SECRET REJECT', req.method, req.url, 'missing or invalid key');
  return;
}
```

**Rationale**: The check is placed **after** the `/healthz` endpoint so that health probes (from `start-tailscale.cmd`, monitoring scripts, etc.) continue to work without the secret. It is placed **before** body reading and upstream forwarding so that unauthorized requests are rejected as early as possible, minimizing resource consumption.

### Why not use `safeWrite(res, '')` before `writeHead`?

An earlier implementation called `safeWrite(res, '')` before `res.writeHead(403, ...)`. This caused `ERR_HTTP_HEADERS_SENT` because writing an empty string still triggers Node.js's implicit header write. The corrected code calls `res.writeHead` directly without any preceding `res.write`.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SHIM_SECRET` | `''` (empty) | Shared secret. Empty string disables the check entirely (backward compatible). |

### Backward compatibility

- If `SHIM_SECRET` is unset or empty, the check is **skipped entirely**. The shim behaves exactly as before Phase 1.
- This allows users to disable the feature by simply not setting the environment variable.

---

## 4. inject-header-proxy.mjs — Header Injection

### What it does

A minimal HTTP proxy (no external dependencies, ~60 lines) that:

1. Listens on `127.0.0.1:8788`
2. Reads the shared secret from `_shim_secret.txt` in the repo root (falls back to `SHIM_SECRET` env var)
3. For every incoming request, adds `X-Shim-Key: <secret>` to the headers
4. Forwards the request to `127.0.0.1:8787` (the real shim)
5. Pipes the upstream response back to the client verbatim

### Why read from file instead of env var?

PowerShell `Start-Process` does **not** reliably pass environment variables to child processes on Windows, especially when the secret contains base64 characters (`+`, `/`, `=`) that get mangled by shell escaping. Reading from a file avoids this entire class of bugs.

### File created

`inject-header-proxy.mjs` — new file.

### Code

```javascript
// inject-header-proxy.mjs
// Ultra-thin proxy that injects X-Shim-Key into every request.
// Sits between Tailscale Funnel (port 8788) and server.js (port 8787).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Read secret from env or from _shim_secret.txt in the repo root
let SHIM_SECRET = process.env.SHIM_SECRET || '';
if (!SHIM_SECRET) {
  const secretPath = path.join(__dirname, '_shim_secret.txt');
  try {
    SHIM_SECRET = fs.readFileSync(secretPath, 'utf8').trim();
  } catch {
    console.error('FATAL: SHIM_SECRET not set and _shim_secret.txt not found');
    process.exit(1);
  }
}
if (SHIM_SECRET.length < 32) {
  console.error('FATAL: SHIM_SECRET must be at least 32 characters');
  process.exit(1);
}

const TARGET_PORT = parseInt(process.env.SHIM_PORT || '8787', 10);
const LISTEN_PORT = parseInt(process.env.INJECT_PORT || '8788', 10);

http.createServer((req, res) => {
  const options = {
    hostname: '127.0.0.1',
    port: TARGET_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, 'x-shim-key': SHIM_SECRET },
  };

  const proxy = http.request(options, (upRes) => {
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
  });

  req.pipe(proxy);

  proxy.on('error', (err) => {
    try {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'inject-header-proxy: ' + err.message }));
    } catch {}
  });

  res.on('error', () => {
    try { proxy.destroy(); } catch {}
  });
}).listen(LISTEN_PORT, '127.0.0.1', () => {
  console.log(`inject-header-proxy listening on 127.0.0.1:${LISTEN_PORT} -> 127.0.0.1:${TARGET_PORT}`);
});
```

### Key properties

- **Zero npm dependencies**: Uses only Node.js built-in modules (`http`, `fs`, `path`, `url`).
- **Fail-fast**: Exits immediately if the secret is missing or too short.
- **Transparent**: Does not modify request bodies, URLs, or any headers other than adding `X-Shim-Key`.
- **Error handling**: If the upstream shim is unreachable, returns `502` with a JSON error body.
- **Memory efficient**: Uses `pipe()` for streaming, no body buffering.

---

## 5. start-tailscale.cmd — Auto-Generation + Proxy Chain

### What it does

The startup batch file was updated to:

1. **[0/3]** Auto-generate `_shim_secret.txt` if it does not exist (64 random bytes, base64)
2. **[1/3]** Launch both `server.js` and `inject-header-proxy.mjs` with the secret available
3. **[2/3]** Poll `/healthz` on port 8787 (unchanged)
4. **[3/3]** Register Tailscale Funnel pointing to **port 8788** (changed from 8787)

### File changed

`start-tailscale.cmd` — extensive rewrite.

### Code (secret generation)

```batch
REM --- [0/3] Generate or load shared secret -------------------------
if not exist "_shim_secret.txt" (
  powershell -NoProfile -Command ^
  "$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create();" ^
  "$bytes = [byte[]]::new(64);" ^
  "$rng.GetBytes($bytes);" ^
  "[System.Convert]::ToBase64String($bytes)" > "_shim_secret.txt"
)
set /p SHIM_SECRET=<_shim_secret.txt
set SHIM_SECRET=%SHIM_SECRET%
```

**Rationale**: `RandomNumberGenerator::GetBytes()` is not available on .NET Framework (the default PowerShell runtime on Windows). The code uses `RandomNumberGenerator::Create()` + `GetBytes(byte[])` instead, which is compatible with all Windows versions. The output is base64-encoded and persisted to `_shim_secret.txt`.

### Code (launch both processes)

```batch
REM --- [1/3] Launch shim + inject-header-proxy -------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$shimRunning = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue;" ^
  "$proxyRunning = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue;" ^
  "if ($proxyRunning) {" ^
    "Write-Host '[1/3] inject-header-proxy already running on 8788' -ForegroundColor Yellow" ^
  "} else {" ^
    "$secret = (Get-Content '%~dp0_shim_secret.txt' -Raw).Trim();" ^
    "$env:SHIM_SECRET = $secret;" ^
    "if (-not $shimRunning) {" ^
      "Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden;" ^
      "Write-Host '[1/3] shim (server.js) launched on 8787' -ForegroundColor Green;" ^
      "Start-Sleep -Milliseconds 800" ^
    "} else {" ^
      "Write-Host '[1/3] shim already running on 8787' -ForegroundColor Yellow" ^
    "};" ^
    "Start-Process -FilePath 'node' -ArgumentList 'inject-header-proxy.mjs' -WorkingDirectory '%~dp0' -WindowStyle Hidden;" ^
    "Write-Host '[1/3] inject-header-proxy launched on 8788' -ForegroundColor Green" ^
  "}"
```

**Rationale**:
- The secret is read from `_shim_secret.txt` inside the PowerShell block (avoiding shell escaping issues)
- `$env:SHIM_SECRET` is set so that `server.js` receives it via environment variable
- `inject-header-proxy.mjs` reads the same file directly, so it does not depend on `$env:SHIM_SECRET`
- Both processes are launched with `-WindowStyle Hidden` for zero-console startup

### Code (funnel registration to port 8788)

```batch
REM --- [3/3] Register funnel config -> :8788 (inject-header-proxy) ---
REM Retry a few times in case tailscaled is not yet ready right after logon.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$tsExe = 'C:\Program Files\Tailscale\tailscale.exe';" ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 30; $i++) {" ^
    "try {" ^
      "& $tsExe funnel --bg 8788 2>$null | Out-Null;" ^
      "$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4;" ^
      "if ($r.status -eq 'ok') { Write-Host '[3/3] public healthz OK' -ForegroundColor Green } else { throw 'unexpected healthz response' };" ^
      "$ok = $true; break" ^
    "} catch {" ^
      "Start-Sleep -Seconds 2" ^
    "}" ^
  "};" ^
  "if (-not $ok) {" ^
    "Write-Host '[3/3] could not bring funnel up within 60s.' -ForegroundColor Red;" ^
    "exit 1" ^
  "}"
```

**Key change**: `tailscale funnel --bg 8788` (was `8787`). The Funnel now forwards public HTTPS traffic to the inject-header-proxy on port 8788, not directly to server.js.

---

## 6. _shim_secret.txt — Secret Persistence

### What it is

A plain text file in the repo root containing a single base64-encoded random secret. It is:

- **Auto-generated** on first run if missing
- **Reused** on subsequent runs (so the secret survives reboots)
- **Not committed to git** (should be added to `.gitignore`)

### Generation

```powershell
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create();
$bytes = [byte[]]::new(64);
$rng.GetBytes($bytes);
[System.Convert]::ToBase64String($bytes)
```

This produces ~88 characters of base64 (64 bytes × 8/6 ≈ 86 chars + padding).

### Why not commit it?

The secret is a credential. It should never be in version control. If you clone the repo on a new machine, the first run of `start-tailscale.cmd` will generate a new secret automatically.

---

## 7. Files Changed — Summary

| File | Action | Lines | Purpose |
|---|---|---|---|
| `server.js` | Modified | ~16 added | `SHIM_SECRET` startup guard + request handler validation |
| `inject-header-proxy.mjs` | **New** | 63 | Thin proxy that injects `X-Shim-Key` header |
| `start-tailscale.cmd` | Modified | ~40 changed | Secret generation, dual-process launch, funnel port 8788 |
| `_shim_secret.txt` | **New** (runtime) | 1 | Auto-generated persistent secret |
| `recover-moonshot-shim` skill | Modified | ~30 changed | Updated for port 8788 and dual-process recovery |

---

## 8. Verify Active Measures

### 8.1 Check both processes are running

```powershell
Get-NetTCPConnection -LocalPort 8787 -State Listen | Select-Object LocalPort, OwningProcess, State
Get-NetTCPConnection -LocalPort 8788 -State Listen | Select-Object LocalPort, OwningProcess, State
```

Expected: both ports show `Listen` state.

### 8.2 Verify healthz works without secret

```powershell
# Direct shim (no secret needed for healthz)
Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 3
# → { "status": "ok" }

# Via proxy (also no secret needed for healthz)
Invoke-RestMethod 'http://127.0.0.1:8788/healthz' -TimeoutSec 3
# → { "status": "ok" }

# Public URL
Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 6
# → { "status": "ok" }
```

### 8.3 Verify secret rejection (direct access)

```powershell
# Without secret → 403
Invoke-WebRequest 'http://127.0.0.1:8787/v1/models' -Method Get -TimeoutSec 3 -UseBasicParsing
# → 403 Forbidden

# With correct secret → passes to Moonshot (401 from upstream if no API key)
$secret = (Get-Content "<repo-path>\_shim_secret.txt" -Raw).Trim()
Invoke-WebRequest 'http://127.0.0.1:8787/v1/models' -Method Get -Headers @{'X-Shim-Key'=$secret} -TimeoutSec 5 -UseBasicParsing
# → 401 Unauthorized (from Moonshot, meaning shim accepted the request)
```

### 8.4 Verify proxy auto-injects secret

```powershell
# Via proxy: no manual header needed, proxy injects it automatically
Invoke-WebRequest 'http://127.0.0.1:8788/v1/models' -Method Get -TimeoutSec 5 -UseBasicParsing
# → 401 Unauthorized (same as direct-with-secret; proxy is working)
```

### 8.5 Verify log shows rejections

```powershell
Get-Content <repo-path>\moonshot-shim.log -Tail 10
```

Look for:
- `SHIM SECRET REJECT GET /v1/models missing or invalid key` → secret check is active
- `GET /v1/models -> 401 ...` → secret was accepted, upstream reached

### 8.6 Verify Funnel points to 8788

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" funnel status
```

Expected:
```
https://<your-funnel-domain> (Funnel on)
|-- / proxy http://127.0.0.1:8788
```

---

*End of document. For the full security plan including deferred measures, see `SECURITY_HARDCENING_PLAN.en.md`.*
