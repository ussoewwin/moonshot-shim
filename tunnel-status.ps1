# tunnel-status.ps1 — ports, healthz, Tailscale funnel, Cloudflare PID file

$root = $PSScriptRoot
Write-Host '=== moonshot-shim / tunnel status ===' -ForegroundColor Cyan
Write-Host "Repo: $root"
Write-Host ''

foreach ($port in @(8787, 8788)) {
    $c = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) {
        $owningPid = $c[0].OwningProcess
        Write-Host "Port $port LISTEN  pid=$owningPid" -ForegroundColor Green
    }
    else {
        Write-Host "Port $port not listening" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '--- local healthz ---' -ForegroundColor Cyan
try {
    $h = Invoke-RestMethod 'http://127.0.0.1:8787/healthz' -TimeoutSec 2
    Write-Host "8787: $($h | ConvertTo-Json -Compress)"
}
catch { Write-Host '8787: FAIL' -ForegroundColor Red }

try {
    $h2 = Invoke-RestMethod 'http://127.0.0.1:8788/healthz' -TimeoutSec 2
    Write-Host "8788: $($h2 | ConvertTo-Json -Compress)"
}
catch { Write-Host '8788: FAIL' -ForegroundColor Red }

$ts = 'C:\Program Files\Tailscale\tailscale.exe'
Write-Host ''
Write-Host '--- Tailscale funnel ---' -ForegroundColor Cyan
if (Test-Path $ts) {
    & $ts funnel status 2>&1
}
else {
    Write-Host 'tailscale.exe not found at default path.'
}

$pidFile = Join-Path $root 'cloudflared-quick.pid'
Write-Host ''
Write-Host '--- Cloudflare Quick Tunnel (this repo) ---' -ForegroundColor Cyan
if (Test-Path $pidFile) {
    $id = 0
    [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$id)
    $p = if ($id -gt 0) { Get-Process -Id $id -ErrorAction SilentlyContinue } else { $null }
    if ($p) {
        Write-Host "cloudflared PID $id RUNNING" -ForegroundColor Green
    }
    else {
        Write-Host "cloudflared-quick.pid references $id but process not running (stale)." -ForegroundColor Yellow
    }
}
else {
    Write-Host 'No cloudflared-quick.pid (not using Quick Tunnel from start-cloudflare.cmd).'
}

Write-Host ''
Write-Host '--- Cursor Override URL hints ---' -ForegroundColor Cyan
Write-Host 'Tailscale (when funnel active): https://ussoewwin.tail7d4c3e.ts.net/v1'
Write-Host 'Cloudflare: run start-cloudflare.cmd and paste printed URL + /v1'
