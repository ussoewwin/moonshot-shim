@echo off
REM ============================================================
REM  start-shim-zai-low.cmd
REM  ------------------------------------------------------------
REM  Z.ai official GLM-5.3-Flash LOW-EFFORT relay (port 8797).
REM    AutoClaw -> http://127.0.0.1:8797/v1 -> https://api.z.ai/api/coding/paas/v4
REM    thinking forced-on (GLM-5.3-FLASH cannot disable) + reasoning_effort=low
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-zai-low.ps1"
endlocal
