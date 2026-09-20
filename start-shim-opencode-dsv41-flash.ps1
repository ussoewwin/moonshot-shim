# start-shim-opencode-dsv41-flash.ps1
#
# Shim instance relaying OpenCode Go (zen) for DeepSeek V4.1 Flash.
# Runs on port 8798 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8798/v1 -> https://opencode.ai/zen/go/v1
#
# UPSTREAM MODEL ID: deepseek-flash  (AutoClaw display name: go-deepseek-v4.1-flash)
# Do NOT confuse this line with 8792 (start-shim-opencode.ps1), which routes the
# separate upstream model deepseek-v4-flash, or with 8791 (DeepSeek direct API).
# The upstream catalog has no id "deepseek-v4.1-flash"; only "deepseek-flash" works.
#
# Like the glm/kimi/qwen go lines this instance forces thinking injection
# (SHIM_FORCE_THINKING=enabled) so behavior is uniform across OpenCode Go relays.
# The shim still adds the mandatory x-opencode-session header (vendor requirement
# since 2026-09-06), reasoning echo, cache accounting and 429/503 absorption.
#
# Usage (in this directory):  .\start-shim-opencode-dsv41-flash.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8798'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'enabled'  # match glm/kimi/qwen go lines: inject {"thinking":{"type":"enabled"}} on every body
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-dsv41-flash.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-dsv41-flash-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / DeepSeek V4.1 Flash target, thinking forced)"
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
