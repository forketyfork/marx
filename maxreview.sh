#!/usr/bin/env bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'
readonly DOCKER_IMAGE="maxreview:latest"
readonly CONTAINER_RUNNER_DIR="/runner"

# Function to print colored messages
print_info() {
    echo -e "${CYAN}ℹ️  $1${RESET}"
}

print_success() {
    echo -e "${GREEN}✅ $1${RESET}"
}

print_error() {
    echo -e "${RED}❌ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${RESET}"
}

print_header() {
    echo -e "\n${BOLD}${MAGENTA}$1${RESET}\n"
}

extract_repo_slug() {
    local url="${1:-}"
    local trimmed=""

    if [[ -z "$url" ]]; then
        return 1
    fi

    if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
        trimmed="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
        trimmed="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^https?://[^/]+/(.+)$ ]]; then
        trimmed="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$trimmed" ]]; then
        return 1
    fi

    trimmed="${trimmed%.git}"
    trimmed="${trimmed#/}"
    trimmed="${trimmed%/}"

    if [[ -z "$trimmed" ]]; then
        return 1
    fi

    echo "$trimmed"
    return 0
}

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code ${exit_code}"
    fi
}

trap cleanup EXIT

check_dependencies() {
    local missing_deps=()
    local require_docker="${REQUIRE_DOCKER:-true}"

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    if ! command -v gh &> /dev/null; then
        missing_deps+=("gh (GitHub CLI)")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if [ "$require_docker" = "true" ] && ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo -e "${CYAN}Please install them and try again.${RESET}"
        exit 1
    fi
}

build_docker_image() {
    if docker image inspect "${DOCKER_IMAGE}" &> /dev/null; then
        print_info "Docker image ${DOCKER_IMAGE} already exists"
        return 0
    fi

    print_info "Building Docker image ${DOCKER_IMAGE}..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if ! docker build -t "${DOCKER_IMAGE}" "${script_dir}"; then
        print_error "Failed to build Docker image"
        exit 1
    fi

    print_success "Docker image built successfully"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Interactive script to fetch open GitHub PRs with reviewers, create a git worktree,"
    echo "and run automated code review with multiple AI models (Claude, Codex, Gemini)."
    echo ""
    echo "Prerequisites:"
    echo "  - git"
    echo "  - gh (GitHub CLI)"
    echo "  - jq"
    echo "  - docker (not required with --resume)"
    echo ""
    echo "Environment Variables:"
    echo "  GITHUB_TOKEN     GitHub API token (required for container access)"
    echo "  MAXREVIEW_REPO   Optional owner/name override when auto-detect fails"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  --pr <number>        Specify PR number directly (skip interactive selection)"
    echo "  --agent <agents>     Comma-separated list of agents to run (claude,codex,gemini)"
    echo "                       Default: all agents"
    echo "  --resume             Reuse artifacts from the previous run and skip AI execution"
    echo ""
    echo "Examples:"
    echo "  $0                            # Interactive mode with all agents"
    echo "  $0 --pr 123                   # Review PR #123 with all agents"
    echo "  $0 --pr 123 --agent claude    # Review PR #123 with Claude only"
    echo "  $0 --agent codex,gemini       # Interactive mode with Codex and Gemini"
    echo "  $0 --resume --pr 123          # Reuse artifacts for PR #123 without rerunning agents"
}

# Parse command-line arguments
SELECTED_PR=""
SELECTED_AGENTS=""
RESUME_MODE="false"
REQUIRE_DOCKER="true"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --pr)
            if [[ -z "${2:-}" ]] || [[ "$2" =~ ^- ]]; then
                print_error "--pr requires a PR number"
                exit 1
            fi
            SELECTED_PR="$2"
            shift 2
            ;;
        --agent)
            if [[ -z "${2:-}" ]] || [[ "$2" =~ ^- ]]; then
                print_error "--agent requires a comma-separated list of agents"
                exit 1
            fi
            SELECTED_AGENTS="$2"
            shift 2
            ;;
        --resume)
            RESUME_MODE="true"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Adjust dependency requirements for resume mode
if [ "$RESUME_MODE" = "true" ]; then
    REQUIRE_DOCKER="false"
fi

# Validate agents if specified
if [[ -n "$SELECTED_AGENTS" ]]; then
    IFS=',' read -ra AGENT_ARRAY <<< "$SELECTED_AGENTS"
    for agent in "${AGENT_ARRAY[@]}"; do
        agent=$(echo "$agent" | tr '[:upper:]' '[:lower:]' | xargs)
        if [[ "$agent" != "claude" ]] && [[ "$agent" != "codex" ]] && [[ "$agent" != "gemini" ]]; then
            print_error "Invalid agent: $agent. Valid agents are: claude, codex, gemini"
            exit 1
        fi
    done
fi

check_dependencies
if [ "$RESUME_MODE" != "true" ]; then
    build_docker_image
else
    print_info "Resume mode detected, skipping Docker image build"
fi

# Check if GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN:-}" ]; then
    print_warning "GITHUB_TOKEN environment variable is not set"
    print_info "The AI agents may not be able to access GitHub API inside the container"
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not a git repository!"
    exit 1
fi

# Determine repository slug
print_info "Detecting repository..."
REPO_SOURCE=""
REPO="${MAXREVIEW_REPO:-}"

if [ -n "$REPO" ]; then
    REPO_SOURCE="environment variable MAXREVIEW_REPO"
else
    GH_ERROR=$(mktemp)
    if REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>"${GH_ERROR}"); then
        REPO_SOURCE="gh repo view"
    else
        if [ -s "${GH_ERROR}" ]; then
            print_warning "gh repo view failed, attempting to infer repository from git remote"
            print_warning "Error details:"
            cat "${GH_ERROR}" >&2
        else
            print_warning "gh repo view failed with no additional details, attempting git remote fallback"
        fi
    fi
    rm -f "${GH_ERROR}"
fi

if [ -z "$REPO" ]; then
    remote_url=$(git remote get-url origin 2>/dev/null || git remote -v | awk 'NR==1 {print $2}')
    if [ -n "${remote_url:-}" ]; then
        if fallback_repo=$(extract_repo_slug "$remote_url"); then
            REPO="$fallback_repo"
            REPO_SOURCE="git remote"
        fi
    fi
fi

if [ -z "$REPO" ]; then
    print_error "Unable to determine repository automatically."
    print_info "Set MAXREVIEW_REPO (e.g. owner/repo) and rerun."
    exit 1
fi

case "$REPO_SOURCE" in
    "environment variable MAXREVIEW_REPO")
        print_success "Repository: ${BOLD}${REPO}${RESET} (from ${REPO_SOURCE})"
        ;;
    "git remote")
        print_warning "Using repository inferred from git remote"
        print_success "Repository: ${BOLD}${REPO}${RESET}"
        ;;
    *)
        print_success "Repository: ${BOLD}${REPO}${RESET}"
        ;;
esac

# Get current GitHub user
print_info "Getting your GitHub username..."
GH_ERROR=$(mktemp)
if ! CURRENT_USER=$(gh api user --jq '.login' 2>"${GH_ERROR}"); then
    print_error "Could not get GitHub username. Make sure gh CLI is authenticated."
    if [ -s "${GH_ERROR}" ]; then
        print_error "Error details:"
        cat "${GH_ERROR}" >&2
    fi
    rm -f "${GH_ERROR}"
    exit 1
fi
if [ -z "$CURRENT_USER" ]; then
    print_error "GitHub CLI returned an empty username."
    rm -f "${GH_ERROR}"
    exit 1
fi
rm -f "${GH_ERROR}"
print_success "Current user: ${BOLD}${CURRENT_USER}${RESET}"

# Fetch PRs with reviewers or use --pr if provided
if [[ -z "$SELECTED_PR" ]]; then
    print_header "🔍 Fetching open PRs with reviewers (excluding yours)..."
    GH_ERROR=$(mktemp)
    if ! PRS=$(gh pr list --repo "$REPO" --state open --json number,title,headRefName,author,reviewRequests,reviews,additions,deletions --limit 100 2>"${GH_ERROR}"); then
        print_error "Failed to fetch pull requests."
        if [ -s "${GH_ERROR}" ]; then
            print_error "Error details:"
            cat "${GH_ERROR}" >&2
        fi
        rm -f "${GH_ERROR}"
        exit 1
    fi
    rm -f "${GH_ERROR}"

    # Filter PRs that:
    # 1. Have at least one reviewer (either requested or completed review)
    # 2. Current user is NOT the author
    # 3. Current user is NOT in the reviewers list
    # Note: Handle both flat array format and nested nodes[] format from GitHub API
    FILTERED_PRS=$(echo "$PRS" | jq -c --arg user "$CURRENT_USER" '[
        .[] |
        # Extract reviewer logins handling both flat arrays and nested nodes
        (.reviewRequests | if type == "array" then
            if length > 0 and (.[0] | has("login")) then map(.login)
            elif length > 0 and (.[0] | has("requestedReviewer")) then map(.requestedReviewer.login)
            else []
            end
        elif type == "object" and has("nodes") then .nodes | map(.requestedReviewer.login // .login)
        else []
        end) as $requestedReviewers |
        (.reviews | if type == "array" then
            if length > 0 and (.[0] | has("author")) then map(.author.login)
            else []
            end
        elif type == "object" and has("nodes") then .nodes | map(.author.login)
        else []
        end) as $reviewAuthors |
        # Filter based on extracted data
        select(
            (($requestedReviewers | length) > 0 or ($reviewAuthors | length) > 0) and
            (.author.login != $user) and
            (($requestedReviewers + $reviewAuthors) | all(. != $user))
        )
    ]')

    PR_COUNT=$(echo "$FILTERED_PRS" | jq 'length')

    if [ "$PR_COUNT" -eq 0 ]; then
        print_warning "No open PRs with reviewers found in ${REPO} (excluding PRs where you are the author or reviewer)"
        exit 0
    fi

    print_success "Found ${BOLD}${PR_COUNT}${RESET} PR(s) with reviewers"

    # Display PRs
    echo ""
    echo -e "${BOLD}${BLUE}Available PRs:${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    declare -a PR_NUMBERS
    declare -a PR_BRANCHES
    index=1

    while IFS= read -r pr; do
        number=$(echo "$pr" | jq -r '.number')
        title=$(echo "$pr" | jq -r '.title')
        branch=$(echo "$pr" | jq -r '.headRefName')
        author=$(echo "$pr" | jq -r '.author.login')
        additions=$(echo "$pr" | jq -r '.additions')
        deletions=$(echo "$pr" | jq -r '.deletions')

        # Get reviewer info - handle both flat arrays and nested nodes
        reviewers=$(echo "$pr" | jq -r '
            ((.reviewRequests | if type == "array" then
                if length > 0 and (.[0] | has("login")) then map(.login)
                elif length > 0 and (.[0] | has("requestedReviewer")) then map(.requestedReviewer.login)
                else []
                end
            elif type == "object" and has("nodes") then .nodes | map(.requestedReviewer.login // .login)
            else []
            end) +
            (.reviews | if type == "array" then
                if length > 0 and (.[0] | has("author")) then map(.author.login)
                else []
                end
            elif type == "object" and has("nodes") then .nodes | map(.author.login)
            else []
            end)) | unique | join(", ")
        ')

        PR_NUMBERS[index]=$number
        PR_BRANCHES[index]=$branch

        echo -e "${BOLD}${GREEN}[$index]${RESET} ${YELLOW}#${number}${RESET} ${BOLD}${title}${RESET}"
        echo -e "    👤 Author: ${CYAN}${author}${RESET}"
        echo -e "    🌿 Branch: ${MAGENTA}${branch}${RESET}"
        echo -e "    👥 Reviewers: ${BLUE}${reviewers}${RESET}"
        echo -e "    📊 Lines: ${GREEN}+${additions}${RESET} ${RED}-${deletions}${RESET}"
        echo ""

        ((index++))
    done < <(echo "$FILTERED_PRS" | jq -c '.[]')

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    # Prompt for selection
    echo ""
    echo -e "${BOLD}${CYAN}Select a PR [1-$((index-1))]:${RESET} "
    read -r selection

    # Validate input
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -ge "$index" ]; then
        print_error "Invalid selection"
        exit 1
    fi

    SELECTED_PR=${PR_NUMBERS[$selection]}
    SELECTED_BRANCH=${PR_BRANCHES[$selection]}
else
    print_info "Using PR #${SELECTED_PR} from command line"
    # Validate that the PR exists and get its branch
    GH_ERROR=$(mktemp)
    if ! PR_DATA=$(gh pr view "$SELECTED_PR" --repo "$REPO" --json number,headRefName 2>"${GH_ERROR}"); then
        print_error "Failed to fetch PR #${SELECTED_PR}"
        if [ -s "${GH_ERROR}" ]; then
            print_error "Error details:"
            cat "${GH_ERROR}" >&2
        fi
        rm -f "${GH_ERROR}"
        exit 1
    fi
    rm -f "${GH_ERROR}"

    SELECTED_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
    print_success "Found PR #${SELECTED_PR} with branch: ${SELECTED_BRANCH}"
fi

print_header "🚀 Preparing container workspace for PR #${SELECTED_PR}"

print_info "Fetching PR metadata..."
GH_ERROR=$(mktemp)
if ! PR_METADATA=$(gh pr view "$SELECTED_PR" --repo "$REPO" --json headRefName,headRefOid 2>"${GH_ERROR}"); then
    print_error "Failed to fetch PR metadata"
    if [ -s "${GH_ERROR}" ]; then
        print_error "Error details:"
        cat "${GH_ERROR}" >&2
    fi
    rm -f "${GH_ERROR}"
    exit 1
fi
rm -f "${GH_ERROR}"

PR_HEAD_BRANCH=$(echo "$PR_METADATA" | jq -r '.headRefName')
if [ -n "$PR_HEAD_BRANCH" ] && [ "$PR_HEAD_BRANCH" != "null" ]; then
    SELECTED_BRANCH="$PR_HEAD_BRANCH"
fi
COMMIT_SHA=$(echo "$PR_METADATA" | jq -r '.headRefOid')

if [ -n "$COMMIT_SHA" ] && [ "$COMMIT_SHA" != "null" ]; then
    print_success "PR head commit: ${COMMIT_SHA:0:8}"
else
    print_warning "Unable to determine the PR head commit SHA"
    COMMIT_SHA=""
fi

SANITIZED_BRANCH="${SELECTED_BRANCH//\//-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_BASE_DIR="${SCRIPT_DIR}/runs"
RUN_DIR_NAME="pr-${SELECTED_PR}-${SANITIZED_BRANCH}"
RUN_PATH="${RUN_BASE_DIR}/${RUN_DIR_NAME}"

mkdir -p "${RUN_BASE_DIR}"

if [ "$RESUME_MODE" = "true" ]; then
    if [ ! -d "${RUN_PATH}" ]; then
        print_error "Resume mode requested but no artifacts found at ${RUN_PATH}"
        print_info "Run the agents at least once before using --resume."
        exit 1
    fi
    print_success "Using existing run artifacts directory: ${RUN_PATH}"
else
    if [ -d "${RUN_PATH}" ]; then
        print_warning "Existing run directory detected: ${RUN_PATH}"
        echo -e "${CYAN}Do you want to remove it and start fresh? [y/N]:${RESET} "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "${RUN_PATH}" || {
                print_error "Failed to remove ${RUN_PATH}"
                exit 1
            }
            print_success "Removed existing run directory"
        else
            print_info "Reusing existing run directory"
        fi
    fi

    mkdir -p "${RUN_PATH}"
    print_success "Run artifacts directory: ${RUN_PATH}"
fi

# Paths for agent outputs
CLAUDE_OUTPUT="${RUN_PATH}/claude-review.json"
CODEX_OUTPUT="${RUN_PATH}/codex-review.json"
GEMINI_OUTPUT="${RUN_PATH}/gemini-review.json"
MERGED_OUTPUT="${RUN_PATH}/merged-review.json"

# Function to run a single AI model review
run_model_review() {
    local model_name="$1"
    local model_cmd="$2"
    local output_file="$3"
    local agent_name="$4"

    local review_output_host="${output_file}"
    local review_output_container
    review_output_container="${CONTAINER_RUNNER_DIR}/$(basename "$output_file")"
    local workspace_review_container="/workspace/repo/.maxreview/${model_cmd}-review.json"
    local raw_output_file="${RUN_PATH}/${model_cmd}-raw.jsonl"

    rm -f "${review_output_host}" "${raw_output_file}"
    mkdir -p "$(dirname "${review_output_host}")"

    local prompt="You are conducting a comprehensive code review for PR #${SELECTED_PR} in repository ${REPO}.

Available tools at your disposal:
- gh: GitHub CLI for fetching PR details, diffs, and comments
- rg (ripgrep): Fast text search (better alternative to grep)
- fd: Fast file finder (better alternative to find)
- tree: Display directory structure
- fastmod: Fast code refactoring tool for large-scale changes
- ast-grep (sg): AST-based code search and manipulation
- git, jq, and standard Unix tools

Your task:
1. Use the gh command to gather all context about this PR:
   - Run 'gh pr view ${SELECTED_PR} --json title,body,author,number' to get PR details
   - Run 'gh pr diff ${SELECTED_PR}' to see the code changes
   - Run 'gh api repos/${REPO}/pulls/${SELECTED_PR}/comments --paginate' to get review comments
   - Use rg, fd, tree, or ast-grep to explore the codebase and understand context
   - Analyze the current state of the code in the current directory (the latest state from the PR) as well as the PR code changes.

2. Review the code for:
   - Bugs and logic errors
   - Security vulnerabilities
   - Performance issues
   - Code quality and maintainability
   - Best practices violations
   - Potential edge cases not handled
   - Type safety issues
   - Missing error handling

3. Take the following considerations into account:
   - Focus on files and lines that were changed in this PR. Confirm every potential issue by inspecting 'gh pr diff ${SELECTED_PR}' (optionally scoped with '--path <file>') or equivalent git diff commands.
   - Only emit inline findings when you can point to an exact line in the new revision of the file that appears in commit ${COMMIT_SHA}. Use repository-relative paths (e.g. 'src/file.ts').
   - If an issue concerns context that is not touched by the diff, set \"line\": null and explain it in the description so it can be surfaced in the general summary instead of as an inline comment.
   - If you find a bug, consider whether tests or linting could have caught it, and recommend those improvements as part of the proposed fix.
   - Avoid reporting on issues that were already noted in the PR comments or fixed in subsequent commits.

4. Prepare your findings in valid JSON format with this exact structure:
{
  \"pr_summary\": {
    \"number\": <pr_number>,
    \"title\": \"<pr_title>\",
    \"description\": \"<brief description of what changes this PR makes>\"
  },
  \"issues\": [
    {
      \"agent\": \"${agent_name}\",
      \"priority\": \"P0|P1|P2\",
      \"file\": \"<full_file_path>\",
      \"line\": <line_number_or_null>,
      \"commit_id\": \"${COMMIT_SHA}\",
      \"category\": \"<bug|security|performance|quality|style>\",
      \"description\": \"<detailed description of the issue>\",
      \"proposed_fix\": \"<concrete suggestion on how to fix it>\"
    }
  ]
}

Priority definitions:
- P0: Critical issues that must be fixed (security vulnerabilities, bugs causing crashes/data loss)
- P1: Important issues that should be fixed (logic bugs, performance problems, poor error handling)
- P2: Nice-to-have improvements (code style, minor optimizations, suggestions)

5. Write the JSON to '${workspace_review_container}'. The file must contain only the JSON object described above (no Markdown fences or extra commentary).
6. After writing the file, validate that it is well-formed JSON, then respond with a short confirmation message (no JSON in the message body)."

    print_info "Starting ${model_name} analysis..."

    local temp_output
    local exit_code
    local stderr_file
    local stderr_path

    stderr_file="$(basename "${output_file}").stderr"
    stderr_path="${RUN_PATH}/${stderr_file}"

    local prompt_file
    prompt_file=$(mktemp "${RUN_PATH}/prompt-${model_cmd}.XXXXXX.txt")
    printf '%s\n' "$prompt" > "$prompt_file"

    local runner_script
    runner_script=$(mktemp "${RUN_PATH}/run-${model_cmd}.XXXXXX.sh")
    cat > "$runner_script" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

MODEL_CMD="$1"
PROMPT_FILE="$2"
STDERR_FILE="$3"
REPO_SLUG="$4"
PR_NUMBER="$5"
COMMIT_SHA="$6"

HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"
CONTAINER_RUNNER_DIR="${CONTAINER_RUNNER_DIR:-/runner}"
MODEL_REVIEW_PATH="${MODEL_REVIEW_PATH:-${CONTAINER_RUNNER_DIR}/${MODEL_CMD}-review.json}"
MODEL_REVIEW_WORKSPACE_PATH="${MODEL_REVIEW_WORKSPACE_PATH:-/workspace/repo/.maxreview/${MODEL_CMD}-review.json}"

if [ -z "$HOST_UID" ] || [ "$HOST_UID" = "0" ]; then
    HOST_UID=1000
fi

if [ -z "$HOST_GID" ] || [ "$HOST_GID" = "0" ]; then
    HOST_GID=1000
fi

TARGET_USER="maxreview"
if getent passwd "$HOST_UID" >/dev/null 2>&1; then
    TARGET_USER="$(getent passwd "$HOST_UID" | cut -d: -f1)"
fi

    if ! getent group "$HOST_GID" >/dev/null 2>&1; then
        if [ "$HOST_GID" -lt 1000 ]; then
            groupadd --system -g "$HOST_GID" maxreview 2>/dev/null || true
        else
            groupadd -g "$HOST_GID" maxreview 2>/dev/null || true
        fi
    fi

    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        useradd_args=(-u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash -d "/home/$TARGET_USER")
        if [ "$HOST_UID" -lt 1000 ]; then
            useradd_args+=(--system)
        fi
        if ! useradd "${useradd_args[@]}" "$TARGET_USER" 2>/dev/null; then
            if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
                echo "Failed to create user ${TARGET_USER} with uid ${HOST_UID}" >&2
                exit 1
            fi
        fi
    fi

mkdir -p "$(dirname "$STDERR_FILE")"
touch "$STDERR_FILE"
chown -R "$HOST_UID:$HOST_GID" "$(dirname "$STDERR_FILE")"

if [ -d "$CONTAINER_RUNNER_DIR" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$CONTAINER_RUNNER_DIR" || true
fi

mkdir -p /workspace
chown -R "$HOST_UID:$HOST_GID" /workspace

cat > /tmp/run-as-user.sh <<'INNERSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_CMD:?MODEL_CMD is required}"
: "${PROMPT_FILE:?PROMPT_FILE is required}"
: "${STDERR_FILE:?STDERR_FILE is required}"
: "${REPO_SLUG:?REPO_SLUG is required}"
: "${PR_NUMBER:=}"
: "${COMMIT_SHA:=}"

: "${HOME_OVERRIDE:=/workspace}"
mkdir -p "$HOME_OVERRIDE"
export HOME="$HOME_OVERRIDE"

: > "$STDERR_FILE"
exec 2>>"$STDERR_FILE"

: "${MODEL_REVIEW_PATH:=/workspace/${MODEL_CMD}-review.json}"
mkdir -p "$(dirname "$MODEL_REVIEW_PATH")"
rm -f "$MODEL_REVIEW_PATH"

: "${MODEL_REVIEW_WORKSPACE_PATH:=/workspace/repo/.maxreview/${MODEL_CMD}-review.json}"
mkdir -p "$(dirname "$MODEL_REVIEW_WORKSPACE_PATH")"
rm -f "$MODEL_REVIEW_WORKSPACE_PATH"

setup_credentials() {
    local source_dir="$1"
    local target_dir="$2"

    if [[ -n "$source_dir" && -d "$source_dir" ]]; then
        mkdir -p "$target_dir"
        cp -a "$source_dir"/. "$target_dir"/
    else
        mkdir -p "$target_dir"
    fi
}

clone_repository() {
    local repo="$1"
    local pr_number="$2"
    local commit_sha="$3"

    export GIT_TERMINAL_PROMPT=0
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        export GH_TOKEN="${GITHUB_TOKEN}"
    fi

    mkdir -p /workspace
    cd /workspace

    rm -rf repo
    if ! gh repo clone "$repo" repo >/dev/null 2>&1; then
        if ! git clone "https://github.com/${repo}.git" repo >/dev/null 2>&1; then
            echo "Failed to clone repository ${repo}" >&2
            return 1
        fi
    fi

    cd repo

    if [ -n "$pr_number" ]; then
        if ! gh pr checkout "$pr_number" --detach >/dev/null 2>&1; then
            if ! git fetch origin "pull/${pr_number}/head:pr-${pr_number}" >/dev/null 2>&1; then
                echo "Failed to fetch PR ${pr_number}" >&2
                return 1
            fi
            if ! git checkout "pr-${pr_number}" >/dev/null 2>&1; then
                echo "Failed to checkout PR branch pr-${pr_number}" >&2
                return 1
            fi
        fi
    fi

    if [ -n "$commit_sha" ]; then
        if ! git checkout "$commit_sha" >/dev/null 2>&1; then
            echo "Failed to checkout commit ${commit_sha}" >&2
            return 1
        fi
    fi

    return 0
}

if ! clone_repository "$REPO_SLUG" "$PR_NUMBER" "$COMMIT_SHA"; then
    exit 1
fi

cd /workspace/repo

case "$MODEL_CMD" in
    claude)
        setup_credentials "${CLAUDE_CONFIG_SRC:-}" "$HOME/.claude"
        claude --print --output-format stream-json --verbose --dangerously-skip-permissions < "$PROMPT_FILE"
        ;;
    codex)
        setup_credentials "${CODEX_CONFIG_SRC:-}" "$HOME/.codex"
        codex exec --yolo < "$PROMPT_FILE"
        ;;
    gemini)
        setup_credentials "${GEMINI_CONFIG_SRC:-}" "$HOME/.gemini"
        gemini --output-format text --yolo < "$PROMPT_FILE"
        ;;
    *)
        echo "Unknown model command: $MODEL_CMD" >&2
        exit 1
        ;;
esac
INNERSCRIPT

chmod +x /tmp/run-as-user.sh
chown "$HOST_UID:$HOST_GID" /tmp/run-as-user.sh

if [ -z "${HOME_OVERRIDE:-}" ]; then
    HOME_OVERRIDE="/workspace"
fi

printf -v su_command "MODEL_CMD=%q PROMPT_FILE=%q STDERR_FILE=%q REPO_SLUG=%q PR_NUMBER=%q COMMIT_SHA=%q HOME_OVERRIDE=%q MODEL_REVIEW_PATH=%q CLAUDE_CONFIG_SRC=%q CODEX_CONFIG_SRC=%q GEMINI_CONFIG_SRC=%q /tmp/run-as-user.sh" \
    "$MODEL_CMD" "$PROMPT_FILE" "$STDERR_FILE" "$REPO_SLUG" "$PR_NUMBER" "$COMMIT_SHA" "$HOME_OVERRIDE" "${MODEL_REVIEW_PATH}" "${CLAUDE_CONFIG_SRC:-}" "${CODEX_CONFIG_SRC:-}" "${GEMINI_CONFIG_SRC:-}"

su "$TARGET_USER" -c "$su_command"

if [ -f "$MODEL_REVIEW_WORKSPACE_PATH" ]; then
    cp "$MODEL_REVIEW_WORKSPACE_PATH" "$MODEL_REVIEW_PATH"
    chown "$HOST_UID:$HOST_GID" "$MODEL_REVIEW_PATH" 2>/dev/null || true
    chmod 0644 "$MODEL_REVIEW_PATH" 2>/dev/null || true
fi
SCRIPT
    chmod +x "$runner_script"

    local runner_basename
    local prompt_basename
    local stderr_basename
    local host_uid
    local host_gid

    runner_basename=$(basename "$runner_script")
    prompt_basename=$(basename "$prompt_file")
    stderr_basename=$(basename "$stderr_path")
    host_uid=$(id -u)
    host_gid=$(id -g)

    local container_name
    container_name="maxreview-${model_cmd}-${SELECTED_PR}-$(date +%s%N)"
    print_info "${model_name} container: ${container_name}"
    local docker_args=(
        docker run
        --name "${container_name}"
        -v "${RUN_PATH}:${CONTAINER_RUNNER_DIR}"
        -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}"
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
        -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}"
        -e "GOOGLE_API_KEY=${GOOGLE_API_KEY:-}"
        -e "GEMINI_API_KEY=${GEMINI_API_KEY:-}"
        -e "HOME_OVERRIDE=/workspace"
        -e "HOST_UID=${host_uid}"
        -e "HOST_GID=${host_gid}"
        -e "CONTAINER_RUNNER_DIR=${CONTAINER_RUNNER_DIR}"
        -e "MODEL_REVIEW_PATH=${review_output_container}"
        -e "MODEL_REVIEW_WORKSPACE_PATH=${workspace_review_container}"
        -w /workspace
    )

    if [ -d "${HOME}/.claude" ]; then
        docker_args+=(-v "${HOME}/.claude:/host-configs/claude:ro")
        docker_args+=(-e "CLAUDE_CONFIG_SRC=/host-configs/claude")
    fi

    if [ -d "${HOME}/.codex" ]; then
        docker_args+=(-v "${HOME}/.codex:/host-configs/codex:ro")
        docker_args+=(-e "CODEX_CONFIG_SRC=/host-configs/codex")
    fi

    if [ -d "${HOME}/.gemini" ]; then
        docker_args+=(-v "${HOME}/.gemini:/host-configs/gemini:ro")
        docker_args+=(-e "GEMINI_CONFIG_SRC=/host-configs/gemini")
    fi

    docker_args+=(
        "${DOCKER_IMAGE}"
        /bin/bash "${CONTAINER_RUNNER_DIR}/${runner_basename}" "$model_cmd" "${CONTAINER_RUNNER_DIR}/${prompt_basename}" "${CONTAINER_RUNNER_DIR}/${stderr_basename}" "$REPO" "$SELECTED_PR" "${COMMIT_SHA}"
    )

    local docker_stderr
    docker_stderr=$(mktemp)
    if temp_output=$("${docker_args[@]}" 2>"${docker_stderr}"); then
        exit_code=0
    else
        exit_code=$?
    fi

    rm -f "$prompt_file" "$runner_script"

    printf '%s\n' "$temp_output" > "$raw_output_file"

    if [ $exit_code -eq 0 ]; then
        local review_success="false"
        local review_failure_reason=""

        if [ -f "${review_output_host}" ]; then
            if jq empty "${review_output_host}" 2>/dev/null; then
                review_success="true"
                print_success "${model_name} analysis completed"
            else
                print_warning "${model_name} produced invalid JSON in ${review_output_host}. Keeping original as ${review_output_host}.invalid"
                mv "${review_output_host}" "${review_output_host}.invalid" 2>/dev/null || true
                review_failure_reason="produced invalid JSON"
            fi
        else
            print_warning "${model_name} did not create the expected review file (${review_output_host})"
            review_failure_reason="did not create the expected review file"
        fi

        if [ "$review_success" = "false" ]; then
            if [ -z "$review_failure_reason" ]; then
                review_failure_reason="encountered an unknown error"
            fi
            echo "{\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Error\",\"description\":\"${model_name} ${review_failure_reason}\"},\"issues\":[]}" > "${output_file}"
        fi

        if [ -f "${stderr_path}" ]; then
            if [ ! -s "${stderr_path}" ]; then
                rm -f "${stderr_path}"
            elif ! grep -v "Loaded cached credentials\|stdout is not a terminal\|YOLO mode is enabled" "${stderr_path}" | grep -q .; then
                rm -f "${stderr_path}"
            fi
        fi
        rm -f "${docker_stderr}"
    else
        print_error "${model_name} analysis failed"
        local error_shown=false

        if [ -f "${docker_stderr}" ] && [ -s "${docker_stderr}" ]; then
            print_warning "Docker error details:"
            cat "${docker_stderr}" >&2
            error_shown=true
        fi

        if [ -f "${stderr_path}" ] && [ -s "${stderr_path}" ]; then
            print_warning "Container stderr:"
            cat "${stderr_path}" >&2
            error_shown=true
        fi

        if [ "$error_shown" = false ]; then
            print_warning "No error details captured. Common issues:"
            echo "  - Missing or invalid credentials in ~/.${model_cmd}/" >&2
            echo "  - Check if ${model_cmd} CLI is properly authenticated" >&2
            echo "  - For Claude: run 'claude auth' to set up credentials" >&2
        fi

        rm -f "${docker_stderr}"
        echo "{\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Error\",\"description\":\"${model_name} analysis failed\"},\"issues\":[]}" > "${output_file}"
    fi
}

# Function to merge review results using jq
merge_reviews() {
    local claude_file="$1"
    local codex_file="$2"
    local gemini_file="$3"

    jq -s '
    {
        "descriptions": [
            {
                "agent": "claude",
                "description": (.[0].pr_summary.description // "No description")
            },
            {
                "agent": "codex",
                "description": (.[1].pr_summary.description // "No description")
            },
            {
                "agent": "gemini",
                "description": (.[2].pr_summary.description // "No description")
            }
        ],
        "pr_summary": {
            "number": (.[0].pr_summary.number // 0),
            "title": (.[0].pr_summary.title // "Unknown")
        },
        "issues": ([.[] | (.issues // []) | .[]] | sort_by(
            if .priority == "P0" then 0
            elif .priority == "P1" then 1
            else 2
            end
        ))
    }
    ' "${claude_file}" "${codex_file}" "${gemini_file}"
}

fetch_valid_inline_map() {
    local repo="$1"
    local pr_number="$2"

    local raw_files
    if ! raw_files=$(gh api "repos/${repo}/pulls/${pr_number}/files" --paginate | jq -s 'add'); then
        return 1
    fi

    local parsed
    if ! parsed=$(
        RAW_FILES="$raw_files" python3 <<'PY'
import json
import os
import re

files = json.loads(os.environ["RAW_FILES"])
pattern = re.compile(r'@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
result = {}

for file_info in files:
    patch = file_info.get("patch")
    if not patch:
        continue

    current = None
    valid_lines = set()

    for line in patch.splitlines():
        if line.startswith('@@'):
            match = pattern.match(line)
            if not match:
                current = None
                continue
            current = int(match.group(1))
            continue

        if current is None:
            continue

        if line.startswith('+') and not line.startswith('+++'):
            valid_lines.add(current)
            current += 1
        elif line.startswith('-') and not line.startswith('---'):
            continue
        else:
            valid_lines.add(current)
            current += 1

    if valid_lines:
        result[file_info.get("filename")] = sorted(valid_lines)

print(json.dumps(result))
PY
    ); then
        return 1
    fi

    echo "$parsed"
    return 0
}

# Skip or run agents based on mode
if [ "$RESUME_MODE" = "true" ]; then
    print_header "⏩ Resume Mode: Reusing previous agent results"
    if [[ -n "$SELECTED_AGENTS" ]]; then
        print_warning "--agent option is ignored when --resume is used"
    fi

    for agent in "claude" "codex" "gemini"; do
        case "$agent" in
            claude) output_file="$CLAUDE_OUTPUT" ;;
            codex) output_file="$CODEX_OUTPUT" ;;
            gemini) output_file="$GEMINI_OUTPUT" ;;
        esac

        if [ -f "$output_file" ]; then
            print_info "Found ${agent} review: ${output_file}"
        else
            print_warning "No ${agent} review found at ${output_file}, creating placeholder"
            echo "{\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Not run\",\"description\":\"${agent} review not found in resume mode\"},\"issues\":[]}" > "$output_file"
        fi
    done
else
    # Determine which agents to run
    declare -a AGENTS_TO_RUN
    if [[ -n "$SELECTED_AGENTS" ]]; then
        IFS=',' read -ra AGENTS_TO_RUN <<< "$SELECTED_AGENTS"
        for i in "${!AGENTS_TO_RUN[@]}"; do
            AGENTS_TO_RUN[i]=$(echo "${AGENTS_TO_RUN[i]}" | tr '[:upper:]' '[:lower:]' | xargs)
        done
    else
        AGENTS_TO_RUN=("claude" "codex" "gemini")
    fi

    print_header "🤖 Running automated code review with AI models: ${AGENTS_TO_RUN[*]}"
    print_info "Launching parallel reviews (this may take a few minutes)..."

    declare -a PIDS
    declare -a PID_AGENTS

    # Run selected models in parallel
    for agent in "${AGENTS_TO_RUN[@]}"; do
        case "$agent" in
            claude)
                run_model_review "Claude" "claude" "${CLAUDE_OUTPUT}" "claude" &
                PIDS+=($!)
                PID_AGENTS+=("claude")
                ;;
            codex)
                run_model_review "Codex" "codex" "${CODEX_OUTPUT}" "codex" &
                PIDS+=($!)
                PID_AGENTS+=("codex")
                ;;
            gemini)
                run_model_review "Gemini" "gemini" "${GEMINI_OUTPUT}" "gemini" &
                PIDS+=($!)
                PID_AGENTS+=("gemini")
                ;;
        esac
    done

    # Wait for all background jobs to complete
    declare -a FAILED_MODELS=()
    for idx in "${!PIDS[@]}"; do
        pid="${PIDS[$idx]}"
        agent="${PID_AGENTS[$idx]}"
        if ! wait "$pid"; then
            FAILED_MODELS+=("$agent")
        fi
    done

    if [ ${#FAILED_MODELS[@]} -gt 0 ]; then
        print_warning "Some model runs failed: ${FAILED_MODELS[*]}"
    else
        print_success "All AI models completed their analysis! 📝"
    fi

    agent_in_list() {
        local search="$1"
        shift
        local item
        for item in "$@"; do
            if [[ "$item" == "$search" ]]; then
                return 0
            fi
        done
        return 1
    }

    for agent in "claude" "codex" "gemini"; do
        output_var="${agent^^}_OUTPUT"
        output_file="${!output_var}"

        if ! agent_in_list "$agent" "${AGENTS_TO_RUN[@]}"; then
            echo "{\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Not run\",\"description\":\"${agent} was not selected\"},\"issues\":[]}" > "$output_file"
        fi
    done
fi


create_pending_github_review() {
    local merged_json="$1"
    local repo="$2"
    local pr_number="$3"
    local p0_count="$4"
    local p1_count="$5"
    local p2_count="$6"
    local total_issues="$7"
    local head_commit="$8"

    local allow_inline_comments="true"
    local comments_payload="[]"
    local comment_count=0
    local inline_validation=""
    local invalid_inline_notes=""

    if ! comments_payload=$(printf '%s' "$merged_json" | jq \
        --arg commit "$head_commit" \
        '
        [.issues[]
            | ((.file // "")
                | gsub("^/workspace/repo/?"; "")
                | gsub("^\\./"; "")
            ) as $path
            | .line as $raw_line
            | (.description // "") as $description
            | (.proposed_fix // "") as $fix
            | (.priority // "Unspecified") as $priority
            | (.category // "unspecified") as $category
            | (try (
                if $raw_line == null then null
                elif ($raw_line | type) == "number" then ($raw_line | floor)
                elif ($raw_line | type) == "string" and ($raw_line | length) > 0 then ($raw_line | tonumber | floor)
                else null
                end
            ) catch null) as $line
            | select(($path // "") != "" and $line != null and $line >= 1)
            | {
                path: $path,
                line: $line,
                side: "RIGHT"
            }
            | (if ($commit | length) > 0 then . + {commit_id: $commit} else . end)
            | . + {
                body: (
                    (if ($description | length) > 0 then $description else "Issue requires attention." end) +
                    (if ($fix | length) > 0 then "\n\nSuggested fix: " + $fix else "" end) +
                    "\n\nPriority: " + $priority +
                    "\nCategory: " + $category
                )
            }
        ]'); then
        print_error "Failed to prepare review comments payload."
        return 1
    fi

    if ! comment_count=$(printf '%s' "$comments_payload" | jq 'length'); then
        print_error "Unable to count prepared review comments."
        return 1
    fi

    if [ "$comment_count" -gt 0 ]; then
        local valid_map
        if ! valid_map=$(fetch_valid_inline_map "$repo" "$pr_number"); then
            print_warning "Unable to retrieve PR diff metadata; inline comments will be converted to summary notes."
            allow_inline_comments="false"
            comments_payload="[]"
            comment_count=0
        else
            if ! inline_validation=$(jq -n \
                --argjson comments "$comments_payload" \
                --argjson valid "$valid_map" \
                '
                reduce $comments[] as $comment (
                    {valid: [], invalid: []};
                    if (($valid[$comment.path] // []) | index($comment.line)) != null then
                        .valid += [$comment]
                    else
                        .invalid += [$comment]
                    end
                )
                '); then
                print_warning "Failed to validate inline comments; they will be included in the summary instead."
                allow_inline_comments="false"
                comments_payload="[]"
                comment_count=0
            else
                comments_payload=$(printf '%s' "$inline_validation" | jq '.valid')
                comment_count=$(printf '%s' "$inline_validation" | jq '.valid | length')
                local invalid_count
                invalid_count=$(printf '%s' "$inline_validation" | jq '.invalid | length')
                if [ "$invalid_count" -gt 0 ]; then
                    allow_inline_comments="true"
                    local invalid_payload
                    invalid_payload=$(printf '%s' "$inline_validation" | jq '.invalid')
                    invalid_inline_notes=$(jq -n \
                        --argjson invalid "$invalid_payload" \
                        --argjson issues "$(printf '%s' "$merged_json" | jq '.issues')" \
                        '
                        [ $invalid[] as $comment |
                          (first(
                              $issues[]
                              | ((.file // "") | gsub("^/workspace/repo/?"; "") | gsub("^\\./"; "")) as $issue_path
                              | (try (
                                  if .line == null then null
                                  elif (.line | type) == "string" then (.line | tonumber)
                                  else (.line | floor)
                                  end
                              ) catch null) as $issue_line
                              | select($issue_path == $comment.path and $issue_line == $comment.line)
                          )?) as $match
                          | (if $match != null then
                                "- " +
                                (if ($match.description // "" | length) > 0 then $match.description else "Issue requires attention." end) +
                                " (file: " + (($match.file // "" | gsub("^/workspace/repo/?"; "") | gsub("^\\./"; ""))) +
                                ", requested line: " + ($comment.line | tostring) + ")" +
                                (if ($match.proposed_fix // "" | length) > 0 then "\n  Suggested fix: " + $match.proposed_fix else "" end) +
                                "\n  Priority: " + ($match.priority // "Unspecified") +
                                "\n  Category: " + ($match.category // "unspecified")
                            else
                                "- " +
                                (if ($comment.body // "" | length) > 0 then ($comment.body | split("\n\nPriority:")[0]) else "Issue requires attention." end) +
                                " (file: " + ($comment.path // "unknown") + ", requested line: " + ($comment.line | tostring) + ")"
                            end)
                        ] | if length > 0 then join("\n\n") else "" end
                        ')
                    if [ "$invalid_count" -gt 0 ]; then
                        print_warning "Ignored ${invalid_count} inline comment(s) that did not match the PR diff; moved to summary."
                    fi
                fi
                if [ "$comment_count" -eq 0 ]; then
                    allow_inline_comments="false"
                fi
            fi
        fi
    fi

    if [ "$allow_inline_comments" = "true" ] && [ "$comment_count" -eq 0 ]; then
        print_warning "No inline issues qualified for GitHub comments."
    fi

    local general_notes
    local include_all_for_summary="false"
    local summary_intro="Issues without precise location:"
    if [ "$allow_inline_comments" != "true" ] || [ "$comment_count" -eq 0 ]; then
        include_all_for_summary="true"
        summary_intro="Review findings:"
    fi

    if ! general_notes=$(printf '%s' "$merged_json" | jq -r \
        --argjson include_all "$include_all_for_summary" \
        '
        [.issues[]
            | ((.file // "")
                | gsub("^/workspace/repo/?"; "")
                | gsub("^\\./"; "")
            ) as $path
            | (.line // "") as $raw_line
            | (.description // "") as $description
            | (.priority // "Unspecified") as $priority
            | (.category // "unspecified") as $category
            | (.proposed_fix // "") as $fix
            | (try (
                if $raw_line == null then null
                elif ($raw_line | type) == "number" then ($raw_line | floor)
                elif ($raw_line | type) == "string" and ($raw_line | length) > 0 then ($raw_line | tonumber | floor)
                else null
                end
            ) catch null) as $line
            | select($include_all == true or ($path // "") == "" or $line == null)
            | "- " +
              (if ($description | length) > 0 then $description else "Issue requires attention." end) +
              (if ($path // "" | length) > 0 then " (file: " + $path + ")" else "" end) +
              (if $line != null then " line " + ($line | tostring) else "" end) +
              "\n  Priority: " + $priority +
              "\n  Category: " + $category +
              (if ($fix | length) > 0 then "\n  Suggested fix: " + $fix else "" end)
        ] | if length > 0 then join("\n\n") else "" end
    '); then
        print_error "Failed to prepare summary notes for non-inline issues."
        return 1
    fi

    if [ "$general_notes" = "null" ]; then
        general_notes=""
    fi

    if [ -n "$invalid_inline_notes" ]; then
        if [ -n "$general_notes" ]; then
            general_notes+=$'\n\n'
        fi
        general_notes+="Issues moved to summary (line not in diff):\n"
        general_notes+="$invalid_inline_notes"
    fi

    if [ "$general_notes" = "null" ]; then
        general_notes=""
    fi

    local review_body
    printf -v review_body 'Automated review findings:\n- Critical (P0): %s\n- Important (P1): %s\n- Suggestions (P2): %s\n- Total issues: %s' \
        "$p0_count" "$p1_count" "$p2_count" "$total_issues"

    if [ -n "$general_notes" ]; then
        review_body+=$'\n\n'
        review_body+="$summary_intro"
        review_body+=$'\n'
        review_body+="$general_notes"
    fi

    if [ -z "$review_body" ] && [ "$comment_count" -eq 0 ]; then
        print_warning "No review content available to send to GitHub."
        return 1
    fi

    local request_json
    if ! request_json=$(jq -n \
        --arg body "$review_body" \
        --argjson comments "$comments_payload" \
        '({}
          | (if ($body | length) > 0 then . + {body: $body} else . end)
          | (if ($comments | length) > 0 then . + {comments: $comments} else . end)
        )'); then
        print_error "Failed to build GitHub review payload."
        return 1
    fi

    if [ -z "$request_json" ] || [ "$request_json" = "{}" ]; then
        print_warning "Empty GitHub review payload, skipping."
        return 1
    fi

    local pending_payload_path="${RUN_PATH}/pending-review-request.json"
    if ! printf '%s' "$request_json" > "${pending_payload_path}"; then
        print_warning "Could not persist GitHub review payload for debugging."
    else
        print_info "Prepared GitHub review payload with ${comment_count} inline comment(s); saved to ${pending_payload_path}"
    fi

    local gh_error
    gh_error=$(mktemp)
    local gh_error_log="${RUN_PATH}/pending-review-error.log"
    local response
    if ! response=$(printf '%s' "$request_json" | gh api --method POST \
        "repos/${repo}/pulls/${pr_number}/reviews" \
        --input - 2>"${gh_error}"); then
        print_error "Failed to create pending GitHub review."
        if [ -s "${gh_error}" ]; then
            print_error "Error details:"
            cat "${gh_error}" >&2
            if ! cp "${gh_error}" "${gh_error_log}" 2>/dev/null; then
                print_warning "Unable to persist GitHub error details to ${gh_error_log}"
            else
                print_warning "GitHub API error details saved to ${gh_error_log}"
            fi
        fi
        print_warning "Inspect ${pending_payload_path} to review the request sent to GitHub."
        rm -f "${gh_error}"
        return 1
    fi
    rm -f "${gh_error}"

    local review_url
    review_url=$(printf '%s' "$response" | jq -r '.html_url // empty' 2>/dev/null || true)

    if [ "$comment_count" -gt 0 ]; then
        print_success "Created pending GitHub review with ${comment_count} inline comment(s)."
    else
        print_success "Created pending GitHub review with a summary comment."
    fi

    if [ -n "$review_url" ] && [ "$review_url" != "null" ]; then
        print_info "Review URL (visible only to you until submitted): ${review_url}"
    fi

    rm -f "${pending_payload_path}" 2>/dev/null || true

    return 0
}

prompt_for_pending_github_review() {
    local merged_json="$1"
    local repo="$2"
    local pr_number="$3"
    local p0_count="$4"
    local p1_count="$5"
    local p2_count="$6"
    local total_issues="$7"
    local head_commit="$8"

    printf "%b" "${BOLD}${CYAN}Create a pending GitHub review with these findings? [y/N]: ${RESET}"
    local response=""
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "Skipping GitHub review creation."
        return 0
    fi

    if create_pending_github_review "$merged_json" "$repo" "$pr_number" "$p0_count" "$p1_count" "$p2_count" "$total_issues" "$head_commit"; then
        print_info "Review stays pending until you submit it on GitHub."
    else
        print_warning "Pending GitHub review was not created."
    fi
}

# Merge the results
print_info "Merging results from all models..."

# Verify all review files are valid JSON before merging
for review_file in "${CLAUDE_OUTPUT}" "${CODEX_OUTPUT}" "${GEMINI_OUTPUT}"; do
    if ! jq empty "$review_file" 2>/dev/null; then
        print_error "Invalid JSON in ${review_file}, replacing with empty review"
        echo "{\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Error\",\"description\":\"Review file was invalid\"},\"issues\":[]}" > "$review_file"
    fi
done

MERGED_RESULT=$(merge_reviews "${CLAUDE_OUTPUT}" "${CODEX_OUTPUT}" "${GEMINI_OUTPUT}")
if [ -z "$MERGED_RESULT" ] || ! echo "$MERGED_RESULT" | jq empty 2>/dev/null; then
    print_error "Failed to merge reviews, creating fallback result"
    MERGED_RESULT="{\"descriptions\":[{\"agent\":\"error\",\"description\":\"Failed to merge reviews\"}],\"pr_summary\":{\"number\":${SELECTED_PR},\"title\":\"Merge Error\"},\"issues\":[]}"
fi
echo "$MERGED_RESULT" > "${MERGED_OUTPUT}"

# Parse and display the merged review
if echo "$MERGED_RESULT" | jq empty 2>/dev/null; then
    print_success "Merged code review completed! 📝"
    echo ""

    # Extract and display PR summary
    print_header "📋 PR Summary"
    PR_TITLE=$(echo "$MERGED_RESULT" | jq -r '.pr_summary.title')

    echo -e "${BOLD}Title:${RESET} ${PR_TITLE}"
    echo ""

    # Display descriptions from each agent
    print_header "📝 Descriptions from Each AI Model"
    echo "$MERGED_RESULT" | jq -r '.descriptions[] |
        "🤖 \u001b[1;35m\(.agent | ascii_upcase)\u001b[0m: \(.description)"'
    echo ""

    # Count issues by priority
    P0_COUNT=$(echo "$MERGED_RESULT" | jq '[.issues[] | select(.priority == "P0")] | length')
    P1_COUNT=$(echo "$MERGED_RESULT" | jq '[.issues[] | select(.priority == "P1")] | length')
    P2_COUNT=$(echo "$MERGED_RESULT" | jq '[.issues[] | select(.priority == "P2")] | length')
    TOTAL_ISSUES=$(echo "$MERGED_RESULT" | jq '.issues | length')

    print_header "📊 Issues Found: ${TOTAL_ISSUES}"

    if [ "$TOTAL_ISSUES" -eq 0 ]; then
        print_success "No issues found! Code looks great! ✨"
    else
        echo -e "${RED}${BOLD}🔴 P0 (Critical):${RESET} ${P0_COUNT}"
        echo -e "${YELLOW}${BOLD}🟡 P1 (Important):${RESET} ${P1_COUNT}"
        echo -e "${BLUE}${BOLD}🔵 P2 (Suggestions):${RESET} ${P2_COUNT}"
        echo ""

        # Display P0 issues
        if [ "$P0_COUNT" -gt 0 ]; then
            print_header "🔴 P0 - Critical Issues"
            echo "$MERGED_RESULT" | jq -r '.issues[] | select(.priority == "P0") |
                "╭─────────────────────────────────────────────────────────────\n" +
                "│ 🤖 Agent: \u001b[1;35m\(.agent | ascii_upcase)\u001b[0m\n" +
                "│ 📁 \u001b[1;36m\(.file):\(.line)\u001b[0m\n" +
                "│ 🏷️  \u001b[1m\(.category)\u001b[0m\n" +
                "│\n" +
                "│ \u001b[1mIssue:\u001b[0m \(.description)\n" +
                "│\n" +
                "│ \u001b[1;32m💡 Fix:\u001b[0m \(.proposed_fix)\n" +
                "╰─────────────────────────────────────────────────────────────\n"'
        fi

        # Display P1 issues
        if [ "$P1_COUNT" -gt 0 ]; then
            print_header "🟡 P1 - Important Issues"
            echo "$MERGED_RESULT" | jq -r '.issues[] | select(.priority == "P1") |
                "╭─────────────────────────────────────────────────────────────\n" +
                "│ 🤖 Agent: \u001b[1;35m\(.agent | ascii_upcase)\u001b[0m\n" +
                "│ 📁 \u001b[1;36m\(.file):\(.line)\u001b[0m\n" +
                "│ 🏷️  \u001b[1m\(.category)\u001b[0m\n" +
                "│\n" +
                "│ \u001b[1mIssue:\u001b[0m \(.description)\n" +
                "│\n" +
                "│ \u001b[1;32m💡 Fix:\u001b[0m \(.proposed_fix)\n" +
                "╰─────────────────────────────────────────────────────────────\n"'
        fi

        # Display P2 issues
        if [ "$P2_COUNT" -gt 0 ]; then
            print_header "🔵 P2 - Suggestions"
            echo "$MERGED_RESULT" | jq -r '.issues[] | select(.priority == "P2") |
                "╭─────────────────────────────────────────────────────────────\n" +
                "│ 🤖 Agent: \u001b[1;35m\(.agent | ascii_upcase)\u001b[0m\n" +
                "│ 📁 \u001b[1;36m\(.file):\(.line)\u001b[0m\n" +
                "│ 🏷️  \u001b[1m\(.category)\u001b[0m\n" +
                "│\n" +
                "│ \u001b[1mIssue:\u001b[0m \(.description)\n" +
                "│\n" +
                "│ \u001b[1;32m💡 Fix:\u001b[0m \(.proposed_fix)\n" +
                "╰─────────────────────────────────────────────────────────────\n"'
        fi
    fi

    # Save individual and merged reviews
    print_info "Individual reviews saved:"
    echo -e "  ${CYAN}${CLAUDE_OUTPUT}${RESET}"
    echo -e "  ${CYAN}${CODEX_OUTPUT}${RESET}"
    echo -e "  ${CYAN}${GEMINI_OUTPUT}${RESET}"
    print_info "Merged review saved to: ${MERGED_OUTPUT}"

    prompt_for_pending_github_review "$MERGED_RESULT" "$REPO" "$SELECTED_PR" "$P0_COUNT" "$P1_COUNT" "$P2_COUNT" "$TOTAL_ISSUES" "$COMMIT_SHA"
else
    print_error "Failed to parse merged output as JSON"
    print_warning "Raw output:"
    echo "$MERGED_RESULT"
fi

echo ""
echo -e "${BOLD}${GREEN}Review artifacts directory:${RESET}"
echo -e "${CYAN}  ${RUN_PATH}${RESET}"
echo ""
print_info "Need a local checkout? Run:"
echo -e "${CYAN}  gh pr checkout ${SELECTED_PR}${RESET}"
