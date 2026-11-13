@echo off
REM ============================================================
REM  start-shim-beam-free.cmd
REM  Launch the OpenCode Go relay for Beam Free on port 8802.
REM    AutoClaw -> http://127.0.0.1:8802/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-beam-free.ps1"
endlocal
