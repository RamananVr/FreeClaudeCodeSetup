# Dynamic Copilot Model Discovery + Seeding — Design

**Date:** 2026-07-31
**Status:** Approved (design), pending implementation plan

## Problem

The `/model` picker in Claude Code only surfaces the Copilot models that have
seeded aliases. Today `setup-omniroute.ps1` (§6.5) seeds a **hardcoded** alias
table (a fixed opus/sonnet/haiku/fable list). Any Copilot model not in that
table does not appear/switch cleanly, and the list goes stale whenever GitHub
Copilot adds or removes models.

## Goals

1. **Setup-time (goal 3):** enumerate *all* connected Copilot (`github/*`)
   models from OmniRoute and seed aliases for every one, so the full catalog is
   available after install.
2. **In-session (goal 2):** the `/model` picker shows and switches to the full
   Copilot catalog without "Ambiguous model" errors.
3. **Both, shared logic:** setup seeds initially, and the same logic is exposed
   as a standalone refresh command to re-seed on demand.

Non-goals: changing routing/settings.json behavior; adding non-Copilot
providers; a full model-management UI.

## Chosen approach — A: Dynamic seeder built from `/v1/models`

Replace the hardcoded `aliases` object with dynamic discovery:

1. Query `http://localhost:$Port/v1/models` (existing no-auth sentinel header),
   filter `data[].id` to `^(gh|github)/`.
2. For each `github/<base>`, generate the bare-id alias keys Claude Code emits
   and map them all to the unambiguous `github/<base>` value.
3. Write to the `modelAliases` namespace in `~/.omniroute/storage.sqlite`
   (`INSERT OR REPLACE`, idempotent).

Extract this into a reusable `scripts/refresh-models.ps1` that both
`setup-omniroute.ps1` and the user can call.

Rejected alternatives:
- **B (raw ids only, no variant expansion):** simplest, but drops the
  dotted/hyphen/dated variants that the original hardcoded table existed to
  fix — would regress "Ambiguous model" errors.
- **C (dynamic + curated override map):** A plus a small hardcoded override for
  tricky ids (e.g. dated haiku id). Held in reserve — only folded in if the
  verification step proves specific undeliverable variants (like dated ids) are
  still required.

## Architecture & components

- **New:** `scripts/refresh-models.ps1`
  - Params: `-Port` (default 20128, matching setup), `-StageDir` (to locate
    OmniRoute's `better-sqlite3` and thus `storage.sqlite`).
  - Single source of truth for discovery + seeding.
  - Runnable standalone (re-seed anytime the Copilot catalog changes) or called
    by setup.
- **Changed:** `scripts/setup-omniroute.ps1`
  - Remove the inline §6.5 seeder block; call `refresh-models.ps1 -Port -StageDir`
    in its place.
- **Changed:** `README.md`
  - Add the new script to the Contents table; add a "refresh models" usage note.

### Flow

1. Query `/v1/models` → filter to `^(gh|github)/` → id list.
2. Generate CJS seeder over that id list; run under x64 Node (fallback host node)
   to load the native `better-sqlite3`.
3. Print seeded count + discovered model list.

## Alias-key generation (heuristic)

For each `github/<base>` (e.g. `github/claude-opus-4.8`), emit these keys → all
map to value `github/<base>`:

- **Prefix-stripped:** `claude-opus-4.8`
- **Dotted → hyphen:** `claude-opus-4-8`
- **Hyphen → dotted:** if the id uses hyphens in the version, also emit the
  dotted form.

**Dated forms** (e.g. `claude-haiku-4-5-20251001`) cannot be derived from the
catalog id. They are covered only if the verification step shows Claude Code
still emits them — in which case a small override map (Approach C fallback) is
folded in.

## Empirical verification (open question)

Before finalizing, run a one-time check (documented in the plan; not shipped
code) to answer: does seeding *all* discovered models populate the `/model`
listing, or do they already list and aliases only fix the *switch*?

1. `Invoke-WebRequest /v1/models` → capture real `github/*` ids and their exact
   formatting (dotted vs hyphen).
2. Inspect `modelAliases` in `storage.sqlite` before/after seeding.
3. In a Claude session, run `/model`: note whether non-seeded models appear and
   whether selecting one succeeds or throws "Ambiguous model".

Drives two decisions: (a) whether listing needs seeding or only switching does,
and (b) whether the dated-id override map is required. Findings recorded here
after the check.

## Error handling

- `/v1/models` unreachable or zero `github/*` ids → warn, skip seeding, do not
  fail setup (mirrors existing `Get-CopilotModelCount` try/catch → 0).
- `better-sqlite3` missing or arch mismatch (ERR_DLOPEN_FAILED) → reuse existing
  x64-Node-first, host-node-fallback pattern.
- Empty discovery when run standalone → clear message pointing to dashboard
  OAuth connect.
- Idempotent throughout (`INSERT OR REPLACE`); safe to re-run.

## Testing

- Run `refresh-models.ps1` standalone; seeded count matches discovered
  `github/*` count × variants.
- Re-run; no errors, stable count.
- Full `setup-omniroute.ps1` run; §6.5 delegation still succeeds.
- `/model` picker check from the verification step.
- README reflects the new script + usage.
