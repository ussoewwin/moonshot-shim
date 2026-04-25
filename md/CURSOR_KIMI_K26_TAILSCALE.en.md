# Cursor × Kimi K2.6 — Tailscale Funnel (Fixed URL) Complete Guide

A complete guide to using Moonshot's `kimi-k2.6` (Thinking model) with **tool calling** from Cursor IDE, exposed via a **fixed URL** using **Tailscale Funnel**.

Created: 2026-04-26
Working folder: `<repo-path>\`

Sister documents:
- `CURSOR_KIMI_K26_FIX.md` — Cloudflare Tunnel (quick tunnel, legacy method)
- `KIMI_K26_CACHE_GUIDE.md` — Prompt cache optimization guide

---

## Table of Contents

1. [Symptoms](#1-symptoms)
2. [Root Cause](#2-root-cause)
3. [Affected Tools](#3-affected-tools)
4. [Solution Overview](#4-solution-overview)
5. [Architecture Diagram](#5-architecture-diagram)
6. [Created Files](#6-created-files)
7. [First-Time Setup](#7-first-time-setup)
8. [Automation — Fully Automatic After Reboot](#8-automation--fully-automatic-after-reboot)
9. [Cursor Settings](#9-cursor-settings)
10. [Verification](#10-verification)
11. [Operational Notes](#11-operational-notes)
12. [Known Limitations & Future Improvements](#12-known-limitations--future-improvements)
13. [Full Auto-Reproduction Playbook (unattended execution)](#13-full-auto-reproduction-playbook-unattended-execution)

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
| openclaude | GitHub HEAD has `preserveReasoningContent: true`. npm release may lag; see sister doc `OPENCLAUDE_KIMI_K26_REASONING_PATCH.md` for manual patching. |
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

2. **Tailscale Funnel (fixed URL)**
   - Cursor's Override OpenAI Base URL is reached **via Cursor's cloud servers**, which block private IPs (`127.0.0.1`) via SSRF protection (`ssrf_blocked: connection to private IP is blocked`)
   - Therefore the shim must be exposed externally
   - **Tailscale Funnel** provides a **fixed HTTPS URL** like `https://<machine>.<tail-XXXX>.ts.net/`
   - `--bg` flag registers the config with the `tailscaled` Windows service, which persists and auto-restores it
   - No window needs to stay open; URL never changes across reboots

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
         │ HTTPS to https://<your-funnel-domain>/v1/...
         ▼
┌──────────────────────────────┐
│  Tailscale Funnel edge       │  HTTPS termination
│  (<your-funnel-domain>)│
└────────┬─────────────────────┘
         │ Encrypted tunnel (WireGuard over UDP)
         ▼
┌──────────────────────────────────────┐
│  tailscaled (Windows service)        │
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
| `server.js` | Main (~200 lines) | Shim core. HTTP server, patcher, and proxy logic. |
| `README.md` | Doc | Standalone usage instructions. |
| `test-echo.mjs` | Test | Spins up a local echo server to regression-test the patcher. |
| `CURSOR_KIMI_K26_FIX.md` | Doc | Sister doc for Cloudflare Tunnel method. |
| `CURSOR_KIMI_K26_TAILSCALE.md` | Doc | **This file**. Tailscale Funnel method summary. |
| `start-tailscale.cmd` | Launcher | Launches shim + registers `tailscale funnel --bg`. One-shot execution. |
| `start-tailscale-hidden.vbs` | Launcher | VBScript that runs `start-tailscale.cmd` completely hidden (zero windows). |

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

## 7. First-Time Setup

### 7.1 Prerequisites

- Tailscale account (free tier is fine). https://login.tailscale.com/
- Tailscale Windows client installed
- `server.js` and dependencies (`npm install` done) already placed in `<repo-path>\`

### 7.2 Steps

```powershell
# (1) Enable Tailscale Funnel (first time only, in Tailscale admin console)
#     https://login.tailscale.com/admin/settings/features
#     Turn ON "Funnel"

# (2) Verify shim runs locally
cd <repo-path>
node server.js
# → "listening on http://127.0.0.1:8787" appears, then Ctrl+C to stop

# (3) Test Tailscale Funnel manually (if this succeeds, no further manual steps needed)
& "C:\Program Files\Tailscale\tailscale.exe" funnel --bg 8787
# → "Available on the internet: https://<your-funnel-domain>/"

# (4) Verify public healthz via Tailscale URL
Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# → pid, uptimeSec, target, reasoningPatcher returned = OK

# (5) Reset funnel after test
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

## 8. Automation — Fully Automatic After Reboot

Automatically launch **shim + Tailscale Funnel registration** on Windows logon. No manual steps, no windows to keep open.

### 8.1 Automation Stack

| Layer | File | Role |
| --- | --- | --- |
| Startup registration | `.lnk` shortcut in `shell:startup` | Auto-launched on Windows logon |
| Hidden launcher | `start-tailscale-hidden.vbs` | VBScript that runs `start-tailscale.cmd` hidden |
| Actual work | `start-tailscale.cmd` | Launches shim + registers funnel --bg + exits |

### 8.2 Register in Startup Folder

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "<repo-path>\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "<repo-path>"
$shortcut.WindowStyle = 7  # Minimized
$shortcut.Save()
```

### 8.3 File Contents

**start-tailscale-hidden.vbs** (Hidden launcher)

```vbs
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run Chr(34) & "<repo-path>\start-tailscale.cmd" & Chr(34), 0, False
Set WshShell = Nothing
```

- `Chr(34)` = double-quote. Handles spaces in path defensively.
- `0` = hidden window
- `False` = fire-and-forget (do not wait for completion)

**start-tailscale.cmd** (One-shot execution)

```batch
@echo off
setlocal
cd /d "%~dp0"

REM [1/3] Launch shim (skip if 8787 already LISTEN)
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { Write-Host '[1/3] shim already running' -ForegroundColor Yellow } else { Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden; Write-Host '[1/3] shim launched' -ForegroundColor Green }"

REM [2/3] Wait for /healthz (up to 5 seconds)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('[2/3] healthz OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host '[2/3] healthz FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

REM [3/3] tailscale funnel --bg 8787 (waits for tailscaled readiness, up to 60s)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts='C:\Program Files\Tailscale\tailscale.exe'; $ok=$false; for($i=0;$i-lt30;$i++){ try{ & $ts funnel --bg 8787 2>$null | Out-Null; $r=Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4; Write-Host ('[3/3] public OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{ Start-Sleep -Seconds 2 } }; if(-not $ok){ Write-Host '[3/3] FAIL' -ForegroundColor Red; exit 1 }"

endlocal
exit /b 0
```

### 8.4 State After Automation

After reboot and user logon (~20–30 seconds), the following holds:

| Check | State |
| --- | --- |
| shim (node.exe) | Running as a background process |
| Local healthz | `http://127.0.0.1:8787/healthz` responds OK |
| Public healthz | `https://<your-funnel-domain>/healthz` responds OK |
| Visible windows | **0** (cmd / wscript / tailscale all hidden) |
| Funnel config | Persisted by `tailscaled` service; auto-restores after reboot |

In Task Manager → **Details** tab, look for `node.exe` with Command line containing `server.js`.

## 9. Cursor Settings

Set once. Never needs updating again (fixed URL).

### 9.1 Override OpenAI Base URL

```
https://<your-funnel-domain>/v1
```

Paste into Cursor → Settings → Models → "Override OpenAI Base URL".

### 9.2 API Key

Enter your Moonshot API key as-is.

### 9.3 Custom Model

- Model Name: `kimi-k2.6`
- Recommended context length: `256000` (256K)

### 9.4 Verify

Click "Verify" to test connection. If successful, Agent mode works immediately.

## 10. Verification

### 10.1 Basic Checks

```powershell
# Local
Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2

# Public URL (via Tailscale Funnel)
Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
```

Both should return `pid`, `uptimeSec`, `target`, `reasoningPatcher`.

### 10.2 Practical Test in Cursor

1. Open Cursor
2. Select `kimi-k2.6` in Agent mode
3. Ask: "Read package.json and tell me the version" (triggers a tool call)
4. Confirm the follow-up turn after the tool result completes **without 400 error** and generates an answer.

## 11. Operational Notes

### 11.1 Connection Stability During Long Thinking (Preventing Network Error)

Moonshot's Kimi K2.6 can take **60–150+ seconds** to respond during complex reasoning. During this silence, Cursor's cloud backend or intermediate proxies may treat the idle SSE stream as timed out and drop it, resulting in a `Network Error`. The multi-layer mitigations implemented in the shim are as follows.

| Layer | Mitigation | Default | Target |
|---|---|---|---|
| HTTP (SSE) | **SSE keepalive comments** (`: keepalive\n\n`) sent downstream | **15 s** | Idle timeout in Cursor cloud / intermediate proxies |
| HTTP (Header) | `X-Accel-Buffering: no` + `Cache-Control: no-cache, no-transform` | Always added | Suppress nginx/CDN/edge buffering |
| TCP | **TCP keep-alive** (`setKeepAlive(true, 15s)` + `setNoDelay(true)`) | **15 s** | NAT/CGNAT/home & corporate FW silent-TCP session drops |
| Node.js | `requestTimeout=0` / `keepAliveTimeout=600s` / `timeout=0` | — | Prevent shim's own default timeouts from killing long SSE |
| Upstream | Auto-retry (`ECONNRESET` / `ETIMEDOUT` / `UND_ERR_SOCKET`) | 3 retries | Recover transient disconnects to Moonshot |

Adjustable via environment variables:

```powershell
# Shorten SSE keepalive interval further (example: 10 seconds)
$env:SHIM_KEEPALIVE_MS="10000"

# Change TCP keep-alive interval (example: 10 seconds)
$env:SHIM_TCP_KEEPALIVE_MS="10000"
```

**Limitations (not fixable from shim side)**

- **Cursor client’s own SSE receive timeout** is internal to Cursor and cannot be changed by the shim. The mitigations above are a best-effort attempt to avoid hitting it.
- **Moonshot upstream silence of 60–150 s** is Moonshot's thinking-time behavior; the shim cannot shorten it.

If a `Network Error` occurs again, check `moonshot-shim.log` for that timestamp. If `keepalive=N` is present on the line, it confirms that keepalives were sent but Cursor still dropped the connection, isolating the issue to the Cursor client side.

### 11.2 URL is Fixed

The Tailscale Funnel URL (`https://<your-funnel-domain>/`) **never changes**. No Cursor setting updates needed after reboots.

### 11.3 If Tailscale Service Stops

If the `tailscaled` Windows service stops, the funnel drops. It normally auto-starts and auto-recovers, but if manual restart is needed:

```powershell
Restart-Service tailscaled
# Wait ~30 seconds for funnel to restore
```

### 11.4 Shim Log

```powershell
Get-Content "<repo-path>\moonshot-shim.log" -Tail 20
```

### 11.5 Check Funnel Status

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" funnel status
```

### 11.6 Completely Stop Funnel

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

## 12. Known Limitations & Future Improvements

| Item | Current | Future |
| --- | --- | --- |
| Placeholder `" "` | Works because Moonshot doesn't validate content. Will break if Moonshot tightens validation. | If Cursor natively supports `reasoning_content`, shim becomes unnecessary. |
| External exposure | Port 8787 is exposed via Tailscale Funnel. | Effectively inside Tailscale's trust boundary, so zero-trust-safe. |
| Shim resident | node.exe stays in background (~48 MB). | Could be converted to a Windows service for complete invisibility. |

## 13. Full Auto-Reproduction Playbook (unattended execution)

The following requires no human judgment or contextual understanding; it can be reproduced purely through a sequence of commands and file operations. Uses copy-paste blocks and pass/fail conditions to minimize required knowledge.

### 13-1. Precondition Checks

Run sequentially. If any stop condition triggers, go back to the step before it.

```powershell
# A. Tailscale installed?
Test-Path "C:\Program Files\Tailscale\tailscale.exe"
# Stop: False → Install Tailscale Windows client from https://tailscale.com/download/windows

# B. shim file exists?
Test-Path "<repo-path>\server.js"
# Stop: False → Place server.js per sister doc CURSOR_KIMI_K26_FIX.md §6

# C. node_modules exists?
Test-Path "<repo-path>\node_modules\undici\package.json"
# Stop: False → cd <repo-path> && npm install

# D. Funnel enabled in Tailscale admin console?
# https://login.tailscale.com/admin/settings/features
# Confirm Funnel is ON
```

### 13-2. First Manual Test

```powershell
cd "<repo-path>"

# Manual shim launch → Ctrl+C to stop (just to verify listening)
node server.js
# Stop: "listening on http://127.0.0.1:8787" not shown → Check SHIM_PORT conflict via netstat

# Test Tailscale Funnel
& "C:\Program Files\Tailscale\tailscale.exe" funnel --bg 8787

# Verify public healthz
$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# Stop: $r.reasoningPatcher -ne "enabled" → Funnel may point to wrong port or shim not running

# Reset after test
& "C:\Program Files\Tailscale\tailscale.exe" funnel reset
```

### 13-3. Create Automation Files

#### start-tailscale.cmd

Path: `<repo-path>\start-tailscale.cmd`

Full content:

```batch
@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { Write-Host '[1/3] shim already running' -ForegroundColor Yellow } else { Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden; Write-Host '[1/3] shim launched' -ForegroundColor Green }"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; for($i=0;$i-lt10;$i++){Start-Sleep -Milliseconds 500; try{ $r=Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2; Write-Host ('[2/3] healthz OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{} }; if(-not $ok){ Write-Host '[2/3] healthz FAIL' -ForegroundColor Red; exit 1 }"
if errorlevel 1 exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ts='C:\Program Files\Tailscale\tailscale.exe'; $ok=$false; for($i=0;$i-lt30;$i++){ try{ & $ts funnel --bg 8787 2>$null | Out-Null; $r=Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4; Write-Host ('[3/3] public OK pid={0}' -f $r.pid) -ForegroundColor Green; $ok=$true; break }catch{ Start-Sleep -Seconds 2 } }; if(-not $ok){ Write-Host '[3/3] FAIL' -ForegroundColor Red; exit 1 }"

endlocal
exit /b 0
```

#### start-tailscale-hidden.vbs

Path: `<repo-path>\start-tailscale-hidden.vbs`

Full content:

```vbs
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run Chr(34) & "<repo-path>\start-tailscale.cmd" & Chr(34), 0, False
Set WshShell = Nothing
```

#### Startup Shortcut (.lnk)

Run the following PowerShell:

```powershell
$shell = New-Object -ComObject WScript.Shell
$startup = $shell.SpecialFolders("Startup")
$shortcut = $shell.CreateShortcut("$startup\Start-MoonshotShim-Tailscale-Hidden.lnk")
$shortcut.TargetPath = "<repo-path>\start-tailscale-hidden.vbs"
$shortcut.WorkingDirectory = "<repo-path>"
$shortcut.WindowStyle = 7
$shortcut.Save()
```

**Pass condition**: `Start-MoonshotShim-Tailscale-Hidden.lnk` exists in `$startup`.

### 13-4. Post-Automation Verification

Reboot (or log off → log on), wait 30 seconds, then run:

```powershell
# Public healthz check
$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 5
# Pass: $r.reasoningPatcher -eq "enabled" and $r.pid -gt 0

# Manual: In Task Manager Details tab, confirm a node.exe has CommandLine containing server.js
```

### 13-5. Cursor Settings (User performs manually)

Out of scope for this doc. User sets manually:

```
Override OpenAI Base URL: https://<your-funnel-domain>/v1
```

---

**Operations out of scope for this document:**
- Modifying Cursor's `settings.json` or model list
- Setting the API Key
- Enabling Funnel in Tailscale admin console (first-time only)
