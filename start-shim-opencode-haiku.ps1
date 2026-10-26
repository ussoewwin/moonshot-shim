# start-shim-opencode-haiku.ps1
#
# Launch a moonshot-shim instance relaying OpenCode Go (zen) for Claude Haiku 5.5.
# Runs on port 8799 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8799/v1/messages -> https://opencode.ai/zen/go/v1/messages
#
# claude-haiku-5-5 is Anthropic-protocol only: the OpenAI chat/completions form
# returns 400 ModelProtocolUnsupported (measured 2026-10-26), while POST
# /v1/messages with x-api-key returns 200 (billing_source "go", measured
# 2026-10-27). This line therefore forwards the /messages path unchanged and
# does NOT force thinking (the field is OpenAI-only; injection would break the
# Anthropic body). The shim still adds the mandatory x-opencode-session header,
# redacts logs, and enforces loopback-only.
#
# Client must send: x-api-key: <OpenCode Go key>, anthropic-version: 2023-06-01.
# Authorization: Bearer is rejected upstream ("Go requires a credential") - use
# x-api-key only.
#
# Usage (in this directory):  .\start-shim-opencode-haiku.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8799'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = ''  # no thinking field: Anthropic protocol body
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-haiku.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-haiku-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / Claude Haiku 5.5, Anthropic /messages passthrough)"
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