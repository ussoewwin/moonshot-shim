# start-shim-beam-free.ps1
#
# Launch a moonshot-shim instance relaying to OpenCode Go for Beam Free.
# Runs on port 8802 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8802/v1 -> https://opencode.ai/zen/go/v1
#
# beam-free is one of the Go free entries: unlimited requests per the Go limit
# table, and prompts are not used for training (data retention 30 days).
#
# SHIM_FORCE_MODEL pins the upstream model id, so the client can send any name
# (or omit the model) and still reach beam-free. The /v1/models response is
# rewritten to advertise only that id, which is what FORCE_MODEL does.
#
# SHIM_FORCE_THINKING is deliberately unset: beam-free is not a reasoning model
# in the Go lineup and the thinking field is not part of its contract.
#
# Usage (in this directory):  .\start-shim-beam-free.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8802'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_MODEL = 'beam-free'
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-beam-free.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [beam-free-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / beam-free target, model pinned)"
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
