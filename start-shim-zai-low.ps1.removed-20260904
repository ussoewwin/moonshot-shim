# start-shim-zai-low.ps1
#
# Z.ai OFFICIAL relay for "cheap/fast GLM": GLM-5.3-Flash with reasoning_effort=low (mild inference).
# Port 8797, auto-restart, mirroring the other launchers.
#
#   AutoClaw -> http://127.0.0.1:8797/v1 -> https://api.z.ai/api/coding/paas/v4
#
# GLM-5.3-FLASH has FORCED thinking (cannot be disabled per Z.ai docs), but
# reasoning_effort:"low" is the officially supported minimal-thought mode.
#
# Usage (in this directory):  .\start-shim-zai-low.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$env:SHIM_PORT = '8797'
$env:SHIM_TARGET = 'https://api.z.ai/api/coding/paas/v4'
$env:SHIM_FORCE_THINKING = 'enabled'  # GLM-5.3-FLASH: forced thinking (disabled would error)
$env:SHIM_REASONING_EFFORT = 'low'    # official minimal-thought mode for GLM-5.3/FLASH

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-zai-low.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [zai-low-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (Z.ai / GLM-5.3-Flash LOW-EFFORT target)"
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
