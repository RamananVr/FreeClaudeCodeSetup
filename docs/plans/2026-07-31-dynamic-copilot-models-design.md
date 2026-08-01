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

### Verification findings (2026-07-31)

Ran the non-interactive checks (interactive `/model` picker check deferred to user).

- **Host is ARM64.** The staged `better_sqlite3.node` is an **arm64** build, so the
  x64 Node *cannot* load it (`ERR_DLOPEN_FAILED`); only the **host arm64 node**
  seeds successfully. The seeder must try both and the host-node fallback is what
  actually works here. (Native module arch = whichever node ran `npm install`.)
- **Path corrections for the plan:**
  - `StageDir` default is `~/omniroute-stage` (not `~/.omniroute/stage`).
  - x64 Node is nested: `~/.omniroute/node-x64/node-v20.18.1-win-x64/node.exe`
    (must glob for `node.exe`, not assume a fixed path).
  - better-sqlite3 resolves via the existing require list's dist path
    (`StageDir/node_modules/omniroute/dist/node_modules/better-sqlite3`) — keep it.
- **`/v1/models` returns 23 unique `github/*` models** (46 rows counting both
  `gh/` and `github/` prefixes): 9 Claude, plus gpt-*, gemini-*, kimi, mai-code,
  oswe, and 2 `text-embedding-*`.
- **Existing `modelAliases` has 23 entries.** Critically, some bare ids are
  already mapped to **other providers** — e.g. `gemini-3.1-pro-preview -> agy/…`,
  `gemini-3-pro-high -> agy/…`, `gemini-3.1-flash-lite-preview -> gemini/…`
  (seeded outside this repo, likely Agency). Seeding bare-id aliases for *all*
  discovered `github/*` models would **clobber** these via `INSERT OR REPLACE`.
- **Dated-id override IS required.** Claude Code still emits the dated
  `claude-haiku-4-5-20251001`, which is not derivable from the catalog id
  `github/claude-haiku-4.5`. Approach-C fallback (small override map) is needed
  for at least this id.

**Scope decision (resolved 2026-07-31):** seed bare-id aliases for **all
discovered `github/*` models except `text-embedding-*`**. To avoid clobbering
bare-id aliases already pointing at other providers (Agency's `agy/*`, `gemini/*`),
the seeder applies a **clobber guard**: write a key only if it does not already
exist OR its existing value is a `github/*` id. Keys mapped to non-github
providers are left untouched. The dated `claude-haiku-4-5-20251001` override is
included.

### Interactive `/model` finding (2026-07-31) — RESOLVES the open question

Confirmed with the user's live session:

- The in-session `/model` picker is Claude Code's **built-in, fixed menu**
  (Default / Opus 1M / Sonnet / Sonnet 5 1M / Haiku / Opus 4). It does **not**
  enumerate the discovered `github/*` Copilot catalog. Seeding aliases does not,
  and cannot, inject models into this picker.
- **Aliases fix routing/switching, not the arrow-key menu.** They make the
  built-in menu entries route unambiguously to Copilot (no "Ambiguous model"),
  and they let any discovered model be selected two ways:
  - at launch: `claude --model github/<id>` (verified: `github/gpt-5.5` →
    `routed-ok`);
  - **mid-session: type the id into `/model`** — e.g. `/model github/gpt-5.5`
    switches the live session immediately (verified: session confirmed
    "I'm using github/gpt-5.5"). The arrow-key menu still shows only Claude
    Code's built-in entries, but the typed-argument form reaches ANY connected
    model. The picker header says as much: "specify with --model".
  - Note: a typed `/model` change is saved as the new-session default too, but
    the OmniRoute routing default written into `settings.json` is what applies on
    the next launch.

**Consequence for goals:** Goal 3 (setup-time seed of the full catalog) and
Goal 2 (in-session switching to any Copilot model) are both **met**. Switching is
done by typing the id into `/model` (`/model github/<id>`) or via
`--model github/<id>` at launch — the alias seeding is what makes those resolve
unambiguously. The only thing NOT achievable is having the arrow-key `/model`
menu *enumerate* all 22 Copilot models; that list is Claude Code's fixed built-in
UI. Discover the full list anytime with `refresh-models.ps1`.

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
