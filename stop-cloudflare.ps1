# stop-cloudflare.ps1 — stop Quick Tunnel started by start-cloudflare.ps1 (PID file)

$root = $PSScriptRoot
$pidFile = Join-Path $root 'cloudflared-quick.pid'

if (-not (Test-Path $pidFile)) {
    Write-Host 'No cloudflared-quick.pid (Quick Tunnel not started from this repo, or already stopped).'
    exit 0
}

$idTxt = (Get-Content $pidFile -Raw).Trim()
$procId = 0
if (-not [int]::TryParse($idTxt, [ref]$procId)) {
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

try {
    Stop-Process -Id $procId -Force -ErrorAction Stop
    Write-Host "Stopped cloudflared (PID $procId)"
}
catch {
    Write-Host "Process $procId not running (already exited)."
}

Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
exit 0
