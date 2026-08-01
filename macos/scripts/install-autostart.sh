#!/usr/bin/env bash
#
# Install (or remove) a launchd LaunchAgent that keeps the local OmniRoute server
# running for the current user.
#
# This is the macOS counterpart to the Windows install-autostart.ps1, which
# registers a per-user AtLogOn Scheduled Task. Here we use a launchd
# LaunchAgent under ~/Library/LaunchAgents that fires start-omniroute.sh at
# login (and periodically) so the `claude` command always has a live backend.
#
# Usage:
#   install-autostart.sh [--port <n>] [--label <id>]
#   install-autostart.sh --uninstall [--label <id>]
#
#   --port <n>     Port passed to start-omniroute.sh (default 20128).
#   --label <id>   launchd label / plist basename (default dev.omniroute.server).
#   --uninstall    Bootout and remove the LaunchAgent, then exit.

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PORT=20128
LABEL="dev.omniroute.server"
UNINSTALL=0

# --- Parse args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || die "--port requires a value."
      PORT="$2"
      shift 2
      ;;
    --label)
      [ $# -ge 2 ] || die "--label requires a value."
      LABEL="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# Validate values that get interpolated into the plist XML.
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric (got '$PORT')."
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || die "--label must be [A-Za-z0-9._-] (got '$LABEL')."

# --- Resolve paths ---------------------------------------------------------------
# Resolve the start script absolutely from THIS script's own directory so the
# plist ProgramArguments never depend on the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START_SCRIPT="$SCRIPT_DIR/start-omniroute.sh"

AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"

# Modern (10.11+) launchctl operates on a domain target rather than a bare path.
domain="gui/$(id -u)"

# --- Uninstall -------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  # bootout may fail if the agent is not currently loaded; that is fine.
  launchctl bootout "$domain" "$PLIST" 2>/dev/null || true
  if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    ok "Removed LaunchAgent $LABEL."
  else
    warn "No LaunchAgent $LABEL found."
  fi
  exit 0
fi

# --- Install ---------------------------------------------------------------------
[ -f "$START_SCRIPT" ] || die "start-omniroute.sh not found at $START_SCRIPT."

mkdir -p "$AGENTS_DIR"
mkdir -p "$HOME/.omniroute"

LOG_FILE="$HOME/.omniroute/launchd-omniroute.log"

# Write the plist.
#
# KeepAlive/StartInterval design note:
#   start-omniroute.sh is NOT a long-running foreground process. It health-checks
#   the server, starts it *detached* in the background, confirms health, then
#   EXITS 0. The detached server persists on its own. If we set KeepAlive=true,
#   launchd would see the agent's short-lived process exit and immediately re-run
#   it in a tight loop. So instead:
#     - RunAtLoad=true         -> fire once at login (the primary requirement).
#     - StartInterval=300      -> re-run every 5 min; start-omniroute.sh is
#                                 idempotent (exits early if already healthy), so
#                                 this cheaply resurrects the server if it died
#                                 mid-session without hammering launchd.
#     - (no KeepAlive)         -> avoid the tight restart loop.
#
# The heredoc is UNQUOTED so bash expands the variables below. All interpolated
# values are integers ($PORT), a trusted label ($LABEL), or $HOME-derived paths,
# so no XML escaping is required.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$START_SCRIPT</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF

ok "Wrote LaunchAgent plist to $PLIST."

# Load it fresh: bootout any prior instance (ignore "not loaded"), then bootstrap.
launchctl bootout "$domain" "$PLIST" 2>/dev/null || true
if launchctl bootstrap "$domain" "$PLIST"; then
  ok "Bootstrapped LaunchAgent $LABEL into $domain."
else
  warn "Could not bootstrap the LaunchAgent automatically."
  warn "Load it manually with: launchctl bootstrap $domain \"$PLIST\""
fi

# --- Management hints ------------------------------------------------------------
info "OmniRoute will now start at login on port $PORT."
info "Start it now:  launchctl kickstart -k \"$domain/$LABEL\""
info "Uninstall:     \"$SCRIPT_DIR/install-autostart.sh\" --uninstall --label $LABEL"
info "Log file:      $LOG_FILE"
