# start-shim-opencode-minimax31.ps1
#
# Launch a moonshot-shim instance relaying to OpenCode Go (zen) for MiniMax M3.1 Flash.
# Runs on port 8800 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8800/v1 -> https://opencode.ai/zen/go/v1
#
# minimax-m3.1-flash accepts the OpenAI chat/completions protocol with the
# thinking field (measured alongside the other go lines). SHIM_FORCE_THINKING=enabled
# matches kimi/qwen: MiniMax reasoning models emit reasoning_content when the body
# carries {"thinking":{"type":"enabled"}}. The model id is forwarded unchanged
# (client sends minimax-m3.1-flash; no SHIM_FORCE_MODEL needed).
#
# Usage (in this directory):  .\start-shim-opencode-minimax31.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8800'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'enabled'  # MiniMax emits reasoning_content under the thinking field
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-minimax31.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-minimax31-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / MiniMax M3.1 Flash target, thinking forced)"
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
