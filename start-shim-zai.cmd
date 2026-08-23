@echo off
REM ============================================================
REM  start-shim-zai.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> Z.ai (GLM) ローカル中継リレーの起動スクリプト。
REM  2台目シム: node server.js (127.0.0.1:8789)
REM     AutoClaw -> http://127.0.0.1:8789/v1 -> https://api.z.ai/api/coding/paas/v4
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-zai.ps1"
endlocal
