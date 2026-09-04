# start-shim-opencode.ps1
#
# Launch a FOURTH moonshot-shim instance that relays to OpenCode Go (zen) instead of
# Moonshot/Z.ai/DeepSeek. Runs on port 8792 with auto-restart, mirroring the others.
#
#   AutoClaw -> http://127.0.0.1:8792/v1 -> https://opencode.ai/zen/go/v1
#
# OpenCode Go routes DeepSeek V4 Flash. Its relay tolerates missing reasoning_content
# in tool-call history (no 400), but thinking is active, so the shim's reasoning echo
# + cache accounting + 429/503 absorber still add value and keep all instances uniform.
#
# Usage (in this directory):  .\start-shim-opencode.ps1
# Logon auto-start: add a line to start-shim-hidden.vbs or a shortcut.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8792'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go target)"
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
