# Security Hardening — Implemented Measures

> **Version**: 2026-04-27  
> **Target**: `<repo-path>`  
> **Scope**: All measures that have been implemented and are currently active  
> **Language**: English

---

## Table of Contents

1. [Background](#1-background)
2. [Measure 7: Path/Method Whitelist](#2-measure-7-pathmethod-whitelist)
3. [Measure 8: Minimal /healthz Response](#3-measure-8-minimal-healthz-response)
4. [Measure 11: Security Headers](#4-measure-11-security-headers)
5. [Follow-up Fix: start-tailscale.cmd healthz Check](#5-follow-up-fix-start-tailscalecmd-healthz-check)
6. [Files Changed — Summary](#6-files-changed--summary)
7. [Verify Active Measures](#7-verify-active-measures)
8. [Remaining (Planned but Not Yet Implemented)](#8-remaining-planned-but-not-yet-implemented)

---

## 1. Background

The `moonshot-shim` is a local HTTP proxy that sits between Cursor (or any OpenAI-compatible client) and Moonshot's Kimi K2.6 API. Its primary purpose is to inject `reasoning_content: " "` into assistant tool-call messages — a workaround required by Moonshot's thinking model validation.

The shim is exposed to the public internet via Tailscale Funnel (fixed HTTPS URL) or Cloudflare Quick Tunnel (ephemeral HTTPS URL). This exposure is necessary because Cursor's cloud backend has SSRF protection that blocks direct connections to `127.0.0.1`. However, it also means **anyone who knows the tunnel URL can send requests through the shim**, potentially consuming the Moonshot API key quota.

Three security measures (Phase 0 of the [Security Hardening Plan](./SECURITY_HARDCENING_PLAN.en.md)) have been implemented to reduce this attack surface. They were chosen for being zero-risk, zero-dependency, and providing immediate benefit.

---

## 2. Measure 7: Path/Method Whitelist

### What it does

Rejects requests targeting unexpected URL paths or using unexpected HTTP methods. Only the following paths and methods are allowed:

| Allowed Paths | Purpose |
|---|---|
| `/chat/completions` | Main chat completion endpoint (POST) |
| `/models` | Model listing (GET) |
| `/completions` | Legacy completions (POST) |
| `/embeddings` | Embedding requests (POST) |
| `/healthz` | Liveness probe (GET) |
| `/_shim/healthz` | Alias health probe (GET) |

| Allowed Methods | Purpose |
|---|---|
| `GET` | Read-only queries |
| `POST` | Mutating requests / chat completions |
| `OPTIONS` | CORS preflight |

### Why it matters

Before this measure, the shim forwarded **any path and any method** to the upstream Moonshot API. An attacker probing `/admin`, `/debug`, `/config`, or sending `DELETE /v1/chat/completions` would have those requests forwarded verbatim to Moonshot. This:

- Leaks Moonshot API structure and error messages
- Enables probes for internal endpoints
- Causes undefined behavior from non-standard HTTP methods

After the whitelist, such requests are immediately rejected at the shim with `405 Method Not Allowed`.

### File changed

`server.js` — 2 code sections added.

### Code (definition)

```javascript
// server.js L48-57
const ALLOWED_PATHS = new Set([
  '/chat/completions',
  '/models',
  '/completions',
  '/embeddings',
  '/healthz',
  '/_shim/healthz',
]);
const ALLOWED_METHODS = new Set(['GET', 'POST', 'OPTIONS']);
```

### Code (enforcement)

```javascript
// server.js L382-395 — inside the main request handler, after URL parsing
const barePath = url.pathname.startsWith('/v1/')
  ? url.pathname.slice(3)
  : url.pathname;
if (!ALLOWED_PATHS.has(barePath) || !ALLOWED_METHODS.has(req.method)) {
  stats.err++;
  bumpStatus(405);
  const errHeaders = { 'content-type': 'application/json' };
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    errHeaders[key] = value;
  }
  safeWrite(res, '');
  res.writeHead(405, errHeaders);
  safeEnd(res, JSON.stringify({ error: 'path or method not allowed' }));
  return;
}
```

### How it works

1. The incoming URL path is normalized: `/v1/chat/completions` → `/chat/completions` (the `/v1/` prefix is stripped).
2. The bare path is checked against `ALLOWED_PATHS`. If not found → **405**.
3. The HTTP method is checked against `ALLOWED_METHODS`. If not found → **405**.
4. Security headers are always included in the error response (defense-in-depth).
5. Both `stats.err` counter and per-minute `bumpStatus(405)` are incremented for monitoring.

### Environment variables

None. This measure is always active with no configuration needed.

### Backward compatibility

Fully compatible. All legitimate requests use one of the allowed paths and POST/GET/OPTIONS. If a new Moonshot API endpoint needs to be added in the future, the set is trivially extensible.

### Diff summary

```
+ ALLOWED_PATHS definition (7 entries)
+ ALLOWED_METHODS definition (3 entries)
+ Early rejection in main handler (~12 lines)
```

---

## 3. Measure 8: Minimal /healthz Response

### What it does

Reduces the `/healthz` endpoint response to the bare minimum: only `{"status":"ok"}`.

### Before (original)

```json
{
  "ok": true,
  "uptimeSec": 12345,    // ←  System uptime exposed
  "target": "https://api.moonshot.ai/v1",  // ← Upstream URL exposed
  "pid": 25560            // ←  Process ID exposed
}
```

### After (current)

```json
{"status":"ok"}
```

### Why it matters

The `/healthz` endpoint is accessible via the public Tailscale Funnel URL (`https://<your-funnel-domain>/healthz`). Anyone who discovers the URL could previously learn:

1. **`uptimeSec`** — Confirms the shim is running and for how long (useful for reconnaissance).
2. **`target`** — Reveals the upstream Moonshot API URL (`api.moonshot.ai/v1`), providing a target for direct attacks.
3. **`pid`** — The internal process ID. While not directly exploitable alone, it aids local privilege escalation if combined with another vulnerability.

After this measure, the only information disclosed is that the shim is alive (`status: ok`). No operational metadata is leaked.

### File changed

`server.js` — 1 code section replaced.

### Code

```javascript
// server.js L397-406
if (url.pathname === '/healthz' || url.pathname === '/_shim/healthz') {
  const healthHeaders = { 'content-type': 'application/json' };
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    healthHeaders[key] = value;
  }
  res.writeHead(200, healthHeaders);
  res.end(JSON.stringify({ status: 'ok' }));
  return;
}
```

Note: Security headers (`X-Content-Type-Options`, `X-Frame-Options`, etc.) are also applied to the healthz response, ensuring consistent hardening.

### Environment variables

None.

### Compatibility note

Because the healthz response no longer contains `pid` or `uptimeSec`, any external script or startup batch file that parsed those fields will need updating. The `start-tailscale.cmd` batch file was fixed as a follow-up (see §5 below).

### Diff summary

```
- 4 fields in response (ok, uptimeSec, target, pid)
+ 1 field in response (status)
+ Security headers on healthz response
```

---

## 4. Measure 11: Security Headers

### What it does

Adds standard HTTP security headers to every response from the shim (success, error, healthz, all paths).

### Headers applied

| Header | Value | Purpose |
|---|---|---|
| `X-Content-Type-Options` | `nosniff` | Prevents MIME-type sniffing by the browser. Stops content-type confusion attacks. |
| `X-Frame-Options` | `DENY` | Prevents the page from being displayed in an iframe. Eliminates clickjacking risk. |
| `X-XSS-Protection` | `1; mode=block` | Enables XSS filter in older browsers (legacy but widely supported). |
| `Referrer-Policy` | `no-referrer` | Prevents the Referer header from leaking the shim URL to external sites. |

### Why it matters

The shim's HTTPS URL is publicly reachable via Tailscale Funnel. While the shim is not a web page, these headers provide defense-in-depth against:

- **MIME sniffing**: An attacker who tricks a browser into loading the shim's JSON response as a script or stylesheet (`nosniff` blocks this).
- **Clickjacking**: Embedding the shim URL in an iframe on a malicious page (`DENY` blocks this).
- **Referer leakage**: If a user accidentally accesses the shim URL in a browser, the `no-referrer` policy prevents the URL from appearing in the `Referer` header when navigating to other sites.

### File changed

`server.js` — 2 code sections added.

### Code (definition)

```javascript
// server.js L59-64
const SECURITY_HEADERS = {
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'x-xss-protection': '1; mode=block',
  'referrer-policy': 'no-referrer',
};
```

### Code (application)

```javascript
// server.js L501-504 — applied AFTER upstream response headers are copied
for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
  respHeaders[key] = value;
}
```

**Note on `Cache-Control`**: The shim already sets `Cache-Control: no-cache, no-transform` for SSE responses (chat completions with `stream: true`). The `SECURITY_HEADERS` object does **not** override this — SSE headers are set before the security headers loop, and there is no conflict. Non-SSE responses (errors, `/models`, healthz) receive only the default Node.js caching behavior plus the security headers.

### Environment variables

None.

### Compatibility

These headers are universally accepted by HTTP clients and proxies. They have no functional impact on legitimate API usage. All OpenAI-compatible SDKs ignore them or handle them transparently.

### Diff summary

```
+ SECURITY_HEADERS constant (4 headers)
+ Security header merge in main response path
+ Security header merge in 405 error response
+ Security header merge in healthz response
```

---

## 5. Follow-up Fix: start-tailscale.cmd healthz Check

### What it does

Fixes the healthz polling logic in `start-tailscale.cmd` that broke when `/healthz` response was minimized (Measure 8).

### Why it broke

Before Measure 8, `/healthz` returned:

```json
{"ok":true,"uptimeSec":12345,"target":"...","pid":25560}
```

The batch file used PowerShell's `Invoke-RestMethod` and accessed `$r.pid` and `$r.uptimeSec` from the response. After Measure 8, the response is:

```json
{"status":"ok"}
```

The fields `$r.pid` and `$r.uptimeSec` no longer exist. `Invoke-RestMethod` returns `$r.status` instead. In the old code, attempting to access `$r.pid` on the new response would throw an error. This error was caught by the `catch {}` block, causing the retry loop to spin for the full 5 seconds (10 attempts × 500ms) before timing out.

**However**, the shim itself was already running successfully by this point, so the timeout in step [2/3] did **not** prevent the funnel registration in step [3/3] from succeeding. The bug was invisible to the end user — the startup appeared to work, but the healthz check was silently failing every time.

### Fix applied

**File**: `start-tailscale.cmd` — 2 lines changed.

**Local healthz check (line 44):**

```batch
REM Before (broken):
"Write-Host ('[2/3] healthz OK pid={0} uptime={1}s' -f $r.pid, $r.uptimeSec)..."

REM After (fixed):
"if ($r.status -eq 'ok') { Write-Host '[2/3] healthz OK' } else { throw 'unexpected healthz response' };"
```

**Public healthz check (line 65):**

```batch
REM Before (broken):
"Write-Host ('[3/3] public healthz OK pid={0} uptime={1}s' -f $r.pid, $r.uptimeSec)..."

REM After (fixed):
"if ($r.status -eq 'ok') { Write-Host '[3/3] public healthz OK' } else { throw 'unexpected healthz response' };"
```

### Effect

- [2/3] now completes on the first or second attempt (500ms–1s instead of 5s timeout).
- [3/3] public healthz verification is also faster and correctly reports success.
- Both healthz checks now validate the actual response content (`$r.status -eq 'ok'`) rather than assuming success based on field access.

---

## 6. Files Changed — Summary

| File | Changes | Lines |
|---|---|---|
| `server.js` | Added `ALLOWED_PATHS` + `ALLOWED_METHODS` + early rejection (Measure 7) | ~22 |
| `server.js` | Replaced `/healthz` response with minimal `{"status":"ok"}` (Measure 8) | ~10 |
| `server.js` | Added `SECURITY_HEADERS` constant + merge into all responses (Measure 11) | ~10 |
| `start-tailscale.cmd` | Fixed local healthz check to use `$r.status` (Follow-up fix) | 1 line |
| `start-tailscale.cmd` | Fixed public healthz check to use `$r.status` (Follow-up fix) | 1 line |

Total non-comment lines added: **~44 lines** across 2 files.

---

## 7. Verify Active Measures

You can verify that all measures are active by running these commands from a PowerShell prompt:

### 7.1 Path whitelist test

```powershell
# Unauthorized path → should return 405
Invoke-WebRequest -Uri 'http://127.0.0.1:8787/admin' -UseBasicParsing -TimeoutSec 3
# → 405 Method Not Allowed

# Unauthorized method → should return 405
Invoke-WebRequest -Uri 'http://127.0.0.1:8787/v1/chat/completions' -Method DELETE -UseBasicParsing -TimeoutSec 3
# → 405 Method Not Allowed

# Authorized path → should return 200 (or auth error from Moonshot)
Invoke-WebRequest -Uri 'http://127.0.0.1:8787/v1/models' -UseBasicParsing -TimeoutSec 5
# → 200 (or 401 if no API key)
```

### 7.2 Minimal healthz test

```powershell
$r = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/healthz' -TimeoutSec 3
$r | ConvertTo-Json
# → {"status":"ok"}
# (no pid, no uptimeSec, no target)
```

### 7.3 Security headers test

```powershell
$r = Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -UseBasicParsing -TimeoutSec 3
$r.Headers
# Should contain:
#   X-Content-Type-Options → nosniff
#   X-Frame-Options → DENY
#   X-XSS-Protection → 1; mode=block
#   Referrer-Policy → no-referrer
```

### 7.4 Public endpoint (via Tailscale Funnel)

```powershell
# These tests go through the public HTTPS URL
$r = Invoke-RestMethod -Uri 'https://<your-funnel-domain>/healthz' -TimeoutSec 6
$r | ConvertTo-Json
# → {"status":"ok"}

# Unauthorized path via public URL
Invoke-WebRequest -Uri 'https://<your-funnel-domain>/debug' -UseBasicParsing -TimeoutSec 6
# → 405 Method Not Allowed
```

---

## 8. Remaining (Planned but Not Yet Implemented)

The following measures are defined in the [Security Hardening Plan](./SECURITY_HARDCENING_PLAN.en.md) but have **not** been implemented yet:

| Measure | Priority | Status |
|---|---|---|
| **Measure 1: Shared Secret** (`X-Shim-Key` header auth) | High | Planned — Phase 1 |
| **Measure 6: Body Size Limiter** (1 MB max request) | Medium | Planned — Phase 1 |
| **Measure 9: Content-Type Validation** (reject non-JSON POST) | Recommended | Planned — Phase 1 |
| **Measure 10: CORS Headers** (`Access-Control-*` + OPTIONS handling) | Recommended | Planned — Phase 1 |
| **Measure 2: Rate Limiting** (sliding window, 60 req/min) | High | Planned — Phase 2 |
| **Measure 3: Log Sanitization** | Low | Deferred |
| **Measure 4: TLS Termination** | N/A | Not needed (Tailscale WireGuard) |
| **Measure 5: Connection Limit** | Low | Deferred |

The highest-priority remaining measure is **Measure 1 (Shared Secret)**, which requires:

1. `server.js` — Add `X-Shim-Key` header validation (~30 lines)
2. `inject-header-proxy.mjs` — Create thin proxy to inject the header (~20 lines, new file)
3. `start-tailscale.cmd` — Add secret generation and proxy chain setup (~10 lines)
4. Cursor Override URL change from `:8787` to `:8788` (one-time manual update)

---

*End of document. For the full hardening plan including deferred measures, see `SECURITY_HARDCENING_PLAN.en.md`.*
