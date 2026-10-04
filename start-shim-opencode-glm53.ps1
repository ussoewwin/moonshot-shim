# start-shim-opencode-glm53.ps1
#
# Launch a moonshot-shim instance relaying to OpenCode Go (zen) for GLM-5.3.
# Runs on port 8796 with auto-restart, mirroring the other go lines.
#
#   AutoClaw -> http://127.0.0.1:8796/v1 -> https://opencode.ai/zen/go/v1
#
# OpenCode Go carries GLM-5.3 (full model) in addition to GLM-5.3-Flash (8793).
# The upstream catalog id is "glm-5.3"; the alias id "go-glm-5.3" 400s as
# "Model is unavailable" (measured 2026-10-04), so the client model name is
# forwarded unchanged (no SHIM_FORCE_MODEL on this line). Thinking is stripped
# like the 8793 line: OpenCode Go mixes backends and some reject the thinking
# field (measured 2026-09-11, see start-shim-opencode-glm.ps1).

#
# Usage (in this directory):  .\start-shim-opencode-glm53.ps1
# Logon auto-start: registered in start-shim-hidden.vbs.
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# --- OpenCode Go target (override defaults) ---
$env:SHIM_PORT = '8796'
$env:SHIM_TARGET = 'https://opencode.ai/zen/go/v1'
$env:SHIM_FORCE_THINKING = 'strip'    # remove thinking entirely: mixed OpenCode Go backends 400 on it (see glm 8793 header)
$env:SHIM_LOOPBACK_ONLY = '1'  # hardening: reject non-loopback clients
$env:SHIM_REDACT_TAIL   = '1'  # hardening: redact secrets in newest message only (prefix untouched -> cache preserved)

$wrapperLog = Join-Path $PSScriptRoot 'shim-wrapper-opencode-glm53.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [opencode-glm53-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: node server.js (OpenCode Go / GLM-5.3 target, model forced to go-glm-5.3)"
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
