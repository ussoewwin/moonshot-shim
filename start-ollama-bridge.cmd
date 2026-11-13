@echo off
REM ============================================================
REM  start-ollama-bridge.cmd
REM  Auto-start: Ollama VRAM-optimized restart + bridge on 8801.
REM  Called from start-shim-hidden.vbs at logon (after other relays).
REM ============================================================

setlocal

REM Wait for Ollama API to be ready (max 30s)
set /a tries=0
:wait_ollama
timeout /t 2 /nobreak >nul 2>&1
set /a tries+=1
curl -s -o nul http://127.0.0.1:11434/api/version 2>nul
if %errorlevel% neq 0 (
  if %tries% lss 15 goto wait_ollama
  echo OLLAMA NOT READY after %tries% tries - skipping bridge
  goto :eof
)

REM VRAM optimization: restart Ollama with flash attention + KV cache q8_0 + single slot
REM (only kills llama-server, the main ollama daemon stays alive)
taskkill /f /im llama-server.exe >nul 2>&1

REM Set optimized env vars for the next llama-server spawn
REM These are inherited by ollama's llama-server child processes
REM (ollama main process reads its own env, but passes these to llama-server)

REM Note: env vars must be set on the ollama main process to propagate.
REM Since ollama is already running, we set them system-wide for next boot
REM and restart llama-server manually with them:

setx OLLAMA_FLASH_ATTENTION 1 >nul 2>&1
setx OLLAMA_KV_CACHE_TYPE q8_0 >nul 2>&1
setx OLLAMA_NUM_PARALLEL 1 >nul 2>&1
setx OLLAMA_MAX_LOADED_MODELS 1 >nul 2>&1

REM Also set for this session
set OLLAMA_FLASH_ATTENTION=1
set OLLAMA_KV_CACHE_TYPE=q8_0
set OLLAMA_NUM_PARALLEL=1
set OLLAMA_MAX_LOADED_MODELS=1

REM Start the bridge on 8801
cd /d "D:\USERFILES\GitHub\moonshot-shim"
start /b "" node ollama-bridge.mjs

echo ollama-bridge started on port 8801

endlocal