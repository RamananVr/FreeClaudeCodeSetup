# Route Default `claude` Through OmniRoute — Design

**Date:** 2026-07-30
**Status:** Approved
**Scope:** Internal team distribution (Windows, PowerShell), Copilot-only

## Problem

Today the repo installs a `claude-omni` wrapper: a separate launcher that sets OmniRoute
routing env vars per-invocation and uses an isolated `~/.claude/profiles/omniroute`
profile, leaving the normal `claude` command pointed at Anthropic directly.

For a **Copilot-only** team, that indirection is unnecessary. Nobody needs a
direct-to-Anthropic `claude`, so maintaining a second command (and a second profile) adds
friction without benefit. Teammates should just run `claude` and have it route to
Copilot.

## Goal

Make the plain `claude` command route through OmniRoute → GitHub Copilot with **no
wrapper**, by writing routing config into Claude Code's supported `settings.json` `env`
block. Default to a Copilot model, but surface every provider OmniRoute exposes in the
`/model` picker so a teammate can switch in-session if another provider is connected.

## Decisions

- **Config surface = Claude Code `settings.json` `env` block** (not persistent User env
  vars, not an aliased shim). It's the tool's supported config, inspectable,
  version-controllable, and easy to revert.
- **Default config dir** (not a separate `omniroute` profile). In a Copilot-only world
  there is no "normal" login to protect.
- **Copilot default, others visible** — pin `ANTHROPIC_MODEL = github/claude-opus-4.8`
  for a deterministic default, but seed the `/model` picker with `-All` so other
  connected providers are selectable in-session.
- **Remove `claude-omni` entirely** — one obvious path (`claude`). No fallback wrapper.
- **Disclaimer at setup time** — because this changes the user's *default* `claude`,
  setup prints a clear notice, backs up the prior `settings.json`, and (interactively)
  pauses for confirmation.

## Architecture

### New: `scripts/configure-claude-routing.ps1`

Merges a routing `env` block into `settings.json`.

- Target file: `$CLAUDE_CONFIG_DIR\settings.json` if that env var is set, else
  `$HOME\.claude\settings.json`.
- **Merge, don't overwrite:** read existing JSON (if any), set only the routing keys,
  preserve everything else. Idempotent — re-running yields the same file.
- Keys written under `env`:
  - `ANTHROPIC_BASE_URL = http://localhost:<Port>`
  - `ANTHROPIC_AUTH_TOKEN = omniroute-no-auth`
  - `ANTHROPIC_MODEL = <Model>` (default `github/claude-opus-4.8`)
  - `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = 1`
- Remove `ANTHROPIC_API_KEY` from the `env` block if present (it would override the
  routed token).
- On the first write, back up the existing file to `settings.json.bak` (only if no
  `.bak` already exists, so repeated runs don't clobber the original backup).
- Params: `-Port`, `-Model`, `-SettingsPath` (override for tests).

### `/model` picker seeding

Call the existing seed step with `-All` instead of `-Prefix 'gh/'`, so the picker lists
Copilot **and** any other connected provider. Copilot remains the pinned default via
`ANTHROPIC_MODEL`; the picker is the escape hatch.

### `setup-omniroute.ps1` changes

- After the server + Copilot-connection steps, **before** writing routing config, print a
  disclaimer and pause:
  - Interactive host → `Read-Host` "Press ENTER to continue, or Ctrl+C to cancel".
  - Non-interactive (or `-AcceptRoutingChange` / `-NoLaunch`) → print notice, do not block.
- Call `configure-claude-routing.ps1`.
- Seed `/model` with `-All`.
- **Delete the `claude-omni.cmd/.ps1` generation block** (section 4).
- Final launch step calls plain `claude` (respecting `-NoLaunch`).
- Add `-AcceptRoutingChange` switch to skip the pause explicitly.

### `bootstrap.ps1` changes

- Forward `-AcceptRoutingChange` to setup.
- Summary/messaging refers to `claude`, not `claude-omni`.

### README changes

- Replace all `claude-omni` references with `claude`.
- Document: this routes your default `claude` to Copilot; prior `settings.json` is backed
  up to `settings.json.bak`; other connected providers appear in `/model`.

## Disclaimer text (setup)

```
[!] This configures your DEFAULT `claude` to route through OmniRoute -> GitHub Copilot.
[!] After setup, running `claude` uses Copilot, not direct Anthropic access.
[!] Your previous settings.json is backed up to settings.json.bak (revert anytime).
```

## Error handling

- Malformed existing `settings.json` → fail with a clear message naming the file; do not
  silently discard it.
- Missing config dir → create it.
- Ambiguous bare model IDs across providers → already handled by the existing
  alias-seeder; keep it and keep IDs provider-prefixed.

## Testing

- Fresh machine (no `settings.json`): setup writes the `env` block; `claude` routes to
  Copilot; `/model` lists multiple providers.
- Existing `settings.json` with unrelated keys: those keys survive; `.bak` created once;
  routing keys added.
- Idempotent re-run: file unchanged after first configuration; no second `.bak`.
- `ANTHROPIC_API_KEY` present beforehand: removed from the `env` block.
- Revert: restoring `.bak` returns `claude` to its prior behavior.

## Out of scope

- macOS/Linux.
- A mode toggle / wrapper fallback (explicitly removed — Copilot-only, one path).
- Changes to the ARM64 x64-Node provisioning (already shipped).
