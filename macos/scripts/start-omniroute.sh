#!/usr/bin/env bash
#
# Idempotently start the local OmniRoute server if it is not already healthy.
#
# OmniRoute is a globally-installed npm CLI ("omniroute") that runs a local HTTP
# server proxying Claude Code -> GitHub Copilot. This script checks the health
# endpoint; if the server is already up it exits 0. Otherwise it resolves the
# omniroute launcher, starts "omniroute serve" detached in the background, and
# polls until the server is healthy.
#
# On Apple Silicon (arm64) hosts, OmniRoute's native deps ship no darwin-arm64
# binary, so the server is launched under Rosetta 2 (arch -x86_64).
#
# Usage: start-omniroute.sh [--port <n>]   (default port 20128)

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PORT=20128

# --- Parse args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || die "--port requires a value."
      PORT="$2"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

HEALTH_URL="http://localhost:$PORT/api/monitoring/health"

# Return 0 (success) iff the health endpoint responds 200 within 4s.
# Only ever call as an if/while condition so set -e does not abort on "down".
test_up() {
  curl -fs -m 4 "$HEALTH_URL" >/dev/null 2>&1
}

# --- Already healthy? ------------------------------------------------------------
if test_up; then
  ok "OmniRoute is already running and healthy on port $PORT."
  exit 0
fi

# --- Resolve the omniroute launcher portably -------------------------------------
omni=""
if command -v omniroute >/dev/null 2>&1; then
  omni="$(command -v omniroute)"
else
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -x "$npm_prefix/bin/omniroute" ]; then
    omni="$npm_prefix/bin/omniroute"
  fi
fi

if [ -z "$omni" ]; then
  die "omniroute launcher not found. Run setup-omniroute.sh first."
fi

# --- Build the Rosetta prefix for arm64 hosts ------------------------------------
# Empty on x64. Expanded with the "${PREFIX[@]+...}" idiom so an empty array is
# safe under set -u.
if [ "$(host_arch)" = "arm64" ]; then
  PREFIX=(arch -x86_64)
else
  PREFIX=()
fi

# --- Launch detached in the background -------------------------------------------
mkdir -p "$HOME/.omniroute"
LOG_FILE="$HOME/.omniroute/omniroute-server.log"

info "Starting OmniRoute server on port $PORT..."
nohup "${PREFIX[@]+"${PREFIX[@]}"}" "$omni" serve >"$LOG_FILE" 2>&1 &
server_pid=$!

# --- Poll until healthy, up to a 90s wall-clock deadline -------------------------
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  # Fail fast if the server process died (bad install, port in use, Rosetta missing).
  if ! kill -0 "$server_pid" 2>/dev/null; then
    warn "OmniRoute server exited immediately. Check $LOG_FILE for details."
    exit 1
  fi
  if test_up; then
    ok "OmniRoute is running and healthy on port $PORT."
    exit 0
  fi
  sleep 3
done

warn "OmniRoute did not become healthy within 90s. Check $LOG_FILE for details."
exit 1
