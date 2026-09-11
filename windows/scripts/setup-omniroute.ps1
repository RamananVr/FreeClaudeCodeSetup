<#
.SYNOPSIS
  Install OmniRoute on Windows (working around the npm feed break), and route the default
  `claude` command through OmniRoute -> GitHub Copilot by writing routing config into
  Claude Code's settings.json.

.DESCRIPTION
  Encodes the hard-won learnings from getting `npm install -g omniroute` working on this
  machine:

    * The direct global install fails: a transitive dep pins yuku-ast@0.6.5, which is
      MISSING from the configured npm feed (it only has 0.6.7/0.6.8). Global installs also
      ignore `overrides` in the global-prefix package.json. Fix: install into a staging
      dir with overrides { "yuku-ast": "0.6.7" }, then junction that package into the
      global node_modules and hand-write .cmd/.ps1 bin shims.

    * Routing lives in Claude Code's supported settings.json `env` block (no wrapper),
      so plain `claude` routes through OmniRoute -> Copilot. Because this changes the
      user's default `claude`, setup shows a disclaimer, backs up the prior settings.json,
      and (interactively) pauses before writing.

  The script is idempotent - safe to re-run.

.PARAMETER Model
  Main model Claude Code should use (default: github/claude-opus-4.8). Pinned as the
  default; switch to any other connected provider in-session via /model.

.PARAMETER StageDir
  Persistent staging directory for the npm install (default: $HOME\omniroute-stage).
  NOTE: keep this stable - the global junction points here.

.PARAMETER Port
  OmniRoute server port (default: 20128).

.PARAMETER OmniRouteVersion
  OmniRoute package version to install (default: 3.8.50).

.PARAMETER NoLaunch
  Set up everything but do not launch the interactive Claude Code session at the end.

.PARAMETER AcceptRoutingChange
  Skip the interactive confirmation pause before writing routing config into settings.json.

.PARAMETER RefreshFeedAuth
  Run vsts-npm-auth to refresh the Azure Artifacts feed token before installing
  (use if npm install fails with TLS/401 auth errors).

.EXAMPLE
  pwsh -File .\setup-omniroute.ps1

.EXAMPLE
  pwsh -File .\setup-omniroute.ps1 -Model github/claude-sonnet-5 -NoLaunch
#>
[CmdletBinding()]
param(
  [string]$Model = "github/claude-opus-4.8",
  [string]$StageDir = (Join-Path $env:USERPROFILE "omniroute-stage"),
  [int]$Port = 20128,
  [string]$OmniRouteVersion = "3.8.50",
  [string]$X64NodeVersion = "22.22.2",
  [switch]$NoLaunch,
  [switch]$AcceptRoutingChange,
  [switch]$RefreshFeedAuth
)

$ErrorActionPreference = "Stop"
function Info($m) { Write-Host "  [*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [x] $m" -ForegroundColor Red; exit 1 }

Write-Host "`n=== OmniRoute + Claude Code setup ===`n" -ForegroundColor White

# --- 0. Prerequisites -------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Die "Node.js not found on PATH." }
if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { Die "npm not found on PATH." }

$nodeArch = node -p "process.arch"

# On ARM64, OmniRoute's native deps ship no arm64 binary. Provision a portable x64 Node
# and run everything Node-related under it. On x64 this is a no-op ($node.NodeExe = "node").
$ensureX64 = Join-Path $PSScriptRoot "ensure-x64-node.ps1"
$node = & $ensureX64 -X64NodeVersion $X64NodeVersion
if ($node.Dir) {
  # Process-local only: put x64 Node first on PATH for this script's npm/node calls.
  $env:Path = "$($node.Dir);$env:Path"
  Ok "Using provisioned x64 Node: $($node.NodeExe)"
}

$nodeVersion = & $node.NodeExe -p "process.versions.node"
$nodeMajor, $nodeMinor, $nodePatch = $nodeVersion.Split('.')[0..2] | ForEach-Object { [int]$_ }
$nodeSupported = (
  ($nodeMajor -eq 22 -and ($nodeMinor -gt 22 -or ($nodeMinor -eq 22 -and $nodePatch -ge 2))) -or
  ($nodeMajor -ge 24 -and $nodeMajor -lt 27)
)
if (-not $nodeSupported) {
  Die "OmniRoute $OmniRouteVersion requires Node >=22.22.2 <23 or >=24 <27; found v$nodeVersion."
}

$prefix = (npm config get prefix).Trim()
$gRoot  = (npm root -g).Trim()
Info "npm prefix    : $prefix"
Info "npm global lib: $gRoot"
Info "omniroute     : $OmniRouteVersion"
Info "main model    : $Model"
Info "stage dir     : $StageDir"

$previousVersion = $null
$existingOmni = Get-Command omniroute -ErrorAction SilentlyContinue
if ($existingOmni) {
  try { $previousVersion = (& $existingOmni.Source --version 2>$null | Select-Object -Last 1).Trim() } catch { }
}

$healthUrl = "http://localhost:$Port/api/monitoring/health"
function Test-OmniUp { try { (Invoke-WebRequest $healthUrl -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200 } catch { $false } }

# Windows keeps loaded native modules locked, so stop an older server before npm
# replaces its staged package. A same-version idempotent run leaves it running.
if ((Test-OmniUp) -and $previousVersion -and $previousVersion -ne $OmniRouteVersion) {
  Info "Stopping OmniRoute before upgrade ($previousVersion -> $OmniRouteVersion)..."
  & $existingOmni.Source stop | Out-Null
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline -and (Test-OmniUp)) { Start-Sleep -Seconds 1 }
  if (Test-OmniUp) { Die "OmniRoute did not stop before upgrading. Run 'omniroute stop', then re-run setup." }
}

if ($RefreshFeedAuth) {
  $vsts = Join-Path $prefix "vsts-npm-auth.ps1"
  if (Test-Path $vsts) { Info "Refreshing feed auth via vsts-npm-auth..."; & $vsts | Out-Null; Ok "Feed auth refreshed." }
  else { Warn "vsts-npm-auth.ps1 not found at $vsts - skipping feed refresh." }
}

# --- 1. Staging install with yuku-ast override ------------------------------
Info "Preparing staging install (works around missing yuku-ast@0.6.5 in the feed)..."
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
@"
{
  "name": "omniroute-staging",
  "version": "1.0.0",
  "private": true,
  "dependencies": { "omniroute": "$OmniRouteVersion" },
  "overrides": { "yuku-ast": "0.6.7" }
}
"@ | Set-Content -Path (Join-Path $StageDir "package.json") -Encoding ascii

Push-Location $StageDir
try {
  Info "Running npm install (this can take several minutes)..."
  npm install --no-fund --no-audit
  if ($LASTEXITCODE -ne 0) { Die "npm install failed in staging dir. If this is a TLS/401 feed error, re-run with -RefreshFeedAuth." }
} finally { Pop-Location }

$stagedPkg = Join-Path $StageDir "node_modules\omniroute"
if (-not (Test-Path (Join-Path $stagedPkg "bin\omniroute.mjs"))) { Die "omniroute package not found after install at $stagedPkg" }
$ver = (Get-Content (Join-Path $stagedPkg "package.json") -Raw | ConvertFrom-Json).version
Ok "Staged omniroute@$ver"

# --- 2. Junction into global node_modules -----------------------------------
$target = Join-Path $gRoot "omniroute"
if (Test-Path $target) { cmd /c rmdir "$target" 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path $gRoot | Out-Null
cmd /c mklink /J "$target" "$stagedPkg" | Out-Null
if (-not (Test-Path (Join-Path $target "bin\omniroute.mjs"))) { Die "Failed to junction omniroute into $target" }
Ok "Junctioned omniroute -> global node_modules"

# --- 3. Bin shims for omniroute CLIs ----------------------------------------
# On x64, invoke bare `node` (unchanged). On arm64, bake the absolute x64 node.exe path
# so the shims never depend on which Node is first on PATH at runtime.
$nodeInvoke = if ($node.Dir) { '"' + $node.NodeExe + '"' } else { 'node' }
function New-BinShim([string]$name, [string]$relMjs) {
  $cmd = @"
@ECHO off
SETLOCAL
SET "dp0=%~dp0"
$nodeInvoke "%dp0%node_modules\omniroute\$relMjs" %*
"@
  Set-Content -Path (Join-Path $prefix "$name.cmd") -Value $cmd -Encoding ascii

  $ps1 = @"
#!/usr/bin/env pwsh
`$dir = Split-Path -Parent `$MyInvocation.MyCommand.Definition
$nodeInvoke "`$dir/node_modules/omniroute/$relMjs" `$args
exit `$LASTEXITCODE
"@
  Set-Content -Path (Join-Path $prefix "$name.ps1") -Value $ps1 -Encoding utf8
}
New-BinShim "omniroute" "bin/omniroute.mjs"
New-BinShim "omniroute-reset-password" "bin/reset-password.mjs"
Ok "Created omniroute / omniroute-reset-password shims"

# Make omniroute callable within this script run.
if (($env:Path -split ';') -notcontains $prefix) { $env:Path = "$prefix;$env:Path" }
$omni = Join-Path $prefix "omniroute.cmd"

# OmniRoute keeps native modules in a per-user runtime directory. Ensure the
# version-specific better-sqlite3 binary exists before starting the server.
Info "Checking OmniRoute native runtime..."
& $omni runtime repair
if ($LASTEXITCODE -ne 0) { Die "OmniRoute native runtime repair failed." }

# --- 4. (removed) The former claude-omni wrapper is gone: routing now lives in
#        Claude Code's settings.json env block (see section 6.6), so plain `claude`
#        routes through OmniRoute -> Copilot. No separate launcher/profile.

# --- 5. Start the OmniRoute server (if not already up) ----------------------
if (Test-OmniUp) {
  Ok "OmniRoute server already running on port $Port"
} else {
  Info "Starting OmniRoute server..."
  Start-Process -FilePath $omni -ArgumentList @("serve", "--port", "$Port", "--no-open") -WindowStyle Minimized
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline -and -not (Test-OmniUp)) { Start-Sleep -Seconds 3 }
  if (Test-OmniUp) { Ok "OmniRoute server is up on port $Port" }
  else { Die "OmniRoute server did not become healthy within 180s. Run 'omniroute serve' manually to see errors." }
}

# --- 6. Ensure GitHub Copilot provider is connected -------------------------
$sentinel = @{ "Authorization" = "Bearer omniroute-no-auth"; "x-api-key" = "omniroute-no-auth" }
function Get-CopilotModelCount {
  try {
    $raw = (& $omni --quiet --output json --base-url "http://localhost:$Port" api models get-api-models 2>$null | Out-String)
    $jsonStart = $raw.IndexOf('{')
    if ($jsonStart -lt 0) { return 0 }
    $models = ($raw.Substring($jsonStart) | ConvertFrom-Json).models
    @($models | Where-Object { $_.available -and $_.provider -match '^(gh|github)$' }).Count
  } catch { 0 }
}
$ghCount = Get-CopilotModelCount
if ($ghCount -gt 0) {
  Ok "GitHub Copilot connected ($ghCount Copilot models available)"
} else {
  Warn "GitHub Copilot is not connected yet - opening the OmniRoute dashboard so you can connect it."
  Warn "In the dashboard: Providers/OAuth -> GitHub Copilot -> Connect -> authorize the device code."
  Start-Process "http://localhost:$Port/dashboard/oauth"
  Read-Host "Press ENTER once GitHub Copilot shows as connected in the dashboard"
  $ghCount = Get-CopilotModelCount
  if ($ghCount -gt 0) { Ok "GitHub Copilot connected ($ghCount models)" }
  else { Warn "Still no Copilot models detected - you can finish connecting later and then run: claude" }
}

# --- 6.5 Show the model catalog ---------------------------------------------
# OmniRoute 3.8.50+ manages aliases internally. Keep the helper as a read-only,
# authenticated catalog view for setup output and the bundled list-models skill.
Info "Reading the discovered Copilot catalog..."
$refresh = Join-Path $PSScriptRoot "refresh-models.ps1"
& $refresh -Port $Port -StageDir $StageDir

# --- 6.6 Route the DEFAULT `claude` through OmniRoute -----------------------
# This changes the user's default `claude` command, so show a disclaimer and (when
# interactive) pause for confirmation before writing settings.json.
Write-Host ""
Warn "This configures your DEFAULT ``claude`` to route through OmniRoute -> GitHub Copilot."
Warn "After setup, running ``claude`` uses Copilot, not direct Anthropic access."
Warn "Your previous settings.json is backed up to settings.json.bak (revert anytime)."

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if (-not $AcceptRoutingChange -and -not $NoLaunch -and $interactive) {
  Read-Host "Press ENTER to continue, or Ctrl+C to cancel"
}

$configureRouting = Join-Path $PSScriptRoot "configure-claude-routing.ps1"
& $configureRouting -Port $Port -Model $Model
Ok "Default ``claude`` now routes through OmniRoute (model: $Model)"

# --- 7. Summary + launch ----------------------------------------------------
Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "  OmniRoute       : http://localhost:$Port  (dashboard: http://localhost:$Port/dashboard)"
Write-Host "  Main model      : $Model  (change in-session via /model)"
Write-Host "  Command         : claude   (routes through OmniRoute -> Copilot)"
Write-Host "  Usage           : claude                # opus via OmniRoute -> Copilot"
Write-Host "                    claude -p 'prompt'    # headless"
Write-Host "                    /model in-session     # switch to any connected provider"
Write-Host ""

if ($NoLaunch) {
  Info "-NoLaunch set. Skipping interactive launch. Run 'claude' when ready."
} else {
  Info "Launching Claude Code (routed through OmniRoute)..."
  & claude
}
