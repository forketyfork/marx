# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Development Environment
The project uses Nix with flakes for reproducible development. With `direnv` configured, the environment loads automatically:
```bash
# Enter Nix development shell manually
nix develop

# Or with direnv (preferred)
direnv allow
```

### Common Commands (via Just)
```bash
just                    # List all available commands
just check              # Run all checks (lint + type-check + test + check-sh)
just lint               # Run all linters (black, ruff, mypy)
just format             # Format code with black
just fix                # Auto-fix ruff issues and format
just test               # Run all tests
just test-file FILE     # Run specific test file
just run --pr 123       # Review PR #123
just docker-build       # Build Docker image
```

### Installation

For Nix users:
```bash
nix profile install .                 # Install globally
nix run .                             # Run without installing
nix develop                           # Enter development environment
```

For non-Nix users:
```bash
pip install .                         # Install globally
pip install -e ".[dev]"               # Install in editable mode for development
```

**Note**: In Nix environments, `pip install` will fail because the Python environment is read-only.

### Manual Commands
Always reformat the codebase with `black` before completing any task.
```bash
# Testing
pytest -v                              # Run all tests
pytest tests/test_github.py           # Run specific test file
pytest -k "test_name"                 # Run tests matching pattern

# Linting and formatting
black marx tests                      # Format code
ruff check marx tests                 # Check for linting issues
ruff check --fix marx tests           # Auto-fix linting issues
mypy marx                             # Type check

# Run Marx
marx                                  # Interactive mode
marx --pr 123                         # Review specific PR
marx --pr 123 --agents claude         # Review with specific agent(s)
marx --resume --pr 123                # Resume from previous artifacts
```

## Architecture

### High-Level Overview
Marx is a CLI tool that orchestrates parallel AI code reviews of GitHub PRs using multiple AI models (Claude, Codex, Gemini). The tool:
1. Fetches PRs via GitHub API
2. Creates isolated run directories for artifacts
3. Runs AI agents in parallel within Docker containers
4. Merges results and optionally posts them as GitHub reviews

### Core Components

**CLI Orchestration** (`marx/cli.py`):
- Entry point that coordinates the entire workflow
- Handles dependency checking, PR selection, and result display
- Manages the run directory lifecycle for storing artifacts
- Creates placeholders for agents not selected with `--agents` flag
- Supports `--resume` mode to skip re-running agents

**GitHub API Client** (`marx/github.py`):
- Wraps `gh` CLI commands for PR operations
- Auto-detects repository from environment, `gh repo view`, or git remotes
- Filters PRs to exclude those authored by or assigned to current user
- Handles both flat arrays and nested GraphQL `nodes[]` response formats
- Parses PR diff hunks to determine valid inline comment positions
- Creates pending reviews with inline comments and summary text

**Docker Runner** (`marx/docker_runner.py`):
- Orchestrates parallel execution of AI agents in Docker containers
- Builds Docker image from Dockerfile if not present
- Generates dynamic review prompts for each agent
- Mounts run directory and optional config directories (`~/.claude`, `~/.codex`, `~/.gemini`)
- Passes API keys and GitHub token via environment variables
- Executes bash runner script that:
  - Sets up user/group matching host UID/GID for file permissions
  - Clones repository and checks out PR branch at specific commit
  - Copies agent config directories if available
  - Runs agent-specific CLI commands with appropriate flags
  - Copies review JSON from workspace to run directory
- Handles container errors and produces fallback error reviews

**Review Processing** (`marx/review.py`):
- Defines Pydantic models for issues, reviews, and merged results
- Merges individual agent reviews into unified output
- Sorts issues by priority (P0 → P1 → P2)
- Filters issues into inline-able vs. summary-only based on diff positions
- Creates GitHub review payloads with inline comments and summary text
- Prompts user before posting pending reviews to GitHub

**Configuration** (`marx/config.py`):
- Defines supported agents: claude, codex, gemini
- Maps agents to CLI commands and config directory names
- Specifies Docker image name and container paths
- Defines priority ordering for issue sorting

### Key Workflow Details

**Run Directory Structure**:
- Created at `runs/pr-{number}-{branch}/` relative to project root
- Contains individual agent reviews: `{agent}-review.json`
- Contains raw agent outputs: `{agent}-raw.jsonl`
- Contains stderr logs: `{agent}-review.json.stderr`
- Contains merged review: `merged-review.json`
- Contains pending review payload: `pending-review-request.json`

**Docker Container Environment**:
- Image includes: claude, codex, gemini CLIs, gh, git, rg, fd, tree, fastmod, ast-grep
- Working directory: `/workspace` (repository cloned to `/workspace/repo`)
- Runner artifacts mounted at: `/runner`
- Config directories mounted read-only at: `/host-configs/{agent}`
- Agents write review JSON to: `/workspace/repo/.marx/{agent}-review.json`
- Runner script copies it to: `/runner/{agent}-review.json`

**Agent Review Prompt**:
Each agent receives a detailed prompt instructing it to:
- Use `gh` commands to fetch PR details, diff, and comments
- Use rg, fd, tree, ast-grep to explore the codebase
- Review for bugs, security, performance, quality, best practices
- Focus on changed files and lines in the PR diff
- Only emit inline comments for exact lines in the new revision
- Set `line: null` for issues not tied to specific changed lines
- Output structured JSON with `pr_summary` and `issues` arrays
- Write the JSON to `/workspace/repo/.marx/{agent}-review.json`

**Authentication Methods**:
1. API keys via environment variables (preferred for CI/CD):
   - `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`/`GEMINI_API_KEY`
2. Local config directories (preferred for development):
   - `~/.claude`, `~/.codex`, `~/.gemini` mounted read-only into containers

**GitHub Review Posting**:
- Fetches valid diff positions for inline comments via GitHub API
- Filters issues into inline-able (file + line in diff) vs. summary-only
- Creates pending review with inline comments + summary
- Prompts user for confirmation before posting
- Review stays pending until manually submitted on GitHub

## Code Style and Conventions

- Python 3.12+ with full type hints (enforced by mypy with `disallow_untyped_defs`)
- Line length: 100 characters (black and ruff)
- Import ordering: E, F, I, N, W, UP (ruff)
- Pydantic models for all structured data (reviews, issues, prompts)
- Rich library for colored terminal output
- Docker SDK for Python for container orchestration
- `gh` CLI for GitHub API interactions
- Environment variables for configuration (no config files)

## Testing

- Test suite in `tests/` using pytest
- Fixtures in `tests/conftest.py` for mocking GitHub API and Docker
- Tests run with coverage reporting (see pyproject.toml for settings)
- CI workflow in `.github/workflows/build.yml` runs checks on push/PR

## Environment Variables

Required:
- `GITHUB_TOKEN`: GitHub API token (required for container GitHub access)

Optional:
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`/`GEMINI_API_KEY`: API keys for agents
- `MARX_REPO`: Override repository detection (format: `owner/repo`)

## Important Behaviors

- Always update README.md when making code changes (per project instructions)
- The tool never modifies the repository being reviewed (read-only operations)
- Worktrees are no longer used; instead, repositories are cloned in containers
- Agent failures produce empty reviews with error descriptions (non-fatal)
- Invalid JSON from agents is handled gracefully with placeholder reviews
- Resume mode reuses previous agent outputs and skips Docker execution
- Agents not selected via `--agents` flag receive placeholder "Not run" reviews
