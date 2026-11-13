# start-shim-ollama-gemma4.ps1
#
# Launch a moonshot-shim instance relaying to the local Ollama OpenAI-compatible
# endpoint for gemma4-31b-ara-heretic (local GGUF, no API key needed upstream).
# Runs on port 8801 with auto-restart.
#
#   AutoClaw -> http://127.0.0.1:8801/v1 -> http://127.0.0.1:11434/v1
#
# Notes:
# - The upstream is the local Ollama service (no auth, no rate limit). The shim
#   still provides reasoning_content echo, cache accounting, and keepalive.
# - SHIM_FORCE_THINKING is unset: Ollama handles the model's own thinking format
#   natively, so the shim must not inject {"thinking":{...}} (unknown to Ollama).
# - SHIM_FORCE_MODEL is unset: the client picks the model id (gemma4-31b-ara-heretic).
#   If you want this shim to serve ONLY this model, set SHIM_FORCE_MODEL to pin it.
# - SHIM_LOOPBACK_ONLY=1 (hardening): reject non-loopback clients.
#
# Usage (in this directory):  .\start-shim-ollama-gemma4.ps1
# Logon auto-start: NOT registered in start-shim-hidden.vbs (start manually or add
# a line there if you want it always on).

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- Ollama target (override defaults) ---
$env:SHIM_PORT = '8801'
$env:SHIM_TARGET = 'http://127.0.0.1:11434/v1'
# No SHIM_FORCE_THINKING: Ollama handles thinking natively; injected field is unknown to it.
# No SHIM_FORCE_MODEL: client picks the model id (gemma4-31b-ara-heretic).
$env:SHIM_LOOPBACK_ONLY = '1'
$env:SHIM_REDACT_TAIL   = '1'

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-ollama-gemma4.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [ollama-gemma4-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (Ollama local / gemma4-31b-ara-heretic)"
Write-WrapperLog "wrapper log : $wrapperLog"

$attempt = 0
while ($true) {
    $attempt++
    Write-WrapperLog "attempt #$attempt -> spawning node server.js"
    $startedAt = Get-Date

    try {
        & node server.js
        $exit = $LASTEXITCODE
    } catch {
        $exit = -1
        Write-WrapperLog ("spawn threw: " + $_.Exception.Message)
    }

    $duration = (Get-Date) - $startedAt
    Write-WrapperLog ("node exited code={0} after {1:n1}s" -f $exit, $duration.TotalSeconds)

    if ($duration.TotalSeconds -lt 5) { $sleep = 5 } else { $sleep = 2 }
    Write-WrapperLog "sleeping ${sleep}s before restart"
    Start-Sleep -Seconds $sleep
}
