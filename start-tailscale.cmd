@echo off
REM ============================================================
REM  start-tailscale.cmd
REM  ------------------------------------------------------------
REM  One-shot launcher (fire-and-forget) for the Cursor <-> Kimi
REM  K2.6 path using Tailscale Funnel (fixed URL).
REM
REM  Behavior:
REM    [1/3] If port 8787 is not LISTEN, launch node server.js
REM          hidden in the background.
REM    [2/3] Poll /healthz for up to 5 seconds.
REM    [3/3] Run `tailscale funnel --bg 8787` to register the
REM          funnel config with the tailscaled Windows service.
REM          The config is persisted by tailscaled; this command
REM          exits immediately, no console window stays open.
REM
REM  Fixed URL: https://<your-funnel-domain>/
REM  Cursor -> Override OpenAI Base URL:
REM     https://<your-funnel-domain>/v1
REM
REM  This .cmd is intended to be invoked from start-tailscale-hidden.vbs
REM  on logon, but can also be run manually for verification.
REM ============================================================

setlocal
cd /d "%~dp0"

REM --- [1/3] Launch shim if not already on 8787 ---------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) {" ^
    "Write-Host '[1/3] shim already running on 8787' -ForegroundColor Yellow" ^
  "} else {" ^
    "Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory '%~dp0' -WindowStyle Hidden;" ^
    "Write-Host '[1/3] shim launched (hidden)' -ForegroundColor Green" ^
  "}"

REM --- [2/3] Wait for /healthz -------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 10; $i++) {" ^
    "Start-Sleep -Milliseconds 500;" ^
    "try {" ^
      "$r = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2;" ^
      "Write-Host ('[2/3] healthz OK pid={0} uptime={1}s' -f $r.pid, $r.uptimeSec) -ForegroundColor Green;" ^
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

REM --- [3/3] Register funnel config (one-shot, persisted by tailscaled) ---
REM Retry a few times in case tailscaled is not yet ready right after logon.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$tsExe = 'C:\Program Files\Tailscale\tailscale.exe';" ^
  "$ok = $false;" ^
  "for ($i = 0; $i -lt 30; $i++) {" ^
    "try {" ^
      "& $tsExe funnel --bg 8787 2>$null | Out-Null;" ^
      "$r = Invoke-RestMethod 'https://<your-funnel-domain>/healthz' -TimeoutSec 4;" ^
      "Write-Host ('[3/3] public healthz OK pid={0} uptime={1}s' -f $r.pid, $r.uptimeSec) -ForegroundColor Green;" ^
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
