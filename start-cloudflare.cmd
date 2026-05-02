@echo off
REM ============================================================
REM  start-cloudflare.cmd
REM  ------------------------------------------------------------
REM  Cloudflare Quick Tunnel for Cursor <-> Kimi (moonshot-shim).
REM  Local stack matches Tailscale: cloudflared -> :8788
REM  (inject-header-proxy, adds X-Shim-Key) -> :8787 server.js.
REM
REM  [0/3] _shim_secret.txt (same as start-tailscale.cmd)
REM  [1/3] server.js :8787 + inject-header-proxy.mjs :8788
REM  [2/3] Poll /healthz on :8787
REM  [3/3] cloudflared quick tunnel (background) + print URL
REM
REM  After run: paste printed URL + /v1 into Cursor Override, Verify.
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

REM --- [3/3] Cloudflare Quick Tunnel -> :8788 -------------------------
echo.
echo === [3/3] Starting Cloudflare Quick Tunnel (8788) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-cloudflare.ps1"
if errorlevel 1 (
  echo [3/3] start-cloudflare.ps1 failed.
  exit /b 1
)

endlocal
exit /b 0
