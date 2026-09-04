@echo off
REM ============================================================
REM  start-shim-opencode-kimi.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go KIMI relay launcher (port 8794).
REM    AutoClaw -> http://127.0.0.1:8794/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-kimi.ps1"
endlocal
