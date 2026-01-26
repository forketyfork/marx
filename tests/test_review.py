"""Tests for review processing."""

from pathlib import Path

from marx.review import (
    Issue,
    count_issues_by_priority,
    filter_issues_for_inline_comments,
    load_review,
    merge_reviews,
)


def test_count_issues_by_priority() -> None:
    """Test counting issues by priority."""
    issues = [
        Issue(
            agent="claude",
            priority="P0",
            file="test.py",
            line=1,
            commit_id="abc123",
            category="bug",
            description="Critical bug",
            proposed_fix="Fix it",
        ),
        Issue(
            agent="codex",
            priority="P1",
            file="test.py",
            line=2,
            commit_id="abc123",
            category="performance",
            description="Performance issue",
            proposed_fix="Optimize",
        ),
        Issue(
            agent="gemini",
            priority="P2",
            file="test.py",
            line=3,
            commit_id="abc123",
            category="style",
            description="Style issue",
            proposed_fix="Format",
        ),
    ]

    p0, p1, p2 = count_issues_by_priority(issues)
    assert p0 == 1
    assert p1 == 1
    assert p2 == 1


def test_filter_issues_for_inline_comments() -> None:
    """Test filtering issues for inline comments."""
    issues = [
        Issue(
            agent="claude",
            priority="P0",
            file="test.py",
            line=10,
            commit_id="abc123",
            category="bug",
            description="Bug at line 10",
            proposed_fix="Fix it",
        ),
        Issue(
            agent="codex",
            priority="P1",
            file="test.py",
            line=20,
            commit_id="abc123",
            category="performance",
            description="Performance at line 20",
            proposed_fix="Optimize",
        ),
        Issue(
            agent="gemini",
            priority="P1",
            file=None,
            line=None,
            commit_id="abc123",
            category="quality",
            description="General issue",
            proposed_fix="Improve",
        ),
    ]

    valid_positions = {"test.py": [10, 15, 20, 25]}

    inline, summary = filter_issues_for_inline_comments(issues, valid_positions)

    assert len(inline) == 2
    assert len(summary) == 1
    assert summary[0].description == "General issue"


def test_filter_issues_invalid_line() -> None:
    """Test filtering issues with invalid line numbers."""
    issues = [
        Issue(
            agent="claude",
            priority="P0",
            file="test.py",
            line=100,
            commit_id="abc123",
            category="bug",
            description="Bug at invalid line",
            proposed_fix="Fix it",
        ),
    ]

    valid_positions = {"test.py": [10, 15, 20, 25]}

    inline, summary = filter_issues_for_inline_comments(issues, valid_positions)

    assert len(inline) == 0
    assert len(summary) == 1


def test_load_review(tmp_path: Path) -> None:
    """Test loading review from file."""
    review_file = tmp_path / "review.txt"
    review_file.write_text(
        "\n".join(
            [
                "PR_NUMBER: 123",
                "PR_TITLE: Test PR",
                "PR_DESCRIPTION:",
                "  Test description",
                "--- ISSUE ---",
                "agent: claude",
                "priority: P0",
                "path: test.py",
                "line: 10",
                "commit_id: abc123",
                "category: bug",
                "description:",
                "  Test issue",
                "proposed_fix:",
                "  Test fix",
                "",
            ]
        )
    )

    review = load_review(review_file)

    assert review.pr_summary.number == 123
    assert review.pr_summary.title == "Test PR"
    assert len(review.issues) == 1
    assert review.issues[0].agent == "claude"


def test_merge_reviews(tmp_path: Path) -> None:
    """Test merging multiple reviews."""
    claude_file = tmp_path / "claude-review.txt"
    codex_file = tmp_path / "codex-review.txt"
    gemini_file = tmp_path / "gemini-review.txt"

    claude_file.write_text(
        "\n".join(
            [
                "PR_NUMBER: 123",
                "PR_TITLE: Test PR",
                "PR_DESCRIPTION:",
                "  Claude description",
                "--- ISSUE ---",
                "agent: claude",
                "priority: P0",
                "path: test.py",
                "line: 10",
                "commit_id: abc123",
                "category: bug",
                "description:",
                "  Claude issue",
                "proposed_fix:",
                "  Claude fix",
                "",
            ]
        )
    )

    codex_file.write_text(
        "\n".join(
            [
                "PR_NUMBER: 123",
                "PR_TITLE: Test PR",
                "PR_DESCRIPTION:",
                "  Codex description",
                "--- ISSUE ---",
                "agent: codex",
                "priority: P1",
                "path: test.py",
                "line: 20",
                "commit_id: abc123",
                "category: performance",
                "description:",
                "  Codex issue",
                "proposed_fix:",
                "  Codex fix",
                "",
            ]
        )
    )

    gemini_file.write_text(
        "\n".join(
            [
                "PR_NUMBER: 123",
                "PR_TITLE: Test PR",
                "PR_DESCRIPTION:",
                "  Gemini description",
                "",
            ]
        )
    )

    merged = merge_reviews(claude_file, codex_file, gemini_file)

    assert merged.pr_summary.number == 123
    assert len(merged.descriptions) == 3
    assert len(merged.issues) == 2
    assert merged.issues[0].priority == "P0"
    assert merged.issues[1].priority == "P1"


def test_merge_reviews_prefers_dedup(tmp_path: Path) -> None:
    """Test that merge_reviews uses deduplicated issues when provided."""

    claude_file = tmp_path / "claude-review.txt"
    codex_file = tmp_path / "codex-review.txt"
    gemini_file = tmp_path / "gemini-review.txt"
    dedup_file = tmp_path / "dedup-review.txt"

    for path in (claude_file, codex_file, gemini_file):
        path.write_text(
            "\n".join(
                [
                    "PR_NUMBER: 42",
                    "PR_TITLE: Test PR",
                    "PR_DESCRIPTION:",
                    "--- ISSUE ---",
                    f"agent: {path.stem.split('-', 1)[0]}",
                    "priority: P1",
                    "path: null",
                    "line: null",
                    "commit_id: abc123",
                    "category: quality",
                    "description:",
                    f"  Issue from {path.stem}",
                    "proposed_fix:",
                    "",
                ]
            )
        )

    dedup_file.write_text(
        "\n".join(
            [
                "PR_NUMBER: 42",
                "PR_TITLE: Test PR",
                "PR_DESCRIPTION:",
                "--- ISSUE ---",
                "agent: claude,codex",
                "priority: P0",
                "path: core.py",
                "line: 5",
                "commit_id: abc123",
                "category: bug",
                "description:",
                "  Deduplicated issue",
                "proposed_fix:",
                "  Fix it",
                "",
            ]
        )
    )

    merged = merge_reviews(claude_file, codex_file, gemini_file, dedup_file)

    assert len(merged.issues) == 1
    assert merged.issues[0].priority == "P0"
    assert merged.issues[0].agent == "claude,codex"
