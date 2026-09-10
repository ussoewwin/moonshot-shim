# start-shim-opencode-glm.ps1
#
# Launch a FIFTH moonshot-shim instance relaying to OpenCode Go (zen) for GLM-5.3-Flash.
# Runs on port 8793 with auto-restart, mirroring the others.
#
#   AutoClaw -> http://127.0.0.1:8793/v1 -> https://opencode.ai/zen/go/v1
#
# OpenCode Go routes GLM-5.3-Flash. This instance exists so the GLM-go model gets
# the same uniformity (429/503 absorption, reasoning_content patcher, logging) as
# every other shim line.
#
# SHIM_FORCE_THINKING=strip (changed 2026-09-11): OpenCode Go now load-balances
# glm-5.3-flash across backends where some reject the thinking field entirely.
# Measured with 6 direct probes per variant against /zen/go/v1:
#   body without thinking -> 6/6 HTTP 200
#   body with    thinking -> 4/6 HTTP 400  (json: unknown field "thinking")
# So this line must never forward the field, even if the client sends it.
# GLM-5.3-Flash still returns reasoning_content without the field, so thinking
# is not lost. Other go lines (kimi 8794 / qwen 8795 / dsv41 8798) keep
# SHIM_FORCE_THINKING=enabled because their models still accept the field.
#
# Usage (in this directory):  .\start-shim-opencode-glm.ps1
# Logon auto-start: add a line to start-shim-hidden.vbs or a shortcut.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8793'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'strip'    # remove thinking entirely: mixed OpenCode Go backends 400 on it (see header)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-glm.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-glm-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / GLM target)"
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