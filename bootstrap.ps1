<#
.SYNOPSIS
  One-command bootstrap: install OmniRoute + create the claude-omni launcher, then
  register the logon autostart task.

.DESCRIPTION
  Runs scripts\setup-omniroute.ps1 followed by scripts\install-autostart.ps1 so a fresh
  machine goes from nothing to a working `claude-omni` in a single command. Both child
  scripts are resolved relative to this file, so it works from wherever the repo is cloned.

.PARAMETER Model
  Main model Claude Code should use (default: auto/best-coding).

.PARAMETER Port
  OmniRoute server port, applied to both setup and autostart (default: 20128).

.PARAMETER NoAutostart
  Run setup only; skip registering the logon task.

.PARAMETER NoLaunch
  Do not open an interactive Claude Code session after setup.

.PARAMETER RefreshFeedAuth
  Refresh the Azure Artifacts feed token before installing (fixes TLS/401 errors).

.EXAMPLE
  pwsh -File .\bootstrap.ps1

.EXAMPLE
  pwsh -File .\bootstrap.ps1 -Model github/claude-opus-4.8 -NoLaunch
#>
[CmdletBinding()]
param(
  [string]$Model = "auto/best-coding",
  [int]$Port = 20128,
  [switch]$NoAutostart,
  [switch]$NoLaunch,
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
$setupArgs = @{ Model = $Model; Port = $Port }
if ($NoLaunch)        { $setupArgs.NoLaunch = $true }
if ($RefreshFeedAuth) { $setupArgs.RefreshFeedAuth = $true }
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
Write-Host "  Launch: claude-omni"

# Re-open the interactive session we deferred above.
if ($deferLaunch) {
  Write-Host "`nLaunching Claude Code (omniroute profile)..." -ForegroundColor Cyan
  & claude-omni
}
