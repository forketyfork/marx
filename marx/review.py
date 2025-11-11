"""Review processing, merging, and GitHub posting."""

import json
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from marx.config import PRIORITY_ORDER
from marx.exceptions import ReviewError
from marx.github import GitHubClient
from marx.ui import confirm, print_error, print_info, print_success, print_warning


class Issue(BaseModel):
    """Model for a single review issue."""

    agent: str
    priority: str
    file: str | None = None
    line: int | None = None
    commit_id: str
    category: str
    description: str
    proposed_fix: str


class PRSummary(BaseModel):
    """Model for PR summary information."""

    number: int
    title: str
    description: str | None = None


class AgentReview(BaseModel):
    """Model for a single agent's review."""

    pr_summary: PRSummary
    issues: list[Issue]


class MergedReview(BaseModel):
    """Model for merged review from all agents."""

    descriptions: list[dict[str, str]]
    pr_summary: PRSummary
    issues: list[Issue]


def load_review(file_path: Path) -> AgentReview:
    """Load a review from a JSON file."""
    try:
        with open(file_path) as f:
            data = json.load(f)
        return AgentReview(**data)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        raise ReviewError(f"Failed to load review from {file_path}: {e}") from e


def merge_reviews(
    claude_file: Path,
    codex_file: Path,
    gemini_file: Path,
) -> MergedReview:
    """Merge reviews from all agents."""
    reviews = {
        "claude": load_review(claude_file),
        "codex": load_review(codex_file),
        "gemini": load_review(gemini_file),
    }

    descriptions = [
        {"agent": agent, "description": review.pr_summary.description or "No description"}
        for agent, review in reviews.items()
    ]

    first_review = next(iter(reviews.values()))
    pr_summary = PRSummary(
        number=first_review.pr_summary.number,
        title=first_review.pr_summary.title,
    )

    all_issues: list[Issue] = []
    for review in reviews.values():
        all_issues.extend(review.issues)

    all_issues.sort(key=lambda issue: PRIORITY_ORDER.get(issue.priority, 999))

    return MergedReview(
        descriptions=descriptions,
        pr_summary=pr_summary,
        issues=all_issues,
    )


def save_merged_review(review: MergedReview, output_file: Path) -> None:
    """Save merged review to a JSON file."""
    with open(output_file, "w") as f:
        json.dump(review.model_dump(), f, indent=2)


def count_issues_by_priority(issues: list[Issue]) -> tuple[int, int, int]:
    """Count issues by priority level."""
    p0 = sum(1 for issue in issues if issue.priority == "P0")
    p1 = sum(1 for issue in issues if issue.priority == "P1")
    p2 = sum(1 for issue in issues if issue.priority == "P2")
    return p0, p1, p2


def filter_issues_for_inline_comments(
    issues: list[Issue],
    valid_positions: dict[str, list[int]],
) -> tuple[list[Issue], list[Issue]]:
    """Filter issues into inline-able and non-inline-able categories."""
    inline_issues: list[Issue] = []
    summary_issues: list[Issue] = []

    for issue in issues:
        if not issue.file or issue.line is None:
            summary_issues.append(issue)
            continue

        file_path = issue.file.removeprefix("/workspace/repo/").removeprefix("./")

        if file_path in valid_positions and issue.line in valid_positions[file_path]:
            inline_issues.append(issue)
        else:
            summary_issues.append(issue)

    return inline_issues, summary_issues


def create_github_review_payload(
    merged_review: MergedReview,
    github_client: GitHubClient,
    pr_number: int,
    commit_sha: str,
) -> dict[str, Any]:
    """Create a GitHub review payload with inline comments and summary."""
    p0, p1, p2 = count_issues_by_priority(merged_review.issues)
    total = len(merged_review.issues)

    valid_positions = github_client.get_valid_inline_positions(pr_number)

    inline_issues, summary_issues = filter_issues_for_inline_comments(
        merged_review.issues, valid_positions
    )

    payload: dict[str, Any] = {}

    body_lines = [
        "Automated review findings:",
        f"- Critical (P0): {p0}",
        f"- Important (P1): {p1}",
        f"- Suggestions (P2): {p2}",
        f"- Total issues: {total}",
    ]

    if summary_issues:
        body_lines.append("")
        if inline_issues:
            body_lines.append("Issues without precise location:")
        else:
            body_lines.append("Review findings:")
        body_lines.append("")

        for issue in summary_issues:
            file_info = f" (file: {issue.file})" if issue.file else ""
            line_info = f" line {issue.line}" if issue.line else ""

            body_lines.extend(
                [
                    f"- {issue.description}{file_info}{line_info}",
                    f"  Priority: {issue.priority}",
                    f"  Category: {issue.category}",
                ]
            )

            if issue.proposed_fix:
                body_lines.append(f"  Suggested fix: {issue.proposed_fix}")

            body_lines.append("")

    payload["body"] = "\n".join(body_lines)

    if inline_issues:
        comments: list[dict[str, Any]] = []

        for issue in inline_issues:
            if not issue.file or issue.line is None:
                continue

            file_path = issue.file.removeprefix("/workspace/repo/").removeprefix("./")

            comment: dict[str, Any] = {
                "path": file_path,
                "line": issue.line,
                "side": "RIGHT",
            }

            if commit_sha:
                comment["commit_id"] = commit_sha

            comment_body_parts = [issue.description]

            if issue.proposed_fix:
                comment_body_parts.append(f"\nSuggested fix: {issue.proposed_fix}")

            comment_body_parts.extend(
                [f"\nPriority: {issue.priority}", f"Category: {issue.category}"]
            )

            comment["body"] = "\n".join(comment_body_parts)

            comments.append(comment)

        payload["comments"] = comments

        print_info(
            f"Prepared GitHub review with {len(comments)} inline comment(s) "
            f"and {len(summary_issues)} summary issue(s)"
        )
    else:
        print_info(f"Prepared GitHub review with {len(summary_issues)} summary issue(s)")

    return payload


def post_github_review(
    merged_review: MergedReview,
    github_client: GitHubClient,
    pr_number: int,
    commit_sha: str,
    run_path: Path,
) -> None:
    """Post a pending GitHub review."""
    if not confirm("Create a pending GitHub review with these findings?", default=False):
        print_info("Skipping GitHub review creation.")
        return

    try:
        payload = create_github_review_payload(merged_review, github_client, pr_number, commit_sha)

        payload_file = run_path / "pending-review-request.json"
        with open(payload_file, "w") as f:
            json.dump(payload, f, indent=2)

        response = github_client.create_review(
            pr_number=pr_number,
            body=payload.get("body"),
            comments=payload.get("comments"),
        )

        payload_file.unlink(missing_ok=True)

        inline_count = len(payload.get("comments", []))
        if inline_count > 0:
            print_success(f"Created pending GitHub review with {inline_count} inline comment(s)")
        else:
            print_success("Created pending GitHub review with a summary comment")

        review_url = response.get("html_url")
        if review_url:
            print_info(f"Review URL (visible only to you until submitted): {review_url}")

        print_info("Review stays pending until you submit it on GitHub.")

    except Exception as e:
        print_error(f"Failed to create pending GitHub review: {e}")
        print_warning("Review not posted to GitHub")
