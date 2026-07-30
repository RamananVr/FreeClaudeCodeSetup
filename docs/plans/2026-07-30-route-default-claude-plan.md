# Implementation Plan — Route Default `claude` Through OmniRoute

Design: `2026-07-30-route-default-claude-design.md`

## Task 1 — Create `scripts/configure-claude-routing.ps1`

- `param([int]$Port = 20128, [string]$Model = "github/claude-opus-4.8", [string]$SettingsPath)`.
- Resolve `$SettingsPath`: if not passed, use `$env:CLAUDE_CONFIG_DIR\settings.json` when
  `CLAUDE_CONFIG_DIR` is set, else `$HOME\.claude\settings.json`.
- Ensure the parent dir exists.
- Load existing settings: if file exists, `Get-Content -Raw | ConvertFrom-Json`; on parse
  failure, `throw` naming the file (do not overwrite). If absent, start from `@{}`.
- Back up once: if the file exists and no `settings.json.bak` exists yet, copy it.
- Build/merge the `env` object:
  - Ensure an `env` property exists (create if missing), preserving existing keys.
  - Set `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` (= `$Model`),
    `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"`.
  - Remove `ANTHROPIC_API_KEY` from `env` if present.
- Write back with `ConvertTo-Json -Depth 20` (UTF-8). Handle the PSCustomObject-vs-hashtable
  merge carefully so unrelated keys survive.
- Emit a one-line confirmation with the settings path.

## Task 2 — Wire into `setup-omniroute.ps1`

- Add `[switch]$AcceptRoutingChange` to the param block.
- After the Copilot-connection section (6) and alias seeding (6.5), add a new section:
  - Print the 3-line disclaimer (design doc).
  - If not `$AcceptRoutingChange` and not `$NoLaunch` and the host is interactive
    (`[Environment]::UserInteractive` and `-not [Console]::IsInputRedirected`), `Read-Host`
    to pause. Otherwise proceed without blocking.
  - Call `configure-claude-routing.ps1 -Port $Port -Model $Model`.
- Change the alias/model seeding so the `/model` picker gets `-All` (all providers
  visible). If seeding is done inline, adjust; if via `seed-omniroute-models.ps1`, pass
  `-All`. (Confirm which mechanism this repo uses — the alias-seeder is inline; the
  picker cache is the separate seed script. Seed picker with `-All`.)
- **Remove section 4** (the `claude-omni.ps1` / `claude-omni.cmd` generation) entirely.
- Update the summary block: launcher line becomes `claude`; usage examples use `claude`.
- Final launch: replace `& (Join-Path $prefix "claude-omni.cmd")` with `& claude` (guarded
  by `-NoLaunch`).

## Task 3 — Update `bootstrap.ps1`

- Add `[switch]$AcceptRoutingChange`; forward into `$setupArgs` when set.
- Replace the deferred `& claude-omni` re-launch with `& claude`.
- Summary text: `Launch: claude`.

## Task 4 — Update `README.md`

- Replace `claude-omni` references with `claude` throughout (workarounds bullet, Contents,
  Quick start, usage).
- Add `scripts/configure-claude-routing.ps1` to the Contents table.
- Add a short "What this changes" note: default `claude` now routes to Copilot; prior
  `settings.json` backed up to `settings.json.bak`; other connected providers show in
  `/model`.

## Task 5 — Verify

- Parse-check all scripts (`[Parser]::ParseFile`).
- Unit-style test of the configurator against a temp `-SettingsPath`:
  - No file → creates `env` block with all 4 keys.
  - Pre-existing unrelated keys → survive; `.bak` created once; re-run makes no further
    `.bak` and leaves file stable (idempotent).
  - Pre-existing `ANTHROPIC_API_KEY` in `env` → removed.
- Grep the repo for any remaining `claude-omni` references (should be zero after Task 2–4).

## Commit / PR

- Logical commits (configurator, setup wiring + claude-omni removal, bootstrap, README).
- Push to `main` (token-injected) per established workflow, or branch+PR if review wanted.
