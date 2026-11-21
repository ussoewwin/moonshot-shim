# start-shim-longcat-free.ps1
#
# Launch a moonshot-shim instance relaying to OpenCode Go for LongCat 2.5 Free.
# Runs on port 8803 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8803/v1 -> https://opencode.ai/zen/go/v1
#
# longcat-2.5-free is one of the Go free entries: 100 requests per day,
# prompts are not used for training and not retained (zero retention).
# Hosted in China: the Go workspace privacy settings must allow Global
# regions or upstream rejects the request. The strongest of the four
# current Go free models on shared benchmarks (Terminal-Bench 2.1 88.4,
# DeepSWE 64.6, measured 2026-11-22).
#
# SHIM_FORCE_MODEL pins the upstream model id, so the client can send any name
# (or omit the model) and still reach longcat-2.5-free. The /v1/models response
# is rewritten to advertise only that id, which is what FORCE_MODEL does.
#
# SHIM_FORCE_THINKING is deliberately unset, mirroring beam-free: whether the
# thinking field is part of longcat's contract is unverified; the AUTO mode
# only injects for z.ai/bigmodel targets, so nothing is added here.
#
# Usage (in this directory):  .\start-shim-longcat-free.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8803'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_MODEL = 'longcat-2.5-free'
# Dual-stack listen: clients that resolve "localhost" to ::1 must reach
# this relay too (measured on the beam-free relay: [::1]:8802 was refused while 127.0.0.1 worked).
$env:SHIM_HOST = '::'
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-longcat-free.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [longcat-free-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / longcat-2.5-free target, model pinned)"
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
