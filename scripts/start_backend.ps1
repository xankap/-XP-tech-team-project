# Convenience wrapper: starts the sibling xp-gastech-backend repo.
$ErrorActionPreference = 'Stop'
$backend = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'xp-gastech-backend'
if (-not (Test-Path (Join-Path $backend 'server.js'))) { Write-Error "Backend not found at $backend"; exit 1 }
& (Join-Path $backend 'scripts\start_backend.ps1')
