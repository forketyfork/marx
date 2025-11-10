"""Command-line interface for MaxReview."""

import os
import shutil
import sys
from pathlib import Path

import click

from maxreview.config import SUPPORTED_AGENTS
from maxreview.docker_runner import DockerRunner, ReviewPrompt
from maxreview.exceptions import DependencyError, MaxReviewError
from maxreview.github import GitHubClient
from maxreview.review import (
    count_issues_by_priority,
    merge_reviews,
    post_github_review,
    save_merged_review,
)
from maxreview.ui import (
    confirm,
    console,
    display_issue,
    display_pr_table,
    display_review_summary,
    print_error,
    print_header,
    print_info,
    print_success,
    print_warning,
    prompt_for_selection,
)


def check_dependencies(require_docker: bool = True) -> None:
    """Check for required system dependencies."""
    missing = []

    if not shutil.which("git"):
        missing.append("git")

    if not shutil.which("gh"):
        missing.append("gh (GitHub CLI)")

    if not shutil.which("jq"):
        missing.append("jq")

    if require_docker and not shutil.which("docker"):
        missing.append("docker")

    if missing:
        raise DependencyError(
            f"Missing required dependencies: {', '.join(missing)}\n"
            "Please install them and try again."
        )


def validate_agents(agents_str: str) -> list[str]:
    """Validate and parse agent list."""
    agents = [a.strip().lower() for a in agents_str.split(",")]
    invalid = [a for a in agents if a not in SUPPORTED_AGENTS]

    if invalid:
        raise click.BadParameter(
            f"Invalid agent(s): {', '.join(invalid)}. "
            f"Valid agents are: {', '.join(SUPPORTED_AGENTS)}"
        )

    return agents


def select_pr_interactive(github_client: GitHubClient) -> tuple[int, str]:
    """Interactively select a PR from the list."""
    print_header("🔍 Fetching open PRs with reviewers (excluding yours)...")

    current_user = github_client.get_current_user()
    print_success(f"Current user: {current_user}")

    prs = github_client.list_prs()
    filtered_prs = github_client.filter_prs_for_user(prs, current_user)

    if not filtered_prs:
        print_warning(
            f"No open PRs with reviewers found in {github_client.repo} "
            "(excluding PRs where you are the author or reviewer)"
        )
        sys.exit(0)

    print_success(f"Found {len(filtered_prs)} PR(s) with reviewers")
    console.print()

    pr_data = []
    for pr in filtered_prs:
        review_requests = pr.get("reviewRequests", [])
        reviews = pr.get("reviews", [])

        requested_reviewers = github_client._extract_reviewer_logins(review_requests)
        review_authors = github_client._extract_reviewer_logins(reviews, key="author")

        all_reviewers = list(set(requested_reviewers + review_authors))

        pr_data.append(
            {
                "number": pr["number"],
                "title": pr["title"],
                "author": pr.get("author", {}).get("login", "unknown"),
                "branch": pr["headRefName"],
                "reviewers": ", ".join(all_reviewers) if all_reviewers else "None",
                "additions": pr.get("additions", 0),
                "deletions": pr.get("deletions", 0),
            }
        )

    display_pr_table(pr_data)
    console.print()

    selection = prompt_for_selection(len(pr_data))
    selected = pr_data[selection - 1]

    return selected["number"], selected["branch"]


def setup_run_directory(
    script_dir: Path, pr_number: int, branch_name: str, resume_mode: bool
) -> Path:
    """Set up the run artifacts directory."""
    sanitized_branch = branch_name.replace("/", "-")
    run_dir = script_dir / "runs" / f"pr-{pr_number}-{sanitized_branch}"
    run_dir.parent.mkdir(parents=True, exist_ok=True)

    if resume_mode:
        if not run_dir.exists():
            raise MaxReviewError(
                f"Resume mode requested but no artifacts found at {run_dir}\n"
                "Run the agents at least once before using --resume."
            )
        print_success(f"Using existing run artifacts directory: {run_dir}")
    else:
        if run_dir.exists():
            if confirm(
                f"Existing run directory detected: {run_dir}\n"
                "Do you want to remove it and start fresh?",
                default=False,
            ):
                shutil.rmtree(run_dir)
                print_success("Removed existing run directory")
            else:
                print_info("Reusing existing run directory")

        run_dir.mkdir(parents=True, exist_ok=True)
        print_success(f"Run artifacts directory: {run_dir}")

    return run_dir


@click.command()
@click.option(
    "--pr",
    type=int,
    help="Specify PR number directly (skip interactive selection)",
)
@click.option(
    "--agent",
    type=str,
    help=(
        f"Comma-separated list of agents to run ({', '.join(SUPPORTED_AGENTS)}). "
        "Default: all agents"
    ),
)
@click.option(
    "--resume",
    is_flag=True,
    help="Reuse artifacts from the previous run and skip AI execution",
)
@click.version_option()
def main(pr: int | None, agent: str | None, resume: bool) -> None:
    """Interactive script to fetch open GitHub PRs with reviewers, create a git worktree,
    and run automated code review with multiple AI models (Claude, Codex, Gemini).

    Prerequisites:
      - git
      - gh (GitHub CLI)
      - jq
      - docker (not required with --resume)

    Environment Variables:
      GITHUB_TOKEN     GitHub API token (required for container access)
      MAXREVIEW_REPO   Optional owner/name override when auto-detect fails

    Examples:
      maxreview                            # Interactive mode with all agents
      maxreview --pr 123                   # Review PR #123 with all agents
      maxreview --pr 123 --agent claude    # Review PR #123 with Claude only
      maxreview --agent codex,gemini       # Interactive mode with Codex and Gemini
      maxreview --resume --pr 123          # Reuse artifacts for PR #123 without rerunning agents
    """
    try:
        require_docker = not resume
        check_dependencies(require_docker)

        agents_to_run = list(SUPPORTED_AGENTS)
        if agent:
            agents_to_run = validate_agents(agent)
            if resume:
                print_warning("--agent option is ignored when --resume is used")
                agents_to_run = list(SUPPORTED_AGENTS)

        github_client = GitHubClient()
        print_info(f"Repository: {github_client.repo}")

        if not os.environ.get("GITHUB_TOKEN"):
            print_warning("GITHUB_TOKEN environment variable is not set")
            print_info("The AI agents may not be able to access GitHub API inside the container")

        if pr:
            print_info(f"Using PR #{pr} from command line")
            pr_data = github_client.get_pr(pr)
            pr_number = pr_data["number"]
            branch_name = pr_data["headRefName"]
            commit_sha = pr_data.get("headRefOid", "")
            print_success(f"Found PR #{pr_number} with branch: {branch_name}")
        else:
            pr_number, branch_name = select_pr_interactive(github_client)
            pr_data = github_client.get_pr(pr_number)
            commit_sha = pr_data.get("headRefOid", "")

        if commit_sha:
            print_success(f"PR head commit: {commit_sha[:8]}")
        else:
            print_warning("Unable to determine the PR head commit SHA")

        script_dir = Path(__file__).parent.parent
        run_dir = setup_run_directory(script_dir, pr_number, branch_name, resume)

        claude_output = run_dir / "claude-review.json"
        codex_output = run_dir / "codex-review.json"
        gemini_output = run_dir / "gemini-review.json"
        merged_output = run_dir / "merged-review.json"

        if resume:
            print_header("⏩ Resume Mode: Reusing previous agent results")

            for agent_name, output_file in [
                ("claude", claude_output),
                ("codex", codex_output),
                ("gemini", gemini_output),
            ]:
                if output_file.exists():
                    print_info(f"Found {agent_name} review: {output_file}")
                else:
                    print_warning(
                        f"No {agent_name} review found at {output_file}, creating placeholder"
                    )
                    placeholder = {
                        "pr_summary": {
                            "number": pr_number,
                            "title": "Not run",
                            "description": f"{agent_name} review not found in resume mode",
                        },
                        "issues": [],
                    }
                    import json

                    with open(output_file, "w") as f:
                        json.dump(placeholder, f)
        else:
            docker_runner = DockerRunner(script_dir)
            docker_runner.ensure_image()

            prompt_config = ReviewPrompt(
                repo=github_client.repo,
                pr_number=pr_number,
                commit_sha=commit_sha,
                agent_name="",
            )

            print_header(
                f"🤖 Running automated code review with AI models: {', '.join(agents_to_run)}"
            )
            print_info("Launching parallel reviews (this may take a few minutes)...")

            docker_runner.run_agents_parallel(agents_to_run, prompt_config, run_dir)

            for agent_name in SUPPORTED_AGENTS:
                output_file = run_dir / f"{agent_name}-review.json"
                if agent_name not in agents_to_run:
                    placeholder = {
                        "pr_summary": {
                            "number": pr_number,
                            "title": "Not run",
                            "description": f"{agent_name} was not selected",
                        },
                        "issues": [],
                    }
                    import json

                    with open(output_file, "w") as f:
                        json.dump(placeholder, f)

        print_info("Merging results from all models...")
        merged_review = merge_reviews(claude_output, codex_output, gemini_output)
        save_merged_review(merged_review, merged_output)

        print_success("Merged code review completed! 📝")
        console.print()

        p0_count, p1_count, p2_count = count_issues_by_priority(merged_review.issues)
        total_issues = len(merged_review.issues)

        display_review_summary(
            merged_review.pr_summary.title,
            merged_review.descriptions,
            p0_count,
            p1_count,
            p2_count,
            total_issues,
        )

        if total_issues > 0:
            if p0_count > 0:
                print_header("🔴 P0 - Critical Issues")
                for issue in merged_review.issues:
                    if issue.priority == "P0":
                        display_issue(issue.model_dump(), "🔴")

            if p1_count > 0:
                print_header("🟡 P1 - Important Issues")
                for issue in merged_review.issues:
                    if issue.priority == "P1":
                        display_issue(issue.model_dump(), "🟡")

            if p2_count > 0:
                print_header("🔵 P2 - Suggestions")
                for issue in merged_review.issues:
                    if issue.priority == "P2":
                        display_issue(issue.model_dump(), "🔵")

        print_info("Individual reviews saved:")
        console.print(f"  [cyan]{claude_output}[/cyan]")
        console.print(f"  [cyan]{codex_output}[/cyan]")
        console.print(f"  [cyan]{gemini_output}[/cyan]")
        print_info(f"Merged review saved to: {merged_output}")

        if total_issues > 0:
            post_github_review(merged_review, github_client, pr_number, commit_sha, run_dir)

        console.print()
        console.print("[bold green]Review artifacts directory:[/bold green]")
        console.print(f"[cyan]  {run_dir}[/cyan]")
        console.print()
        print_info("Need a local checkout? Run:")
        console.print(f"[cyan]  gh pr checkout {pr_number}[/cyan]")

    except MaxReviewError as e:
        print_error(str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        print_warning("\nOperation cancelled by user")
        sys.exit(130)
    except Exception as e:
        print_error(f"Unexpected error: {e}")
        import traceback

        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
