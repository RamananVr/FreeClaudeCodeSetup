[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$StageDir = (Join-Path $env:USERPROFILE "omniroute-stage"),
  [switch]$ListOnly
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
# Unique catalog in the github/ form (the gh/ and github/ prefixes are duplicates).
$catalog = $ids |
  ForEach-Object { if ($_ -match '^gh/') { $_ -replace '^gh/', 'github/' } else { $_ } } |
  Select-Object -Unique |
  Sort-Object
Info "Discovered $($catalog.Count) Copilot models:"
$catalog | ForEach-Object { Write-Host "    $_" }
if ($ListOnly) { exit 0 }

function Get-AliasKeys([string]$id) {
  $base = $id -replace '^(gh|github)/', ''
  $keys = New-Object System.Collections.Generic.HashSet[string]
  [void]$keys.Add($base)
  [void]$keys.Add(($base -replace '(\d)\.(\d)', '$1-$2'))
  [void]$keys.Add(($base -replace '(\d)-(\d)', '$1.$2'))
  $keys
}
$models = $ids |
  Where-Object { $_ -notmatch 'text-embedding' } |
  ForEach-Object { if ($_ -match '^gh/') { $_ -replace '^gh/', 'github/' } else { $_ } } |
  Select-Object -Unique
$aliases = @{}
foreach ($full in $models) {
  foreach ($k in (Get-AliasKeys $full)) { $aliases[$k] = $full }
}
$aliases['claude-haiku-4-5-20251001'] = 'github/claude-haiku-4.5'

$aliasJson = ($aliases | ConvertTo-Json -Compress)
Info "Prepared $($aliases.Count) candidate alias keys for $($models.Count) models..."

# Pass the alias map via a temp file (not a native-exe arg): embedded JSON quotes
# get mangled when passed as an argument under Windows PowerShell 5.1.
$aliasFile = Join-Path $env:TEMP "omniroute-aliases.json"
Set-Content -Path $aliasFile -Value $aliasJson -Encoding utf8

$seeder = Join-Path $env:TEMP "omniroute-seed-aliases.cjs"
@"
const path = require('path');
const fs = require('fs');
const stage = '$($StageDir -replace '\\','\\\\')';
let Database;
for (const p of [
  path.join(stage, 'node_modules', 'better-sqlite3'),
  path.join(stage, 'node_modules', 'omniroute', 'node_modules', 'better-sqlite3'),
  path.join(stage, 'node_modules', 'omniroute', 'dist', 'node_modules', 'better-sqlite3'),
]) { try { Database = require(p); break; } catch (_) {} }
if (!Database) { console.error('better-sqlite3 not found; skipping alias seed'); process.exit(2); }
const dbPath = path.join(process.env.USERPROFILE, '.omniroute', 'storage.sqlite');
const db = new Database(dbPath);
const aliases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const existing = new Map(
  db.prepare("SELECT key,value FROM key_value WHERE namespace='modelAliases'")
    .all().map(r => [r.key, JSON.parse(r.value)])
);
const up = db.prepare("INSERT OR REPLACE INTO key_value (namespace, key, value) VALUES ('modelAliases', ?, ?)");
let wrote = 0, skipped = 0;
const tx = db.transaction(() => {
  for (const [k, v] of Object.entries(aliases)) {
    const cur = existing.get(k);
    if (cur !== undefined && !/^(gh|github)\//.test(cur)) { skipped++; continue; }
    up.run(k, JSON.stringify(v)); wrote++;
  }
});
tx();
db.close();
console.log('OK wrote=' + wrote + ' skipped=' + skipped);
"@ | Set-Content -Path $seeder -Encoding utf8

$x64 = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".omniroute\node-x64") -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
$candidates = @("node")
if ($x64) { $candidates += $x64 }
$out = $null; $seeded = $false
foreach ($n in $candidates) {
  try { $out = & $n $seeder $aliasFile 2>&1 } catch { $out = $_.Exception.Message; continue }
  if ($LASTEXITCODE -eq 0) { $seeded = $true; break }
  Info "Seed under '$n' failed (exit $LASTEXITCODE); trying next node..."
}
if ($seeded) { Ok "Model aliases seeded ($out)" }
else { Warn "Could not seed model aliases: $out" }
Remove-Item $seeder, $aliasFile -ErrorAction SilentlyContinue
