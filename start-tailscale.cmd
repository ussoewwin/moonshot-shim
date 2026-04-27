@echo off
REM ============================================================
REM  start-tailscale.cmd
REM  ------------------------------------------------------------
REM  One-shot launcher (fire-and-forget) for the Cursor <-> Kimi
REM  K2.6 path using Tailscale Funnel (fixed URL) + Shared Secret.
REM
REM  Architecture:
REM    Cursor -> https://ussoewwin.tail7d4c3e.ts.net/v1 (public)
REM           -> Tailscale Funnel :443
REM           -> inject-header-proxy :8788 (adds X-Shim-Key)
REM           -> server.js :8787 (validates X-Shim-Key)
REM           -> api.moonshot.ai/v1
REM
REM  Behavior:
REM    [0/3] Generate or load _shim_secret.txt (auto, persistent)
REM    [1/3] Launch server.js (:8787) + inject-header-proxy.mjs (:8788)
REM    [2/3] Poll /healthz on :8787 for up to 5s
REM    [3/3] Run `tailscale funnel --bg 8788` (funnel -> inject-header-proxy)
REM
REM  Cursor Override URL (unchanged):
REM     https://ussoewwin.tail7d4c3e.ts.net/v1
REM
REM  This .cmd is intended to be invoked from start-tailscale-hidden.vbs
REM  on logon, but can also be run manually for verification.
REM ============================================================

setlocal
cd /d "%~dp0"

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

REM --- [1/3] Launch shim + inject-header-proxy -------------------
REM server.js on :8787, inject-header-proxy.mjs on :8788
REM funnel points to :8788 later.
REM Both launched hidden.

REM First check if inject-header-proxy (:8788) is already running
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

REM --- [2/3] Wait for /healthz on shim (:8787) --------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 10; $i++) {" ^
    "Start-Sleep -Milliseconds 500;" ^
    "try {" ^
      "$r = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2;" ^
      "if ($r.status -eq 'ok') { Write-Host '[2/3] healthz OK' -ForegroundColor Green } else { throw 'unexpected healthz response' };" ^
      "$ok = $true; break" ^
    "} catch {}" ^
  "};" ^
  "if (-not $ok) {" ^
    "Write-Host '[2/3] healthz did not respond within 5s. Aborting.' -ForegroundColor Red;" ^
    "exit 1" ^
  "}"
if errorlevel 1 (
  exit /b 1
)

REM --- [3/3] Register funnel config -> :8788 (inject-header-proxy) ---
REM Retry a few times in case tailscaled is not yet ready right after logon.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$tsExe = 'C:\Program Files\Tailscale\tailscale.exe';" ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 30; $i++) {" ^
    "try {" ^
      "& $tsExe funnel --bg 8788 2>$null | Out-Null;" ^
      "$r = Invoke-RestMethod 'https://ussoewwin.tail7d4c3e.ts.net/healthz' -TimeoutSec 4;" ^
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

endlocal
exit /b 0
