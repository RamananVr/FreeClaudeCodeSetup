<#
.SYNOPSIS
  One-command bootstrap: install OmniRoute and route the default `claude` through it,
  then register the logon autostart task.

.DESCRIPTION
  Runs scripts\setup-omniroute.ps1 followed by scripts\install-autostart.ps1 so a fresh
  machine goes from nothing to a working `claude` (routed through OmniRoute -> Copilot) in
  a single command. Both child scripts are resolved relative to this file, so it works from
  wherever the repo is cloned.

.PARAMETER Model
  Main model Claude Code should use (default: github/claude-opus-4.8).

.PARAMETER Port
  OmniRoute server port, applied to both setup and autostart (default: 20128).

.PARAMETER OmniRouteVersion
  OmniRoute package version to install (default: 3.8.50).

.PARAMETER X64NodeVersion
  On ARM64 hosts, the pinned x64 Node version auto-provisioned for OmniRoute
  (default: 22.22.2). Ignored on x64 hosts.

.PARAMETER NoAutostart
  Run setup only; skip registering the logon task.

.PARAMETER NoLaunch
  Do not open an interactive Claude Code session after setup.

.PARAMETER AcceptRoutingChange
  Skip the interactive confirmation pause before routing the default `claude`.

.PARAMETER RefreshFeedAuth
  Refresh the Azure Artifacts feed token before installing (fixes TLS/401 errors).

.EXAMPLE
  pwsh -File .\bootstrap.ps1

.EXAMPLE
  pwsh -File .\bootstrap.ps1 -Model github/claude-opus-4.8 -NoLaunch
#>
[CmdletBinding()]
param(
  [string]$Model = "github/claude-opus-4.8",
  [int]$Port = 20128,
  [string]$OmniRouteVersion = "3.8.50",
  [string]$X64NodeVersion = "22.22.2",
  [switch]$NoAutostart,
  [switch]$NoLaunch,
  [switch]$AcceptRoutingChange,
  [switch]$RefreshFeedAuth
)

$ErrorActionPreference = "Stop"

$scripts   = Join-Path $PSScriptRoot "scripts"
$setup     = Join-Path $scripts "setup-omniroute.ps1"
$autostart = Join-Path $scripts "install-autostart.ps1"
foreach ($s in @($setup, $autostart)) {
  if (-not (Test-Path $s)) { throw "Required script not found: $s" }
}

Write-Host "`n=== OmniRoute bootstrap ===`n" -ForegroundColor White

# --- 1. Setup ---------------------------------------------------------------
$setupArgs = @{
  Model = $Model
  Port = $Port
  OmniRouteVersion = $OmniRouteVersion
  X64NodeVersion = $X64NodeVersion
}
if ($NoLaunch)            { $setupArgs.NoLaunch = $true }
if ($AcceptRoutingChange) { $setupArgs.AcceptRoutingChange = $true }
if ($RefreshFeedAuth)     { $setupArgs.RefreshFeedAuth = $true }
# Always suppress the interactive launch until autostart is registered; re-launch after.
$deferLaunch = -not $NoLaunch -and -not $NoAutostart
if ($deferLaunch) { $setupArgs.NoLaunch = $true }

Write-Host "[1/2] Running setup-omniroute.ps1..." -ForegroundColor Cyan
& $setup @setupArgs
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "setup-omniroute.ps1 failed (exit $LASTEXITCODE)." }

# --- 2. Autostart -----------------------------------------------------------
if ($NoAutostart) {
  Write-Host "[2/2] -NoAutostart set; skipping logon task registration." -ForegroundColor Yellow
} else {
  Write-Host "[2/2] Registering logon autostart task..." -ForegroundColor Cyan
  & $autostart -Port $Port
}

Write-Host "`n=== Bootstrap complete ===" -ForegroundColor Green
Write-Host "  Launch: claude"

# Re-open the interactive session we deferred above.
if ($deferLaunch) {
  Write-Host "`nLaunching Claude Code (routed through OmniRoute)..." -ForegroundColor Cyan
  & claude
}
