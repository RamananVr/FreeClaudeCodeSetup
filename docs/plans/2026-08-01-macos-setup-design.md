# macOS Setup — Design

**Date:** 2026-08-01
**Status:** Approved
**Topic:** Port the Windows OmniRoute + Claude Code setup to macOS, restructuring the repo into per-OS subdirectories.

## Problem

The repo currently ships a Windows-only setup: PowerShell scripts that install OmniRoute, route the default `claude` command through OmniRoute → GitHub Copilot, keep the server running via a logon Scheduled Task, and seed model aliases. macOS users have no equivalent. We want the same end-to-end experience on macOS using native shell scripts.

## Decisions (from brainstorming)

- **Implementation:** native `bash`/`zsh` shell scripts (no PowerShell dependency on macOS).
- **Repo layout:** restructure into `windows/` and `macos/` subdirectories (option C). Existing Windows files move via `git mv` (content unchanged, history preserved).
- **Apple Silicon (arm64):** port the x64-Node fallback — provision a portable darwin-x64 Node and run OmniRoute under Rosetta 2, mirroring the Windows ARM64 workaround.
- **npm install:** plain `npm install -g omniroute` (assume the public npm registry where the dependency resolves; skip the Windows staging-dir + junction `yuku-ast` workaround).
- **Agency MCP shim:** skipped for macOS (not ported).
- **JSON merge:** use `node` (already a required dependency) for the idempotent `settings.json` merge — no new `jq` dependency.
- **Autostart:** `launchd` LaunchAgent instead of Task Scheduler.

## Repository structure

```
omniRouteSetup/
├── README.md                  # top-level: intro + Windows / macOS links
├── LICENSE
├── .gitignore
├── windows/
│   ├── bootstrap.ps1          # moved from root
│   └── scripts/               # moved from root scripts/
│       ├── setup-omniroute.ps1
│       ├── configure-claude-routing.ps1
│       ├── ensure-x64-node.ps1
│       ├── start-omniroute.ps1
│       ├── install-autostart.ps1
│       ├── refresh-models.ps1
│       ├── claude-mcp-shim.cmd
│       └── fix-mcp-config.ps1
├── macos/
│   ├── bootstrap.sh
│   └── scripts/
│       ├── setup-omniroute.sh
│       ├── configure-claude-routing.sh
│       ├── ensure-x64-node.sh
│       ├── start-omniroute.sh
│       ├── install-autostart.sh    # launchd
│       └── refresh-models.sh
├── .claude/skills/list-models/     # shared (cross-platform); SKILL.md OS-detects
└── docs/plans/
```

The Windows `bootstrap.ps1` resolves child scripts relative to `$PSScriptRoot`, and no script uses hardcoded intra-repo absolute paths, so moving `bootstrap.ps1` + `scripts/` together under `windows/` requires no content edits.

## macOS component design

### bootstrap.sh
Mirrors `bootstrap.ps1`. Runs `setup-omniroute.sh` then `install-autostart.sh`. Flags (getopts): `--model` (default `github/claude-opus-4.8`), `--port` (default `20128`), `--x64-node-version` (default matches Windows pin), `--no-autostart`, `--no-launch`, `--accept-routing-change`. Same deferred-launch logic (suppress interactive launch until autostart is registered, then re-launch). `set -euo pipefail`.

### setup-omniroute.sh
1. Prereq check: `node` + `npm` on PATH (else die with Homebrew/nvm hint).
2. Arch detection via `uname -m` → `arm64` vs `x86_64`. On arm64, call `ensure-x64-node.sh`, prepend its dir to `PATH` for this process, and run OmniRoute under `arch -x86_64`.
3. Install: plain `npm install -g omniroute`; verify `omniroute` resolves on PATH.
4. Start server (delegates to `start-omniroute.sh`).
5. Ensure Copilot connected: poll `/v1/models` with the `omniroute-no-auth` sentinel header; if zero `github/*` models, `open http://localhost:$PORT/dashboard/oauth` and prompt ENTER.
6. Seed model aliases via `refresh-models.sh`.
7. Route default `claude` (disclaimer + confirm pause) via `configure-claude-routing.sh`.
8. Summary + launch `claude` unless `--no-launch`.

### configure-claude-routing.sh
Merges the routing `env` block into `~/.claude/settings.json` (respects `$CLAUDE_CONFIG_DIR`). Keys: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`. Drops `ANTHROPIC_API_KEY`. Backs up to `settings.json.bak` once before first write. Idempotent merge via a small `node` script that preserves unrelated keys; refuses to overwrite malformed JSON.

### ensure-x64-node.sh
1. Arch via `uname -m`. If `x86_64` → no-op (host node/npm).
2. If `arm64`:
   - Ensure Rosetta 2 (`arch -x86_64 true` probe; if missing, instruct `softwareupdate --install-rosetta --agree-to-license`).
   - Download official `node-v$VER-darwin-x64.tar.gz` from `nodejs.org/dist`, verify SHA-256 against `SHASUMS256.txt`, extract to `~/.omniroute/node-x64/`.
   - Self-check: `arch -x86_64 <node> -p process.arch` reports `x64`.
   - Idempotent: reuse valid prior install.
3. Emit `NODE_DIR=` / `NODE_EXE=` lines (or temp file) for the caller to parse.

### start-omniroute.sh
Health-check `http://localhost:$PORT/api/monitoring/health`; if down, resolve the `omniroute` launcher from the npm global bin and start detached (`nohup ... &`), wrapped in `arch -x86_64` on arm64. Poll up to 90s. Idempotent.

### install-autostart.sh (launchd)
Writes `~/Library/LaunchAgents/dev.omniroute.server.plist` with `RunAtLoad` + `KeepAlive`, invoking `start-omniroute.sh` with the configured port. Loads via `launchctl bootstrap gui/$UID`. `--uninstall` runs `launchctl bootout` and removes the plist.

### refresh-models.sh
Same discovery logic as Windows: query `/v1/models`, filter `github/*`, dedupe `gh/`↔`github/`, build alias keys with `.`/`-` numeric variants, seed the SQLite DB (`~/.omniroute/storage.sqlite`) via the node CJS seeder (same seeder content, darwin paths, run under `arch -x86_64` on arm64). Clobber guard leaves non-`github/*` aliases intact. `--list-only` mode preserved.

### list-models skill
`SKILL.md` updated to OS-detect and run the `.ps1` on Windows / `.sh` on macOS.

## Error handling
- Every script: `set -euo pipefail`; colored `info/ok/warn/die` helpers mirroring the PS functions.
- Actionable failure hints: missing node → Homebrew/nvm; missing Rosetta → softwareupdate; malformed settings.json → refuse to overwrite (same as Windows).

## Testing
The macOS scripts are authored on a Windows host, so automated verification here is limited to `bash -n` syntax checks and review against the PowerShell originals. The user will validate end-to-end on a Mac. The README will note the macOS scripts are authored-but-pending-hardware-validation.

## Out of scope
- Agency MCP shim port.
- Windows staging-dir/junction `yuku-ast` workaround (macOS assumes plain global install works).
- A unified cross-OS dispatcher (each OS keeps its own entrypoint).
