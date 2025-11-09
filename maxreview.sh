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

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code ${exit_code}"
    fi
}

trap cleanup EXIT

check_dependencies() {
    local missing_deps=()

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    if ! command -v gh &> /dev/null; then
        missing_deps+=("gh (GitHub CLI)")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v claude &> /dev/null; then
        missing_deps+=("claude (Claude CLI)")
    fi

    if ! command -v codex &> /dev/null; then
        missing_deps+=("codex (Codex CLI)")
    fi

    if ! command -v gemini &> /dev/null; then
        missing_deps+=("gemini (Gemini CLI)")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo -e "${CYAN}Please install them and try again.${RESET}"
        exit 1
    fi
}

show_usage() {
    echo "Usage: $0"
    echo ""
    echo "Interactive script to fetch open GitHub PRs with reviewers, create a git worktree,"
    echo "and run automated code review with multiple AI models (Claude, Codex, Gemini)."
    echo ""
    echo "Prerequisites:"
    echo "  - git"
    echo "  - gh (GitHub CLI)"
    echo "  - jq"
    echo "  - claude (Claude CLI)"
    echo "  - codex (Codex CLI)"
    echo "  - gemini (Gemini CLI)"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
fi

check_dependencies

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not a git repository!"
    exit 1
fi

# Get repository information
print_info "Detecting repository..."
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
if [ -z "$REPO" ]; then
    print_error "Could not detect GitHub repository. Make sure you're in a valid repo with gh CLI configured."
    exit 1
fi
print_success "Repository: ${BOLD}${REPO}${RESET}"

# Get current GitHub user
print_info "Getting your GitHub username..."
CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null)
if [ -z "$CURRENT_USER" ]; then
    print_error "Could not get GitHub username. Make sure gh CLI is authenticated."
    exit 1
fi
print_success "Current user: ${BOLD}${CURRENT_USER}${RESET}"

# Fetch PRs with reviewers
print_header "🔍 Fetching open PRs with reviewers (excluding yours)..."
PRS=$(gh pr list --repo "$REPO" --state open --json number,title,headRefName,author,reviewRequests,reviews,additions,deletions --limit 100)

# Filter PRs that:
# 1. Have at least one reviewer (either requested or completed review)
# 2. Current user is NOT the author
# 3. Current user is NOT in the reviewers list
FILTERED_PRS=$(echo "$PRS" | jq -c --arg user "$CURRENT_USER" '[
    .[] | select(
        ((.reviewRequests | length) > 0 or (.reviews | length) > 0) and
        (.author.login != $user) and
        ([.reviewRequests[].login, .reviews[].author.login] | all(. != $user))
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

    # Get reviewer info
    reviewers=$(echo "$pr" | jq -r '[(.reviewRequests[].login // empty), (.reviews[].author.login // empty)] | unique | join(", ")')

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

print_header "🚀 Setting up worktree for PR #${SELECTED_PR}"

ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Fetch the PR
print_info "Fetching PR #${SELECTED_PR}..."
gh pr checkout "$SELECTED_PR" --detach 2>/dev/null || {
    print_error "Failed to fetch PR"
    exit 1
}

# Get the commit SHA
COMMIT_SHA=$(git rev-parse HEAD)
print_success "Fetched commit: ${COMMIT_SHA:0:8}"

# Go back to original branch
print_info "Returning to ${ORIGINAL_BRANCH}..."
git checkout "$ORIGINAL_BRANCH" > /dev/null 2>&1

# Create worktree directory name
WORKTREE_DIR="pr-${SELECTED_PR}-${SELECTED_BRANCH}"
WORKTREE_PATH="../${WORKTREE_DIR}"

# Check if worktree is registered in git (even if directory doesn't exist)
WORKTREE_REGISTERED=false
if git worktree list | grep -q "$(basename "$WORKTREE_PATH")"; then
    WORKTREE_REGISTERED=true
fi

# Check if worktree needs cleanup
if [ "$WORKTREE_REGISTERED" = true ] || [ -d "$WORKTREE_PATH" ]; then
    if [ "$WORKTREE_REGISTERED" = true ]; then
        print_warning "Worktree is registered in git: ${WORKTREE_PATH}"
    fi
    if [ -d "$WORKTREE_PATH" ]; then
        print_warning "Worktree directory exists: ${WORKTREE_PATH}"
    fi

    echo -e "${CYAN}Do you want to remove it and recreate? [y/N]:${RESET} "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cleaning up existing worktree..."

        # First, try to remove the worktree registration if it exists
        if [ "$WORKTREE_REGISTERED" = true ]; then
            if git worktree remove "$WORKTREE_PATH" --force 2>/dev/null; then
                print_success "Removed worktree registration"
            else
                print_warning "Could not remove worktree, pruning stale entries..."
                git worktree prune 2>/dev/null || true
            fi
        fi

        # Then remove the directory if it exists
        if [ -d "$WORKTREE_PATH" ]; then
            rm -rf "$WORKTREE_PATH" || {
                print_error "Failed to remove directory ${WORKTREE_PATH}"
                exit 1
            }
            print_success "Removed worktree directory"
        fi

        # Final verification
        if git worktree list | grep -q "$(basename "$WORKTREE_PATH")"; then
            print_error "Worktree is still registered, running final prune..."
            git worktree prune -v
        fi

        print_success "Cleanup complete"
    else
        print_info "Aborting"
        exit 0
    fi
fi

# Create the worktree
print_info "Creating worktree at ${WORKTREE_PATH}..."
if git worktree add "$WORKTREE_PATH" "$COMMIT_SHA" > /dev/null 2>&1; then
    print_success "Worktree created successfully! 🎉"
else
    print_error "Failed to create worktree"
    print_info "Debug: Listing existing worktrees..."
    git worktree list
    exit 1
fi

# Symlink .claude directory if it exists
ORIGINAL_DIR=$(pwd)
if [ -d "${ORIGINAL_DIR}/.claude" ]; then
    print_info "Symlinking .claude directory..."
    ln -sf "${ORIGINAL_DIR}/.claude" "${WORKTREE_PATH}/.claude"
    print_success ".claude directory symlinked"
fi

# Function to run a single AI model review
run_model_review() {
    local model_name="$1"
    local model_cmd="$2"
    local output_file="$3"
    local agent_name="$4"

    local prompt="You are conducting a comprehensive code review for PR #${SELECTED_PR} in repository ${REPO}.

Your task:
1. Use the gh command to gather all context about this PR:
   - Run 'gh pr view ${SELECTED_PR} --json title,body,author,number' to get PR details
   - Run 'gh pr diff ${SELECTED_PR}' to see the code changes
   - Run 'gh api repos/${REPO}/pulls/${SELECTED_PR}/comments --paginate' to get review comments
   - Analyze the files changed in the current working directory

2. Review the code for:
   - Bugs and logic errors
   - Security vulnerabilities
   - Performance issues
   - Code quality and maintainability
   - Best practices violations
   - Potential edge cases not handled
   - Type safety issues
   - Missing error handling

3. Output your findings in valid JSON format with this exact structure:
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
      \"line\": <line_number>,
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

Ensure your response is ONLY valid JSON, no additional text before or after."

    print_info "Starting ${model_name} analysis..."

    local temp_output
    local exit_code
    local stderr_file="${output_file}.stderr"

    case "$model_cmd" in
        claude)
            temp_output=$(cd "${WORKTREE_PATH}" && claude --output-format text 2>"${stderr_file}" <<EOF
${prompt}
EOF
)
            exit_code=$?
            ;;
        codex)
            temp_output=$(cd "${WORKTREE_PATH}" && codex exec 2>"${stderr_file}" <<EOF
${prompt}
EOF
)
            exit_code=$?
            ;;
        gemini)
            temp_output=$(cd "${WORKTREE_PATH}" && gemini --output-format text 2>"${stderr_file}" <<EOF
${prompt}
EOF
)
            exit_code=$?
            ;;
        *)
            print_error "Unknown model command: ${model_cmd}"
            exit_code=1
            ;;
    esac

    if [ $exit_code -eq 0 ] && [ -n "$temp_output" ]; then
        # Try to extract JSON from output (in case there are extra messages)
        local json_output
        json_output=$(echo "$temp_output" | jq -s '.[0]' 2>/dev/null)

        if [ -n "$json_output" ] && [ "$json_output" != "null" ]; then
            echo "$json_output" > "${output_file}"
            print_success "${model_name} analysis completed"
        else
            # Try to find first valid JSON object using awk
            json_output=$(echo "$temp_output" | awk '
                /^{/ { flag=1; json=$0; next }
                flag { json=json"\n"$0 }
                /^}/ && flag { print json"\n}"; exit }
            ')
            if [ -n "$json_output" ] && echo "$json_output" | jq empty 2>/dev/null; then
                echo "$json_output" | jq '.' > "${output_file}"
                print_success "${model_name} analysis completed"
            else
                print_warning "${model_name} returned non-JSON output, saving as-is"
                echo "$temp_output" > "${output_file}"
            fi
        fi

        # Clean up stderr file if it's empty or only contains benign messages
        if [ -f "${stderr_file}" ]; then
            if [ ! -s "${stderr_file}" ]; then
                rm -f "${stderr_file}"
            elif ! grep -v "Loaded cached credentials\|stdout is not a terminal\|Error executing tool" "${stderr_file}" | grep -q .; then
                rm -f "${stderr_file}"
            fi
        fi
    else
        print_error "${model_name} analysis failed"
        if [ -f "${stderr_file}" ] && [ -s "${stderr_file}" ]; then
            print_warning "Error details:"
            cat "${stderr_file}" >&2
        fi
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
                "description": .[0].pr_summary.description
            },
            {
                "agent": "codex",
                "description": .[1].pr_summary.description
            },
            {
                "agent": "gemini",
                "description": .[2].pr_summary.description
            }
        ],
        "pr_summary": {
            "number": .[0].pr_summary.number,
            "title": .[0].pr_summary.title
        },
        "issues": ([.[].issues[]] | sort_by(
            if .priority == "P0" then 0
            elif .priority == "P1" then 1
            else 2
            end
        ))
    }
    ' "${claude_file}" "${codex_file}" "${gemini_file}"
}

# Run all three AI models in parallel
print_header "🤖 Running automated code review with multiple AI models..."

CLAUDE_OUTPUT="${WORKTREE_PATH}/claude-review.json"
CODEX_OUTPUT="${WORKTREE_PATH}/codex-review.json"
GEMINI_OUTPUT="${WORKTREE_PATH}/gemini-review.json"
MERGED_OUTPUT="${WORKTREE_PATH}/merged-review.json"

print_info "Launching parallel reviews (this may take a few minutes)..."

# Run all three models in parallel
run_model_review "Claude" "claude" "${CLAUDE_OUTPUT}" "claude" &
CLAUDE_PID=$!

run_model_review "Codex" "codex" "${CODEX_OUTPUT}" "codex" &
CODEX_PID=$!

run_model_review "Gemini" "gemini" "${GEMINI_OUTPUT}" "gemini" &
GEMINI_PID=$!

# Wait for all background jobs to complete
wait $CLAUDE_PID
wait $CODEX_PID
wait $GEMINI_PID

print_success "All AI models completed their analysis! 📝"

# Merge the results
print_info "Merging results from all models..."
MERGED_RESULT=$(merge_reviews "${CLAUDE_OUTPUT}" "${CODEX_OUTPUT}" "${GEMINI_OUTPUT}")
echo "$MERGED_RESULT" > "${MERGED_OUTPUT}"

cd "${WORKTREE_PATH}" || {
    print_error "Failed to change to worktree directory"
    exit 1
}

cd "${ORIGINAL_DIR}" || exit 1

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
else
    print_error "Failed to parse merged output as JSON"
    print_warning "Raw output:"
    echo "$MERGED_RESULT"
fi

echo ""
echo -e "${BOLD}${GREEN}To start working on this PR, run:${RESET}"
echo -e "${CYAN}  cd ${WORKTREE_PATH}${RESET}"
echo ""
print_info "When you're done, you can remove the worktree with:"
echo -e "${CYAN}  git worktree remove ${WORKTREE_PATH}${RESET}"
