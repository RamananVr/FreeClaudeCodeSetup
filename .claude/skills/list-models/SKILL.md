---
name: list-models
description: List all GitHub Copilot models currently connected to OmniRoute. Use when the user asks what models are available, which Copilot models they can switch to, or to see the OmniRoute model catalog (e.g. "list models", "what models can I use", "show available copilot models").
---

# List Available Copilot Models

Prints every GitHub Copilot model currently connected to the local OmniRoute
server, discovered live from its `/v1/models` endpoint. Read-only — it does not
change routing or seed aliases.

## When to use

- The user asks what models / Copilot models are available.
- The user wants to know which id to pass to `claude --model <id>` or the
  in-session `/model <id>` command.

## How to run

From the repo root, run the list-only mode of the discovery script for the
current OS.

**Windows:**

```powershell
pwsh -File .\windows\scripts\refresh-models.ps1 -ListOnly
```

**macOS:**

```bash
bash ./macos/scripts/refresh-models.sh --list-only
```

If a non-default port was configured, pass it through:

```powershell
# Windows
pwsh -File .\windows\scripts\refresh-models.ps1 -ListOnly -Port 20200
```

```bash
# macOS
bash ./macos/scripts/refresh-models.sh --list-only --port 20200
```

The command prints one `github/<id>` per line (sorted, de-duplicated).

## Reporting to the user

- Show the list. If it's long, group by family (Claude / GPT / Gemini / other)
  and note the count.
- Remind them how to switch: `claude --model github/<id>` at launch, or
  `/model github/<id>` mid-session (the arrow-key `/model` menu only shows Claude
  Code's built-in entries).
- Note that `text-embedding-*` models are not usable as chat models.

## If it returns nothing

The script prints a warning and exits when no `github/*` models are found —
GitHub Copilot is likely not connected. Point the user to
`http://localhost:20128/dashboard/oauth` to connect it, then re-run.
