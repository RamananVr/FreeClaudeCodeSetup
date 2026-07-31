# Dynamic Copilot Model Discovery + Seeding Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `development/reference/executing-plans-guide.md` to implement this plan task-by-task.

**Goal:** Replace the hardcoded Copilot alias table with dynamic `/v1/models` discovery, shared between `setup-omniroute.ps1` and a new standalone `scripts/refresh-models.ps1`, so the `/model` picker shows and switches to the full Copilot catalog.

**Architecture:** A reusable PowerShell script queries OmniRoute's `/v1/models`, filters to `github/*` ids, and seeds bare-id aliases (prefix-stripped + dotted/hyphen variants) into the `modelAliases` namespace of `~/.omniroute/storage.sqlite` via a generated CJS seeder run under the arch-correct Node. Setup delegates to this script instead of its inline block.

**Tech Stack:** PowerShell 7, Node.js (CJS), better-sqlite3 (OmniRoute native dep), OmniRoute `/v1/models` REST endpoint.

---

## Task 0: Empirical verification (informs Task 2)

**Files:** none (findings recorded in the design doc).

**Step 1: Capture the live catalog**

Run: `Invoke-WebRequest "http://localhost:20128/v1/models" -Headers @{Authorization="Bearer omniroute-no-auth"; "x-api-key"="omniroute-no-auth"} -UseBasicParsing | % Content | ConvertFrom-Json | % data | % id | ? { $_ -match '^(gh|github)/' }`
Expected: a list of `github/*` ids. Record their exact formatting (dotted vs hyphen).

**Step 2: Snapshot current aliases**

Inspect `~/.omniroute/storage.sqlite` `key_value` where `namespace='modelAliases'` (via a throwaway `node -e` using OmniRoute's better-sqlite3). Record which keys exist before any change.

**Step 3: Check the picker**

Launch `claude`, run `/model`. Record: (a) do non-seeded Copilot models appear in the list? (b) does selecting a non-seeded one succeed or throw "Ambiguous model"? (c) is the dated-id form (e.g. `claude-haiku-4-5-20251001`) still emitted?

**Step 4: Record findings**

Append a "Verification findings" section to `docs/plans/2026-07-31-dynamic-copilot-models-design.md`: whether listing needs seeding or only switching does, and whether the dated-id override map is required.

**Step 5: Commit**

```bash
git add docs/plans/2026-07-31-dynamic-copilot-models-design.md
git commit -m "Record verification findings for dynamic model seeding"
```

---

## Task 1: Create refresh-models.ps1 skeleton (discovery only)

**Files:**
- Create: `scripts/refresh-models.ps1`

**Step 1: Write the script — params + discovery + guard**

```powershell
[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$StageDir
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
```

**Step 2: Run it standalone to verify discovery**

Run: `pwsh -File .\scripts\refresh-models.ps1`
Expected: prints the discovered `github/*` ids (matching Task 0 Step 1), exits 0.

**Step 3: Commit**

```bash
git add scripts/refresh-models.ps1
git commit -m "Add refresh-models.ps1 discovery skeleton"
```

---

## Task 2: Add alias-key generation + seeding to refresh-models.ps1

**Files:**
- Modify: `scripts/refresh-models.ps1`

**Step 1: Append the seeder generation + execution**

Build an alias map in PowerShell (so key-generation logic is testable/visible), then hand it to a generated CJS seeder as JSON. Key generation per `github/<base>`: prefix-stripped, dotted→hyphen, hyphen→dotted (version segment). Fold in the dated-id override map here ONLY if Task 0 findings require it.

```powershell
function Get-AliasKeys([string]$id) {
  $base = $id -replace '^(gh|github)/', ''      # e.g. claude-opus-4.8
  $keys = New-Object System.Collections.Generic.HashSet[string]
  [void]$keys.Add($base)
  [void]$keys.Add(($base -replace '(\d)\.(\d)', '$1-$2'))   # dotted -> hyphen
  [void]$keys.Add(($base -replace '(\d)-(\d)', '$1.$2'))    # hyphen -> dotted
  $keys
}
$aliases = @{}
foreach ($id in $ids) {
  $full = if ($id -match '^gh/') { $id -replace '^gh/', 'github/' } else { $id }
  foreach ($k in (Get-AliasKeys $id)) { $aliases[$k] = $full }
}
# --- dated-id overrides (only if Task 0 proved they are still emitted) ---
# $aliases['claude-haiku-4-5-20251001'] = 'github/claude-haiku-4.5'

$aliasJson = ($aliases | ConvertTo-Json -Compress)
Info "Seeding $($aliases.Count) alias keys..."

$seeder = Join-Path $env:TEMP "omniroute-seed-aliases.cjs"
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
const aliases = JSON.parse(process.argv[1]);
const up = db.prepare("INSERT OR REPLACE INTO key_value (namespace, key, value) VALUES ('modelAliases', ?, ?)");
const tx = db.transaction(() => { for (const [k, v] of Object.entries(aliases)) up.run(k, JSON.stringify(v)); });
tx();
db.close();
console.log('OK ' + Object.keys(aliases).length + ' aliases');
"@ | Set-Content -Path $seeder -Encoding utf8

# Prefer arch-correct x64 Node if present; fall back to host node.
$x64 = Join-Path $env:USERPROFILE ".omniroute\node-x64\node.exe"
$nodeExe = if (Test-Path $x64) { $x64 } else { "node" }
$out = & $nodeExe $seeder $aliasJson 2>&1
if ($LASTEXITCODE -ne 0 -and $nodeExe -ne "node") {
  Info "Seed under x64 Node failed; retrying under host node..."
  $out = & node $seeder $aliasJson 2>&1
}
if ($LASTEXITCODE -eq 0) { Ok "Model aliases seeded ($out)" }
else { Warn "Could not seed model aliases: $out" }
Remove-Item $seeder -ErrorAction SilentlyContinue
```

**Step 2: Run standalone and verify seeding**

Run: `pwsh -File .\scripts\refresh-models.ps1 -StageDir "$env:USERPROFILE\.omniroute\stage"`
Expected: "Model aliases seeded (OK N aliases)" where N ≈ discovered count × variants.

**Step 3: Verify idempotency**

Run the same command again. Expected: identical count, no errors.

**Step 4: Verify the picker**

Launch `claude`, run `/model`. Expected: full Copilot catalog listed and any model switches without "Ambiguous model".

**Step 5: Commit**

```bash
git add scripts/refresh-models.ps1
git commit -m "Seed dynamic Copilot aliases in refresh-models.ps1"
```

---

## Task 3: Delegate from setup-omniroute.ps1

**Files:**
- Modify: `scripts/setup-omniroute.ps1` (§6.5 block, ~lines 201-267)

**Step 1: Replace the inline seeder with a delegation call**

Delete the §6.5 inline `$aliasSeeder` block. In its place:

```powershell
# --- 6.5 Seed model aliases (dynamic discovery from /v1/models) -------------
Info "Seeding model aliases from discovered Copilot catalog..."
$refresh = Join-Path $PSScriptRoot "refresh-models.ps1"
& $refresh -Port $Port -StageDir $StageDir
```

Confirm `$StageDir` and `$Port` are in scope at that point (they are — used earlier in setup).

**Step 2: Run full setup**

Run: `pwsh -File .\scripts\setup-omniroute.ps1 -NoLaunch`
Expected: §6.5 now prints the discovered catalog + "Model aliases seeded", setup completes.

**Step 3: Commit**

```bash
git add scripts/setup-omniroute.ps1
git commit -m "Delegate alias seeding to refresh-models.ps1 in setup"
```

---

## Task 4: Update README

**Files:**
- Modify: `README.md` (Contents table + usage)

**Step 1: Add the script row + a refresh usage note**

Add to the Contents table:
`| scripts/refresh-models.ps1 | Discover all connected Copilot models from /v1/models and (re-)seed their aliases so /model lists and switches to the full catalog. |`

Add under a usage section:
```powershell
# Re-seed aliases after GitHub Copilot adds/removes models:
pwsh -File .\scripts\refresh-models.ps1
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "Document refresh-models.ps1 in README"
```

---

## Notes for the implementer

- **DRY:** the seeder logic lives ONLY in `refresh-models.ps1`; setup must call it, never re-inline.
- **YAGNI:** do not add the dated-id override map unless Task 0 proves it is needed.
- **Idempotent:** `INSERT OR REPLACE` — every task is safe to re-run.
- **Arch note:** the native better-sqlite3 must be loaded by the Node arch that built it; the x64-first / host-fallback pattern handles ARM64 hosts.
