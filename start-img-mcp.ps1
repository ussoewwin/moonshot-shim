# start-img-mcp.ps1
#
# Launch the img-recognition MCP server (workspace/mcp/img-mcp-server.mjs, port 19690)
# with auto-restart, mirroring the shim wrappers.
#
#   AutoClaw <-> MCP tools: upload_image / recognize_image (port 19690)
#
# Usage: run once, or wire into start-shim-hidden.vbs for logon auto-start.

$ErrorActionPreference = 'Stop'
$serverPath = "C:\Users\ussoe\.openclaw-autoclaw\agents\shim\workspace\mcp\img-mcp-server.mjs"
$node = "C:\Program Files\AutoClaw\resources\node\node.exe"
if (-not (Test-Path $node)) { $node = 'node' }

$wrapperLog = 'D:\USERFILES\GitHub\moonshot-shim\img-mcp-wrapper.log'

function Write-WrapperLog([string]$msg) {
    $line = "{0} [img-mcp-wrapper] {1}" -f (Get-Date -Format o), $msg
    Write-Host $line
    Add-Content -Path $wrapperLog -Value $line
}

Write-WrapperLog "starting auto-restart loop for: img-mcp-server.mjs"
Write-WrapperLog "wrapper log : $wrapperLog"

$attempt = 0
while ($true) {
    $attempt++
    Write-WrapperLog "attempt #$attempt -> spawning img-mcp-server"
    $startedAt = Get-Date
    try {
        & $node $serverPath
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
