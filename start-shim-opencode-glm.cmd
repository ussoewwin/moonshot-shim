@echo off
REM ============================================================
REM  start-shim-opencode-glm.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> OpenCode Go GLM relay launcher (port 8793).
REM    AutoClaw -> http://127.0.0.1:8793/v1 -> https://opencode.ai/zen/go/v1
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-opencode-glm.ps1"
endlocal
