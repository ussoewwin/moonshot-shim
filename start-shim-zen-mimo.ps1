# start-shim-zen-mimo.ps1
#
# Launch a moonshot-shim instance relaying to OpenCode Zen (not Go) for the
# free models. Runs on port 8802 with auto-restart.
#
#   AutoClaw -> http://127.0.0.1:8802/v1 -> https://opencode.ai/zen/v1
#
# Why Zen and not Go: the free entries are published on Zen and the Go catalog
# only carries a few of them. mimo-v2.6-flash-free is Zen-only.
#
# The model id is forwarded unchanged, so the client sends
# "mimo-v2.6-flash-free" and any other Zen free id can be used through the same
# relay without restarting it.
#
# SHIM_FORCE_THINKING is deliberately unset: the thinking field is a
# Zen/anthropic-style extension and the free model does not need it injected.
#
# Billing: Zen is pay-as-you-go. The models listed as Free in the Zen price
# table are free; any other id sent through this port would be charged, so keep
# this instance for the -free ids only.
#
# Usage (in this directory):  .\start-shim-zen-mimo.ps1
# Logon auto-start: not registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Zen target (override defaults) ---
$env:SHIM_PORT = '8802'
$env:SHIM_TARGET = 'https://opencode.ai/zen/v1'
$env:SHIM_RETRY_429 = '0'        # pass the Zen 429 (FreeUsageLimitError) straight through; the default absorption would retry for minutes
$env:SHIM_LOOPBACK_ONLY = '1'   # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'   # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-zen-mimo.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [zen-mimo-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Zen free models target)"
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
