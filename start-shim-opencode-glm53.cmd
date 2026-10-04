@echo off
REM ============================================================
REM  start-shim-opencode-glm53.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go GLM-5.3 relay launcher (port 8796).
REM    AutoClaw -> http://127.0.0.1:8796/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-glm53.ps1"
endlocal
