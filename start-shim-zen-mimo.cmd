@echo off
REM ============================================================
REM  start-shim-zen-mimo.cmd
REM  Launch the OpenCode Zen relay on port 8802 (free models).
REM    AutoClaw -> http://127.0.0.1:8802/v1 -> https://opencode.ai/zen/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-zen-mimo.ps1"
endlocal
