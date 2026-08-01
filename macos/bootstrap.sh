#!/usr/bin/env bash
#
# One-command bootstrap for macOS: install OmniRoute and route the default `claude`
# through it, then register the launchd autostart agent.
#
# Runs scripts/setup-omniroute.sh followed by scripts/install-autostart.sh so a fresh
# Mac goes from nothing to a working `claude` (routed through OmniRoute -> Copilot) in
# a single command. Both child scripts are resolved relative to this file, so it works
# from wherever the repo is cloned.
#
# Usage:
#   bootstrap.sh [--model <str>] [--port <n>] [--x64-node-version <str>]
#                [--no-autostart] [--no-launch] [--accept-routing-change]
#
#   --model                 Main model Claude Code should use (default github/claude-opus-4.8).
#   --port                  OmniRoute server port, applied to setup and autostart (default 20128).
#   --x64-node-version      On arm64, the pinned x64 Node auto-provisioned for OmniRoute
#                           (default 20.18.1). Ignored on x64.
#   --no-autostart          Run setup only; skip registering the launchd agent.
#   --no-launch             Do not open an interactive Claude Code session after setup.
#   --accept-routing-change Skip the confirmation pause before routing the default `claude`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/scripts/_common.sh"

# --- Defaults --------------------------------------------------------------------
MODEL="github/claude-opus-4.8"
PORT=20128
X64_NODE_VERSION="20.18.1"
NO_AUTOSTART=0
NO_LAUNCH=0
ACCEPT_ROUTING_CHANGE=0

# --- Parse args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --model)                 [ $# -ge 2 ] || die "--model requires a value.";           MODEL="$2"; shift 2 ;;
    --port)                  [ $# -ge 2 ] || die "--port requires a value.";            PORT="$2"; shift 2 ;;
    --x64-node-version)      [ $# -ge 2 ] || die "--x64-node-version requires a value."; X64_NODE_VERSION="$2"; shift 2 ;;
    --no-autostart)          NO_AUTOSTART=1; shift ;;
    --no-launch)             NO_LAUNCH=1; shift ;;
    --accept-routing-change) ACCEPT_ROUTING_CHANGE=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) die "--port must be numeric (got '$PORT')." ;; esac

SETUP="$SCRIPT_DIR/scripts/setup-omniroute.sh"
AUTOSTART="$SCRIPT_DIR/scripts/install-autostart.sh"
for s in "$SETUP" "$AUTOSTART"; do
  [ -f "$s" ] || die "Required script not found: $s"
done

printf '\n=== OmniRoute bootstrap (macOS) ===\n\n'

# --- 1. Setup --------------------------------------------------------------------
# Always suppress setup's interactive launch until autostart is registered; we
# re-launch afterwards. When --no-autostart is set there is nothing to defer, so
# setup launches directly (unless --no-launch).
defer_launch=0
if [ "$NO_LAUNCH" -eq 0 ] && [ "$NO_AUTOSTART" -eq 0 ]; then
  defer_launch=1
fi

setup_args=(--model "$MODEL" --port "$PORT" --x64-node-version "$X64_NODE_VERSION")
if [ "$NO_LAUNCH" -eq 1 ] || [ "$defer_launch" -eq 1 ]; then
  setup_args+=(--no-launch)
fi
if [ "$ACCEPT_ROUTING_CHANGE" -eq 1 ]; then
  setup_args+=(--accept-routing-change)
fi

info "[1/2] Running setup-omniroute.sh..."
bash "$SETUP" "${setup_args[@]}"

# --- 2. Autostart ----------------------------------------------------------------
if [ "$NO_AUTOSTART" -eq 1 ]; then
  info "[2/2] --no-autostart set; skipping launchd agent registration."
else
  info "[2/2] Registering launchd autostart agent..."
  bash "$AUTOSTART" --port "$PORT"
fi

printf '\n=== Bootstrap complete ===\n'
printf '  Launch: claude\n'

# Re-open the interactive session we deferred above.
if [ "$defer_launch" -eq 1 ]; then
  if command -v claude >/dev/null 2>&1; then
    info "Launching Claude Code (routed through OmniRoute)..."
    claude
  else
    warn "claude not found on PATH. Install Claude Code, then run: claude"
  fi
fi
