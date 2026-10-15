# Start xp-gastech-backend (API on http://127.0.0.1:3000 by default).
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\start_backend.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Test-Path '.env')) { Write-Error '.env missing - copy .env.example to .env and fill it in.'; exit 1 }
if (-not (Test-Path 'node_modules')) { npm install }

$port = 3000
$portLine = Select-String -Path '.env' -Pattern '^PORT=(\d+)' | Select-Object -First 1
if ($portLine) { $port = [int]$portLine.Matches[0].Groups[1].Value }

try {
  $h = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 3
  Write-Host "Backend already running on :$port -> $($h | ConvertTo-Json -Compress)"
  exit 0
} catch { }

$env:RUN_SERVER = '1'
node server.js
