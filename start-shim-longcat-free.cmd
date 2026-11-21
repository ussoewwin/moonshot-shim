@echo off
REM ============================================================
REM  start-shim-longcat-free.cmd
REM  Launch the OpenCode Go relay for LongCat 2.5 Free on port 8803.
REM    AutoClaw -> http://127.0.0.1:8803/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-longcat-free.ps1"
endlocal
