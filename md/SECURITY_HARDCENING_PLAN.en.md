# Shim Security Hardening — Plan Document

> Version: 2026-04-26  
> Target: `server.js`  
> Scope: Planned changes only (not yet implemented)  
> Language: English

---

## 1. Background & Motivation

The moonshot-shim currently exposes `/v1/chat/completions` on `127.0.0.1:8787`, proxied to Moonshot via Cloudflare or Tailscale Funnel. Both tunnel methods make the URL publicly reachable over HTTPS. This design is necessary because Cursor's cloud blocks SSRF (`127.0.0.1`), but it creates an attack surface:

- **Tunnel URL discovery**: The `<random>.trycloudflare.com` URL can be guessed or leaked; with Tailscale it is fixed (`<machine>.tailXXXX.ts.net`). Anyone who knows the URL can send requests.
- **Authorization header passthrough**: The shim forwards the client's `Authorization` header verbatim. Without additional checks, any requester can use the Moonshot API key (embedded in the request from Cursor).
- **No usage caps**: Unlimited tokens are forwarded to Moonshot; a single attacker can burn through the quota.
- **Request body logging**: The current debug log does not mask prompt contents; verbose logs could expose conversation data.

This plan enumerates mitigation measures to harden the shim without breaking existing functionality.

---

## 2. Proposed Measures

### Measure 1: Shared Secret Authentication (Recommended)

**Threat addressed**: Unauthorized token theft, quota burning.

#### Concept

Add an environment variable `SHIM_SECRET` containing a randomly generated long string. Every incoming request must include this value as either:

| Header | Location | Example |
|--------|----------|---------|
| `X-Shim-Key` | Request header | `X-Shim-Key: abc123-secret-key-here` |

If the header is missing or mismatched, the shim returns `403 Forbidden` immediately without forwarding anything to Moonshot.

#### Implementation

```
Environment: SHIM_SECRET=<long-random-string>     # required; startup fails if unset
Request header check: req.headers['x-shim-key'] === process.env.SHIM_SECRET
Response on failure: 403 {"error":"shim secret required or invalid"}
```

##### Where to validate

In the main request handler, before reading the body:

```javascript
// After /healthz check, before everything else
if (process.env.SHIM_SECRET && req.headers['x-shim-key'] !== process.env.SHIM_SECRET) {
    stats.err++;
    bumpStatus(403);
    res.writeHead(403, { 'content-type': 'application/json' });
    safeEnd(res, JSON.stringify({ error: 'shim secret required or invalid' }));
    return;
}
```

##### Startup guard

Fail fast if `SHIM_SECRET` is set to a weak value:

```javascript
if (process.env.SHIM_SECRET && process.env.SHIM_SECRET.length < 32) {
    console.error('ERROR: SHIM_SECRET should be at least 32 characters');
    process.exit(1);
}
```

#### Pros

- Simple, zero new dependencies
- Transparent to Cursor (the proxy handles the header pass-through automatically)
- Effective against anyone who doesn't know the secret

#### Cons

- Requires users to configure the header. However, since this runs locally and Cursor sends all headers through the override URL, it is a one-time setup.
- Existing deployments must set the env var and restart.

#### Client-side configuration

For the current deployment (Cursor → Tunnel → Shim), the user must add one line to their Cursor settings:

1. Go to Settings → Models
2. Add the header `X-Shim-Key` with the secret value in the "Additional Headers" section (if available)
3. If no UI support, create a thin wrapper script that injects the header before calling Cursor

**Alternative: Auto-injection via local middleware**

A separate lightweight proxy step adds the header. Since the user already has the shim running, this can be done by modifying `start-tailscale.cmd`:

```batch
set HTTP_PROXY=http://127.0.0.1:8788
start node shim-with-secret.js ^
    --listen-port 8788 ^
    --target http://127.0.0.1:8787 ^
    --add-header X-Shim-Key %SHIM_SECRET%
```

Where `shim-with-secret.js` is a tiny Node module (20 lines) that:

1. Listens on port 8788
2. Reads the incoming request
3. Adds `X-Shim-Key: <secret>`
4. Forwards to 127.0.0.1:8787 (the real shim)

Cursor points its Override URL to `http://127.0.0.1:8788/v1`.

#### Secret generation recommendation

```powershell
[Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(64))
```

Minimum recommended length: 32 bytes (base64 → ~43 chars).

---

### Measure 2: Per-IP Rate Limiting (Recommended)

**Threat addressed**: Token abuse, CPU/memory exhaustion.

#### Concept

Track the number of requests per client IP within a sliding time window. Reject requests that exceed the limit.

```
Environment variables:
  SHIM_RATE_LIMIT_REQ     = 60          # max requests per window
  SHIM_RATE_LIMIT_WINDOW  = 60000       # window size in ms (1 minute)
```

#### Implementation

Maintain a simple in-memory map:

```javascript
const rateLimitMap = Object.create(null); // { ip: [timestamp1, timestamp2, ...] }

function checkRateLimit(ip) {
    const now = Date.now();
    const windowMs = parseInt(process.env.SHIM_RATE_LIMIT_WINDOW || '60000', 10);
    const maxReq = parseInt(process.env.SHIM_RATE_LIMIT_REQ || '60', 10);

    // Prune old entries
    if (!rateLimitMap[ip]) rateLimitMap[ip] = [];
    rateLimitMap[ip] = rateLimitMap[ip].filter(t => now - t < windowMs);

    if (rateLimitMap[ip].length >= maxReq) {
        return false; // exceeded
    }

    rateLimitMap[ip].push(now);
    return true;
}
```

Call `checkRateLimit(clientIp)` early in the handler. If it returns `false`:

```javascript
stats.err++;
bumpStatus(429);
res.writeHead(429, {
    'content-type': 'application/json',
    'Retry-After': String(Math.ceil((windowMs - (now - (rateLimitMap[ip][0] || 0))) / 1000)),
});
safeEnd(res, JSON.stringify({ error: 'too many requests, try again later' }));
return;
```

#### Client IP resolution

For direct connections: `req.socket.remoteAddress`.

For proxied connections behind a load balancer: `req.headers['x-forwarded-for'] || req.socket.remoteAddress`.

#### Memory safety

Prune the timestamps array every call (as shown above). Entries older than the window are discarded. This prevents unbounded memory growth even under sustained load.

Add cleanup interval to remove entirely stale IPs:

```javascript
setInterval(() => {
    const now = Date.now();
    const windowMs = parseInt(process.env.SHIM_RATE_LIMIT_WINDOW || '60000', 10);
    for (const ip of Object.keys(rateLimitMap)) {
        rateLimitMap[ip] = rateLimitMap[ip].filter(t => now - t < windowMs);
        if (rateLimitMap[ip].length === 0) delete rateLimitMap[ip];
    }
}, 60_000).unref();
```

#### Pros

- Prevents a single compromised connection from burning the entire quota
- Lightweight, pure JavaScript
- Configurable per deployment

#### Cons

- In-memory state is lost on crash (but also automatically cleaned up)
- Behind NAT/proxies, multiple clients may share the same apparent IP. Mitigation: set the limit generously.
- Does not protect against distributed attacks (multiple IPs), but that is outside the scope of this shim.

---

### Measure 3: Log Sanitization (Optional but Recommended)

**Threat addressed**: Prompt/conversation leakage in logs.

#### Current state

The shim logs model ID, message count, patch count, stream status, timing, and keepalive counts. It does **not** log the actual request/response bodies. This is already good practice.

However, the `-debug-` logs contain `dlog()` traces. Currently, debug mode shows:

```
[debug] patched 2 assistant.tool_calls message(s)
```

This does **not** include prompt content. No change is strictly needed here.

#### Proposed enhancement

If `SHIM_LOG_SENSITIVE_FIELDS` is set, mask specific fields in `patchInfo`:

```
Currently logged: model=kimi-k2.6 msgs=12 patched=2 stream=true
Proposed masked version: model=? msgs=12 patched=2 stream=true
```

Rationale: Even the model name might be considered sensitive in some deployment contexts.

Alternatively, implement a structured log format (JSON) with a `maskSensitive` flag:

```json
{"ts":"2026-04-26T...", "method":"POST", "path":"/v1/chat/completions", "status":200, "ms":14213, "model":"?","patched":2,"prompt_tokens":15234,"cached_tokens":12100}
```

#### Decision

- Masking the model name: Low priority. Only enable via explicit opt-in.
- Structured JSON logs: Medium priority. Improves log parsing for monitoring systems. Defer to future iteration unless there is clear demand.

**Verdict: Deferred.** Current log output is safe. Add optional structuring later if needed.

---

### Measure 4: TLS Termination (Long-term)

**Threat addressed**: Eavesdropping between shim and tunnel entry point.

#### Current architecture

```
Cursor ─HTTPS──→ [Cloudflare/Tailscale Funnel Edge] ─HTTPS──→ shim(127.0.0.1:8787)
```

The last leg (Funnel Edge → shim) is plaintext HTTP. With Tailscale Funnel, this traffic travels via Tailscale's MagicDNS overlay and terminates at the public Funnel edge before going to localhost.

With Cloudflare Quick Tunnel, the traffic is always HTTPS end-to-end (tunnel endpoint is Cloudflare's edge).

#### Assessment

For Tailscale Funnel: The connection from Funnel edge to localhost is over Tailscale's wireguard overlay. This is already encrypted end-to-end at the transport layer (wireguard). Adding TLS termination inside the shim itself would be redundant for the overlay path, but beneficial if the shim is ever accessed directly.

**Verdict: Not needed for current deployment.** Keep as-is for Tailscale. Consider self-signed TLS if the shim is ever exposed on a non-Tailscale LAN.

---

### Measure 5: Connection Limiting (Optional)

**Threat addressed**: Too many concurrent SSE streams consuming memory/CPU.

#### Concept

Cap the maximum number of simultaneous open connections to the shim.

```
Environment: SHIM_MAX_CONNECTIONS = 10
```

On each incoming request, increment a counter. Decrement on connection close/end. If the counter exceeds the limit, refuse the connection.

#### Implementation complexity

Low. Add counters + check before processing. Use `res.on('close')` or `req.on('close')` for decrement.

#### Trade-off

Most users have only 1–2 agents connected. A cap of 10 is generous. Only relevant for multi-user scenarios.

**Verdict: Deferred.** Add if/when the shim is used by more than one concurrent agent.

---

### Measure 6: Request Body Size Limiter (Recommended)

**Threat addressed**: Large payloads causing memory pressure or slow responses.

#### Concept

Reject requests whose body exceeds a reasonable size. The typical `kimi-k2.6` completion request with tool-calling context is usually well under 500 KB.

```
Environment: SHIM_MAX_BODY_BYTES = 1_048_576   # 1 MB default
```

#### Implementation

Stream the incoming request body into a buffer, checking size at each chunk. If the total exceeds `SHIM_MAX_BODY_BYTES`, abort with `413 Payload Too Large`:

```javascript
let bodySize = 0;
const maxBody = parseInt(process.env.SHIM_MAX_BODY_BYTES || '1048576', 10);

req.on('data', (chunk) => {
    bodySize += chunk.length;
    if (bodySize > maxBody) {
        res.writeHead(413);
        res.end('shim: request body too large');
        req.destroy();
    }
    chunks.push(chunk);
});
```

#### Pros

- Simple, immediate protection against oversized payloads
- Aligns with standard HTTP semantics (413)
- One env var, zero dependencies

#### Cons

- Legitimate long conversations could occasionally exceed 1 MB. Increase the limit if this becomes a problem.

---

## 2b. Additional Findings from Code & Image Review (Added 2026-04-26)

The following issues were identified during a thorough re-review of `server.js` combined with analysis of the ESET detection image (`Tailscale service detected CVE-2025-55182 attacking via 127.0.0.1`). This finding confirms that **the internal Tailscale ↔ Shim communication itself was being flagged by security software**, which reinforces the need for defense-in-depth beyond relying on tunnel encryption alone.

| Issue | Current State | Risk |
|-------|--------------|------|
| No OPTIONS handling | Unhandled → forwarded upstream unpredictably | CORS failures, unexpected behavior |
| /healthz leaks internals | Returns `uptimeSec`, `target`, `pid` | Information disclosure to anyone who can reach the URL |
| No Content-Type validation | Non-JSON bodies pass through silently | Unexpected payloads reach Moonshot |
| No CORS headers | All responses lack `Access-Control-*` headers | Browser-based attacks possible via public URL |
| No method/path filtering | Any method + any path goes upstream | Probes for `/admin`, `/debug`, `/env` are unfiltered |

These findings have been incorporated as Measures 7–11 below.

---

### Measure 7: Path/Method Whitelist (Critical — Immediate)

**Threat addressed**: Arbitrary endpoint probing, unknown routes leaking information, non-standard HTTP methods causing undefined behavior.

#### Current vulnerability

The current `server.js` checks only `req.method === 'POST'` and then passes everything else transparently. There is no allow-list for paths or methods. An attacker sending `GET /v1/config`, `DELETE /v1/chat/completions`, or probing `/admin`, `/debug` gets responses forwarded directly from upstream — exposing internal API structures or returning Moonshot's own error pages (which leak model names, API formats, etc.).

#### Proposed implementation

```javascript
const ALLOWED_PATHS = new Set([
    '/chat/completions',
    '/models',
    '/completions',
    '/embeddings',
    '/healthz',
    '/_shim/healthz',
]);

const ALLOWED_METHODS = new Set(['GET', 'POST', 'OPTIONS']);

// Early in the handler (after URL parsing):
if (!ALLOWED_PATHS.has(url.pathname) || !ALLOWED_METHODS.has(req.method)) {
    stats.err++;
    bumpStatus(405);
    safeWrite(res, '');
    res.writeHead(405, { 'content-type': 'application/json' });
    safeEnd(res, JSON.stringify({ error: 'path not allowed' }));
    return;
}
```

**Decision logic:**

- Paths starting with `/v1/` are stripped to their bare form (`/v1/chat/completions` → `/chat/completions`) before checking.
- Non-standard methods (PUT, DELETE, PATCH, CONNECT, TRACE) are rejected outright.
- Health endpoints are excluded from secret authentication (they should remain probeable).

#### Pros

- Single smallest change with highest impact on attack surface reduction
- Blocks all currently-unintended paths/methods without needing to enumerate them individually going forward
- Zero dependency increase

#### Cons

- Future Moonshot API endpoints must be added to `ALLOWED_PATHS`. Maintainability risk if new endpoints appear frequently. Mitigation: keep a "fallback debug mode" env var `SHIM_ALLOW_ALL_PATHS=true` for development only.

---

### Measure 8: Minimal /healthz Response (High Priority)

**Threat addressed**: Information leakage via health endpoint.

#### Current state

```javascript
// server.js line ~365-372
res.end(JSON.stringify({
    ok: true,
    uptimeSec: Math.round(process.uptime()),   // ← system uptime exposed
    target: TARGET,                            // ← upstream URL exposed (api.moonshot.ai/v1)
    pid: process.pid,                          // ← process ID exposed
}));
```

Anyone reaching the public Funnel URL can determine:

1. The shim is running (uptime > 0)
2. The upstream Moonshot URL (useful for reconnaissance)
3. The PID (helpful for local exploitation if any other vector exists)

#### Proposed implementation

```javascript
// Minimal: only boolean status
res.writeHead(200, { 'content-type': 'application/json' });
res.end(JSON.stringify({ status: 'ok' }));
```

For debugging, add a separate endpoint gated behind the secret:

```javascript
// Only accessible with X-Shim-Key header
if (process.env.SHIM_SECRET && req.headers['x-shim-key'] === process.env.SHIM_SECRET) {
    if (url.pathname === '/_shim/debug') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
            uptimeSec: Math.round(process.uptime()),
            target: TARGET,
            pid: process.pid,
            stats: { ...stats },
            lifetime: { ...lifetime },
            openConnections: activeConnections,
        }));
        return;
    }
}
```

#### Pros

- Eliminates information disclosure while preserving functionality for authorized debugging
- `/healthz` stays minimal; `/healthz` + secret stays full-featured

#### Cons

- Debug endpoint requires the secret header (but since it is already gated behind the secret, this is a feature not a bug)

---

### Measure 9: Content-Type Validation on POST (Recommended)

**Threat addressed**: Non-JSON payloads passed to upstream, potential injection vectors.

#### Current state

```javascript
// server.js line ~400-406
if (req.method === 'POST' && raw.length > 0) {
    let json = null;
    try {
        json = JSON.parse(raw.toString('utf8'));
    } catch {
        // not JSON -> pass through untouched   ← PROBLEM
    }
}
```

Non-JSON requests to POST endpoints are silently forwarded unchanged. While Moonshot may reject them, this means:

1. Any data type can be pushed through the shim (binary, HTML, arbitrary strings)
2. The shim cannot validate patching logic applies correctly
3. Upstream receives garbage input without explicit rejection

#### Proposed implementation

```javascript
const EXPECTED_CT = 'application/json';
const ct = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();

if (req.method === 'POST' && ct !== EXPECTED_CT) {
    // Allow if content-type is missing entirely (some clients omit it)
    // But reject clearly wrong types (text/html, application/xml, etc.)
    const contentTypeHeader = req.headers['content-type'];
    if (contentTypeHeader && !ct.includes('json')) {
        stats.err++;
        bumpStatus(415);
        safeWrite(res, '');
        res.writeHead(415, { 'content-type': 'application/json' });
        safeEnd(res, JSON.stringify({ error: 'content-type must be application/json' }));
        return;
    }
}
```

#### Decision logic rationale

- Missing `Content-Type` header: Accept (compatibility with various clients)
- `application/json; charset=utf-8`: Accept (standard parameterized variant)
- `text/plain`, `application/xml`, etc.: Reject with 415
- Empty body: Already handled separately (passes through)

#### Pros

- Prevents clearly misdirected or malicious payloads from reaching upstream
- Follows REST API best practices (RFC 7231)
- One header check, zero performance impact

#### Cons

- A few unusual clients might send `text/plain;charset=utf-8` without `json` in the label. In practice, all OpenAI-compatible SDKs use `application/json`, so this edge case is unlikely.

---

### Measure 10: CORS Headers for Public Endpoints (Recommended)

**Threat addressed**: Cross-origin browser attacks via public tunnel URL.

#### Why this matters

With Cloudflare Quick Tunnel or Tailscale Funnel, the shim URL is publicly reachable over HTTPS. Without CORS headers, browsers will block cross-origin `fetch()` calls to the endpoint — but more importantly, certain browser-based attack techniques (e.g., using `<form>` submission, SVG embedded `<object>`, or WebAssembly imports) might bypass same-origin restrictions depending on the response headers.

While the shim forwards the user's API key and processes sensitive data, adding strict CORS does not reduce risk if someone already has the tunnel URL. Its primary purpose here is **defense depth** — ensuring that if an XSS or compromised page somehow tries to interact with the shim, the browser enforces cross-origin boundaries.

#### Proposed implementation

```javascript
const CORS_HEADERS = {
    'access-control-allow-origin': '*',                    // '*' is fine because the secret (when enabled) provides actual auth
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'Content-Type, Authorization, X-Shim-Key',
    'access-control-max-age': '86400',                     // Cache preflight results for 24 hours
};

// Apply CORS headers to every response:
for (const [key, value] of Object.entries(CORS_HEADERS)) {
    respHeaders[key.toLowerCase()] = value;
}

// Handle OPTIONS preflight requests explicitly:
if (req.method === 'OPTIONS') {
    stats.req++;
    bumpStatus(204);
    res.writeHead(204, CORS_HEADERS);
    safeEnd(res);
    return;
}
```

#### Pros

- Standard REST API hardening measure
- Compatible with all OpenAI-compatible clients
- Explicit OPTIONS handling prevents CORS preflight failures

#### Cons

- `access-control-allow-origin: *` combined with a public URL means any website can make cross-origin requests. **Mitigation**: When `SHIM_SECRET` is set, the secret requirement provides actual authorization. Without the secret, even successful cors-preflighted requests still hit the secret check.

---

### Measure 11: Security Headers on All Responses (Low-Medium Priority)

**Threat addressed**: Man-in-the-middle attacks, clickjacking, MIME-type sniffing, XSS via content injection.

#### Proposed implementation

```javascript
const SECURITY_HEADERS = {
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'x-xss-protection': '1; mode=block',
    'referrer-policy': 'no-referrer',
    'cache-control': 'no-store',           // Don't cache API responses on intermediate proxies
    'pragma': 'no-cache',                  // HTTP/1.0 compatibility
};

// Merge security headers into every response alongside existing ones:
for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    respHeaders[key.toLowerCase()] = value;
}
```

#### Interaction with existing code

Note that `Cache-Control: no-cache, no-transform` is already set for SSE responses (line ~465-467). The new `no-store` in `SECURITY_HEADERS` provides broader coverage for non-SSE responses (errors, `/models`, etc.). No conflict — `no-store` is stronger than `no-cache` and covers both.

#### Pros

- Adds defense-in-depth for transport-layer concerns
- Follows OWASP Recommended HTTP Headers guidelines
- No functional impact on legitimate API usage

#### Cons

- None significant. These headers are universally accepted.

---

## 3. Summary Matrix (Updated)

| Measure | Priority | Complexity | Env Vars | Dependencies | Immediate Benefit |
|---|---|---|---|---|---|
| **1. Shared Secret** | High | Low | `SHIM_SECRET` | None | Prevents unauthorized access |
| **2. Rate Limiting** | High | Medium | `SHIM_RATE_LIMIT_REQ`, `SHIM_RATE_LIMIT_WINDOW` | None | Prevents quota burning |
| **3. Log Sanitization** | Low | Low | `SHIM_LOG_SENSITIVE_FIELDS` | None | Minor (current logs already safe) |
| **4. TLS Termination** | N/A | High | `SHIM_TLS_KEY`, `SHIM_TLS_CERT` | tls module | Not needed with Funnel |
| **5. Connection Limit** | Low | Low | `SHIM_MAX_CONNECTIONS` | None | Multi-agent scenarios only |
| **6. Body Size Limiter** | Medium | Low | `SHIM_MAX_BODY_BYTES` | None | Prevents resource exhaustion |
| **7. Path/Method Whitelist** | Critical | Low | None | None | Blocks all unintended routes |
| **8. Minimal /healthz** | High | Low | None | None | Stops information leakage |
| **9. Content-Type Validation** | Recommended | Low | None | None | Rejects non-API payloads |
| **10. CORS Headers** | Recommended | Low | None | None | Browser attack surface reduction |
| **11. Security Headers** | Low-Medium | Low | None | None | OWASP compliance, MITM defense |

---

## 4. Recommended Rollout Order (Updated)

### Phase 0 (Immediate, zero-risk, high-yield)

1. **Measure 7: Path/Method Whitelist** — Blocks all unintended routes instantly. No config change needed.
2. **Measure 8: Minimal /healthz** — Eliminates infoleak on the most commonly probed endpoint.
3. **Measure 11: Security Headers** — Universal, no functional side effects.

### Phase 1 (High impact, low risk)

4. **Measure 1: Shared Secret** — Most impactful single authentication change.
5. **Measure 6: Body Size Limiter** — Cheap defense-in-depth.
6. **Measure 9: Content-Type Validation** — One-header check, strong signal.
7. **Measure 10: CORS Headers** — Standard API hardening, pairs with Measure 1.

### Phase 2 (Higher complexity, monitor closely)

8. **Measure 2: Rate Limiting** — Add after Phase 1 stability confirmed. Start conservative.

### Phase 3 (Deferred until needed)

9. **Measure 3: Log Sanitization** — When structured logging is adopted.
10. **Measure 5: Connection Limit** — Multi-agent deployment only.
11. **Measure 4: TLS Termination** — Only if exposing on non-Tailscale networks.

---

## 5. Risk Assessment (Updated)

| Change | Risk Level | Rollback | Notes |
|---|---|---|---|
| Shared Secret | Low | Set `SHIM_SECRET=` (unset) to disable | Must coordinate with all clients. Provide migration guide. |
| Rate Limiting | Medium | Lower limits or unset env vars | Could affect legitimate burst traffic. Start conservative. |
| Body Size Limiter | Low | Increase or unset | 1 MB should cover all normal use cases. |
| Path/Method Whitelist | Low | Add entries or enable `SHIM_DEBUG_BYPASS_WHITELIST=true` | Keep a debug bypass for development. |
| Minimal /healthz | None | Restore old format | Purely informational reduction. |
| Content-Type Validation | Low | Remove check or widen match | Edge case: some clients omit `Content-Type`. |
| CORS Headers | None | Remove | No client affected; beneficial for browser compat. |
| Security Headers | None | Remove | Universally accepted; no side effects. |

---

## 6. Migration Guide (for existing deployments)

When deploying Phase 1, existing users need to:

### Step 1: Generate secret

```powershell
$env:SHIM_SECRET = [Convert]::ToBase64String([RandomNumberGenerator]::GetBytes(64))
```

### Step 2: Update startup script

In `start-tailscale.cmd` (or `start-all.cmd`):

```batch
set SHIM_SECRET=your-generated-secret-here
node server.js
```

### Step 3: Restart shim

Stop the current shim process, then let `start-tailscale.cmd` start the new instance.

### Step 4: Verify

```powershell
# Test WITHOUT the secret (should fail for /chat/completions, but healthz still works)
curl http://127.0.0.1:8787/v1/models

# Test WITH the secret (should succeed)
curl -H "X-Shim-Key: your-generated-secret-here" http://127.0.0.1:8787/v1/models

# Test /healthz (should always work regardless of secret)
curl http://127.0.0.1:8787/healthz
# → {"status":"ok"}
```

### Step 5: Cursor integration

Since Cursor's native settings do not support custom headers, use the two-proxy approach described in Measure 1:

1. Create `inject-header-proxy.mjs` (tiny, ~20 lines)
2. Update `start-tailscale.cmd` to chain: `Cursor → inject-header-proxy:8788 → shim:8787`
3. Update Cursor Override Base URL to `http://127.0.0.1:8788/v1`

---

## 7. Files Changed (Estimated)

| File | Changes |
|---|---|
| `server.js` | Phases 0+1 adds (~200 lines), covering: whitelist, minimal healthz, secrets, rate limiter, body size, content-type, CORS, security headers |
| `start-tailscale.cmd` | Add `SHIM_SECRET` env var, optional proxy chain |
| `inject-header-proxy.mjs` | New file (~25 lines) |
| `README.md` §B-5 | Document secret generation & injection steps |
| `md/CACHE_HIT_LOGGING.en.md` | Update log examples with new field names (if renamed) |
| `md/SECURITY_HARDCENING_PLAN.en.md` | This document (reference) |

No new npm dependencies. All new code uses Node.js built-in modules only.


| Measure | Priority | Complexity | Env Vars | Dependencies | Immediate Benefit |
|---------|----------|-----------|----------|-------------|-------------------|
| **1. Shared Secret** | High | Low | `SHIM_SECRET` | None | Prevents unauthorized access |
| **2. Rate Limiting** | High | Medium | `SHIM_RATE_LIMIT_REQ`, `SHIM_RATE_LIMIT_WINDOW` | None | Prevents quota burning |
| **3. Log Sanitization** | Low | Low | `SHIM_LOG_SENSITIVE_FIELDS` | None | Minor (current logs already safe) |
| **4. TLS Termination** | N/A | High | `SHIM_TLS_KEY`, `SHIM_TLS_CERT` | tls module | Not needed with Funnel |
| **5. Connection Limit** | Low | Low | `SHIM_MAX_CONNECTIONS` | None | Multi-agent scenarios only |
| **6. Body Size Limiter** | Medium | Low | `SHIM_MAX_BODY_BYTES` | None | Prevents resource exhaustion |

---

## 4. Recommended Rollout Order

### Phase 1 (Immediate, high impact, low risk)

1. **Measure 1: Shared Secret** — Deploy first. Most impactful single change.
2. **Measure 6: Body Size Limiter** — Cheap defense-in-depth alongside the secret.

### Phase 2 (High impact, moderate risk)

3. **Measure 2: Rate Limiting** — Add after Phase 1 is stable. Monitor for false positives.

### Phase 3 (Deferred until needed)

4. **Measure 3: Log Sanitization** — When JSON log format is adopted.
5. **Measure 5: Connection Limit** — When supporting multiple concurrent agents.
6. **Measure 4: TLS Termination** — Only if exposing on non-Tailscale networks.

---

## 5. Risk Assessment

| Change | Risk Level | Rollback | Notes |
|--------|-----------|----------|-------|
| Shared Secret | Low | Set `SHIM_SECRET=` (unset) to disable | Must coordinate with all clients. Provide migration guide. |
| Rate Limiting | Medium | Lower limits or unset env vars | Could affect legitimate burst traffic. Start conservative. |
| Body Size Limiter | Low | Increase or unset | 1 MB should cover all normal use cases. |

---

## 6. Migration Guide (for existing deployments)

When deploying Phase 1, existing users need to:

### Step 1: Generate secret

```powershell
$env:SHIM_SECRET = [Convert]::ToBase64String([RandomNumberGenerator]::GetBytes(64))
```

### Step 2: Update startup script

In `start-tailscale.cmd` (or `start-all.cmd`):

```batch
set SHIM_SECRET=your-generated-secret-here
node server.js
```

### Step 3: Restart shim

Stop the current shim process, then let `start-tailscale.cmd` start the new instance.

### Step 4: Verify

```powershell
# Test WITHOUT the secret (should fail)
curl http://127.0.0.1:8787/v1/models

# Test WITH the secret (should succeed)
curl -H "X-Shim-Key: your-generated-secret-here" http://127.0.0.1:8787/v1/models
```

### Step 5: Cursor integration

Since Cursor's native settings do not support custom headers, use the two-proxy approach described in Measure 1:

1. Create `inject-header-proxy.mjs` (tiny, ~20 lines)
2. Update `start-tailscale.cmd` to chain: `Cursor → inject-header-proxy:8788 → shim:8787`
3. Update Cursor Override Base URL to `http://127.0.0.1:8788/v1`

---

## 7. Files Changed (Estimated)

| File | Changes |
|------|---------|
| `server.js` | Shared secret check, rate limiter, body size limiter (≈80 lines added) |
| `start-tailscale.cmd` | Add `SHIM_SECRET` env var, optional proxy chain |
| `inject-header-proxy.mjs` | New file (~25 lines) |
| `README.md` §B-5 | Document secret generation & injection steps |
| `md/SECURITY_HARDCENING_PLAN.en.md` | This document (reference) |

No new npm dependencies. All new code uses Node.js built-in modules only.
