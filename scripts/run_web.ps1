# Run the XP GasTech Flutter app in Chrome against the local backend.
# Usage (from anywhere):  powershell -ExecutionPolicy Bypass -File scripts\run_web.ps1
# Override:               $env:XP_API_BASE_URL='http://192.168.1.10:3000'; .\scripts\run_web.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$api = if ($env:XP_API_BASE_URL) { $env:XP_API_BASE_URL } else { 'http://127.0.0.1:3000' }
$googleClientId = if ($env:GOOGLE_CLIENT_ID) { $env:GOOGLE_CLIENT_ID } else { '264320031504-avqcsa5p6kic2toh3edv9ueje8h5dh10.apps.googleusercontent.com' }

try {
  $h = Invoke-RestMethod "$api/health" -TimeoutSec 3
  Write-Host "Backend OK at $api -> $($h | ConvertTo-Json -Compress)"
} catch {
  Write-Warning "Backend not reachable at $api. Start it: ..\xp-gastech-backend\scripts\start_backend.ps1"
}

flutter run -d chrome --web-port=5050 `
  --dart-define=XP_API_BASE_URL=$api `
  --dart-define=GOOGLE_CLIENT_ID=$googleClientId
