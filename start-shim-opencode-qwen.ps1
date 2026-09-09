# start-shim-opencode-qwen.ps1
#
# Launch a shim instance relaying to OpenCode Go (zen) for qwen3.8-flash.
# Runs on port 8795 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8795/v1 -> https://opencode.ai/zen/go/v1
#
# qwen3.8-flash mirrors the other OpenCode Go lines (glm/kimi): provider is
# registered reasoning:true and this instance forces thinking injection so
# behavior is uniform across all go relays. The shim still adds the mandatory
# x-opencode-session header (vendor requirement since 2026-09-06), reasoning
# echo, cache accounting and 429/503 absorption.
#
# Usage (in this directory):  .\start-shim-opencode-qwen.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8795'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'enabled'  # match glm/kimi go lines: inject {"thinking":{"type":"enabled"}} on every body

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-qwen.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-qwen-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / qwen target, thinking forced)"
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
