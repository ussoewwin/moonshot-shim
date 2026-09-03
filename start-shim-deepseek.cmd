@echo off
REM ============================================================
REM  start-shim-deepseek.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> DeepSeek local relay launcher (port 8791).
REM    AutoClaw -> http://127.0.0.1:8791/v1 -> https://api.deepseek.com/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-deepseek.ps1"
endlocal
