@echo off
REM ============================================================
REM  switch-tunnel.cmd  tailscale | cloudflare | status
REM  ------------------------------------------------------------
REM  cloudflare: clear Tailscale Funnel, start Quick Tunnel (8788).
REM  tailscale:  stop Quick Tunnel (this repo), run start-tailscale.cmd.
REM  status:     tunnel-status.cmd
REM ============================================================

setlocal
cd /d "%~dp0"

if /I "%~1"=="cloudflare" goto DO_CF
if /I "%~1"=="tailscale" goto DO_TS
if /I "%~1"=="status" goto DO_ST

echo Usage: %~nx0 tailscale ^| cloudflare ^| status
endlocal
exit /b 1

:DO_CF
echo [switch-tunnel] ---^> Cloudflare Quick Tunnel
call "%~dp0stop-tailscale.cmd"
call "%~dp0start-cloudflare.cmd"
goto END_OK

:DO_TS
echo [switch-tunnel] ---^> Tailscale Funnel (fixed URL)
call "%~dp0stop-cloudflare.cmd"
call "%~dp0start-tailscale.cmd"
goto END_OK

:DO_ST
call "%~dp0tunnel-status.cmd"
goto END_OK

:END_OK
endlocal
exit /b 0
