@echo off
REM ============================================================
REM  start-shim-opencode-dsv41-flash.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go DeepSeek V4.1 Flash relay (port 8798).
REM    AutoClaw -> http://127.0.0.1:8798/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-dsv41-flash.ps1"
endlocal
