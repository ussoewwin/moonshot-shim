@echo off
REM ============================================================
REM  start-ollama-bridge.cmd
REM
REM  Start the OpenAI-compatible bridge for the local Ollama model
REM  on port 8801. Called from start-shim-hidden.vbs at logon.
REM
REM  VRAM-first settings:
REM    BRIDGE_KEEP_ALIVE=0     unload the model as soon as a reply is out,
REM                            so the weights never sit on the GPU while
REM                            ComfyUI / Topaz / other work needs it.
REM    BRIDGE_VRAM_FLOOR=2048  if free VRAM drops below this while a peer
REM                            GPU app runs, release the model.
REM    BRIDGE_NUM_CTX=8192     context cap (KV cache is 10 full + 50 SWA layers).
REM
REM  Note: the VRAM values themselves come from Ollama's own process
REM  environment - see start-ollama-optimized.cmd.
REM ============================================================

setlocal

REM Wait for Ollama API to be ready (max 30s), otherwise skip
set /a tries=0
:wait_ollama
curl -s -o nul http://127.0.0.1:11434/api/version 2>nul
if %errorlevel% equ 0 goto ollama_ready
set /a tries+=1
if %tries% geq 15 (
  echo OLLAMA NOT READY after %tries% checks - bridge not started
  goto :eof
)
timeout /t 2 /nobreak >nul 2>&1
goto wait_ollama

:ollama_ready

REM Skip if the bridge is already listening on 8801
curl -s -o nul http://127.0.0.1:8801/healthz 2>nul
if %errorlevel% equ 0 (
  echo bridge already listening on 8801
  goto :eof
)

set BRIDGE_KEEP_ALIVE=0
set BRIDGE_VRAM_FLOOR=2048
set BRIDGE_NUM_CTX=8192

cd /d "%~dp0"
start /b "" node ollama-bridge.mjs
echo ollama-bridge started on port 8801 (keep_alive=0, vram floor 2048 MiB)

endlocal
