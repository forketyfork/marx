# MARX - Multi-Agentic Review eXperience

[![Build status](https://github.com/forketyfork/marx/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/marx/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/language-Python-blue.svg)](https://www.python.org/)

An interactive CLI tool for automated multi-model AI code review of GitHub Pull Requests. Marx fetches open PRs, creates a git worktree, and runs parallel code reviews using three AI models (Claude, Codex, and Gemini).

## Features

- **Multi-Model AI Review**: Runs Claude, Codex, and Gemini in parallel for comprehensive code analysis
- **Git Worktree Integration**: Creates isolated worktrees for safe PR review without affecting your main branch
- **Intelligent PR Filtering**: Automatically filters PRs where you're not the author or reviewer
- **Docker Isolation**: All AI models run in containers with proper permissions
- **Structured Output**: JSON-formatted results with priority-based issue categorization
- **Robust Error Handling**: Graceful fallbacks and comprehensive validation
- **User-Friendly Interface**: Colored output with clear progress indicators

## Prerequisites

The following tools must be installed:

- `git` - Version control
- `gh` - GitHub CLI (must be authenticated)
- `jq` - JSON processing
- `docker` - Container runtime

## Quick Start with Nix (Recommended for Development)

If you have [Nix](https://nixos.org/download.html) with flakes enabled:

```bash
# Clone the repository
git clone https://github.com/forketyfork/marx.git
cd marx

# Enter the development environment
nix develop

# Or use direnv for automatic environment loading
direnv allow
```

The Nix flake provides:
- Python 3.12 with all dependencies
- System tools (git, gh, jq, docker)
- Development tools (pytest, black, ruff, mypy)
- Just command runner for common tasks

### Using Just Commands

```bash
# See all available commands
just

# Run linters
just lint

# Run tests
just test

# Run marx
just run

# Install package in editable mode
just install

# Run all checks (CI equivalent)
just check
```

## Installation

1. Clone this repository
2. Install dependencies:
   ```bash
   pip install -e .
   # Or for development with testing tools:
   pip install -e ".[dev]"
   ```
3. Run the tool:
   ```bash
   marx
   ```

## Environment Variables

### Setting up Environment Variables

Copy the example environment file and fill in your credentials:

```bash
cp .env.example .env
# Edit .env with your API keys and tokens
```

If using direnv (recommended), the `.env` file will be automatically loaded.

### Required
- `GITHUB_TOKEN` - GitHub API token (required for container access to GitHub API)

### API Keys (at least one required)
The following API keys enable the respective AI models to function. You can provide one or more:

- `ANTHROPIC_API_KEY` - Anthropic API key for Claude
- `OPENAI_API_KEY` - OpenAI API key for Codex
- `GOOGLE_API_KEY` or `GEMINI_API_KEY` - Google API key for Gemini

Without API keys, the AI models will fall back to using local configuration from `~/.claude`, `~/.codex`, or `~/.gemini` directories if available.

### Optional
- `MARX_REPO` - Optional owner/name override (e.g., `owner/repo`) when auto-detection fails

## Configuration

Marx supports two authentication methods for AI models:

### Method 1: API Keys (Recommended for CI/CD)
Set environment variables with your API keys:
```bash
export ANTHROPIC_API_KEY="your-key-here"
export OPENAI_API_KEY="your-key-here"
export GOOGLE_API_KEY="your-key-here"
```

### Method 2: Local Configuration Directories
Marx can use AI model configuration directories from your home directory:

- `~/.claude` - Claude CLI configuration
- `~/.codex` - Codex CLI configuration
- `~/.gemini` - Gemini CLI configuration

These directories are mounted read-only into the Docker container during execution. This method is useful for development when you've already authenticated via the respective CLI tools.

## Usage

```bash
marx [OPTIONS]
```

### Options

- `--help` - Show help message and exit
- `--version` - Show version and exit
- `--pr <number>` - Specify PR number directly (skip interactive selection)
- `--agent <agents>` - Comma-separated list of agents to run (claude,codex,gemini)
  - Default: all agents
- `--repo <owner/repo>` - Repository in the format owner/repo (e.g., acmecorp/my-app)
  - Overrides automatic repository detection
- `--resume` - Reuse artifacts from the previous run and skip AI execution

### Examples

```bash
# Interactive mode with all agents (default)
marx

# Review PR #123 with all agents
marx --pr 123

# Review PR #123 with Claude only
marx --pr 123 --agent claude

# Interactive mode with Codex and Gemini
marx --agent codex,gemini

# Review PRs in specific repository
marx --repo acmecorp/my-app

# Review specific PR in specific repository
marx --pr 123 --repo acmecorp/my-app

# Review specific PR with multiple selected agents
marx --pr 456 --agent claude,gemini

# Resume from previous run without rerunning agents
marx --resume --pr 123
```

## How It Works

### 1. Setup & Validation
- Checks for required dependencies (git, gh, jq, docker)
- Builds Docker image `marx:latest` if not present
- Validates `GITHUB_TOKEN` environment variable
- Confirms current directory is a git repository

### 2. Repository Detection
Determines repository slug (owner/name) using three methods in order:
1. `MARX_REPO` environment variable
2. `gh repo view` command
3. Git remote URL parsing (fallback)

### 3. PR Discovery
- Gets current GitHub user via GitHub API
- Fetches open PRs with metadata (title, author, reviewers, line changes)
- Filters PRs where:
  - You are NOT the author
  - You are NOT a reviewer
  - Has at least one reviewer assigned
- Handles both flat array and nested `nodes[]` API response formats

### 4. PR Selection & Worktree Creation
- If `--pr` is specified: validates PR exists and gets branch name
- Otherwise: displays formatted PR list with colors and statistics and prompts for selection
- Fetches the PR and gets commit SHA
- Creates a git worktree at `../pr-{number}-{sanitized-branch}`
- Handles worktree cleanup if it already exists
- Symlinks `.claude` directory from original repo

### 5. Parallel AI Code Review
- If `--agent` is specified: runs only the selected agents
- Otherwise: runs all three agents (claude, codex, gemini)

Each AI model receives a detailed prompt instructing it to:
- Gather PR context using `gh` commands
- Review code for bugs, security issues, performance problems, etc.
- Output findings in structured JSON format

Selected models run simultaneously in isolated Docker containers with:
- Mounted worktree directory
- User UID/GID for proper file permissions
- Config directories from home
- GitHub token for API access

### 6. Results Merging & Display
- Validates all JSON outputs
- Merges reviews from all three models
- Sorts issues by priority (P0 → P1 → P2)
- Displays formatted output with:
  - PR summary and title
  - Description from each AI model
  - Issue counts by priority
  - Detailed issue breakdown

## Output Format

### Review JSON Structure

Each AI model produces JSON output with this structure:

```json
{
  "pr_summary": {
    "number": 123,
    "title": "PR Title",
    "description": "Brief description of changes"
  },
  "issues": [
    {
      "agent": "claude|codex|gemini",
      "priority": "P0|P1|P2",
      "file": "path/to/file.js",
      "line": 42,
      "category": "bug|security|performance|quality|style",
      "description": "Detailed description of the issue",
      "proposed_fix": "Concrete suggestion on how to fix it"
    }
  ]
}
```

### Priority Definitions

- **P0 (Critical)**: Must be fixed - security vulnerabilities, bugs causing crashes/data loss
- **P1 (Important)**: Should be fixed - logic bugs, performance problems, poor error handling
- **P2 (Nice-to-have)**: Suggestions - code style, minor optimizations

### Output Files

All files are saved in the worktree directory:

- `claude-review.json` - Claude's review
- `codex-review.json` - Codex's review
- `gemini-review.json` - Gemini's review
- `merged-review.json` - Combined review from all models

## Example Workflow

```bash
# Run marx
marx

# The tool will:
# 1. Detect your repository
# 2. Show available PRs
# 3. Prompt you to select one
# 4. Create a worktree
# 5. Run AI reviews in parallel
# 6. Display merged results

# Navigate to the worktree to work on issues
cd ../pr-123-feature-branch

# When done, remove the worktree
git worktree remove ../pr-123-feature-branch
```

## Docker Image

Marx uses a Docker image containing:
- **AI CLI Tools**: Claude, Codex, Gemini
- **GitHub Tools**: `gh` (GitHub CLI)
- **Search & Navigation**: `rg` (ripgrep), `fd`, `tree`
- **Code Refactoring**: `fastmod`, `ast-grep` (with `sg` alias)
- **Development Tools**: git, jq, and other utilities

The image is built automatically on first run using the Dockerfile in this repository.

## Error Handling

Marx includes robust error handling:
- Non-JSON outputs from AI models are handled gracefully with empty reviews
- Failed API calls are caught and reported with detailed error messages
- Docker errors and container stderr are both captured and displayed
- Invalid JSON is replaced with valid fallback structures
- All temporary files are cleaned up automatically
- Helpful hints are provided when authentication or configuration issues occur

## Security Considerations

- AI models run in isolated Docker containers
- Config directories are mounted read-only
- GitHub token is passed as an environment variable
- No destructive git operations are performed
- User input is validated before use

## Troubleshooting

### "GITHUB_TOKEN environment variable is not set"
Set your GitHub token: `export GITHUB_TOKEN=ghp_your_token_here`

### "Unable to determine repository automatically"
Set the repository manually: `export MARX_REPO=owner/repo`

### "Missing required dependencies"
Install the missing tools listed in the error message.

### AI model fails or returns non-JSON output
Marx will automatically handle this by creating an empty review. Error details are displayed in the terminal output, including:
- Docker errors (if Docker command failed)
- Container stderr output (errors from the AI CLI tool)
- Helpful hints for common issues (missing/invalid credentials)

Common causes:
- Missing authentication: Set API key environment variables (e.g., `ANTHROPIC_API_KEY`) or run the CLI auth command (e.g., `claude auth` for Claude)
- Invalid API keys or credentials in `~/.claude/`, `~/.codex/`, or `~/.gemini/`
- Network connectivity issues
- API quota/rate limiting

**Tip**: For CI/CD environments, using API key environment variables is more reliable than local configuration directories.

## Development & Testing

### Nix Development Workflow (Recommended)

The project includes a Nix flake for reproducible development environments:

```bash
# Enter development shell
nix develop

# Or use direnv for automatic loading (recommended)
echo "use flake" > .envrc
direnv allow

# Use just for common tasks
just             # List all commands
just check       # Run all checks (lint + type-check + test)
just lint        # Run linters
just test        # Run tests
just run --pr 123  # Run marx
```

#### Setting up direnv

1. Install direnv: `nix-env -iA nixpkgs.direnv` or see [direnv installation](https://direnv.net/docs/installation.html)
2. Add hook to your shell (e.g., `eval "$(direnv hook bash)"` for bash)
3. Allow the directory: `direnv allow`

Now the environment will automatically load when you `cd` into the project!

#### Just Command Reference

```bash
just install       # Install package in editable mode
just lint          # Run all linters (black, ruff, mypy)
just format        # Format code with black
just fix           # Auto-fix linting issues
just test          # Run all tests
just test-cov      # Run tests with coverage
just test-file FILE  # Run specific test file
just clean         # Clean build artifacts
just docker-build  # Build Docker image
just info          # Show environment info
```

### Python Version

The Python codebase includes a comprehensive test suite. To run tests manually:

```bash
# Install development dependencies
pip install -e ".[dev]"

# Run tests with coverage
pytest

# Run tests with verbose output
pytest -v

# Run specific test file
pytest tests/test_github.py

# Type checking with mypy
mypy marx

# Code formatting with black
black marx tests

# Linting with ruff
ruff check marx tests
```

### Project Structure

```
marx/
├── marx/          # Main package
│   ├── __init__.py
│   ├── cli.py          # CLI entry point and orchestration
│   ├── config.py       # Configuration and constants
│   ├── docker_runner.py # Docker container orchestration
│   ├── exceptions.py   # Custom exceptions
│   ├── github.py       # GitHub API client
│   ├── review.py       # Review processing and merging
│   └── ui.py           # Terminal UI and formatting
├── tests/              # Test suite
│   ├── conftest.py     # Pytest fixtures
│   ├── test_github.py  # GitHub client tests
│   └── test_review.py  # Review processing tests
├── pyproject.toml      # Project configuration
├── requirements.txt    # Dependencies
└── README.md           # This file
```

## Contributing

Contributions are welcome! Please ensure:

- Code passes `mypy` type checking
- Code passes `ruff` linting
- Code is formatted with `black`
- Tests pass with `pytest`
- New features include tests
- Follow Python best practices and PEP 8

## License

See LICENSE file for details.
