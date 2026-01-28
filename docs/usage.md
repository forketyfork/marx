# Usage

## Basic usage

```bash
# Interactive PR selection
marx

# Review a specific PR
marx --pr 123

# Review with selected agents
marx --pr 123 --agents claude,codex

# JSON output for automation
marx --pr 123 --json-output
```

## Options

- `--pr <number>`: Review a specific PR and skip the interactive picker.
- `--agents <list>`: Comma- or space-separated agent list. Use `agent:model` to override.
- `--repo <owner/repo>`: Override repository auto-detection.
- `--resume`: Reuse existing run artifacts and skip running agents.
- `--dedupe-with <agent>`: Choose the agent used for deduplication (supports `agent:model`).
  Defaults to the first agent in `--agents`.
- `--json-output`: Print merged review as structured JSON instead of rich terminal output.

## Model overrides

You can select agent-specific model IDs with `agent:model`:

```bash
marx --pr 123 --agents "claude:<model-id>,codex:<model-id>"
marx --pr 123 --dedupe-with "gemini:<model-id>"
```

The value after `:` is passed directly to the agent CLI.

## Output artifacts

Each run creates a directory at `runs/pr-<number>-<branch>/` with:

- `claude-review.txt`
- `codex-review.txt`
- `gemini-review.txt`
- `dedup-review.txt` (only when multiple agents run)
- `merged-review.txt`

Use `--resume` to re-use these files without re-running the agents.

## Review text format

Each agent emits a structured text file similar to:

```text
PR_NUMBER: 123
PR_TITLE: Example
PR_DESCRIPTION:
  Summary here

--- ISSUE ---
agent: claude|codex|gemini
priority: P0|P1|P2
path: path/to/file.py
line: 42
commit_id: abcd1234
category: bug|security|performance|quality|style
description:
  Details
proposed_fix:
  Suggestion
```

## JSON output

With `--json-output`, Marx prints the merged review and artifact paths as JSON for easy
integration in scripts.
