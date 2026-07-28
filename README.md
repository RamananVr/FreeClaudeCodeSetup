# OmniRoute + Claude Code Setup (Windows)

Scripts to install [OmniRoute](https://omniroute.dev) on Windows, wire **Claude Code** to
route through OmniRoute → **GitHub Copilot**, and keep the router running so a
`claude-omni` launcher always has a live backend.

These scripts encode several hard-won Windows workarounds:

- The direct `npm install -g omniroute` fails because a transitive dep pins
  `yuku-ast@0.6.5`, which is missing from some npm feeds. Setup installs into a staging
  dir with an `overrides` pin, then junctions it into the global `node_modules`.
- `omniroute launch` uses `spawn("claude")` with no shell, which fails on Windows (the
  bin is `claude.ps1`/`claude.cmd`). Setup writes a `claude-omni` wrapper that sets the
  right env and invokes the real `claude` binary directly.
- On `win32-arm64` machines, OmniRoute's native deps (`wreq-js`) ship no arm64 binary;
  run under an x64 Node via emulation.

## Contents

| Script | Purpose |
| --- | --- |
| `bootstrap.ps1`                 | One command: run setup then register autostart. Start here. |
| `scripts/setup-omniroute.ps1`   | Install OmniRoute, create the `claude-omni` launcher, start the server, connect Copilot, seed model aliases. |
| `scripts/start-omniroute.ps1`   | Idempotently start the server if it is not already up (health-checks first). |
| `scripts/install-autostart.ps1` | Register/remove a per-user logon task that keeps the server running. |

## Requirements

- Windows 10/11, PowerShell 7 (`pwsh`) recommended.
- Node.js on `PATH` (x64 recommended — see arm64 note above).
- Claude Code installed (`claude` on `PATH`).
- A GitHub Copilot subscription (connected via the OmniRoute dashboard on first run).

## Quick start

```powershell
# One command: install + create launcher + start server + register autostart, then launch.
pwsh -File .\bootstrap.ps1
```

Or run the steps individually:

```powershell
# 1. Install OmniRoute + create the claude-omni launcher + start the server.
pwsh -File .\scripts\setup-omniroute.ps1

# 2. Make the server start automatically at logon (recommended).
pwsh -File .\scripts\install-autostart.ps1

# 3. Launch Claude Code routed through OmniRoute -> Copilot.
claude-omni
```

### Common options

```powershell
# Bootstrap with a specific model and no interactive launch.
pwsh -File .\bootstrap.ps1 -Model github/claude-opus-4.8 -NoLaunch

# Bootstrap setup only, skip the logon task.
pwsh -File .\bootstrap.ps1 -NoAutostart

# Pick the main model (default: auto/best-coding, router picks per request).
pwsh -File .\scripts\setup-omniroute.ps1 -Model github/claude-opus-4.8

# Set up everything but do not open an interactive session.
pwsh -File .\scripts\setup-omniroute.ps1 -NoLaunch

# Refresh Azure Artifacts feed auth before installing (fixes TLS/401 errors).
pwsh -File .\scripts\setup-omniroute.ps1 -RefreshFeedAuth

# Use a non-default port everywhere.
pwsh -File .\scripts\setup-omniroute.ps1 -Port 20200
pwsh -File .\scripts\install-autostart.ps1 -Port 20200
```

## Using the launcher

```powershell
claude-omni                                   # opus via OmniRoute -> Copilot
claude-omni -p "prompt"                        # headless
claude-omni --model github/claude-sonnet-5     # per-run model override
```

`claude-omni` uses an isolated Claude Code profile at
`~/.claude/profiles/omniroute`, so it does **not** touch your normal `claude`
login/credentials.

## Autostart management

```powershell
Start-ScheduledTask -TaskName "OmniRoute Server"          # start now
pwsh -File .\scripts\install-autostart.ps1 -Uninstall     # remove the task
```

## Troubleshooting

- **`claude-omni` starts but no model responds / it hangs:** the OmniRoute server is
  probably down. Run `pwsh -File .\scripts\start-omniroute.ps1` (or `omniroute serve`) and
  retry. The server takes ~20–30s to become healthy on a cold start.
- **No Copilot models:** open `http://localhost:20128/dashboard/oauth` and connect
  GitHub Copilot.
- **`better-sqlite3` / native module errors:** run `omniroute runtime repair`, or use a
  newer Node LTS (24.14.1+ recommended).

## License

MIT — see [LICENSE](LICENSE).
