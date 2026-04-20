# start-shim.ps1
#
# Launch moonshot-shim with auto-restart. If `node server.js` exits for any
# reason (crash, OOM, network blip, etc.) this loop re-spawns it after a
# short backoff. Use Ctrl-C to stop the wrapper itself.
#
# Usage (in this directory):
#   .\start-shim.ps1
#
# Optional environment variables (set before running, or pass as -env...):
#   $env:SHIM_PORT  = "8787"        # listen port
#   $env:SHIM_HOST  = "127.0.0.1"   # listen host
#   $env:SHIM_DEBUG = "1"           # verbose patcher logging
#   $env:SHIM_LOG   = "C:\path\to\moonshot-shim.log"
#
# All shim output is also persisted to .\moonshot-shim.log by the shim
# itself, regardless of this wrapper.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js"
Write-WrapperLog "wrapper log : $wrapperLog"
Write-WrapperLog "shim log    : $(Join-Path $PSScriptRoot 'moonshot-shim.log')"

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

    # If the process died very quickly, back off a bit harder so we don't
    # spin in a tight crash loop and bury the cause in noise.
    if ($duration.TotalSeconds -lt 5) {
        $sleep = 5
    } else {
        $sleep = 2
    }
    Write-WrapperLog "sleeping ${sleep}s before restart"
    Start-Sleep -Seconds $sleep
}
