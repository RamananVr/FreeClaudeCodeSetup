#!/usr/bin/env bash
# Shared helpers for the macOS OmniRoute setup scripts. Source this file.
set -euo pipefail

_c_cyan=$'\033[36m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_reset=$'\033[0m'
info() { printf '  %s[*]%s %s\n' "$_c_cyan"   "$_c_reset" "$*"; }
ok()   { printf '  %s[+]%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '  %s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*"; }
die()  { printf '  %s[x]%s %s\n' "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

# Echo "arm64" or "x64" for the host architecture.
host_arch() { case "$(uname -m)" in arm64) echo arm64;; *) echo x64;; esac; }
