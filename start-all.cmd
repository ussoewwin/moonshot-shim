@echo off
REM ============================================================
REM  start-all.cmd
REM  ------------------------------------------------------------
REM  One-shot launcher for the Cursor <-> Kimi K2.6 path.
REM
REM  1) Start moonshot-shim (node server.js) on 127.0.0.1:8787
REM     (skipped if port 8787 already LISTENs)
REM  2) Verify GET /healthz responds
REM  3) Start cloudflared quick tunnel in foreground so the new
REM     https://*.trycloudflare.com URL is visible to the user.
REM
REM  After the URL appears, paste it (with /v1 suffix) into
REM    Cursor -> Settings -> Models -> Override OpenAI Base URL
REM  Then press Verify. Keep this window open.
REM ============================================================

setlocal
cd /d "%~dp0"

echo.
echo === [1/3] Checking moonshot-shim on port 8787 ===
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) {" ^
    "Write-Host '    shim already running on 8787, skip launch' -ForegroundColor Yellow" ^
  "} else {" ^
    "Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden;" ^
    "Write-Host '    shim launched (background, hidden)' -ForegroundColor Green" ^
  "}"

echo.
echo === [2/3] Waiting for /healthz ===
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 10; $i++) {" ^
    "Start-Sleep -Milliseconds 500;" ^
    "try {" ^
      "$r = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2;" ^
      "Write-Host ('    healthz OK pid={0} uptime={1}s target={2}' -f $r.pid, $r.uptimeSec, $r.target) -ForegroundColor Green;" ^
      "$ok = $true; break" ^
    "} catch {}" ^
  "};" ^
  "if (-not $ok) {" ^
    "Write-Host '    healthz did not respond within 5s. Aborting.' -ForegroundColor Red;" ^
    "Write-Host '    See moonshot-shim.log for details.' -ForegroundColor Red;" ^
    "exit 1" ^
  "}"
if errorlevel 1 (
  echo.
  echo Press any key to close this window.
  pause > nul
  exit /b 1
)

echo.
echo === [3/3] Starting cloudflared quick tunnel (HTTP/2) ===
echo     The public https URL will appear below.
echo     Copy it, append "/v1", paste into Cursor -^> Override OpenAI Base URL.
echo     This launcher will auto-restart cloudflared if it exits.
echo     Press Ctrl+C to stop intentionally.
echo.

:CF_LOOP
echo.
echo [cloudflared] launching at %date% %time%
"%~dp0cloudflared.exe" tunnel --url http://127.0.0.1:8787 --protocol http2
set "CF_EXIT=%errorlevel%"
echo [cloudflared] exited with code %CF_EXIT% at %date% %time%
echo [cloudflared] restarting in 3 seconds...
timeout /t 3 /nobreak > nul
goto CF_LOOP

echo.
echo cloudflared exited. Tunnel is now down.
pause
