#!/usr/bin/env bash
#
# Discover every connected GitHub Copilot model from OmniRoute and seed bare-id
# ALIASES into OmniRoute's SQLite DB so unprefixed model ids route unambiguously
# to github/*.
#
# Claude Code sometimes sends unprefixed model ids (e.g. "claude-opus-4-8") that
# OmniRoute sees on multiple providers, producing an "Ambiguous model" error.
# This script queries OmniRoute's /v1/models endpoint, builds a catalog of the
# connected Copilot models, and writes dot/dash alias variants into the DB's
# modelAliases namespace so those bare ids resolve to a single github/* model.
#
# It is the bash port of the Windows refresh-models.ps1. On Apple Silicon (arm64)
# the node seeder (which loads the native, x64-only better-sqlite3 module) runs
# under Rosetta 2 (arch -x86_64).
#
# Usage: refresh-models.sh [--port <n>] [--stage-dir <path>] [--list-only]
#   --port       OmniRoute HTTP port           (default 20128)
#   --stage-dir  fallback node_modules root     (default $HOME/omniroute-stage)
#   --list-only  print the catalog and exit; do NOT touch the DB
#
# On macOS OmniRoute is installed via plain `npm install -g omniroute`, so its
# bundled better-sqlite3 lives under the npm GLOBAL root (`npm root -g`), not the
# stage dir. The stage dir is kept as a fallback search location.

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PORT=20128
STAGE_DIR="$HOME/omniroute-stage"
LIST_ONLY=0

# --- Parse args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || die "--port requires a value."
      PORT="$2"
      shift 2
      ;;
    --stage-dir)
      [ $# -ge 2 ] || die "--stage-dir requires a value."
      STAGE_DIR="$2"
      shift 2
      ;;
    --list-only)
      LIST_ONLY=1
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# --- Temp files + cleanup trap ---------------------------------------------------
# BSD/macOS mktemp requires the X's to be trailing (no suffix after them), so we
# create bare temp files and rename to add extensions.
MODELS_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/omniroute-models.XXXXXX")"
SEEDER_CJS="$(mktemp "${TMPDIR:-/tmp}/omniroute-seed-aliases.XXXXXX")"
mv "$MODELS_JSON_FILE" "$MODELS_JSON_FILE.json"; MODELS_JSON_FILE="$MODELS_JSON_FILE.json"
mv "$SEEDER_CJS" "$SEEDER_CJS.cjs"; SEEDER_CJS="$SEEDER_CJS.cjs"
cleanup() { rm -f "$MODELS_JSON_FILE" "$SEEDER_CJS"; }
trap cleanup EXIT

# --- Fetch the model catalog -----------------------------------------------------
# Sentinel headers let the local proxy accept the request without real auth.
# Guarded with || true so a down server does not abort under set -e.
info "Querying OmniRoute for connected Copilot models on port $PORT..."
body="$(curl -fsS \
  -H "Authorization: Bearer omniroute-no-auth" \
  -H "x-api-key: omniroute-no-auth" \
  "http://localhost:$PORT/v1/models" 2>/dev/null || true)"

if [ -z "$body" ]; then
  warn "No response from http://localhost:$PORT/v1/models (is OmniRoute running?)."
  warn "Connect GitHub Copilot at http://localhost:$PORT/dashboard/oauth then re-run."
  exit 0
fi

printf '%s' "$body" >"$MODELS_JSON_FILE"

# --- The node seeder -------------------------------------------------------------
# Single CJS script that: parses the model JSON, filters ^(gh|github)/ ids, prints
# the catalog, and (unless list-only) seeds dot/dash alias variants into the DB
# with a clobber guard. All dynamic input arrives via env vars; the heredoc is
# quoted (<<'NODE') so bash performs no expansion inside the JS.
#
# Markers on stdout the bash side keys off:
#   NO_MODELS  -> no github/* models connected (treated as a success path)
# better-sqlite3 resolution failure -> console.error + exit 2.
cat >"$SEEDER_CJS" <<'NODE'
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const listOnly = process.env.LIST_ONLY === '1';
const globalRoot = process.env.GLOBAL_ROOT || '';
const stageDir = process.env.STAGE_DIR || '';

// Parse the fetched /v1/models payload.
let payload;
try {
  payload = JSON.parse(fs.readFileSync(process.env.MODELS_JSON_FILE, 'utf8'));
} catch (e) {
  console.error('Failed to parse models JSON: ' + e.message);
  process.exit(3);
}
const data = (payload && Array.isArray(payload.data)) ? payload.data : [];
const ids = data
  .map(m => (m && typeof m.id === 'string') ? m.id : null)
  .filter(id => id && /^(gh|github)\//.test(id));

if (ids.length === 0) {
  console.log('NO_MODELS');
  process.exit(0);
}

const toGithub = id => id.replace(/^gh\//, 'github/');

// Catalog: every connected id normalized to github/, unique, sorted.
const catalog = Array.from(new Set(ids.map(toGithub))).sort();
console.log('Discovered ' + catalog.length + ' Copilot models:');
for (const c of catalog) console.log('    ' + c);

if (listOnly) process.exit(0);

// Alias models: exclude embeddings, normalize to github/, unique.
const models = Array.from(new Set(
  ids.filter(id => !/text-embedding/.test(id)).map(toGithub)
));

// For a full github/<base> id, build the bare-key variants:
//   base, base with digit.digit -> digit-digit, base with digit-digit -> digit.digit
function aliasKeys(full) {
  const base = full.replace(/^(gh|github)\//, '');
  const keys = new Set();
  keys.add(base);
  keys.add(base.replace(/(\d)\.(\d)/g, '$1-$2'));
  keys.add(base.replace(/(\d)-(\d)/g, '$1.$2'));
  return keys;
}

const aliases = {};
for (const full of models) {
  for (const k of aliasKeys(full)) aliases[k] = full;
}
// Special case: Claude Code's dated haiku id -> the github haiku model.
aliases['claude-haiku-4-5-20251001'] = 'github/claude-haiku-4.5';

// Resolve the native better-sqlite3 module. Search order (first success wins):
//   $GLOBAL_ROOT/omniroute/node_modules/better-sqlite3
//   $GLOBAL_ROOT/better-sqlite3
//   $GLOBAL_ROOT/omniroute/dist/node_modules/better-sqlite3
//   $STAGE_DIR/node_modules/better-sqlite3
//   $STAGE_DIR/node_modules/omniroute/node_modules/better-sqlite3
const searchPaths = [];
if (globalRoot) {
  searchPaths.push(path.join(globalRoot, 'omniroute', 'node_modules', 'better-sqlite3'));
  searchPaths.push(path.join(globalRoot, 'better-sqlite3'));
  searchPaths.push(path.join(globalRoot, 'omniroute', 'dist', 'node_modules', 'better-sqlite3'));
}
if (stageDir) {
  searchPaths.push(path.join(stageDir, 'node_modules', 'better-sqlite3'));
  searchPaths.push(path.join(stageDir, 'node_modules', 'omniroute', 'node_modules', 'better-sqlite3'));
}
let Database;
for (const p of searchPaths) {
  try { Database = require(p); break; } catch (_) { /* try next */ }
}
if (!Database) {
  console.error('better-sqlite3 not found; skipping alias seed');
  process.exit(2);
}

const dbPath = path.join(os.homedir(), '.omniroute', 'storage.sqlite');
let db, existing, up;
try {
  db = new Database(dbPath);
  // Existing aliases keyed by name; value is the JSON-decoded target.
  existing = new Map(
    db.prepare("SELECT key,value FROM key_value WHERE namespace='modelAliases'")
      .all().map(r => [r.key, JSON.parse(r.value)])
  );
  up = db.prepare(
    "INSERT OR REPLACE INTO key_value (namespace, key, value) VALUES ('modelAliases', ?, ?)"
  );
} catch (e) {
  console.error('Could not open OmniRoute DB or key_value table: ' + e.message);
  process.exit(2);
}

let wrote = 0, skipped = 0;
const tx = db.transaction(() => {
  for (const [k, v] of Object.entries(aliases)) {
    const cur = existing.get(k);
    // Clobber guard: never overwrite an alias that points somewhere non-github.
    if (cur !== undefined && !/^(gh|github)\//.test(cur)) { skipped++; continue; }
    up.run(k, JSON.stringify(v));
    wrote++;
  }
});
tx();
db.close();
console.log('OK wrote=' + wrote + ' skipped=' + skipped);
NODE

# --- Build the node candidate list ----------------------------------------------
# better-sqlite3 is a native x64-only module, so on Apple Silicon we must run node
# under Rosetta 2. We try candidate node invocations (argv arrays) until one exits
# 0. On arm64: `arch -x86_64 node`, then any provisioned x64 node under
# ~/.omniroute/node-x64 (also via arch -x86_64). On x64: plain `node`.
GLOBAL_ROOT="$(npm root -g 2>/dev/null || true)"

# Each candidate is a space-joined argv prefix; we word-split it into an array at
# call time. Paths here contain no spaces (arch, node, ~/.omniroute/...).
candidates=()
if [ "$(host_arch)" = "arm64" ]; then
  candidates+=("arch -x86_64 node")
  if [ -d "$HOME/.omniroute/node-x64" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && candidates+=("arch -x86_64 $n")
    done < <(find "$HOME/.omniroute/node-x64" \( -type f -o -type l \) -name node 2>/dev/null || true)
  fi
else
  candidates+=("node")
fi

# --- Run the seeder --------------------------------------------------------------
# Each attempt runs the combined script, which prints the catalog to stdout before
# it reaches the DB step. We break on the first attempt that exits 0.
#
# Catalog-print-on-retry note: because every attempt runs the same combined script,
# the "Discovered N Copilot models:" catalog can print more than once if an early
# candidate node partially succeeds (prints the catalog) then fails resolving
# better-sqlite3 (exit 2) and we fall through to the next candidate. In practice
# the common paths print it exactly once: on x64 there is a single candidate, and
# on arm64 the first candidate either seeds (prints once, we break) or fails so
# early it never prints. This duplication only occurs on the uncommon "node runs
# but better-sqlite3 is missing under it" retry path and is cosmetic. The NO_MODELS
# and list-only paths always exit 0 on the first candidate, so they print once.
seeded=0
last_out=""
for cand in "${candidates[@]}"; do
  # shellcheck disable=SC2086 -- intentional word-split of the argv prefix.
  if out="$(MODELS_JSON_FILE="$MODELS_JSON_FILE" \
            LIST_ONLY="$LIST_ONLY" \
            GLOBAL_ROOT="$GLOBAL_ROOT" \
            STAGE_DIR="$STAGE_DIR" \
            $cand "$SEEDER_CJS" 2>&1)"; then
    printf '%s\n' "$out"
    last_out="$out"
    seeded=1
    break
  else
    # Non-zero: surface output, remember it, and try the next node candidate.
    [ -n "$out" ] && printf '%s\n' "$out"
    last_out="$out"
    info "Seed under '$cand' failed; trying next node candidate (if any)..."
  fi
done

# --- Interpret the result --------------------------------------------------------
# Success paths that do NOT touch the DB (still exit 0 so setup can continue):
#   NO_MODELS  -> no github/* models connected.
#   list-only  -> user asked to list only.
if printf '%s' "$last_out" | grep -q 'NO_MODELS'; then
  warn "No github/* Copilot models found at http://localhost:$PORT/v1/models."
  warn "Connect GitHub Copilot at http://localhost:$PORT/dashboard/oauth then re-run."
  exit 0
fi

if [ "$LIST_ONLY" = "1" ]; then
  # Catalog already printed by the node script.
  exit 0
fi

if [ "$seeded" = "1" ]; then
  ok "Model aliases seeded."
else
  # Do NOT hard-fail: a missing native module should not block the rest of setup.
  warn "Could not seed model aliases (better-sqlite3 unavailable or node failed)."
  exit 0
fi
