# v1.0.6 — Tunnel switcher stack (English technical guide)

This document describes **only** what shipped as **v1.0.6** in `moonshot-shim`: the **Tailscale / Cloudflare tunnel switcher**, supporting scripts, README updates, and related ignore rules. It does **not** cover other version lines (for example, separate releases that only touch `server.js`).

---

## 1. Why v1.0.6 matters

### 1.1 Operational reality

You need a **public HTTPS URL** so Cursor’s cloud backend can reach your shim (SSRF rules block `127.0.0.1`). Two practical options are:

| Path | Typical use |
|------|-------------|
| **Tailscale Funnel** | Stable hostname; good for daily use when Tailscale is acceptable. |
| **Cloudflare Quick Tunnel** | Ephemeral `*.trycloudflare.com` URL; good when you want to avoid Tailscale Funnel or need a quick public endpoint. |

Before v1.0.6, Cloudflare was documented in spirit, but **starting, stopping, and switching** between “Funnel → inject proxy” and “Quick Tunnel → inject proxy” was easy to get wrong—especially **which local port** the tunnel must target.

### 1.2 The critical invariant (v1.0.2+)

Since shared-secret authentication, the correct chain is always:

```text
Public tunnel  →  inject-header-proxy.mjs :8788  →  server.js :8787  →  Moonshot
```

- **`:8788`** — injects `X-Shim-Key` on every request (Cursor cannot send custom headers).
- **`:8787`** — validates the secret and proxies to Moonshot.

**Wrong:** Pointing a tunnel **only** at `:8787` while using Cursor’s Override URL **without** the inject proxy in the path. Requests would lack `X-Shim-Key` and fail with **403**.

**Wrong:** Pointing Cloudflare at `:8787` “to skip a hop.” Same problem.

v1.0.6 makes the **Cloudflare path mirror the Tailscale path**: scripts always bring up **8787 + 8788**, health-check **8787**, then expose **8788** to the internet.

### 1.3 What v1.0.6 adds at a glance

1. **First-class Cloudflare launcher** — same phased startup as Tailscale, with printed `https://….trycloudflare.com/v1` for Cursor.
2. **Clean switch** — `switch-tunnel.cmd` clears the other tunnel’s mapping/process so you do not run two public entrypoints by accident.
3. **Observability** — `tunnel-status` shows listeners, healthz on both ports, Funnel status, and Cloudflare PID state.
4. **Documentation** — README explains Method A/B, switching, and marks legacy `start-all.cmd` when it bypasses the secret stack.

---

## 2. Files added or materially changed (v1.0.6 scope)

| File | Role |
|------|------|
| `start-cloudflare.cmd` | Orchestrates secret file, local stack (8787+8788), healthz, then invokes PowerShell for Quick Tunnel. |
| `start-cloudflare.ps1` | Runs `cloudflared` against `http://127.0.0.1:8788`, parses stderr for `*.trycloudflare.com`, writes PID file. |
| `stop-cloudflare.cmd` | Thin wrapper calling `stop-cloudflare.ps1`. |
| `stop-cloudflare.ps1` | Stops `cloudflared` via `cloudflared-quick.pid`, removes stale PID file. |
| `stop-tailscale.cmd` | Runs `tailscale funnel reset` only (does not stop Windows service or Node processes). |
| `switch-tunnel.cmd` | `cloudflare` \| `tailscale` \| `status` — sequences stop/start for a single public path. |
| `tunnel-status.cmd` | Wrapper for `tunnel-status.ps1`. |
| `tunnel-status.ps1` | Reports ports 8787/8788, healthz, Funnel status, Cloudflare PID; hints Override URLs. |
| `README.md` | Method A/B, port stack, switching section, legacy `start-all.cmd` note. |
| `.gitignore` | Ignore Quick Tunnel logs and PID file (no secrets in git). |

**Not introduced in v1.0.6** (pre-existing; referenced by the new flow): `server.js`, `inject-header-proxy.mjs`, `start-tailscale.cmd`, `_shim_secret.txt` pattern.

---

## 3. Behaviour of each script (meaning)

### 3.1 `start-cloudflare.cmd`

Phases:

0. **Secret** — If `_shim_secret.txt` is missing, generate 64 random bytes (Base64) into that file (same contract as Tailscale launcher).
1. **Local stack** — PowerShell checks port **8788**; if not listening, ensures **8787** (`server.js`) is running, then starts **`inject-header-proxy.mjs`** on **8788**. Idempotent messages if already up.
2. **Health** — Poll `http://127.0.0.1:8787/healthz` until `status: ok` or timeout (~5s). Aborts if the shim never answers (tunnel would be useless).
3. **Tunnel** — Delegates to `start-cloudflare.ps1` for `cloudflared`.

**Meaning:** A single entry command that cannot “forget” the inject proxy or health check before opening the public URL.

### 3.2 `start-cloudflare.ps1`

- Requires `cloudflared.exe` in the repo root (download link printed if missing).
- Removes old log files; if PID file exists, stops that process (restart hygiene).
- Spawns:  
  `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8788 --protocol http2`  
  with stdout/stderr redirected to `cloudflared-quick.log` / `cloudflared-quick.log.err`, hidden window, **writes PID** to `cloudflared-quick.pid`.
- Parses **stderr** for `https://…trycloudflare.com` (Cloudflare prints the URL there), up to ~60s.
- Prints boxed instructions: public URL and **Cursor Override base URL** as `${url}/v1`.

**Meaning:** Quick Tunnel is explicitly bound to the **inject** port so every Cursor request gets `X-Shim-Key` before hitting `server.js`.

### 3.3 `stop-cloudflare.cmd` / `stop-cloudflare.ps1`

- Reads `cloudflared-quick.pid`, `Stop-Process`, deletes PID file; no-op if missing or stale.

**Meaning:** Tear down only the **Cloudflare** public leg; local Node processes may keep running for Tailscale or local debugging.

### 3.4 `stop-tailscale.cmd`

- Runs `tailscale funnel reset` (default install path). Non-zero exit is treated as informational if mapping was already off.

**Meaning:** Clear the **public Funnel mapping** so switching to Cloudflare does not leave an old hostname still forwarding traffic.

### 3.5 `switch-tunnel.cmd`

| Argument | Action |
|----------|--------|
| `cloudflare` | `stop-tailscale.cmd` → `start-cloudflare.cmd` |
| `tailscale` | `stop-cloudflare.cmd` → `start-tailscale.cmd` |
| `status` | `tunnel-status.cmd` |

**Meaning:** One documented path to avoid “Funnel still on while Quick Tunnel also advertising” confusion.

### 3.6 `tunnel-status.ps1`

- **8787 / 8788** — `Get-NetTCPConnection` listen state and owning PID. Uses **`$owningPid`** (not `$PID`) so PowerShell’s automatic `$PID` variable does not break the script.
- **healthz** — `Invoke-RestMethod` to both `127.0.0.1:8787` and `8788` `/healthz`.
- **Tailscale** — `tailscale funnel status` if binary exists.
- **Cloudflare** — PID file + `Get-Process` to detect stale PID.
- **Hints** — Documents fixed Funnel host fragment used in README vs “paste printed Cloudflare URL”.

**Meaning:** Single diagnostic panel before blaming Cursor, Moonshot, or “network errors.”

---

## 4. README changes (v1.0.6 meaning)

README updates for this release focus on:

- **Architecture diagram** — Tunnel → **8788** → **8787** → Moonshot.
- **Method A (Cloudflare)** — Use `start-cloudflare.cmd`; paste printed `…/v1` into Cursor; note URL rotation.
- **Method B (Tailscale)** — Funnel targets **8788**; fixed URL pattern documented.
- **`switch-tunnel.cmd`** — Documented under “Switching between Cloudflare and Tailscale.”
- **`start-all.cmd` as legacy** — If it starts only `server.js` on **8787** without the inject proxy + secret stack, it is **not** aligned with v1.0.2+ security; v1.0.6 calls that out explicitly so operators do not follow an obsolete one-liner.

---

## 5. `.gitignore` changes (v1.0.6 meaning)

Added ignore entries:

- `cloudflared-quick.log`, `cloudflared-quick.log.err` — noisy / machine-local.
- `cloudflared-quick.pid` — process id file; not for version control.

**Meaning:** Quick Tunnel artifacts do not clutter `git status` or leak ephemeral operational state.

---

## 6. Code excerpts (v1.0.6–related files only)

The following are **representative** excerpts for operators and reviewers. Line numbers refer to the repository state that includes v1.0.6.

### 6.1 `start-cloudflare.cmd` — phases and 8788 target

```1:15:D:\USERFILES\GitHub\moonshot-shim\start-cloudflare.cmd
@echo off
REM ============================================================
REM  start-cloudflare.cmd
REM  ------------------------------------------------------------
REM  Cloudflare Quick Tunnel for Cursor <-> Kimi (moonshot-shim).
REM  Local stack matches Tailscale: cloudflared -> :8788
REM  (inject-header-proxy, adds X-Shim-Key) -> :8787 server.js.
...
```

```31:49:D:\USERFILES\GitHub\moonshot-shim\start-cloudflare.cmd
REM --- [1/3] Launch shim + inject-header-proxy -------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$shimRunning = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue;" ^
  "$proxyRunning = Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue;" ^
  ...
    "Start-Process -FilePath 'node' -ArgumentList 'inject-header-proxy.mjs' -WorkingDirectory '%~dp0' -WindowStyle Hidden;" ^
```

### 6.2 `start-cloudflare.ps1` — tunnel to 8788, PID, URL parse

```31:38:D:\USERFILES\GitHub\moonshot-shim\start-cloudflare.ps1
$p = Start-Process -FilePath $exe `
    -ArgumentList @('tunnel', '--no-autoupdate', '--url', 'http://127.0.0.1:8788', '--protocol', 'http2') `
    -WorkingDirectory $root `
    -RedirectStandardOutput $logOut `
    -RedirectStandardError $logErr `
    -WindowStyle Hidden `
    -PassThru
```

```50:54:D:\USERFILES\GitHub\moonshot-shim\start-cloudflare.ps1
        if ($raw -match 'https://[a-zA-Z0-9-]+\.trycloudflare\.com') {
            $url = $Matches[0]
            break
        }
```

### 6.3 `switch-tunnel.cmd` — mutual exclusion

```21:31:D:\USERFILES\GitHub\moonshot-shim\switch-tunnel.cmd
:DO_CF
echo [switch-tunnel] ---^> Cloudflare Quick Tunnel
call "%~dp0stop-tailscale.cmd"
call "%~dp0start-cloudflare.cmd"
goto END_OK

:DO_TS
echo [switch-tunnel] ---^> Tailscale Funnel (fixed URL)
call "%~dp0stop-cloudflare.cmd"
call "%~dp0start-tailscale.cmd"
```

### 6.4 `tunnel-status.ps1` — `$owningPid` fix (not `$PID`)

```8:16:D:\USERFILES\GitHub\moonshot-shim\tunnel-status.ps1
foreach ($port in @(8787, 8788)) {
    $c = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) {
        $owningPid = $c[0].OwningProcess
        Write-Host "Port $port LISTEN  pid=$owningPid" -ForegroundColor Green
    }
```

### 6.5 `inject-header-proxy.mjs` — why 8788 must be the tunnel target

```1:7:D:\USERFILES\GitHub\moonshot-shim\inject-header-proxy.mjs
// inject-header-proxy.mjs
// Ultra-thin proxy that injects X-Shim-Key into every request.
// Sits between Tailscale Funnel (port 8788) and server.js (port 8787).
//
// Cursor's Override Base URL is the public tunnel URL — unchanged.
// Tailscale Funnel sends traffic to port 8788.
```

---

## 7. Operator checklist (v1.0.6)

1. `npm install` once; place `cloudflared.exe` in repo root for Cloudflare path.
2. Run **`switch-tunnel.cmd cloudflare`** *or* **`start-cloudflare.cmd`**.
3. Wait for printed **`https://….trycloudflare.com`**.
4. In Cursor: Override OpenAI Base URL = **`{that URL}/v1`**, then Verify.
5. For Tailscale again: **`switch-tunnel.cmd tailscale`** (clears Quick Tunnel PID-based process first).

---

## 8. Summary

**v1.0.6** is important because it **encodes the correct security and connectivity stack in repeatable scripts**: always **8788** in front of the public internet, always **`X-Shim-Key`** injection before **8787**, explicit **switch** and **status** tooling, and README guidance that matches that architecture—including a clear warning when legacy launchers bypass the stack.

---

*Document: `md/V1_0_6_TUNNEL_SWITCHER.en.md` — v1.0.6 tunnel switcher scope only.*
