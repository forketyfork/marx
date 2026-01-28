# Configuration

## Config file: `~/.marx`

Marx loads environment variables from `~/.marx` on startup. Lines use `KEY=value` format.
A leading `export` is allowed, and lines starting with `#` are ignored.
Environment variables in your shell always take precedence over the file.

Example:

```bash
GITHUB_TOKEN=ghp_your_token_here
ANTHROPIC_API_KEY=your_claude_key
OPENAI_API_KEY=your_openai_key
GEMINI_API_KEY=your_gemini_key
MARX_REPO=owner/repo
```

## GitHub authentication

Marx needs GitHub access in two places:

- On the host, the `gh` CLI uses `GH_TOKEN` if set. If it is not set, Marx falls back to
  `MARX_GITHUB_TOKEN` or `GITHUB_TOKEN` (from the environment or `~/.marx`).
- Inside containers, Marx passes `GITHUB_TOKEN` as an environment variable. This is the token
  used for cloning, fetching PR metadata, and posting reviews. For private repositories, this
  token is required.

Recommended: set `GITHUB_TOKEN` in `~/.marx` and run `gh auth login` once for your host CLI.

## Agent authentication

Marx supports two ways to authenticate agent CLIs. You can use either, or both.

### 1) API keys (easy for CI)

Set any of the following environment variables:

- `ANTHROPIC_API_KEY` for Claude
- `OPENAI_API_KEY` for Codex
- `GOOGLE_API_KEY` or `GEMINI_API_KEY` for Gemini

### 2) Local CLI configurations (great for local development)

If you have agent CLIs configured locally, Marx will reuse those settings inside Docker.
It does this by mounting the local config directories read-only and copying them into the
container before the agent runs:

- `~/.claude`
- `~/.codex`
- `~/.gemini`

This means your local settings should work the same way inside the container.

API keys are optional when local configurations exist; they are just another supported option.

API keys are optional when you have local configs. They're mainly useful in CI or if you don't want to manage local CLI configs.

## Prompt customization

You can override the review prompt templates used for the agents:

- `MARX_REVIEW_PROMPT_PATH` (environment variable)
- `REVIEW_PROMPT_PATH` in `~/.marx`

For the deduplication prompt:

- `MARX_DEDUP_PROMPT_PATH` (environment variable)
- `DEDUP_PROMPT_PATH` in `~/.marx`

Both templates are rendered with Python string formatting and support:
`{pr_number}`, `{repo}`, `{commit_sha}`, `{agent}`, and `{container_workspace_dir}`.
