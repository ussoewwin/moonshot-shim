# start-shim-opencode-kimi.ps1
#
# Launch the SIXTH moonshot-shim instance relaying to OpenCode Go (zen) for kimi-k3.
# Runs on port 8794 with auto-restart, mirroring the others.
#
#   AutoClaw -> http://127.0.0.1:8794/v1 -> https://opencode.ai/zen/go/v1
#
# kimi-k3 was moved from Moonshot direct to OpenCode Go by the owner. This line
# keeps it on the uniform shim setup (429/503 absorber, reasoning_content patcher,
# logging). SHIM_FORCE_THINKING=enabled: kimi-k3 is a thinking model and the
# owner wants thinking on everywhere.
#
# Usage (in this directory):  .\start-shim-opencode-kimi.ps1

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8794'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'enabled'  # kimi-k3 thinking on everywhere (owner request)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-kimi.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-kimi-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / KIMI target)"
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
