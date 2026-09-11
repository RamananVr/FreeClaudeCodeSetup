#!/usr/bin/env bash
#
# List GitHub Copilot models through OmniRoute's authenticated management API.
# OmniRoute 3.8.50+ seeds its own model aliases, so this script is read-only.
#
# Usage: refresh-models.sh [--port <n>] [--stage-dir <path>] [--list-only]

set -euo pipefail

source "$(dirname "$0")/_common.sh"

PORT=20128

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      [ $# -ge 2 ] || die "--port requires a value"; PORT="$2"; shift 2 ;;
    --stage-dir) [ $# -ge 2 ] || die "--stage-dir requires a value"; shift 2 ;;
    --list-only) shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command -v omniroute >/dev/null 2>&1 ||
  die "omniroute is not on PATH. Run setup-omniroute.sh first."

raw="$(omniroute --quiet --output json --base-url "http://localhost:$PORT" \
  api models get-api-models 2>/dev/null || true)"
json="$(printf '%s\n' "$raw" | sed -n '/^{/,$p')"
[ -n "$json" ] || die "OmniRoute returned no model catalog."

catalog="$(printf '%s' "$json" | node -e '
  let raw = "";
  process.stdin.on("data", chunk => raw += chunk);
  process.stdin.on("end", () => {
    const body = JSON.parse(raw);
    const ids = (body.models || [])
      .filter(model => model.available && /^(gh|github)$/.test(model.provider))
      .map(model => model.fullModel.replace(/^gh\//, "github/"));
    process.stdout.write([...new Set(ids)].sort().join("\n"));
  });
')"

if [ -z "$catalog" ]; then
  warn "No GitHub Copilot models are connected at http://localhost:$PORT."
  warn "Connect GitHub Copilot at http://localhost:$PORT/dashboard/oauth then re-run."
  exit 0
fi

count="$(printf '%s\n' "$catalog" | wc -l | tr -d ' ')"
info "Discovered $count Copilot models:"
printf '    %s\n' $catalog
info "OmniRoute 3.8.50+ manages model aliases automatically; no database changes are needed."
