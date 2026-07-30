# ARM64 x64-Node Auto-Provisioning — Design

**Date:** 2026-07-30
**Status:** Approved
**Scope:** Internal team distribution (Windows, PowerShell)

## Problem

OmniRoute's native dependencies (`wreq-js`) ship no `win32-arm64` binary. On ARM64
Windows machines (Surface, Snapdragon laptops), running OmniRoute under the host's
arm64 Node fails to start the server.

Today `scripts/setup-omniroute.ps1` only *warns* on arm64 and then proceeds with the
same broken Node, so an ARM64 teammate runs `bootstrap.ps1`, sees a warning, and hits a
server that never becomes healthy. This is the primary blocker to distributing the setup
across a mixed-architecture team.

## Goal

On ARM64 hosts, `bootstrap.ps1` transparently provisions a pinned **x64 Node (portable
zip)** and runs the entire OmniRoute install + server + alias-seed under it — giving
ARM64 teammates the same zero-touch result as x64 teammates. On x64 hosts the behavior
is byte-for-byte unchanged.

## Decisions

- **Auto-provision (not detect-and-guide):** zero manual steps on ARM64.
- **Portable zip from nodejs.org (not winget):** deterministic, version-pinned, no admin
  required, won't collide with the arm64 Node already on PATH. Ideal in a locked-down
  corp environment.
- **Bake the absolute x64 `node.exe` path into the generated shims (do NOT mutate the
  user's global PATH):** keeps arm64 Node as the machine default for everything else,
  and makes uninstall fully reversible (delete shims + `~/.omniroute/node-x64`).

## Architecture

### New helper: `scripts/ensure-x64-node.ps1`

Responsibilities:
- Detect host arch via `node -p "process.arch"`, falling back to
  `$env:PROCESSOR_ARCHITECTURE` when Node is not yet on PATH.
- **x64 host:** no-op. Return `{ NodeExe = "node"; NpmCmd = "npm"; Dir = $null }` so
  callers stay identical to today (bare `node`).
- **arm64 host:**
  - Target dir: `$HOME\.omniroute\node-x64\node-v<VER>-win-x64\`.
  - If a valid pinned x64 Node already exists there (and self-checks as x64) → reuse it,
    no download (idempotent).
  - Else download `https://nodejs.org/dist/v<VER>/node-v<VER>-win-x64.zip`, verify its
    SHA-256 against `https://nodejs.org/dist/v<VER>/SHASUMS256.txt`, extract, and confirm
    `node.exe -p process.arch` prints `x64`.
  - Return `{ NodeExe = "<dir>\node.exe"; NpmCmd = "<dir>\npm.cmd"; Dir = "<dir>" }`.

Pinned version: a single `$X64NodeVersion` constant (current LTS, e.g. `20.x.x`) at the
top of the helper, overridable via `-X64NodeVersion` so it can be bumped centrally.

### Integration in `setup-omniroute.ps1`

- Replace the current arm64 *warning* block with a call to `ensure-x64-node.ps1`,
  capturing `$node = & ensure-x64-node.ps1`.
- Prepend `$node.Dir` to `$env:Path` **for the setup process only** (process-local, gone
  when the script exits) when `$node.Dir` is non-null, so the staging `npm install`, the
  junction step, and the alias-seed `node` call all run x64.
- Bake `$node.NodeExe` into the generated shims:
  - `omniroute.cmd/.ps1`, `omniroute-reset-password.cmd/.ps1` →
    `"<NodeExe>" "%dp0%node_modules\omniroute\<rel>.mjs" %*`
  - alias-seeder invocation → `& $node.NodeExe $aliasSeeder`
  - On x64, `NodeExe` is bare `node`, so shim output is identical to today.

### Autostart path

`scripts/start-omniroute.ps1` continues to resolve `omniroute.cmd` from the npm global
prefix. That shim now carries the baked x64 `node.exe` path, so the logon task brings the
server up after reboot with no PATH dependency. No change needed to
`install-autostart.ps1`.

## Error handling

- **Download failure** (offline / corp proxy): fail fast with the exact URL and a
  "download `node-v<VER>-win-x64.zip` manually to `<dir>` and re-run" message.
- **SHA-256 mismatch:** hard fail, delete the partial download, do not proceed.
- **Extracted Node fails the `process.arch == x64` self-check:** hard fail.
- x64 hosts skip all of the above entirely — no regression risk for the common case.

## Testing

- **x64 host:** run bootstrap; confirm generated shims are byte-identical to today (bare
  `node`); server comes up; `claude-omni` works.
- **arm64 host:** run bootstrap; confirm x64 Node downloads once; shims carry the absolute
  path; `node.exe -p process.arch` → `x64`; server starts; alias-seed succeeds; reboot →
  autostart still brings the server up.
- **Idempotency (arm64):** re-run bootstrap; no re-download; shims unchanged.

## Out of scope

- macOS/Linux support.
- Removing the OmniRoute-side npm feed / `yuku-ast` workaround (unchanged).
- Any change to the `.local\bin` personal launcher scripts (separate from this repo).
