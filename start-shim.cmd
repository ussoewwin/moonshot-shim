@echo off
REM ============================================================
REM  start-shim.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> Moonshot ローカル中継リレーの起動スクリプト。
REM
REM  トンネル(Tailscale/Cloudflare)・inject-header-proxy は不要。
REM  単一プロセス: node server.js (127.0.0.1:8787)
REM     AutoClaw -> http://127.0.0.1:8787/v1 -> https://api.moonshot.ai/v1
REM
REM  start-shim.ps1 の自動再起動ループを隠しウィンドウで実行する。
REM  手動起動:  .\start-shim.cmd
REM  ログオン自動起動:  start-shim-hidden.vbs を shell:startup へ
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim.ps1"
endlocal