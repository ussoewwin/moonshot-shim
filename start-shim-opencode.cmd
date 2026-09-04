@echo off
REM ============================================================
REM  start-shim-opencode.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go local relay launcher (port 8792).
REM    AutoClaw -> http://127.0.0.1:8792/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode.ps1"
endlocal
