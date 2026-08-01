#!/usr/bin/env bash
#
# Ensure an x64 Node.js toolchain is available and tell the caller which node to use.
#
# On x64 hosts this is a no-op: it emits the output contract with an empty dir and the
# bare "node" command. On Apple Silicon (arm64) hosts, OmniRoute's native deps ship no
# darwin-arm64 binary, so we provision a pinned, portable x64 Node under
# $HOME/.omniroute/node-x64 and run it under Rosetta 2 (arch -x86_64).
#
# OUTPUT CONTRACT (parsed by the caller): the LAST two lines on stdout are
#   NODE_DIR=<absolute bin dir, or empty on x64>
#   NODE_EXE=<absolute node path, or the literal "node" on x64>
# All human-readable logging goes to STDERR so stdout stays machine-parseable.
#
# Overridable via env vars:
#   X64_NODE_VERSION  (default 20.18.1)
#   INSTALL_ROOT      (default $HOME/.omniroute/node-x64)

set -euo pipefail

source "$(dirname "$0")/_common.sh"

# Route the shared logging helpers to stderr so stdout carries only the contract lines.
# die() already writes to stderr in _common.sh.
log_info() { info "$@" >&2; }
log_ok()   { ok   "$@" >&2; }
log_warn() { warn "$@" >&2; }

X64_NODE_VERSION="${X64_NODE_VERSION:-20.18.1}"
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/.omniroute/node-x64}"

# Emit the two-line output contract on stdout, then exit 0.
emit_contract() {
  local node_dir="$1" node_exe="$2"
  printf 'NODE_DIR=%s\n' "$node_dir"
  printf 'NODE_EXE=%s\n' "$node_exe"
  exit 0
}

# --- x64 host: no-op -------------------------------------------------------------
if [ "$(host_arch)" = "x64" ]; then
  emit_contract "" "node"
fi

# --- arm64 host: provision a portable x64 Node -----------------------------------
log_info "Apple Silicon (arm64) host detected. Ensuring a portable x64 Node (v${X64_NODE_VERSION})..."

# (a) Ensure Rosetta 2 is present.
if ! arch -x86_64 true 2>/dev/null; then
  die "Rosetta 2 is required to run x64 Node on Apple Silicon. Install it with: softwareupdate --install-rosetta --agree-to-license"
fi

# (b) Compute paths. macOS tarballs put node under bin/.
folder="node-v${X64_NODE_VERSION}-darwin-x64"
dir="$INSTALL_ROOT/$folder"
exe="$dir/bin/node"

# Return true if $exe exists and reports process.arch == x64 under Rosetta.
is_x64_node() {
  [ -x "$exe" ] || return 1
  [ "$(arch -x86_64 "$exe" -p process.arch 2>/dev/null)" = "x64" ]
}

# (c) Idempotent reuse of a valid prior install.
if is_x64_node; then
  log_ok "Reusing provisioned x64 Node at $dir"
  emit_contract "$dir/bin" "$exe"
fi

base_url="https://nodejs.org/dist/v${X64_NODE_VERSION}"
archive="${folder}.tar.gz"
archive_url="${base_url}/${archive}"
sha_url="${base_url}/SHASUMS256.txt"

mkdir -p "$INSTALL_ROOT"
tmp="$INSTALL_ROOT/$archive"

provision_failed() {
  log_warn "Failed to provision x64 Node automatically."
  log_warn "Download ${archive_url} manually, extract it to:"
  log_warn "  $INSTALL_ROOT"
  log_warn "so that $exe exists, then re-run setup."
  die "Could not provision a portable x64 Node."
}

# (d) Download the tarball.
log_info "Downloading ${archive_url} ..."
if ! curl -fL -o "$tmp" "$archive_url"; then
  rm -f "$tmp"
  provision_failed
fi

# (e) Verify SHA-256.
log_info "Verifying SHA-256..."
sha_text="$(curl -fL "$sha_url" 2>/dev/null)" || { rm -f "$tmp"; provision_failed; }
# SHASUMS256.txt lines: "<hash>  <filename>" (filename may have a leading *).
expected="$(printf '%s\n' "$sha_text" \
  | awk -v f="$archive" '{ n=$2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }')"
if [ -z "$expected" ]; then
  rm -f "$tmp"
  log_warn "Could not find a SHA-256 entry for ${archive} in SHASUMS256.txt."
  provision_failed
fi
actual="$(shasum -a 256 "$tmp" | awk '{print $1}')" || { rm -f "$tmp"; die "Failed to compute SHA-256 for ${archive}."; }
if [ "$actual" != "$expected" ]; then
  rm -f "$tmp"
  die "SHA-256 mismatch for ${archive} (expected ${expected}, got ${actual}). Aborting."
fi
log_ok "Checksum verified."

# (f) Remove any stale extraction, then extract. The tarball contains the
# node-v...-darwin-x64/ folder at its root, so extract into $INSTALL_ROOT.
[ -d "$dir" ] && rm -rf "$dir"
log_info "Extracting..."
if ! tar -xzf "$tmp" -C "$INSTALL_ROOT"; then
  rm -f "$tmp"
  provision_failed
fi
rm -f "$tmp"

# (g) Self-check.
if ! is_x64_node; then
  die "Provisioned Node at $exe did not self-check as x64. Aborting."
fi

log_ok "Provisioned x64 Node at $dir"
emit_contract "$dir/bin" "$exe"
