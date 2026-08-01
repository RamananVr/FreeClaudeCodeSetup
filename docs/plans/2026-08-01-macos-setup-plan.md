# macOS Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `development/reference/executing-plans-guide.md` to implement this plan task-by-task.

**Goal:** Port the Windows OmniRoute + Claude Code setup to macOS with native shell scripts, restructuring the repo into `windows/` and `macos/` subdirectories.

**Architecture:** Move existing Windows files under `windows/` (git mv, history preserved). Author native bash scripts under `macos/` that mirror each PowerShell script: install OmniRoute, route the default `claude` via `~/.claude/settings.json`, keep the server alive via a launchd LaunchAgent, and seed model aliases. Apple Silicon gets a Rosetta 2 + portable darwin-x64 Node fallback.

**Tech Stack:** bash (`set -euo pipefail`), node (JSON merge + SQLite seeder), launchd, `arch -x86_64` (Rosetta), OmniRoute CLI, GitHub Copilot.

**Reference:** design doc `docs/plans/2026-08-01-macos-setup-design.md`. PowerShell originals (now under `windows/`) are the source of truth for behavior parity.

**Testing note:** Authored on Windows; per-task verification is `bash -n <script>` syntax check only. End-to-end validation is done by the user on a Mac.

---

### Task 1: Restructure repo into windows/

**Files:**
- Move: `bootstrap.ps1` → `windows/bootstrap.ps1`
- Move: `scripts/` → `windows/scripts/`

**Step 1: Move Windows files with git mv**

```bash
mkdir -p windows
git mv bootstrap.ps1 windows/bootstrap.ps1
git mv scripts windows/scripts
```

**Step 2: Verify no intra-repo path breakage**

Confirm `windows/bootstrap.ps1` resolves children via `$PSScriptRoot`/`scripts` and that no script hardcodes an absolute repo path. Grep:
```bash
grep -rn "PSScriptRoot" windows/
grep -rniE "C:\\\\Users|omniRouteSetup\\\\scripts" windows/ || echo "no hardcoded repo paths"
```
Expected: `bootstrap.ps1` joins `$PSScriptRoot "scripts"`; no hardcoded repo paths.

**Step 3: Verify tree**

Run: `git status` and `ls windows windows/scripts`
Expected: all former root scripts now under `windows/scripts/`, staged as renames.

**Step 4: Commit**

```bash
git add -A
git commit -m "Move Windows setup under windows/ subdir"
```

---

### Task 2: Scaffold macos/ dir + shared helpers

**Files:**
- Create: `macos/scripts/_common.sh` (shared `info/ok/warn/die`, color helpers, arch detection)

**Step 1: Write `macos/scripts/_common.sh`**

Sourceable helper file:
```bash
#!/usr/bin/env bash
# Shared helpers for the macOS OmniRoute setup scripts.
set -euo pipefail

_c_cyan=$'\033[36m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_reset=$'\033[0m'
info() { printf '  %s[*]%s %s\n' "$_c_cyan"  "$_c_reset" "$*"; }
ok()   { printf '  %s[+]%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn() { printf '  %s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*"; }
die()  { printf '  %s[x]%s %s\n' "$_c_red"   "$_c_reset" "$*" >&2; exit 1; }

# Echo "arm64" or "x64".
host_arch() { case "$(uname -m)" in arm64) echo arm64;; *) echo x64;; esac; }
```

**Step 2: Syntax check**

Run: `bash -n macos/scripts/_common.sh`
Expected: no output (valid).

**Step 3: Commit**

```bash
git add macos/scripts/_common.sh
git commit -m "Add macOS shared shell helpers"
```

---

### Task 3: ensure-x64-node.sh (Apple Silicon fallback)

**Files:**
- Create: `macos/scripts/ensure-x64-node.sh`

**Step 1: Write the script**

Behavior mirrors `windows/scripts/ensure-x64-node.ps1`:
- Default `X64_NODE_VERSION=20.18.1`, `INSTALL_ROOT="$HOME/.omniroute/node-x64"`.
- If `host_arch` is `x64`: print `NODE_DIR=` (empty) / `NODE_EXE=node` and exit 0.
- If `arm64`:
  - Probe Rosetta: `arch -x86_64 true 2>/dev/null` — on failure, die with `softwareupdate --install-rosetta --agree-to-license` hint.
  - `folder="node-v$VER-darwin-x64"`, `dir="$INSTALL_ROOT/$folder"`, `exe="$dir/bin/node"`.
  - Idempotent reuse: if `arch -x86_64 "$exe" -p process.arch` == `x64`, emit paths and exit.
  - Download `https://nodejs.org/dist/v$VER/$folder.tar.gz` via `curl -fL`.
  - Fetch `SHASUMS256.txt`, grep the line for the tarball, compare `shasum -a 256`.
  - Extract with `tar -xzf` into `$INSTALL_ROOT`.
  - Self-check x64; die on mismatch.
  - Emit `NODE_DIR=$dir/bin` and `NODE_EXE=$exe` on stdout (caller parses).

**Step 2: Syntax check**

Run: `bash -n macos/scripts/ensure-x64-node.sh`
Expected: no output.

**Step 3: Commit**

```bash
git add macos/scripts/ensure-x64-node.sh
git commit -m "Add macOS Apple Silicon x64-Node/Rosetta fallback"
```

---

### Task 4: configure-claude-routing.sh

**Files:**
- Create: `macos/scripts/configure-claude-routing.sh`

**Step 1: Write the script**

Mirrors `windows/scripts/configure-claude-routing.ps1`:
- Flags: `--port` (20128), `--model` (`github/claude-opus-4.8`), `--settings-path`.
- Resolve target: `$CLAUDE_CONFIG_DIR/settings.json` if set, else `$HOME/.claude/settings.json`. `mkdir -p` parent.
- If file exists and non-empty: back up to `settings.json.bak` once (only if no `.bak`). Refuse to proceed on malformed JSON.
- Merge via an inline `node` script: load existing (or `{}`), normalize `env`, drop `ANTHROPIC_API_KEY`, set the 4 routing keys (`ANTHROPIC_BASE_URL=http://localhost:$PORT`, `ANTHROPIC_AUTH_TOKEN=omniroute-no-auth`, `ANTHROPIC_MODEL=$MODEL`, `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`), preserve unrelated keys, write pretty JSON.

**Step 2: Syntax check**

Run: `bash -n macos/scripts/configure-claude-routing.sh`
Expected: no output.

**Step 3: (Mac-only, informational) Functional test**

On a Mac: run against a temp `--settings-path`, confirm the 4 keys land and unrelated keys survive. Skipped on Windows host.

**Step 4: Commit**

```bash
git add macos/scripts/configure-claude-routing.sh
git commit -m "Add macOS claude routing config script"
```

---

### Task 5: start-omniroute.sh

**Files:**
- Create: `macos/scripts/start-omniroute.sh`

**Step 1: Write the script**

Mirrors `windows/scripts/start-omniroute.ps1`:
- Flag `--port` (20128).
- `test_up()`: `curl -fs -m 4 http://localhost:$PORT/api/monitoring/health` returns 0.
- If up, exit 0.
- Resolve `omniroute` launcher: `npm bin -g` / `npm prefix -g`/bin, else `command -v omniroute`. Die if not found.
- On arm64, wrap start in `arch -x86_64`.
- Start detached: `nohup "$omni" serve >/dev/null 2>&1 &`.
- Poll up to 90s; exit 0 if healthy else 1.

**Step 2: Syntax check**

Run: `bash -n macos/scripts/start-omniroute.sh`
Expected: no output.

**Step 3: Commit**

```bash
git add macos/scripts/start-omniroute.sh
git commit -m "Add macOS start-omniroute script"
```

---

### Task 6: refresh-models.sh

**Files:**
- Create: `macos/scripts/refresh-models.sh`

**Step 1: Write the script**

Mirrors `windows/scripts/refresh-models.ps1`:
- Flags: `--port` (20128), `--stage-dir` (default `$HOME/omniroute-stage`; on macOS the global install is used so also probe global `node_modules` for `better-sqlite3`), `--list-only`.
- Query `/v1/models` with sentinel headers `Authorization: Bearer omniroute-no-auth` and `x-api-key: omniroute-no-auth`; filter ids matching `^(gh|github)/`.
- Normalize `gh/`→`github/`, unique, sort; print catalog. `--list-only` exits here.
- Build alias keys (base id + `.`↔`-` numeric variants), exclude `text-embedding`, add the `claude-haiku-4-5-20251001 → github/claude-haiku-4.5` special case.
- Write the same node CJS seeder (resolve `better-sqlite3` from global node_modules / omniroute dist; open `~/.omniroute/storage.sqlite`; clobber-guard non-`github/*` aliases; `INSERT OR REPLACE` into `key_value` namespace `modelAliases`).
- Run seeder under `arch -x86_64` on arm64 (fallback to plain `node` on x64).

**Step 2: Syntax check**

Run: `bash -n macos/scripts/refresh-models.sh`
Expected: no output.

**Step 3: Commit**

```bash
git add macos/scripts/refresh-models.sh
git commit -m "Add macOS refresh-models alias seeder"
```

---

### Task 7: install-autostart.sh (launchd)

**Files:**
- Create: `macos/scripts/install-autostart.sh`

**Step 1: Write the script**

- Flags: `--port` (20128), `--label` (`dev.omniroute.server`), `--uninstall`.
- Plist path: `$HOME/Library/LaunchAgents/<label>.plist`.
- `--uninstall`: `launchctl bootout gui/$UID "$plist" 2>/dev/null || true`; `rm -f "$plist"`; report.
- Install: resolve `pwsh`? No — call the bash `start-omniroute.sh` via absolute path (resolved from this script's dir) with `--port`. Write a plist with `Label`, `ProgramArguments` = `[/bin/bash, <abs>/start-omniroute.sh, --port, <port>]`, `RunAtLoad=true`, `KeepAlive=true` (or `KeepAlive.SuccessfulExit=false`), stdout/stderr to a log under `$HOME/.omniroute/`.
- Load: `launchctl bootout gui/$UID "$plist" 2>/dev/null || true; launchctl bootstrap gui/$UID "$plist"`.
- Print manage hints (`launchctl kickstart`, `--uninstall`).

**Step 2: Syntax check**

Run: `bash -n macos/scripts/install-autostart.sh`
Expected: no output.

**Step 3: Commit**

```bash
git add macos/scripts/install-autostart.sh
git commit -m "Add macOS launchd autostart script"
```

---

### Task 8: setup-omniroute.sh

**Files:**
- Create: `macos/scripts/setup-omniroute.sh`

**Step 1: Write the script**

Mirrors `windows/scripts/setup-omniroute.ps1`, orchestrating the pieces above:
- Flags: `--model`, `--stage-dir`, `--port`, `--x64-node-version`, `--no-launch`, `--accept-routing-change`.
- Prereq: `command -v node` and `command -v npm` (die with Homebrew/nvm hint).
- Arch: if arm64, run `ensure-x64-node.sh`, parse `NODE_DIR`/`NODE_EXE`, prepend `NODE_DIR` to `PATH`, set an `OMNI_ARCH_PREFIX=(arch -x86_64)` used for node/omniroute invocations.
- Install: `npm install -g omniroute --no-fund --no-audit`; verify `command -v omniroute`.
- Start server via `start-omniroute.sh --port`.
- Copilot check: poll `/v1/models`; if zero `github/*`, `open http://localhost:$PORT/dashboard/oauth`, `read -r` ENTER, re-check.
- Seed aliases via `refresh-models.sh --port --stage-dir`.
- Routing disclaimer + confirm pause (skip if `--accept-routing-change` or non-interactive), then `configure-claude-routing.sh --port --model`.
- Summary; launch `claude` unless `--no-launch`.

**Step 2: Syntax check**

Run: `bash -n macos/scripts/setup-omniroute.sh`
Expected: no output.

**Step 3: Commit**

```bash
git add macos/scripts/setup-omniroute.sh
git commit -m "Add macOS setup-omniroute orchestrator"
```

---

### Task 9: bootstrap.sh

**Files:**
- Create: `macos/bootstrap.sh`

**Step 1: Write the script**

Mirrors `windows/bootstrap.ps1`:
- Flags: `--model`, `--port`, `--x64-node-version`, `--no-autostart`, `--no-launch`, `--accept-routing-change`.
- Resolve `scripts/` relative to `$0` dir. Verify `setup-omniroute.sh` + `install-autostart.sh` exist.
- Deferred launch: if launching and autostart both enabled, pass `--no-launch` to setup, then re-launch `claude` after autostart.
- Run setup with mapped flags; then autostart unless `--no-autostart`; final message.

**Step 2: Syntax check**

Run: `bash -n macos/bootstrap.sh`
Expected: no output.

**Step 3: Make scripts executable**

```bash
chmod +x macos/bootstrap.sh macos/scripts/*.sh
git update-index --chmod=+x macos/bootstrap.sh macos/scripts/*.sh
```

**Step 4: Commit**

```bash
git add macos/bootstrap.sh
git commit -m "Add macOS bootstrap entrypoint"
```

---

### Task 10: Update list-models skill for OS detection

**Files:**
- Modify: `.claude/skills/list-models/SKILL.md`

**Step 1: Read current SKILL.md**

Understand how it invokes `refresh-models.ps1 -ListOnly`.

**Step 2: Update to OS-detect**

Instruct: on Windows run `windows/scripts/refresh-models.ps1 -ListOnly`; on macOS run `macos/scripts/refresh-models.sh --list-only`. Update any path that assumed root-level `scripts/`.

**Step 3: Commit**

```bash
git add .claude/skills/list-models/SKILL.md
git commit -m "Update list-models skill for macOS + new paths"
```

---

### Task 11: README — split Windows/macOS + fix moved paths

**Files:**
- Modify: `README.md`

**Step 1: Restructure README**

- Retitle to cover both OSes.
- Add a top intro, then two sections: **Windows** (update all `scripts/…` / `bootstrap.ps1` paths to `windows/…`) and **macOS** (quick start `bash macos/bootstrap.sh`, options table, launchd management, troubleshooting incl. Rosetta).
- Note macOS scripts are authored-but-pending-hardware-validation.
- Update the Contents tables per OS.

**Step 2: Verify no stale root-level path references**

```bash
grep -nE '\.\\scripts\\|\./scripts/|bootstrap\.ps1' README.md
```
Expected: all point at `windows/` or `macos/`, none at the old root.

**Step 3: Commit**

```bash
git add README.md
git commit -m "Document macOS setup and update moved Windows paths"
```

---

### Task 12: Final verification

**Step 1: Syntax-check all macOS scripts**

```bash
for f in macos/bootstrap.sh macos/scripts/*.sh; do bash -n "$f" && echo "OK $f"; done
```
Expected: `OK` for every file.

**Step 2: Confirm tree + clean status**

Run: `git status` and `ls -R windows macos`
Expected: clean tree; `windows/` and `macos/` fully populated.

**Step 3: Hand off for Mac validation**

Report to the user: scripts authored + syntax-checked; end-to-end run on a Mac is the remaining validation step (`bash macos/bootstrap.sh`).
