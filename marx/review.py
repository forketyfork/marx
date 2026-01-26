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


def parse_review_text(text: str, source: Path | None = None) -> AgentReview:
    """Parse a structured review text file into an AgentReview."""
    lines = text.splitlines()
    header: dict[str, str] = {}
    issues: list[dict[str, str]] = []

    header_keys = {
        "pr_number": "number",
        "pr_title": "title",
        "pr_description": "description",
    }
    issue_keys = {
        "agent": "agent",
        "priority": "priority",
        "path": "file",
        "file": "file",
        "line": "line",
        "commit_id": "commit_id",
        "category": "category",
        "description": "description",
        "proposed_fix": "proposed_fix",
    }
    multiline_keys = {"description", "proposed_fix"}

    section = "header"
    current_issue: dict[str, str] | None = None
    current_key: str | None = None
    current_lines: list[str] = []

    def finalize_multiline(target: dict[str, str]) -> None:
        nonlocal current_key, current_lines
        if current_key is None:
            return
        target[current_key] = "\n".join(current_lines).rstrip()
        current_key = None
        current_lines = []

    def start_issue() -> None:
        nonlocal section, current_issue
        if current_issue:
            issues.append(current_issue)
        current_issue = {}
        section = "issue"

    def strip_quotes(value: str) -> str:
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            return value[1:-1]
        return value

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        if stripped == "--- ISSUE ---":
            if section == "issue" and current_issue is not None:
                finalize_multiline(current_issue)
            elif section == "header":
                finalize_multiline(header)
            section = "issue"
            start_issue()
            continue

        if stripped == "":
            if current_key is not None:
                current_lines.append("")
            continue

        if current_key is not None and line.startswith("  "):
            current_lines.append(line[2:])
            continue

        if section == "issue" and current_issue is not None:
            finalize_multiline(current_issue)
        else:
            finalize_multiline(header)

        if ":" not in line:
            continue

        key, value = line.split(":", 1)
        key = key.strip()
        value = strip_quotes(value.lstrip())

        if section == "header":
            normalized_key = key.lower()
            if normalized_key not in issue_keys:
                dest_key = header_keys.get(normalized_key)
                if not dest_key:
                    continue
                if dest_key == "description" and value == "":
                    current_key = dest_key
                    current_lines = []
                else:
                    header[dest_key] = value
                continue
            finalize_multiline(header)
            start_issue()
            section = "issue"

        if current_issue is None:
            start_issue()
        if current_issue is None:
            raise ReviewError("Failed to start issue block parsing.")

        normalized_key = key.lower()
        dest_key = issue_keys.get(normalized_key)
        if not dest_key:
            continue

        if dest_key in multiline_keys and value == "":
            current_key = dest_key
            current_lines = []
            continue

        current_issue[dest_key] = value

    if section == "issue" and current_issue is not None:
        finalize_multiline(current_issue)
        if current_issue:
            issues.append(current_issue)
    else:
        finalize_multiline(header)

    missing_header = [key for key in ("number", "title") if key not in header]
    if missing_header:
        origin = f" in {source}" if source else ""
        raise ReviewError(f"Missing header field(s){origin}: {', '.join(missing_header)}")

    try:
        pr_number = int(header["number"])
    except ValueError as exc:
        raise ReviewError(f"Invalid PR_NUMBER value: {header['number']}") from exc

    pr_description = header.get("description") or None

    default_agent = None
    if source is not None:
        stem = source.stem.split("-", 1)[0]
        if stem in {"claude", "codex", "gemini"}:
            default_agent = stem

    parsed_issues: list[Issue] = []
    for issue in issues:
        agent = issue.get("agent") or default_agent
        required_keys = ["priority", "commit_id", "category", "description", "proposed_fix"]
        missing_issue = [key for key in required_keys if key not in issue]
        if agent is None:
            missing_issue.insert(0, "agent")
        if missing_issue:
            raise ReviewError(f"Missing issue field(s): {', '.join(missing_issue)}")
        assert agent is not None

        line_value = issue.get("line")
        if line_value is None or line_value == "" or line_value.lower() == "null":
            line_number = None
        else:
            try:
                line_number = int(line_value)
            except ValueError as exc:
                raise ReviewError(f"Invalid line number: {line_value}") from exc

        file_value = issue.get("file")
        if file_value is not None and file_value.lower() == "null":
            file_value = None

        parsed_issues.append(
            Issue(
                agent=agent,
                priority=issue["priority"],
                file=file_value,
                line=line_number,
                commit_id=issue["commit_id"],
                category=issue["category"],
                description=issue["description"],
                proposed_fix=issue["proposed_fix"],
            )
        )

    return AgentReview(
        pr_summary=PRSummary(number=pr_number, title=header["title"], description=pr_description),
        issues=parsed_issues,
    )


def render_review_text(review: AgentReview) -> str:
    """Render an AgentReview as structured text."""
    lines: list[str] = [
        f"PR_NUMBER: {review.pr_summary.number}",
        f"PR_TITLE: {review.pr_summary.title}",
        "PR_DESCRIPTION:",
    ]

    description = review.pr_summary.description or ""
    if description:
        lines.extend(f"  {line}" for line in description.splitlines())

    for issue in review.issues:
        lines.append("--- ISSUE ---")
        lines.append(f"agent: {issue.agent}")
        lines.append(f"priority: {issue.priority}")
        lines.append(f"path: {issue.file if issue.file is not None else 'null'}")
        lines.append(f"line: {issue.line if issue.line is not None else 'null'}")
        lines.append(f"commit_id: {issue.commit_id}")
        lines.append(f"category: {issue.category}")
        lines.append("description:")
        if issue.description:
            lines.extend(f"  {line}" for line in issue.description.splitlines())
        lines.append("proposed_fix:")
        if issue.proposed_fix:
            lines.extend(f"  {line}" for line in issue.proposed_fix.splitlines())

    return "\n".join(lines) + "\n"


def render_merged_review_text(review: MergedReview) -> str:
    """Render a merged review as structured text."""
    lines: list[str] = [
        f"PR_NUMBER: {review.pr_summary.number}",
        f"PR_TITLE: {review.pr_summary.title}",
        "PR_DESCRIPTION:",
    ]

    if review.pr_summary.description:
        lines.extend(f"  {line}" for line in review.pr_summary.description.splitlines())

    if review.descriptions:
        lines.append("AGENT_DESCRIPTIONS:")
        for entry in review.descriptions:
            agent = entry.get("agent", "unknown")
            description = entry.get("description", "")
            lines.append(f"  {agent}: {description}")

    for issue in review.issues:
        lines.append("--- ISSUE ---")
        lines.append(f"agent: {issue.agent}")
        lines.append(f"priority: {issue.priority}")
        lines.append(f"path: {issue.file if issue.file is not None else 'null'}")
        lines.append(f"line: {issue.line if issue.line is not None else 'null'}")
        lines.append(f"commit_id: {issue.commit_id}")
        lines.append(f"category: {issue.category}")
        lines.append("description:")
        if issue.description:
            lines.extend(f"  {line}" for line in issue.description.splitlines())
        lines.append("proposed_fix:")
        if issue.proposed_fix:
            lines.extend(f"  {line}" for line in issue.proposed_fix.splitlines())

    return "\n".join(lines) + "\n"


def load_review(file_path: Path) -> AgentReview:
    """Load a review from a structured text file."""
    try:
        text = file_path.read_text(encoding="utf-8")
    except FileNotFoundError as e:
        raise ReviewError(f"Failed to load review from {file_path}: {e}") from e

    try:
        return parse_review_text(text, file_path)
    except ReviewError:
        raise
    except Exception as e:
        raise ReviewError(f"Failed to parse review from {file_path}: {e}") from e


def merge_reviews(
    claude_file: Path,
    codex_file: Path,
    gemini_file: Path,
    dedup_file: Path | None = None,
) -> MergedReview:
    """Merge reviews from all agents."""
    reviews = {
        "claude": load_review(claude_file),
        "codex": load_review(codex_file),
        "gemini": load_review(gemini_file),
    }

    dedup_review = load_review(dedup_file) if dedup_file and dedup_file.exists() else None

    descriptions = [
        {"agent": agent, "description": review.pr_summary.description or "No description"}
        for agent, review in reviews.items()
    ]

    first_review = next(iter(reviews.values()))
    pr_summary = PRSummary(
        number=first_review.pr_summary.number,
        title=first_review.pr_summary.title,
    )

    if dedup_review:
        all_issues: list[Issue] = list(dedup_review.issues)
    else:
        all_issues = []
        for review in reviews.values():
            all_issues.extend(review.issues)

    all_issues.sort(key=lambda issue: PRIORITY_ORDER.get(issue.priority, 999))

    return MergedReview(
        descriptions=descriptions,
        pr_summary=pr_summary,
        issues=all_issues,
    )


def save_merged_review(review: MergedReview, output_file: Path) -> None:
    """Save merged review to a structured text file."""
    output_file.write_text(render_merged_review_text(review), encoding="utf-8")


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
