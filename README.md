# OmniRoute + Claude Code Setup

Scripts to install [OmniRoute](https://omniroute.dev) and route the default **`claude`**
command through OmniRoute → **GitHub Copilot**, keeping the router running so `claude`
always has a live backend.

The repo is split by operating system:

| Directory | Platform | Entry point |
| --- | --- | --- |
| [`windows/`](#windows) | Windows 10/11 (x64 / arm64) | `windows\bootstrap.ps1` |
| [`macos/`](#macos)     | macOS (Intel / Apple Silicon) | `macos/bootstrap.sh` |

Both do the same thing: install OmniRoute, route the default `claude` through it via
Claude Code's `settings.json`, start the local server, connect GitHub Copilot, seed
model aliases, and register an autostart agent (Scheduled Task on Windows, launchd on
macOS).

## What this changes

- Your default `claude` now routes to GitHub Copilot via OmniRoute (default model
  `github/claude-opus-4.8`).
- Your prior `settings.json` is backed up to `settings.json.bak` — revert anytime by
  restoring it.
- Other connected providers show up via gateway model discovery, so you can switch
  in-session with `/model <id>` (see [Selecting a Copilot model](#selecting-a-copilot-model)).

---

## Windows

Encodes several hard-won Windows workarounds:

- The direct `npm install -g omniroute` fails because a transitive dep pins
  `yuku-ast@0.6.5`, which is missing from some npm feeds. Setup installs into a staging
  dir with an `overrides` pin, then junctions it into the global `node_modules`.
- Routing lives in Claude Code's supported `settings.json` `env` block (no wrapper), so
  plain `claude` routes through OmniRoute → Copilot. Setup shows a disclaimer and backs
  up your prior `settings.json` first.
- On `win32-arm64` machines, OmniRoute's native deps (`wreq-js`) ship no arm64 binary.
  Setup detects ARM64 and automatically downloads a pinned, portable x64 Node (to
  `~/.omniroute/node-x64`, checksum-verified), runs the OmniRoute install under it, and
  bakes its absolute path into the generated `omniroute` shims.

### Requirements

- Windows 10/11, PowerShell 7 (`pwsh`) recommended.
- Node.js on `PATH`. On ARM64, setup auto-provisions an x64 Node for OmniRoute.
- Claude Code installed (`claude` on `PATH`).
- A GitHub Copilot subscription (connected via the OmniRoute dashboard on first run).

### Contents

| Script | Purpose |
| --- | --- |
| `windows\bootstrap.ps1`                      | One command: run setup then register autostart. Start here. |
| `windows\scripts\setup-omniroute.ps1`        | Install OmniRoute, route the default `claude`, start the server, connect Copilot, seed model aliases. |
| `windows\scripts\refresh-models.ps1`         | Discover connected Copilot models from `/v1/models` and (re-)seed bare-id aliases. Run standalone anytime the catalog changes. |
| `windows\scripts\configure-claude-routing.ps1` | Merge the OmniRoute routing `env` block into `settings.json` (idempotent; backs up to `.bak`). |
| `windows\scripts\ensure-x64-node.ps1`        | On ARM64, provision a pinned portable x64 Node (checksum-verified). No-op on x64. |
| `windows\scripts\start-omniroute.ps1`        | Idempotently start the server if it is not already up. |
| `windows\scripts\install-autostart.ps1`      | Register/remove a per-user logon task that keeps the server running. |
| `windows\scripts\claude-mcp-shim.cmd`        | (Agency users) Stand-in `claude` binary that repairs Agency's MCP config. |
| `windows\scripts\fix-mcp-config.ps1`         | Helper for the shim: strips the invalid string `tools` field Agency adds to http MCP servers. |

### Quick start

```powershell
# One command: install + route claude + start server + register autostart, then launch.
pwsh -File .\windows\bootstrap.ps1
```

Or run the steps individually:

```powershell
pwsh -File .\windows\scripts\setup-omniroute.ps1      # install + route + start
pwsh -File .\windows\scripts\install-autostart.ps1    # autostart at logon
claude                                                # launch (routed)
```

### Common options

```powershell
# Bootstrap with a specific model and no interactive launch.
pwsh -File .\windows\bootstrap.ps1 -Model github/claude-opus-4.8 -NoLaunch

# Bootstrap setup only, skip the logon task.
pwsh -File .\windows\bootstrap.ps1 -NoAutostart

# Skip the confirmation pause before routing your default claude (unattended installs).
pwsh -File .\windows\bootstrap.ps1 -AcceptRoutingChange

# Pin a different x64 Node version on ARM64.
pwsh -File .\windows\bootstrap.ps1 -X64NodeVersion 22.11.0

# Refresh Azure Artifacts feed auth before installing (fixes TLS/401 errors).
pwsh -File .\windows\scripts\setup-omniroute.ps1 -RefreshFeedAuth

# Use a non-default port everywhere.
pwsh -File .\windows\scripts\setup-omniroute.ps1 -Port 20200
pwsh -File .\windows\scripts\install-autostart.ps1 -Port 20200
```

### Autostart management

```powershell
Start-ScheduledTask -TaskName "OmniRoute Server"                   # start now
pwsh -File .\windows\scripts\install-autostart.ps1 -Uninstall      # remove the task
```

---

## macOS

> **Note:** the macOS scripts are authored and syntax-checked but pending end-to-end
> validation on Apple hardware. Please report issues.

The macOS port uses native `bash` scripts and mirrors the Windows flow, with a few
platform differences:

- A plain `npm install -g omniroute` (assumes the public npm registry, where the
  dependency resolves — no staging/junction workaround needed).
- Autostart uses a **launchd** LaunchAgent (`~/Library/LaunchAgents/dev.omniroute.server.plist`)
  instead of a Scheduled Task.
- On **Apple Silicon (arm64)**, OmniRoute's native deps may lack arm64 binaries, so setup
  provisions a pinned, checksum-verified portable **x64 Node** (to `~/.omniroute/node-x64`)
  and runs OmniRoute under **Rosetta 2** (`arch -x86_64`). Rosetta must be installed
  (`softwareupdate --install-rosetta --agree-to-license`).

### Requirements

- macOS (Intel or Apple Silicon). On Apple Silicon, Rosetta 2 (setup prompts if missing).
- Node.js + npm on `PATH` (`brew install node`, or nvm).
- Claude Code installed (`claude` on `PATH`).
- A GitHub Copilot subscription (connected via the OmniRoute dashboard on first run).

### Contents

| Script | Purpose |
| --- | --- |
| `macos/bootstrap.sh`                      | One command: run setup then register autostart. Start here. |
| `macos/scripts/setup-omniroute.sh`        | Install OmniRoute, route the default `claude`, start the server, connect Copilot, seed model aliases. |
| `macos/scripts/refresh-models.sh`         | Discover connected Copilot models from `/v1/models` and (re-)seed bare-id aliases. Run standalone anytime the catalog changes. |
| `macos/scripts/configure-claude-routing.sh` | Merge the OmniRoute routing `env` block into `settings.json` (idempotent; backs up to `.bak`). |
| `macos/scripts/ensure-x64-node.sh`        | On Apple Silicon, provision a pinned portable x64 Node under Rosetta (checksum-verified). No-op on Intel. |
| `macos/scripts/start-omniroute.sh`        | Idempotently start the server if it is not already up. |
| `macos/scripts/install-autostart.sh`      | Install/remove a launchd LaunchAgent that keeps the server running. |
| `macos/scripts/_common.sh`                | Shared logging/arch helpers sourced by the other scripts. |

### Quick start

```bash
# One command: install + route claude + start server + register autostart, then launch.
bash ./macos/bootstrap.sh
```

Or run the steps individually:

```bash
bash ./macos/scripts/setup-omniroute.sh       # install + route + start
bash ./macos/scripts/install-autostart.sh     # autostart at login (launchd)
claude                                         # launch (routed)
```

### Common options

```bash
# Bootstrap with a specific model and no interactive launch.
bash ./macos/bootstrap.sh --model github/claude-opus-4.8 --no-launch

# Bootstrap setup only, skip the launchd agent.
bash ./macos/bootstrap.sh --no-autostart

# Skip the confirmation pause before routing your default claude (unattended installs).
bash ./macos/bootstrap.sh --accept-routing-change

# Pin a different x64 Node version on Apple Silicon.
bash ./macos/bootstrap.sh --x64-node-version 22.11.0

# Use a non-default port everywhere.
bash ./macos/scripts/setup-omniroute.sh --port 20200
bash ./macos/scripts/install-autostart.sh --port 20200
```

### Autostart management

```bash
launchctl kickstart -k "gui/$(id -u)/dev.omniroute.server"     # start now
bash ./macos/scripts/install-autostart.sh --uninstall          # remove the agent
```

---

## Using Claude Code

```bash
claude                          # opus via OmniRoute -> Copilot
claude -p "prompt"              # headless
# In-session: run /model <id> to switch to any other connected provider.
```

Routing is written into your Claude Code `settings.json` `env` block. To revert, restore
`settings.json.bak` (or remove the OmniRoute keys from the `env` block).

### Selecting a Copilot model

The in-session `/model` **arrow-key menu** shows only Claude Code's built-in entries — it
does not enumerate the connected Copilot catalog. But you can switch to **any** discovered
Copilot model two ways:

```bash
# At launch:
claude --model github/gpt-5.5 -p "hello"

# Mid-session: type the full id as an argument to /model (no restart):
#   /model github/gpt-5.5
```

To see the full discovered list without touching aliases:

```powershell
# Windows
pwsh -File .\windows\scripts\refresh-models.ps1 -ListOnly
```

```bash
# macOS
bash ./macos/scripts/refresh-models.sh --list-only
```

In a Claude Code session in this repo you can also just ask "list models" — the bundled
`list-models` skill runs that for you. A typed `/model` switch applies to the current
session; the OmniRoute routing default in `settings.json` applies on the next launch.

### Refreshing the model list

Setup seeds bare-id aliases so Claude Code's model ids route unambiguously to Copilot. If
GitHub Copilot adds or removes models, re-seed the catalog:

```powershell
# Windows
pwsh -File .\windows\scripts\refresh-models.ps1
```

```bash
# macOS
bash ./macos/scripts/refresh-models.sh
```

This is idempotent and only touches aliases that are new or already point at a `github/*`
model — aliases owned by other providers are left untouched.

## Troubleshooting

- **`claude` starts but no model responds / it hangs:** the OmniRoute server is probably
  down. Run the `start-omniroute` script for your OS (or `omniroute serve`) and retry. The
  server takes ~20–30s to become healthy on a cold start.
- **No Copilot models:** open `http://localhost:20128/dashboard/oauth` and connect GitHub
  Copilot.
- **Want direct Anthropic access back:** restore `settings.json.bak` over your
  `settings.json`.
- **`better-sqlite3` / native module errors:** run `omniroute runtime repair`, or use a
  newer Node LTS.
- **(macOS, Apple Silicon) install/build errors mentioning arm64:** ensure Rosetta 2 is
  installed (`softwareupdate --install-rosetta --agree-to-license`), then re-run setup —
  it provisions and uses a portable x64 Node.
- **(Windows) `agency claude` fails with `exit code 9009`:** point Agency's
  `AGENCY_CLAUDE_PATH` at `windows\scripts\claude-mcp-shim.cmd` (keep `fix-mcp-config.ps1`
  beside it) — the shim trims blank values and auto-detects the newest `claude.exe`.

## License

MIT — see [LICENSE](LICENSE).
