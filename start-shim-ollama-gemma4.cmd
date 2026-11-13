@echo off
REM ============================================================
REM  start-shim-ollama-gemma4.cmd
REM  ------------------------------------------------------------
REM  AutoClaw <-> local Ollama gemma4-31b-ara-heretic (port 8801).
REM    AutoClaw -> http://127.0.0.1:8801/v1 -> http://127.0.0.1:11434/v1
REM  Prerequisite: Ollama service on 11434 with the model loaded:
REM    ollama create gemma4-31b-ara-heretic -f <path to Modelfile>
REM ============================================================

setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-shim-ollama-gemma4.ps1"
endlocal