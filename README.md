# MARX - Multi-Agentic Review eXperience

[![Build status](https://github.com/forketyfork/marx/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/marx/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/language-Python-blue.svg)](https://www.python.org/)

Marx is an interactive CLI that runs parallel AI code reviews for GitHub pull requests in Docker.
It clones and reviews PRs inside containers, so your local repo stays untouched.

## Screenshots

![CLI summary](docs/screenshots/cli-summary.png)
![CLI issues](docs/screenshots/cli-issues.png)

## Features

- Parallel multi-model reviews with Claude, Codex, and Gemini
- Containerized checkout keeps local repos clean
- Structured review outputs with a merged summary
- Interactive PR selection (excludes your own PRs and PRs assigned to you)
- Works with local CLI configs or API keys (config dirs are mounted into containers)
- JSON output for automation via `--json-output`

## Prerequisites

- `git`
- `gh` (authenticated)
- `docker`

## Install

```bash
uv tool install marx-ai
```

Need Nix or a source install? See `docs/installation.md`.

## Configure

Create `~/.marx` with your GitHub token and any agent keys you want to use:

```bash
cat > ~/.marx <<'MARX'
GITHUB_TOKEN=ghp_your_token_here
ANTHROPIC_API_KEY=your_claude_key
OPENAI_API_KEY=your_openai_key
GEMINI_API_KEY=your_gemini_key
MARX
```

If you already use the agent CLIs locally, Marx copies `~/.claude`, `~/.codex`, and `~/.gemini`
into the containers so those configs work there too. API keys are optional.
See `docs/configuration.md` for details.

## Use

```bash
# Interactive PR selection
marx

# Review a specific PR with all agents
marx --pr 123 --agents claude,codex,gemini

# Machine-readable output
marx --pr 123 --json-output
```

## Docs

- `docs/installation.md`
- `docs/configuration.md`
- `docs/usage.md`
- `docs/how-it-works.md`
- `docs/troubleshooting.md`
- `docs/development.md`
- `docs/publishing.md`
- `docs/contributing.md`
