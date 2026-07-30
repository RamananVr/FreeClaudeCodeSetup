# Implementation Plan — ARM64 x64-Node Auto-Provisioning

Design: `2026-07-30-arm64-node-autoprovision-design.md`

## Task 1 — Create `scripts/ensure-x64-node.ps1`

New helper that returns an object describing which Node the caller should use.

- `param([string]$X64NodeVersion = "20.18.1", [string]$InstallRoot = (Join-Path $env:USERPROFILE ".omniroute\node-x64"))`.
- Detect arch: `$arch = try { node -p "process.arch" } catch { if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' } }`.
- **If not arm64:** return `[pscustomobject]@{ NodeExe = "node"; NpmCmd = "npm"; Dir = $null }`.
- **If arm64:**
  - `$dir = Join-Path $InstallRoot "node-v$X64NodeVersion-win-x64"`; `$exe = Join-Path $dir "node.exe"`.
  - Reuse check: if `Test-Path $exe` and `& $exe -p "process.arch"` → `x64`, return it.
  - Else download `node-v$X64NodeVersion-win-x64.zip` from `https://nodejs.org/dist/v$X64NodeVersion/` to a temp file.
  - Fetch `SHASUMS256.txt`, extract the expected hash for the zip, compare to `Get-FileHash -Algorithm SHA256`. On mismatch: delete temp, `throw`.
  - `Expand-Archive` into `$InstallRoot` (zip already contains the `node-v..-win-x64` folder).
  - Self-check `& $exe -p "process.arch"` == `x64`, else `throw`.
  - Return `[pscustomobject]@{ NodeExe = $exe; NpmCmd = (Join-Path $dir "npm.cmd"); Dir = $dir }`.
- Wrap download/extract in try/catch that emits the exact URL + manual-download instructions before rethrowing.
- Use `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` guard for older PS.

## Task 2 — Wire helper into `scripts/setup-omniroute.ps1`

- Add `$node = & (Join-Path $PSScriptRoot "ensure-x64-node.ps1")` right after the prereq
  checks, replacing the current `if ($nodeArch -eq "arm64") { Warn ... }` block.
- If `$node.Dir` non-null: `$env:Path = "$($node.Dir);$env:Path"` (process-local) and
  `Ok "Using provisioned x64 Node: $($node.NodeExe)"`.
- Thread `$node.NodeExe` into `New-BinShim`: change the `node ...` lines in both the
  `.cmd` and `.ps1` heredocs to `"<NodeExe>" ...`. When `NodeExe` is bare `node`, the
  emitted text must remain exactly `node "..."` (verify the x64 path only appears on
  arm64). Simplest: pass `$NodeExe` as a param to `New-BinShim` and interpolate.
- Change the alias-seeder call `& node $aliasSeeder` → `& $node.NodeExe $aliasSeeder`.
- The `claude-omni` launcher invokes `claude`, not `node`, so it needs no change.

## Task 3 — Confirm autostart needs no change

- Re-read `start-omniroute.ps1`: it launches `omniroute.cmd` (which now carries the baked
  path). Confirm no `node` invocation there. Document in the plan that no edit is needed.

## Task 4 — Update `README.md`

- Replace the arm64 bullet ("run under an x64 Node via emulation") with: "On ARM64, setup
  automatically downloads a pinned x64 Node (portable, to `~/.omniroute\node-x64`) and
  runs OmniRoute under it — no manual steps."
- Add `ensure-x64-node.ps1` to the Contents table.
- Note the `-X64NodeVersion` override on `bootstrap.ps1` / `setup-omniroute.ps1`.

## Task 5 — Optional passthrough param

- Add `[string]$X64NodeVersion` to `bootstrap.ps1` and `setup-omniroute.ps1`, forwarded
  to the helper, so the pinned version can be overridden without editing the helper.

## Task 6 — Verify

- Static: on this x64 machine, run setup with `-NoLaunch -NoAutostart`; diff generated
  `omniroute.cmd` against the pre-change version — must be identical (bare `node`).
- ARM64: hand off to a teammate on an ARM64 box (or emulate) per the design's test matrix:
  download-once, baked path, server up, alias-seed OK, reboot autostart, re-run idempotent.

## Commit / PR

- One commit per logical unit (helper, setup wiring, README), then open a PR against
  `main` for team review before merge.
