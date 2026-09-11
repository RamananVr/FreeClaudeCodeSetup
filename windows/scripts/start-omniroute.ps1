<#
.SYNOPSIS
  Start the OmniRoute server if it is not already running. Idempotent.

.DESCRIPTION
  Health-checks the OmniRoute server and, only if it is down, starts `omniroute serve`
  minimized. Resolves the `omniroute` launcher from the npm global prefix so it works on
  any machine (no hard-coded paths). Used by the "OmniRoute Server" logon task, but also
  safe to run manually.

.PARAMETER Port
  OmniRoute server port (default: 20128). Must match your setup port.
#>
[CmdletBinding()]
param(
  [int]$Port = 20128
)

$healthUrl = "http://localhost:$Port/api/monitoring/health"

function Test-OmniUp {
  try { (Invoke-WebRequest $healthUrl -TimeoutSec 4 -UseBasicParsing).StatusCode -eq 200 }
  catch { $false }
}

if (Test-OmniUp) { exit 0 }

# Resolve the omniroute launcher from the npm global prefix (portable across machines).
$omni = $null
if (Get-Command npm -ErrorAction SilentlyContinue) {
  $prefix = (npm config get prefix).Trim()
  foreach ($candidate in @("$prefix\omniroute.cmd", "$prefix\omniroute")) {
    if (Test-Path $candidate) { $omni = $candidate; break }
  }
}
if (-not $omni) { $omni = (Get-Command omniroute -ErrorAction SilentlyContinue).Source }
if (-not $omni) { Write-Error "omniroute launcher not found. Run setup-omniroute.ps1 first."; exit 1 }

Start-Process -FilePath $omni -ArgumentList @("serve", "--port", "$Port", "--no-open") -WindowStyle Minimized

$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline -and -not (Test-OmniUp)) { Start-Sleep -Seconds 3 }
if (Test-OmniUp) { exit 0 } else { exit 1 }
