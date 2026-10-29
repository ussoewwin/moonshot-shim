@echo off
REM ============================================================
REM  start-shim-opencode-minimax31.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go MiniMax M3.1 Flash relay (port 8800).
REM    AutoClaw -> http://127.0.0.1:8800/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-minimax31.ps1"
endlocal