# Changelog

---

## v1.0.4 (2026-04-29) — Cursor Model Validation Workaround

> Release notes: [v1.0.4](https://github.com/ussoewwin/moonshot-shim/releases/tag/v1.0.4) (to be updated)

- Added Cursor compatibility workaround for `Model name is not valid: "kimi-k2.6"`:
  - `server.js` now forces `json.model` to `kimi-k2.6` on chat-completion requests
  - `GET /v1/models` response is rewritten to ensure `kimi-k2.6` is visible in the model catalog
  - Catalog response is returned as HTTP 200 for strict client-side validators while preserving upstream auth behavior for generation requests
- Detailed incident write-up (local doc): `md/CURSOR_MODEL_VALIDATION_FIX.md` (release note body to be added later)

---

## v1.0.3 (2026-04-27) — Startup 80070002 Fix

> Release notes: [v1.0.3](https://github.com/ussoewwin/moonshot-shim/releases/tag/v1.0.3) (to be updated)

- Fixed `wscript.exe` startup error `80070002` by removing hard-coded placeholder path usage in `start-tailscale-hidden.vbs`
- Updated launcher to resolve `start-tailscale.cmd` relative to `WScript.ScriptFullName`, making startup robust against folder moves
- Added detailed incident and fix documentation: `md/STARTUP_80070002_ROOT_CAUSE_AND_FIX.en.md`

---

## v1.02 (2026-04-27) — Phase 1 Shared Secret Authentication

> Release notes: [v1.02](https://github.com/<github-username>/moonshot-shim/releases/tag/v1.02) (TBD)

- **Shared Secret Authentication** (Measure 1): `X-Shim-Key` header required for all non-healthz requests; missing/invalid → 403
- **inject-header-proxy.mjs**: New thin proxy (port 8788) that auto-injects `X-Shim-Key` into every request; zero npm dependencies
- **Two-proxy chain**: Tailscale Funnel → :8788 (inject-header-proxy) → :8787 (server.js with validation) → Moonshot
- **Auto-generated secret**: `start-tailscale.cmd` creates `_shim_secret.txt` (64 random bytes, base64) on first run; persists across reboots
- **Gitignore**: `_shim_secret.txt` added to `.gitignore` to prevent credential leakage
- **recover-moonshot-shim skill**: Updated for port 8788 and dual-process recovery

---

## v1.01 (2026-04-27) — Phase 0 Security Hardening

> Release notes: [v1.01](https://github.com/<github-username>/moonshot-shim/releases/tag/v1.01) (TBD)

- **Path/Method Whitelist**: 6 paths + 3 methods only; else 405
- **Minimal /healthz**: Returns `{"status":"ok"}` only (no uptime/target/pid leak)
- **Security Headers**: `X-Content-Type-Options`, `X-Frame-Options`, `X-XSS-Protection`, `Referrer-Policy` on all responses
- **Cache hit logging**: Parses `cached_tokens` from usage, logs per-minute/lifetime hit rates
- **Fixed** `start-tailscale.cmd` healthz check for new minimal response format

---

## v1.0 (2026-04-26) — Initial Release

- Field injection: adds `reasoning_content: " "` to assistant tool-call messages
- SSE keepalive (15s), TCP keep-alive, no-buffer headers
- Upstream retry with exponential backoff (ECONNRESET, ETIMEDOUT)
- Crash-proof handlers (`uncaughtException`, `unhandledRejection`)
- Persistent log (5 MB rotation) + per-minute summary
- Cloudflare Quick Tunnel + Tailscale Funnel support
- Hidden auto-start on Windows logon (Tailscale)
