<#
.SYNOPSIS
  Install OmniRoute on Windows (working around the npm feed break), wire Claude Code
  to route through OmniRoute -> GitHub Copilot, and launch Claude Code with an isolated
  "omniroute" profile using Claude Opus as the main model.

.DESCRIPTION
  Encodes the hard-won learnings from getting `npm install -g omniroute` working on this
  machine:

    * The direct global install fails: a transitive dep pins yuku-ast@0.6.5, which is
      MISSING from the configured npm feed (it only has 0.6.7/0.6.8). Global installs also
      ignore `overrides` in the global-prefix package.json. Fix: install into a staging
      dir with overrides { "yuku-ast": "0.6.7" }, then junction that package into the
      global node_modules and hand-write .cmd/.ps1 bin shims.

    * `omniroute launch` uses spawn("claude") with no shell, which fails on Windows
      (the bin is claude.ps1/claude.cmd). Fix: a `claude-omni` wrapper that sets the same
      env OmniRoute would and invokes the real `claude` binary directly.

  The script is idempotent - safe to re-run.

.PARAMETER Model
  Main model Claude Code should use (default: github/claude-opus-4.8). Background/small
  model is intentionally left to Claude Code's own default.

.PARAMETER StageDir
  Persistent staging directory for the npm install (default: $HOME\omniroute-stage).
  NOTE: keep this stable - the global junction points here.

.PARAMETER Port
  OmniRoute server port (default: 20128).

.PARAMETER NoLaunch
  Set up everything but do not launch the interactive Claude Code session at the end.

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
  [string]$Model = "auto/best-coding",
  [string]$StageDir = (Join-Path $env:USERPROFILE "omniroute-stage"),
  [int]$Port = 20128,
  [string]$X64NodeVersion = "20.18.1",
  [switch]$NoLaunch,
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

$prefix = (npm config get prefix).Trim()
$gRoot  = (npm root -g).Trim()
Info "npm prefix    : $prefix"
Info "npm global lib: $gRoot"
Info "main model    : $Model"
Info "stage dir     : $StageDir"

if ($RefreshFeedAuth) {
  $vsts = Join-Path $prefix "vsts-npm-auth.ps1"
  if (Test-Path $vsts) { Info "Refreshing feed auth via vsts-npm-auth..."; & $vsts | Out-Null; Ok "Feed auth refreshed." }
  else { Warn "vsts-npm-auth.ps1 not found at $vsts - skipping feed refresh." }
}

# --- 1. Staging install with yuku-ast override ------------------------------
Info "Preparing staging install (works around missing yuku-ast@0.6.5 in the feed)..."
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
@'
{
  "name": "omniroute-staging",
  "version": "1.0.0",
  "private": true,
  "dependencies": { "omniroute": "*" },
  "overrides": { "yuku-ast": "0.6.7" }
}
'@ | Set-Content -Path (Join-Path $StageDir "package.json") -Encoding ascii

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

# --- 4. claude-omni launcher (Windows-correct replacement for `omniroute launch`) ---
$profileDir = Join-Path $env:USERPROFILE ".claude\profiles\omniroute"
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

$claudeOmniPs1 = @"
#!/usr/bin/env pwsh
# Launch Claude Code routed through OmniRoute (-> GitHub Copilot). Isolated profile;
# does NOT touch your normal `claude` login/credentials.
`$env:ANTHROPIC_BASE_URL = "http://localhost:$Port"
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
`$env:ANTHROPIC_AUTH_TOKEN = "omniroute-no-auth"
`$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"
`$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "190000"
`$env:CLAUDE_CONFIG_DIR = Join-Path `$env:USERPROFILE ".claude\profiles\omniroute"
# Main model = auto/best-coding (router picks best backend per request); background/small model left to Claude Code's default.
if (-not `$env:ANTHROPIC_MODEL) { `$env:ANTHROPIC_MODEL = "$Model" }
& claude --dangerously-skip-permissions @args
exit `$LASTEXITCODE
"@
Set-Content -Path (Join-Path $prefix "claude-omni.ps1") -Value $claudeOmniPs1 -Encoding utf8

$claudeOmniCmd = @"
@ECHO off
SETLOCAL
SET "ANTHROPIC_BASE_URL=http://localhost:$Port"
SET "ANTHROPIC_API_KEY="
SET "ANTHROPIC_AUTH_TOKEN=omniroute-no-auth"
SET "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1"
SET "CLAUDE_CODE_AUTO_COMPACT_WINDOW=190000"
SET "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude\profiles\omniroute"
IF "%ANTHROPIC_MODEL%"=="" SET "ANTHROPIC_MODEL=$Model"
call claude.cmd --dangerously-skip-permissions %*
"@
Set-Content -Path (Join-Path $prefix "claude-omni.cmd") -Value $claudeOmniCmd -Encoding ascii
Ok "Created claude-omni launcher (profile: $profileDir)"

# --- 5. Start the OmniRoute server (if not already up) ----------------------
$healthUrl = "http://localhost:$Port/api/monitoring/health"
function Test-OmniUp { try { (Invoke-WebRequest $healthUrl -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200 } catch { $false } }

if (Test-OmniUp) {
  Ok "OmniRoute server already running on port $Port"
} else {
  Info "Starting OmniRoute server..."
  Start-Process -FilePath $omni -ArgumentList "serve" -WindowStyle Minimized
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline -and -not (Test-OmniUp)) { Start-Sleep -Seconds 3 }
  if (Test-OmniUp) { Ok "OmniRoute server is up on port $Port" }
  else { Die "OmniRoute server did not become healthy within 90s. Run 'omniroute serve' manually to see errors." }
}

# --- 6. Ensure GitHub Copilot provider is connected -------------------------
$sentinel = @{ "Authorization" = "Bearer omniroute-no-auth"; "x-api-key" = "omniroute-no-auth" }
function Get-CopilotModelCount {
  try {
    $r = Invoke-WebRequest "http://localhost:$Port/v1/models" -Headers $sentinel -TimeoutSec 10 -UseBasicParsing
    (($r.Content | ConvertFrom-Json).data.id | Where-Object { $_ -match '^(gh|github)/' }).Count
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
  else { Warn "Still no Copilot models detected - you can finish connecting later and then run: claude-omni" }
}

# --- 6.5 Seed model aliases (route Claude Code's bare model IDs -> Copilot) ---
# Claude Code (esp. via /model or gateway discovery) can send unprefixed canonical
# ids like "claude-opus-4-8". OmniRoute then sees that id on several providers
# (cc/kie/vp) and fails with "Ambiguous model". These aliases pin those bare ids
# to the GitHub Copilot (github/*) models so routing is unambiguous.
Info "Seeding model aliases (bare Claude ids -> github/* Copilot models)..."
$aliasSeeder = Join-Path $env:TEMP "omniroute-seed-aliases.cjs"
@"
const path = require('path');
const pkg = path.join('$StageDir', 'node_modules', 'omniroute');
let Database;
for (const p of [
  path.join(pkg, 'node_modules', 'better-sqlite3'),
  path.join(pkg, 'node_modules', '@omniroute', 'better-sqlite3'),
  path.join(pkg, 'dist', 'node_modules', 'better-sqlite3'),
]) { try { Database = require(p); break; } catch (_) {} }
if (!Database) { console.error('better-sqlite3 not found; skipping alias seed'); process.exit(0); }
const dbPath = path.join(process.env.USERPROFILE, '.omniroute', 'storage.sqlite');
const db = new Database(dbPath);
const aliases = {
  'claude-opus-4-8': 'github/claude-opus-4.8',
  'claude-opus-4-8-fast': 'github/claude-opus-4.8-fast',
  'claude-haiku-4-5': 'github/claude-haiku-4.5',
  'claude-sonnet-4-5': 'github/claude-sonnet-4.5',
};
const up = db.prepare("INSERT OR REPLACE INTO key_value (namespace, key, value) VALUES ('modelAliases', ?, ?)");
const tx = db.transaction(() => { for (const [k, v] of Object.entries(aliases)) up.run(k, JSON.stringify(v)); });
tx();
db.close();
console.log('OK ' + Object.keys(aliases).length + ' aliases');
"@ | Set-Content -Path $aliasSeeder -Encoding utf8
$seedOut = & $node.NodeExe $aliasSeeder 2>&1
if ($LASTEXITCODE -eq 0) { Ok "Model aliases seeded ($seedOut)" }
else { Warn "Could not seed model aliases: $seedOut" }
Remove-Item $aliasSeeder -ErrorAction SilentlyContinue

# --- 7. Summary + launch ----------------------------------------------------
Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "  OmniRoute       : http://localhost:$Port  (dashboard: http://localhost:$Port/dashboard)"
Write-Host "  Main model      : $Model"
Write-Host "  Launcher        : claude-omni   (isolated profile at $profileDir)"
Write-Host "  Usage           : claude-omni                # opus via OmniRoute -> Copilot"
Write-Host "                    claude-omni -p 'prompt'    # headless"
Write-Host "                    claude-omni --model github/claude-sonnet-5   # per-run override"
Write-Host ""

if ($NoLaunch) {
  Info "-NoLaunch set. Skipping interactive launch. Run 'claude-omni' when ready."
} else {
  Info "Launching Claude Code (omniroute profile)..."
  & (Join-Path $prefix "claude-omni.cmd") @()
}
