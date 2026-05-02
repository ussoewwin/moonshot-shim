@echo off
REM Stop Cloudflare Quick Tunnel for this repo (cloudflared-quick.pid only).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-cloudflare.ps1"
