@echo off
REM ============================================================
REM  start-shim-opencode-haiku.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go Claude Haiku 5.5 relay (port 8799).
REM    AutoClaw -> http://127.0.0.1:8799/v1/messages -> https://opencode.ai/zen/go/v1/messages
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-haiku.ps1"
endlocal