[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$StageDir = (Join-Path $env:USERPROFILE "omniroute-stage"),
  [switch]$ListOnly
)
$ErrorActionPreference = "Stop"
function Info($m) { Write-Host "[*] $m" }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

$omni = Get-Command omniroute -ErrorAction SilentlyContinue
if (-not $omni) {
  Warn "omniroute is not on PATH. Run setup-omniroute.ps1 first."
  exit 1
}

try {
  $raw = (& $omni.Source --quiet --output json --base-url "http://localhost:$Port" api models get-api-models 2>$null | Out-String)
  $jsonStart = $raw.IndexOf('{')
  if ($jsonStart -lt 0) { throw "OmniRoute returned no JSON." }
  $response = $raw.Substring($jsonStart) | ConvertFrom-Json
  $catalog = @(
    $response.models |
      Where-Object { $_.available -and $_.provider -match '^(gh|github)$' } |
      ForEach-Object { $_.fullModel -replace '^gh/', 'github/' } |
      Sort-Object -Unique
  )
} catch {
  Warn "Could not query OmniRoute's authenticated model catalog: $($_.Exception.Message)"
  exit 1
}

if ($catalog.Count -eq 0) {
  Warn "No GitHub Copilot models are connected at http://localhost:$Port."
  Warn "Connect GitHub Copilot at http://localhost:$Port/dashboard/oauth then re-run."
  exit 0
}

Info "Discovered $($catalog.Count) Copilot models:"
$catalog | ForEach-Object { Write-Host "    $_" }

if (-not $ListOnly) {
  Info "OmniRoute 3.8.50+ manages model aliases automatically; no database changes are needed."
}
