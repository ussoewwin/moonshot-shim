# start-shim-zai.ps1
#
# Launch a SECOND moonshot-shim instance that relays to Z.ai (GLM) instead of
# Moonshot. Runs on port 8789 with auto-restart, mirroring start-shim.ps1.
#
#   AutoClaw -> http://127.0.0.1:8789/v1 -> https://api.z.ai/api/coding/paas/v4
#
# Usage (in this directory):  .\start-shim-zai.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- Z.ai target (override defaults) ---
$env:SHIM_PORT = '8789'
$env:SHIM_TARGET = 'https://api.z.ai/api/coding/paas/v4'

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-zai.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [zai-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (Z.ai target)"
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
