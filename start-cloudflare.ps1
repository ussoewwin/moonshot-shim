# start-cloudflare.ps1
# Launch Cloudflare Quick Tunnel to inject-header-proxy (:8788).
# Writes cloudflared-quick.pid; logs to cloudflared-quick.log / .log.err

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$exe = Join-Path $root 'cloudflared.exe'
if (-not (Test-Path $exe)) {
    Write-Host 'ERROR: cloudflared.exe not found in this folder.' -ForegroundColor Red
    Write-Host 'Download: https://github.com/cloudflare/cloudflared/releases (windows-amd64)' -ForegroundColor Yellow
    exit 2
}

$logOut = Join-Path $root 'cloudflared-quick.log'
$logErr = Join-Path $root 'cloudflared-quick.log.err'
$pidFile = Join-Path $root 'cloudflared-quick.pid'

Remove-Item $logOut, $logErr -ErrorAction SilentlyContinue

if (Test-Path $pidFile) {
    $oldId = 0
    [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$oldId)
    if ($oldId -gt 0) {
        Stop-Process -Id $oldId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}

$p = Start-Process -FilePath $exe `
    -ArgumentList @('tunnel', '--no-autoupdate', '--url', 'http://127.0.0.1:8788', '--protocol', 'http2') `
    -WorkingDirectory $root `
    -RedirectStandardOutput $logOut `
    -RedirectStandardError $logErr `
    -WindowStyle Hidden `
    -PassThru

if (-not $p -or -not $p.Id) {
    Write-Host 'ERROR: failed to spawn cloudflared' -ForegroundColor Red
    exit 3
}

$p.Id | Out-File -FilePath $pidFile -Encoding ascii -NoNewline

$url = $null
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $logErr) {
        $raw = Get-Content $logErr -Raw -ErrorAction SilentlyContinue
        if ($raw -match 'https://[a-zA-Z0-9-]+\.trycloudflare\.com') {
            $url = $Matches[0]
            break
        }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
if ($url) {
    Write-Host "Public URL: $url" -ForegroundColor Green
    Write-Host "Cursor -> Override OpenAI Base URL: ${url}/v1" -ForegroundColor Green
}
else {
    Write-Host 'Could not parse trycloudflare URL within 60s.' -ForegroundColor Yellow
    Write-Host "See: $logErr" -ForegroundColor Yellow
}
Write-Host "cloudflared PID $($p.Id)  (stop: stop-cloudflare.cmd)" -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

exit 0
