# Changelog

---

## v1.01 (2026-04-27) — Phase 0 Security Hardening

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
