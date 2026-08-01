#!/usr/bin/env bash
#
# Install OmniRoute on macOS and route the default `claude` command through
# OmniRoute -> GitHub Copilot by writing routing config into Claude Code's
# settings.json.
#
# This is the ORCHESTRATOR: it ties together the sibling scripts in this dir
# (ensure-x64-node.sh, start-omniroute.sh, refresh-models.sh,
# configure-claude-routing.sh). It is the bash port of the Windows
# setup-omniroute.ps1, adapted for macOS.
#
# Flow:
#   0. Prereqs: require node + npm on PATH.
#   1. Arch: run ensure-x64-node.sh. On Apple Silicon (arm64) it provisions a
#      portable x64 Node under Rosetta 2; we prepend that node's bin dir to PATH
#      and run node/omniroute under `arch -x86_64`.
#   2. Install: plain `npm install -g omniroute` (no Windows-style staging).
#   3. Start the OmniRoute server (start-omniroute.sh).
#   4. Ensure GitHub Copilot is connected (poll /v1/models; open dashboard).
#   5. Seed model aliases (refresh-models.sh).
#   6. Route the default `claude` (configure-claude-routing.sh), with disclaimer.
#   7. Summary + launch `claude` unless --no-launch.
#
# It is idempotent - safe to re-run.
#
# Usage:
#   setup-omniroute.sh [--model <str>] [--stage-dir <path>] [--port <n>]
#                      [--x64-node-version <str>] [--no-launch]
#                      [--accept-routing-change]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# --- Defaults --------------------------------------------------------------------
MODEL="github/claude-opus-4.8"
STAGE_DIR="$HOME/omniroute-stage"
PORT=20128
X64_NODE_VERSION="20.18.1"
NO_LAUNCH=0
ACCEPT_ROUTING_CHANGE=0

# --- Parse args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --model)                [ $# -ge 2 ] || die "--model requires a value.";             MODEL="$2"; shift 2 ;;
    --stage-dir)            [ $# -ge 2 ] || die "--stage-dir requires a value.";          STAGE_DIR="$2"; shift 2 ;;
    --port)                 [ $# -ge 2 ] || die "--port requires a value.";               PORT="$2"; shift 2 ;;
    --x64-node-version)     [ $# -ge 2 ] || die "--x64-node-version requires a value.";   X64_NODE_VERSION="$2"; shift 2 ;;
    --no-launch)            NO_LAUNCH=1; shift ;;
    --accept-routing-change) ACCEPT_ROUTING_CHANGE=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) die "--port must be numeric (got '$PORT')." ;; esac

# --- Verify sibling scripts exist ------------------------------------------------
ENSURE_X64_NODE="$SCRIPT_DIR/ensure-x64-node.sh"
START_OMNIROUTE="$SCRIPT_DIR/start-omniroute.sh"
REFRESH_MODELS="$SCRIPT_DIR/refresh-models.sh"
CONFIGURE_ROUTING="$SCRIPT_DIR/configure-claude-routing.sh"
for s in "$ENSURE_X64_NODE" "$START_OMNIROUTE" "$REFRESH_MODELS" "$CONFIGURE_ROUTING"; do
  [ -f "$s" ] || die "Required sibling script not found: $s"
done

printf '\n=== OmniRoute + Claude Code setup ===\n\n'

# --- 0. Prerequisites ------------------------------------------------------------
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  die "Node.js/npm not found on PATH. Install via Homebrew (brew install node) or nvm, then re-run."
fi

# --- 1. Arch: ensure an x64 Node on Apple Silicon --------------------------------
# ensure-x64-node.sh emits a two-line OUTPUT CONTRACT on stdout (all other logging
# goes to stderr). We capture stdout and read ONLY the last matching line for each
# key so any stray stdout leakage cannot confuse the parse.
info "Ensuring x64 Node toolchain (host arch: $(host_arch))..."
ensure_out="$(X64_NODE_VERSION="$X64_NODE_VERSION" INSTALL_ROOT="${INSTALL_ROOT:-}" \
  bash "$ENSURE_X64_NODE")" || die "ensure-x64-node.sh failed. See messages above."

NODE_DIR="$(printf '%s\n' "$ensure_out" | grep '^NODE_DIR=' | tail -1 | cut -d= -f2- || true)"
NODE_EXE="$(printf '%s\n' "$ensure_out" | grep '^NODE_EXE=' | tail -1 | cut -d= -f2- || true)"
[ -n "$NODE_EXE" ] || NODE_EXE="node"

# NODE_PREFIX is the argv prefix used to run node/omniroute. On arm64 with a
# provisioned x64 Node we run under Rosetta (arch -x86_64); on x64 it is empty.
# Use the set -u-safe "${NODE_PREFIX[@]+...}" idiom at every call site.
if [ -n "$NODE_DIR" ]; then
  # Prepend the provisioned x64 node's bin dir so `node`/`npm` resolve to it for
  # the rest of this script (and so `npm install -g` builds x64-native deps).
  export PATH="$NODE_DIR:$PATH"
  NODE_PREFIX=(arch -x86_64)
  ok "Using provisioned x64 Node: $NODE_EXE"
else
  NODE_PREFIX=()
fi

info "main model : $MODEL"
info "stage dir  : $STAGE_DIR"
info "port       : $PORT"

# --- 2. Install omniroute globally -----------------------------------------------
# macOS uses a plain global install (no Windows-style staging/junction). On arm64
# we wrap the install in the Rosetta prefix (arch -x86_64) so the ENTIRE spawned
# process tree prefers x86_64 -- not just the top-level node. A dep's postinstall
# can shell out to node-gyp/prebuild-install children that key off `uname -m`; an
# un-wrapped arm64 child could otherwise pull/build an arm64 native artifact, the
# exact thing OmniRoute's native deps lack. On x64 NODE_PREFIX is empty (no-op).
info "Installing omniroute globally (npm install -g omniroute)..."
if ! "${NODE_PREFIX[@]+"${NODE_PREFIX[@]}"}" npm install -g omniroute --no-fund --no-audit; then
  die "npm install -g omniroute failed. Check your network/npm registry, then re-run."
fi

# Verify the omniroute launcher resolves (on PATH, or under the npm global root).
if command -v omniroute >/dev/null 2>&1; then
  ok "omniroute installed: $(command -v omniroute)"
else
  g_root="$(npm root -g 2>/dev/null || true)"
  if [ -n "$g_root" ] && [ -e "$g_root/omniroute" ]; then
    ok "omniroute installed under npm global root: $g_root/omniroute"
  else
    die "omniroute not found after install. Try: npm install -g omniroute, then re-run."
  fi
fi

# --- 3. Start the OmniRoute server -----------------------------------------------
info "Starting the OmniRoute server..."
if ! bash "$START_OMNIROUTE" --port "$PORT"; then
  die "OmniRoute server did not become healthy. Run '$START_OMNIROUTE --port $PORT' manually to see errors."
fi

# --- 4. Ensure GitHub Copilot is connected ---------------------------------------
# Count the github/* model ids reported by /v1/models. Sentinel headers let the
# local proxy accept the request without real auth. We pipe the JSON body to node
# (already a dependency) to count ids matching ^(gh|github)/. Never aborts under
# set -e: every failure path yields "0".
copilot_model_count() {
  local body
  body="$(curl -fsS -m 10 \
    -H "Authorization: Bearer omniroute-no-auth" \
    -H "x-api-key: omniroute-no-auth" \
    "http://localhost:$PORT/v1/models" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    echo 0
    return 0
  fi
  local count
  count="$(printf '%s' "$body" | "${NODE_PREFIX[@]+"${NODE_PREFIX[@]}"}" node -e '
    let raw = "";
    process.stdin.on("data", d => raw += d);
    process.stdin.on("end", () => {
      let n = 0;
      try {
        const p = JSON.parse(raw);
        const data = (p && Array.isArray(p.data)) ? p.data : [];
        n = data.filter(m => m && typeof m.id === "string" && /^(gh|github)\//.test(m.id)).length;
      } catch (_) { n = 0; }
      process.stdout.write(String(n));
    });
  ' 2>/dev/null || true)"
  case "$count" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$count" ;;
  esac
}

gh_count="$(copilot_model_count)"
if [ "$gh_count" -gt 0 ]; then
  ok "GitHub Copilot connected ($gh_count Copilot models available)."
else
  warn "GitHub Copilot is not connected yet - opening the OmniRoute dashboard so you can connect it."
  warn "In the dashboard: Providers/OAuth -> GitHub Copilot -> Connect -> authorize the device code."
  if command -v open >/dev/null 2>&1; then
    open "http://localhost:$PORT/dashboard/oauth" || true
  else
    warn "Could not auto-open a browser. Visit: http://localhost:$PORT/dashboard/oauth"
  fi
  if [ -t 0 ]; then
    read -r -p "Press ENTER once GitHub Copilot shows as connected in the dashboard..." _ || true
  fi
  gh_count="$(copilot_model_count)"
  if [ "$gh_count" -gt 0 ]; then
    ok "GitHub Copilot connected ($gh_count Copilot models available)."
  else
    warn "Still no Copilot models detected - you can finish connecting later and then run: claude"
  fi
fi

# --- 5. Seed model aliases -------------------------------------------------------
# Discovers every connected github/* Copilot model and seeds bare-id aliases so
# unprefixed ids route unambiguously. Never hard-fails.
info "Seeding model aliases from the discovered Copilot catalog..."
bash "$REFRESH_MODELS" --port "$PORT" --stage-dir "$STAGE_DIR" || true

# --- 6. Route the DEFAULT `claude` through OmniRoute -----------------------------
# This changes the user's default `claude` command, so show a disclaimer and (when
# interactive) pause for confirmation before writing settings.json.
printf '\n'
warn "This configures your DEFAULT \`claude\` to route through OmniRoute -> GitHub Copilot."
warn "After setup, running \`claude\` uses Copilot, not direct Anthropic access."
warn "Your previous settings.json is backed up to settings.json.bak (revert anytime)."

if [ -t 0 ] && [ "$ACCEPT_ROUTING_CHANGE" -eq 0 ] && [ "$NO_LAUNCH" -eq 0 ]; then
  read -r -p "Press ENTER to continue, or Ctrl+C to cancel..." _ || true
fi

if ! bash "$CONFIGURE_ROUTING" --port "$PORT" --model "$MODEL"; then
  die "Failed to configure default claude routing. See messages above."
fi
ok "Default \`claude\` now routes through OmniRoute (model: $MODEL)."

# --- 7. Summary + launch ---------------------------------------------------------
printf '\n=== Setup complete ===\n'
printf '  OmniRoute       : http://localhost:%s  (dashboard: http://localhost:%s/dashboard)\n' "$PORT" "$PORT"
printf '  Main model      : %s  (change in-session via /model)\n' "$MODEL"
printf '  Command         : claude   (routes through OmniRoute -> Copilot)\n'
printf '  Usage           : claude                # opus via OmniRoute -> Copilot\n'
printf '                    claude -p "prompt"    # headless\n'
printf '                    /model in-session     # switch to any connected provider\n\n'

if [ "$NO_LAUNCH" -eq 1 ]; then
  info "--no-launch set. Skipping interactive launch. Run 'claude' when ready."
else
  if command -v claude >/dev/null 2>&1; then
    info "Launching Claude Code (routed through OmniRoute)..."
    claude
  else
    warn "claude not found on PATH. Install Claude Code, then run: claude"
  fi
fi
