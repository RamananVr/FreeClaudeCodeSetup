<#
.SYNOPSIS
  Route the default `claude` command through OmniRoute -> GitHub Copilot by merging a
  routing `env` block into Claude Code's settings.json.

.DESCRIPTION
  Merges (never overwrites) the OmniRoute routing keys into settings.json:
    * ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL,
      CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY
  Existing unrelated settings are preserved. ANTHROPIC_API_KEY is removed from the env
  block (it would override the routed token). On the first write the prior file is backed
  up to settings.json.bak (only if no .bak exists yet). Idempotent.

.PARAMETER Port
  OmniRoute server port (default: 20128). Used to build ANTHROPIC_BASE_URL.

.PARAMETER Model
  Model pinned as ANTHROPIC_MODEL (default: github/claude-opus-4.8).

.PARAMETER SettingsPath
  Override the target settings.json path (mainly for tests). Defaults to
  $CLAUDE_CONFIG_DIR\settings.json if set, else $HOME\.claude\settings.json.

.PARAMETER ApiKey
  OmniRoute API key for secured instances. Defaults to OMNIROUTE_API_KEY; when
  omitted, uses the sentinel accepted by an unauthenticated local instance.

.EXAMPLE
  pwsh -File .\configure-claude-routing.ps1

.EXAMPLE
  pwsh -File .\configure-claude-routing.ps1 -Port 20200 -Model github/claude-sonnet-5
#>
[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$Model = "github/claude-opus-4.8",
  [string]$SettingsPath,
  [string]$ApiKey = $env:OMNIROUTE_API_KEY
)

$ErrorActionPreference = "Stop"

# --- Resolve target settings.json -------------------------------------------
if (-not $SettingsPath) {
  if ($env:CLAUDE_CONFIG_DIR) {
    $SettingsPath = Join-Path $env:CLAUDE_CONFIG_DIR "settings.json"
  } else {
    $SettingsPath = Join-Path $HOME ".claude\settings.json"
  }
}

$parent = Split-Path -Parent $SettingsPath
if ($parent -and -not (Test-Path $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

# --- Load existing settings (fail loudly on malformed JSON) -----------------
$settings = $null
if (Test-Path $SettingsPath) {
  $raw = Get-Content -Raw -Path $SettingsPath
  if ($raw -and $raw.Trim()) {
    try {
      $settings = $raw | ConvertFrom-Json
    } catch {
      throw "settings.json at '$SettingsPath' is not valid JSON; refusing to overwrite. Fix or remove it, then re-run. ($($_.Exception.Message))"
    }
  }

  # Back up once, before the first modification.
  $bak = "$SettingsPath.bak"
  if (-not (Test-Path $bak)) {
    Copy-Item -Path $SettingsPath -Destination $bak
  }
}

if ($null -eq $settings) { $settings = [pscustomobject]@{} }

# --- Merge the routing env block --------------------------------------------
$routing = [ordered]@{
  ANTHROPIC_BASE_URL                        = "http://localhost:$Port"
  ANTHROPIC_AUTH_TOKEN                      = $(if ($ApiKey) { $ApiKey } else { "omniroute-no-auth" })
  ANTHROPIC_MODEL                           = $Model
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"
}

# Normalize existing env (may be absent or a PSCustomObject) into an ordered hashtable,
# preserving unrelated keys.
$env = [ordered]@{}
$existingEnv = $settings.PSObject.Properties['env']
if ($existingEnv -and $existingEnv.Value) {
  foreach ($p in $existingEnv.Value.PSObject.Properties) {
    $env[$p.Name] = $p.Value
  }
}

# Drop ANTHROPIC_API_KEY (would override the routed token).
if ($env.Contains('ANTHROPIC_API_KEY')) { $env.Remove('ANTHROPIC_API_KEY') }

# Apply routing keys.
foreach ($k in $routing.Keys) { $env[$k] = $routing[$k] }

# Write env back onto settings.
if ($settings.PSObject.Properties['env']) {
  $settings.env = [pscustomobject]$env
} else {
  $settings | Add-Member -MemberType NoteProperty -Name env -Value ([pscustomobject]$env)
}

# --- Persist ----------------------------------------------------------------
$json = $settings | ConvertTo-Json -Depth 20
Set-Content -Path $SettingsPath -Value $json -Encoding utf8

Write-Host "  [+] Routing configured in $SettingsPath (model: $Model, port: $Port)" -ForegroundColor Green
