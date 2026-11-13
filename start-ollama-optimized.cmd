@echo off
REM ============================================================
REM  start-ollama-optimized.cmd
REM
REM  Launch Ollama with the VRAM-focused variables applied in this
REM  process, so ollama serve -> llama-server inherit them.
REM
REM  Why this file exists: a plain "restart the app" keeps an old
REM  serve process alive and the new values never reach llama-server.
REM
REM  Measured on RTX 5060 Ti 16 GB with gemma-4-31B Q2_K, ctx 8192:
REM    weights           11349 MiB
REM    KV f16             1840 MiB  (640 full + 1200 SWA)
REM    compute              177 MiB
REM    total              13366 MiB
REM  KV q8_0 needs flash attention on; with --flash-attn auto the
REM  cache stays f16, so OLLAMA_FLASH_ATTENTION=1 matters.
REM ============================================================

setlocal

set OLLAMA_FLASH_ATTENTION=1
set OLLAMA_KV_CACHE_TYPE=q8_0
set OLLAMA_NUM_PARALLEL=1
set OLLAMA_MAX_LOADED_MODELS=1
set OLLAMA_KEEP_ALIVE=120s
set OLLAMA_CONTEXT_LENGTH=8192

REM --- stop anything already holding 11434 -------------------------
set /a tries=0
:stoploop
curl -s -o nul http://127.0.0.1:11434/api/version 2>nul
if %errorlevel% neq 0 goto launch
taskkill /f /im "ollama app.exe" >nul 2>&1
taskkill /f /im ollama.exe >nul 2>&1
timeout /t 2 /nobreak >nul 2>&1
set /a tries+=1
if %tries% lss 10 goto stoploop

:launch
start "ollama-serve" /b "C:\Users\ussoe\AppData\Local\Programs\Ollama\ollama.exe" serve

echo waiting for Ollama on 11434 ...
set /a tries=0
:wait
timeout /t 2 /nobreak >nul 2>&1
curl -s -o nul http://127.0.0.1:11434/api/version 2>nul
if %errorlevel% equ 0 goto ready
set /a tries+=1
if %tries% lss 20 goto wait
echo Ollama did not answer after %tries% checks
endlocal
exit /b 1

:ready
echo Ollama is up with:
echo   OLLAMA_FLASH_ATTENTION=%OLLAMA_FLASH_ATTENTION%
echo   OLLAMA_KV_CACHE_TYPE=%OLLAMA_KV_CACHE_TYPE%
echo   OLLAMA_NUM_PARALLEL=%OLLAMA_NUM_PARALLEL%
echo   OLLAMA_MAX_LOADED_MODELS=%OLLAMA_MAX_LOADED_MODELS%
echo   OLLAMA_KEEP_ALIVE=%OLLAMA_KEEP_ALIVE%
echo   OLLAMA_CONTEXT_LENGTH=%OLLAMA_CONTEXT_LENGTH%
endlocal
exit /b 0
