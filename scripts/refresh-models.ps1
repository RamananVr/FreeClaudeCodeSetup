[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$StageDir = (Join-Path $env:USERPROFILE "omniroute-stage")
)
$ErrorActionPreference = "Stop"
function Info($m){ Write-Host "[*] $m" }
function Ok($m){ Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

$sentinel = @{ "Authorization" = "Bearer omniroute-no-auth"; "x-api-key" = "omniroute-no-auth" }
function Get-CopilotModelIds {
  try {
    $r = Invoke-WebRequest "http://localhost:$Port/v1/models" -Headers $sentinel -TimeoutSec 10 -UseBasicParsing
    ($r.Content | ConvertFrom-Json).data.id | Where-Object { $_ -match '^(gh|github)/' }
  } catch { @() }
}
$ids = @(Get-CopilotModelIds)
if ($ids.Count -eq 0) {
  Warn "No github/* Copilot models found at http://localhost:$Port/v1/models."
  Warn "Connect GitHub Copilot at http://localhost:$Port/dashboard/oauth then re-run."
  exit 0
}
Info "Discovered $($ids.Count) Copilot models:"
$ids | ForEach-Object { Write-Host "    $_" }
