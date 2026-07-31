# OmniRoute + Claude Code Setup (Windows)

Scripts to install [OmniRoute](https://omniroute.dev) on Windows and route the default
**`claude`** command through OmniRoute → **GitHub Copilot**, keeping the router running so
`claude` always has a live backend.

These scripts encode several hard-won Windows workarounds:

- The direct `npm install -g omniroute` fails because a transitive dep pins
  `yuku-ast@0.6.5`, which is missing from some npm feeds. Setup installs into a staging
  dir with an `overrides` pin, then junctions it into the global `node_modules`.
- Routing lives in Claude Code's supported `settings.json` `env` block (no wrapper), so
  plain `claude` routes through OmniRoute → Copilot. Because this changes your default
  `claude`, setup shows a disclaimer and backs up your prior `settings.json` first.
- On `win32-arm64` machines, OmniRoute's native deps (`wreq-js`) ship no arm64 binary.
  Setup detects ARM64 and automatically downloads a pinned, portable x64 Node (to
  `~/.omniroute/node-x64`, checksum-verified), runs the OmniRoute install under it, and
  bakes its absolute path into the generated `omniroute` shims — no manual steps, and
  your machine's default arm64 Node is left untouched.

## What this changes

- Your default `claude` now routes to GitHub Copilot via OmniRoute (default model
  `github/claude-opus-4.8`).
- Your prior `settings.json` is backed up to `settings.json.bak` — revert anytime by
  restoring it.
- Other connected providers show up in the in-session `/model` picker (gateway model
  discovery is enabled), so you can switch without leaving Claude Code.

## Contents

| Script | Purpose |
| --- | --- |
| `bootstrap.ps1`                      | One command: run setup then register autostart. Start here. |
| `scripts/setup-omniroute.ps1`        | Install OmniRoute, route the default `claude` (settings.json), start the server, connect Copilot, seed model aliases. |
| `scripts/configure-claude-routing.ps1` | Merge the OmniRoute routing `env` block into `settings.json` (idempotent; backs up to `.bak`). |
| `scripts/ensure-x64-node.ps1`        | On ARM64, provision a pinned portable x64 Node (checksum-verified). No-op on x64. |
| `scripts/start-omniroute.ps1`        | Idempotently start the server if it is not already up (health-checks first). |
| `scripts/install-autostart.ps1`      | Register/remove a per-user logon task that keeps the server running. |
| `scripts/claude-mcp-shim.cmd`        | (Agency users) Stand-in `claude` binary that repairs Agency's MCP config and resolves the real `claude.exe` robustly. |
| `scripts/fix-mcp-config.ps1`         | Helper for the shim: strips the invalid string `tools` field Agency adds to http MCP servers. |

## Requirements

- Windows 10/11, PowerShell 7 (`pwsh`) recommended.
- Node.js on `PATH`. On ARM64, setup auto-provisions an x64 Node for OmniRoute (see the
  arm64 note above); your host arm64 Node is fine as the default.
- Claude Code installed (`claude` on `PATH`).
- A GitHub Copilot subscription (connected via the OmniRoute dashboard on first run).

To pin a different x64 Node version on ARM64:
`pwsh -File .\bootstrap.ps1 -X64NodeVersion 22.11.0`

## Quick start

```powershell
# One command: install + route claude + start server + register autostart, then launch.
pwsh -File .\bootstrap.ps1
```

Or run the steps individually:

```powershell
# 1. Install OmniRoute + route the default claude + start the server.
pwsh -File .\scripts\setup-omniroute.ps1

# 2. Make the server start automatically at logon (recommended).
pwsh -File .\scripts\install-autostart.ps1

# 3. Launch Claude Code (now routed through OmniRoute -> Copilot).
claude
```

### Common options

```powershell
# Bootstrap with a specific model and no interactive launch.
pwsh -File .\bootstrap.ps1 -Model github/claude-opus-4.8 -NoLaunch

# Bootstrap setup only, skip the logon task.
pwsh -File .\bootstrap.ps1 -NoAutostart

# Skip the confirmation pause before routing your default claude (for unattended installs).
pwsh -File .\bootstrap.ps1 -AcceptRoutingChange

# Pick the main model (default: github/claude-opus-4.8; switch in-session via /model).
pwsh -File .\scripts\setup-omniroute.ps1 -Model github/claude-sonnet-5

# Set up everything but do not open an interactive session.
pwsh -File .\scripts\setup-omniroute.ps1 -NoLaunch

# Refresh Azure Artifacts feed auth before installing (fixes TLS/401 errors).
pwsh -File .\scripts\setup-omniroute.ps1 -RefreshFeedAuth

# Use a non-default port everywhere.
pwsh -File .\scripts\setup-omniroute.ps1 -Port 20200
pwsh -File .\scripts\install-autostart.ps1 -Port 20200
```

## Using Claude Code

```powershell
claude                          # opus via OmniRoute -> Copilot
claude -p "prompt"              # headless
# In-session: run /model to switch to any other connected provider.
```

Routing is written into your Claude Code `settings.json` `env` block. To revert, restore
`settings.json.bak` (or remove the OmniRoute keys from the `env` block).

## Autostart management

```powershell
Start-ScheduledTask -TaskName "OmniRoute Server"          # start now
pwsh -File .\scripts\install-autostart.ps1 -Uninstall     # remove the task
```

## Troubleshooting

- **`claude` starts but no model responds / it hangs:** the OmniRoute server is
  probably down. Run `pwsh -File .\scripts\start-omniroute.ps1` (or `omniroute serve`) and
  retry. The server takes ~20–30s to become healthy on a cold start.
- **No Copilot models:** open `http://localhost:20128/dashboard/oauth` and connect
  GitHub Copilot.
- **Want direct Anthropic access back:** restore `settings.json.bak` over your
  `settings.json`.
- **`better-sqlite3` / native module errors:** run `omniroute runtime repair`, or use a
  newer Node LTS (24.14.1+ recommended).
- **`agency claude` fails with `exit code 9009` / "resolved claude binary does not exist":**
  Agency can inject `OMNI_REAL_CLAUDE` as a blank/whitespace value, which the older shim
  treated as a real path. Point Agency's `AGENCY_CLAUDE_PATH` at
  `scripts\claude-mcp-shim.cmd` (keep `fix-mcp-config.ps1` beside it) — the shim trims the
  value and auto-detects the newest `~\.claude-cli\<version>\claude.exe`.

## License

MIT — see [LICENSE](LICENSE).
