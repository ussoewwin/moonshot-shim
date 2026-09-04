@echo off
REM ============================================================
REM  start-img-mcp.cmd
REM  ------------------------------------------------------------
REM  img-recognition MCP server launcher (port 19690, auto-restart).
REM    AutoClaw MCP tools: upload_image / recognize_image
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-img-mcp.ps1"
endlocal
