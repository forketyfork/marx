# MaxReview

An interactive CLI tool for automated multi-model AI code review of GitHub Pull Requests. MaxReview fetches open PRs, creates a git worktree, and runs parallel code reviews using three AI models (Claude, Codex, and Gemini).

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

## Installation

1. Clone this repository
2. Make the script executable: `chmod +x maxreview.sh`
3. Run the script: `./maxreview.sh`

The script will automatically build the required Docker image on first run.

## Environment Variables

- `GITHUB_TOKEN` - GitHub API token (required for container access to GitHub API)
- `MAXREVIEW_REPO` - Optional owner/name override (e.g., `owner/repo`) when auto-detection fails

## Configuration

MaxReview expects AI model configuration directories in your home directory:

- `~/.claude` - Claude CLI configuration
- `~/.codex` - Codex CLI configuration
- `~/.gemini` - Gemini CLI configuration

These directories are mounted read-only into the Docker container during execution.

## Usage

```bash
./maxreview.sh [OPTIONS]
```

### Options

- `-h, --help` - Show help message
- `--pr <number>` - Specify PR number directly (skip interactive selection)
- `--agent <agents>` - Comma-separated list of agents to run (claude,codex,gemini)
  - Default: all agents

### Examples

```bash
# Interactive mode with all agents (default)
./maxreview.sh

# Review PR #123 with all agents
./maxreview.sh --pr 123

# Review PR #123 with Claude only
./maxreview.sh --pr 123 --agent claude

# Interactive mode with Codex and Gemini
./maxreview.sh --agent codex,gemini

# Review specific PR with multiple selected agents
./maxreview.sh --pr 456 --agent claude,gemini
```

## How It Works

### 1. Setup & Validation
- Checks for required dependencies (git, gh, jq, docker)
- Builds Docker image `maxreview:latest` if not present
- Validates `GITHUB_TOKEN` environment variable
- Confirms current directory is a git repository

### 2. Repository Detection
Determines repository slug (owner/name) using three methods in order:
1. `MAXREVIEW_REPO` environment variable
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
# Run maxreview
./maxreview.sh

# The script will:
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

The script builds a Docker image containing:
- **AI CLI Tools**: Claude, Codex, Gemini
- **GitHub Tools**: `gh` (GitHub CLI)
- **Search & Navigation**: `rg` (ripgrep), `fd`, `tree`
- **Code Refactoring**: `fastmod`, `ast-grep` (with `sg` alias)
- **Development Tools**: git, jq, and other utilities

The image is built automatically on first run using the Dockerfile in this repository.

## Error Handling

MaxReview includes robust error handling:
- Non-JSON outputs from AI models are handled gracefully with empty reviews
- Failed API calls are caught and reported with detailed error messages
- Docker-level errors and container stderr are both captured and displayed
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
Set the repository manually: `export MAXREVIEW_REPO=owner/repo`

### "Missing required dependencies"
Install the missing tools listed in the error message.

### AI model fails or returns non-JSON output
The script will automatically handle this by creating an empty review. Error details are displayed in the terminal output, including:
- Docker-level errors (if Docker command failed)
- Container stderr output (errors from the AI CLI tool)
- Helpful hints for common issues (missing/invalid credentials)

Common causes:
- Missing authentication: Run the CLI auth command (e.g., `claude auth` for Claude)
- Invalid credentials in `~/.claude/`, `~/.codex/`, or `~/.gemini/`
- Network connectivity issues
- API quota/rate limiting

## Contributing

Contributions are welcome! Please ensure:
- Scripts pass `shellcheck` validation
- Scripts pass `bash -n` syntax checking
- Follow bash best practices
- Include appropriate error handling

## License

See LICENSE file for details.
