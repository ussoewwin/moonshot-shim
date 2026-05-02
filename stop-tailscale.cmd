@echo off
REM ============================================================
REM  stop-tailscale.cmd
REM  Clears Tailscale Funnel mapping. Does NOT stop shim, proxy,
REM  or the Tailscale Windows service.
REM ============================================================

setlocal
echo Running: tailscale funnel reset ...
"C:\Program Files\Tailscale\tailscale.exe" funnel reset
set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" (
  echo NOTE: funnel reset exited %EC% ^(mapping may already have been off^).
) else (
  echo Tailscale funnel cleared.
)
endlocal
exit /b 0
