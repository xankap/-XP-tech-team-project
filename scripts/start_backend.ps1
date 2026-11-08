# Starts the XP GasTech backend: prefers the monorepo copy, falls back to a sibling checkout.
$ErrorActionPreference = 'Stop'
$mono = Join-Path $PSScriptRoot '..\xp-gastech-backend'
$sibling = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'xp-gastech-backend'
$backend = if (Test-Path (Join-Path $mono 'server.js')) { $mono } else { $sibling }
if (-not (Test-Path (Join-Path $backend 'server.js'))) { Write-Error "Backend not found at $mono or $sibling"; exit 1 }
& (Join-Path $backend 'scripts\start_backend.ps1')
