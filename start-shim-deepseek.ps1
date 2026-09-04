# start-shim-deepseek.ps1
#
# Launch a THIRD moonshot-shim instance that relays to DeepSeek instead of
# Moonshot/Z.ai. Runs on port 8791 with auto-restart, mirroring the others.
#
#   AutoClaw -> http://127.0.0.1:8791/v1 -> https://api.deepseek.com/v1
#
# DeepSeek V4 (thinking mode) has the same validation rule as Kimi/Z.ai GLM:
# every assistant message with tool_calls must carry reasoning_content.
# The shim's patcher + reasoning echo solves it, and the 429 absorber +
# thinking injection (auto: off for non z.ai targets) apply as configured.
#
# Usage (in this directory):  .\start-shim-deepseek.ps1
# Logon auto-start: add a line to start-shim-hidden.vbs or a shortcut.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- DeepSeek target (override defaults) ---
$env:SHIM_PORT = '8791'
$env:SHIM_TARGET = 'https://api.deepseek.com/v1'
$env:SHIM_FORCE_THINKING = 'enabled'  # inject {"thinking":{"type":"enabled"}} on every body lacking it

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-deepseek.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [deepseek-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (DeepSeek target)"
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
