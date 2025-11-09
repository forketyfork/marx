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
    echo "and run automated code review with Claude."
    echo ""
    echo "Prerequisites:"
    echo "  - git"
    echo "  - gh (GitHub CLI)"
    echo "  - jq"
    echo "  - claude (Claude CLI)"
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

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
    print_warning "Worktree directory already exists: ${WORKTREE_PATH}"
    echo -e "${CYAN}Do you want to remove it and recreate? [y/N]:${RESET} "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Removing existing worktree..."
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        rm -rf "$WORKTREE_PATH" 2>/dev/null || true
    else
        print_info "Aborting"
        exit 0
    fi
fi

# Create the worktree
print_info "Creating worktree at ${WORKTREE_PATH}..."
git worktree add "$WORKTREE_PATH" "$COMMIT_SHA" > /dev/null 2>&1

print_success "Worktree created successfully! 🎉"

# Symlink .claude directory if it exists
ORIGINAL_DIR=$(pwd)
if [ -d "${ORIGINAL_DIR}/.claude" ]; then
    print_info "Symlinking .claude directory..."
    ln -sf "${ORIGINAL_DIR}/.claude" "${WORKTREE_PATH}/.claude"
    print_success ".claude directory symlinked"
fi

# Run Claude code review
print_header "🤖 Running automated code review with Claude..."

REVIEW_PROMPT="You are conducting a comprehensive code review for PR #${SELECTED_PR} in repository ${REPO}.

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

cd "${WORKTREE_PATH}" || {
    print_error "Failed to change to worktree directory"
    exit 1
}

print_info "Analyzing code... (this may take a minute)"

REVIEW_OUTPUT=$(claude --output-format text <<EOF
${REVIEW_PROMPT}
EOF
)

cd "${ORIGINAL_DIR}" || exit 1

# Parse and display the review
if echo "$REVIEW_OUTPUT" | jq empty 2>/dev/null; then
    print_success "Code review completed! 📝"
    echo ""

    # Extract and display PR summary
    print_header "📋 PR Summary"
    PR_TITLE=$(echo "$REVIEW_OUTPUT" | jq -r '.pr_summary.title')
    PR_DESC=$(echo "$REVIEW_OUTPUT" | jq -r '.pr_summary.description')

    echo -e "${BOLD}Title:${RESET} ${PR_TITLE}"
    echo -e "${BOLD}Description:${RESET} ${PR_DESC}"
    echo ""

    # Count issues by priority
    P0_COUNT=$(echo "$REVIEW_OUTPUT" | jq '[.issues[] | select(.priority == "P0")] | length')
    P1_COUNT=$(echo "$REVIEW_OUTPUT" | jq '[.issues[] | select(.priority == "P1")] | length')
    P2_COUNT=$(echo "$REVIEW_OUTPUT" | jq '[.issues[] | select(.priority == "P2")] | length')
    TOTAL_ISSUES=$(echo "$REVIEW_OUTPUT" | jq '.issues | length')

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
            echo "$REVIEW_OUTPUT" | jq -r '.issues[] | select(.priority == "P0") |
                "╭─────────────────────────────────────────────────────────────\n" +
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
            echo "$REVIEW_OUTPUT" | jq -r '.issues[] | select(.priority == "P1") |
                "╭─────────────────────────────────────────────────────────────\n" +
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
            echo "$REVIEW_OUTPUT" | jq -r '.issues[] | select(.priority == "P2") |
                "╭─────────────────────────────────────────────────────────────\n" +
                "│ 📁 \u001b[1;36m\(.file):\(.line)\u001b[0m\n" +
                "│ 🏷️  \u001b[1m\(.category)\u001b[0m\n" +
                "│\n" +
                "│ \u001b[1mIssue:\u001b[0m \(.description)\n" +
                "│\n" +
                "│ \u001b[1;32m💡 Fix:\u001b[0m \(.proposed_fix)\n" +
                "╰─────────────────────────────────────────────────────────────\n"'
        fi
    fi

    # Save review to file
    REVIEW_FILE="${WORKTREE_PATH}/claude-review.json"
    echo "$REVIEW_OUTPUT" > "$REVIEW_FILE"
    print_info "Full review saved to: ${REVIEW_FILE}"
else
    print_error "Failed to parse Claude output as JSON"
    print_warning "Raw output:"
    echo "$REVIEW_OUTPUT"
fi

echo ""
echo -e "${BOLD}${GREEN}To start working on this PR, run:${RESET}"
echo -e "${CYAN}  cd ${WORKTREE_PATH}${RESET}"
echo ""
print_info "When you're done, you can remove the worktree with:"
echo -e "${CYAN}  git worktree remove ${WORKTREE_PATH}${RESET}"
