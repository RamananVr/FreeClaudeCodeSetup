#!/usr/bin/env bash
#
# Route the default `claude` command through OmniRoute -> GitHub Copilot by merging a
# routing `env` block into Claude Code's settings.json.
#
# Merges (never overwrites) the OmniRoute routing keys into settings.json:
#   * ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL,
#     CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY
# Existing unrelated settings are preserved. ANTHROPIC_API_KEY is removed from the env
# block (it would override the routed token). On the first write the prior file is backed
# up to settings.json.bak (only if no .bak exists yet). Idempotent.
#
# The JSON read/merge/write is done by node (already a required dependency). Values are
# passed to node via env vars (never string-interpolated into the JS) to avoid quoting
# and injection bugs.
#
# ORDERING (see the two node passes below):
#   1. If the target exists and is non-empty, run a node "validate" pass that JSON.parses
#      it and exits nonzero on malformed JSON. The bash wrapper dies BEFORE any backup or
#      write, so a malformed file is never clobbered.
#   2. Bash backs up the file once (cp to .bak) only if it exists, is non-empty, and no
#      .bak exists yet -- i.e. only after validation proved the input is good JSON.
#   3. A second node pass reads/merges/writes the file. Because step 1 already guaranteed
#      valid JSON, the write in this pass operates on trusted input.
#
# Usage:
#   configure-claude-routing.sh [--port <n>] [--model <str>] [--settings-path <path>]

set -euo pipefail

source "$(dirname "$0")/_common.sh"

# --- Parse flags -----------------------------------------------------------------
PORT=20128
MODEL="github/claude-opus-4.8"
SETTINGS_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --port)          [ $# -ge 2 ] || die "--port requires a value";          PORT="$2"; shift 2 ;;
    --model)         [ $# -ge 2 ] || die "--model requires a value";         MODEL="$2"; shift 2 ;;
    --settings-path) [ $# -ge 2 ] || die "--settings-path requires a value"; SETTINGS_PATH="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Resolve target settings.json ------------------------------------------------
if [ -z "$SETTINGS_PATH" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    SETTINGS_PATH="$CLAUDE_CONFIG_DIR/settings.json"
  else
    SETTINGS_PATH="$HOME/.claude/settings.json"
  fi
fi

parent="$(dirname "$SETTINGS_PATH")"
if [ -n "$parent" ] && [ ! -d "$parent" ]; then
  mkdir -p "$parent"
fi

# --- 1. Validate existing JSON (before any backup/write) -------------------------
# Non-empty here means "has non-whitespace content".
has_content=0
if [ -s "$SETTINGS_PATH" ] && [ -n "$(tr -d '[:space:]' < "$SETTINGS_PATH")" ]; then
  has_content=1
fi

if [ "$has_content" -eq 1 ]; then
  if ! SETTINGS_PATH="$SETTINGS_PATH" node -e '
    const fs = require("fs");
    const p = process.env.SETTINGS_PATH;
    const raw = fs.readFileSync(p, "utf8");
    try {
      JSON.parse(raw);
    } catch (e) {
      console.error(`settings.json at ${p} is not valid JSON; refusing to overwrite. Fix or remove it, then re-run. (${e.message})`);
      process.exit(1);
    }
  '; then
    die "Aborting: existing settings.json is not valid JSON (see message above)."
  fi

  # --- 2. Back up once, only after validation succeeded --------------------------
  bak="$SETTINGS_PATH.bak"
  if [ ! -e "$bak" ]; then
    cp "$SETTINGS_PATH" "$bak"
  fi
fi

# --- 3. Merge routing env block and write ----------------------------------------
if ! SETTINGS_PATH="$SETTINGS_PATH" PORT="$PORT" MODEL="$MODEL" HAS_CONTENT="$has_content" node -e '
  const fs = require("fs");
  const p = process.env.SETTINGS_PATH;

  let settings = {};
  if (process.env.HAS_CONTENT === "1") {
    settings = JSON.parse(fs.readFileSync(p, "utf8"));
  }
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    settings = {};
  }

  const env = (settings.env && typeof settings.env === "object" && !Array.isArray(settings.env))
    ? settings.env
    : {};

  // Drop ANTHROPIC_API_KEY (would override the routed token).
  delete env.ANTHROPIC_API_KEY;

  // Apply routing keys, preserving all other env and top-level keys.
  env.ANTHROPIC_BASE_URL = `http://localhost:${process.env.PORT}`;
  env.ANTHROPIC_AUTH_TOKEN = "omniroute-no-auth";
  env.ANTHROPIC_MODEL = process.env.MODEL;
  env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1";

  settings.env = env;

  fs.writeFileSync(p, JSON.stringify(settings, null, 2) + "\n");
'; then
  die "Failed to write routing configuration to $SETTINGS_PATH."
fi

ok "Routing configured in $SETTINGS_PATH (model: $MODEL, port: $PORT)"
