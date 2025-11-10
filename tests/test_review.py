"""Tests for review processing."""

import json
from pathlib import Path

from maxreview.review import (
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
    review_file = tmp_path / "review.json"
    review_data = {
        "pr_summary": {"number": 123, "title": "Test PR", "description": "Test description"},
        "issues": [
            {
                "agent": "claude",
                "priority": "P0",
                "file": "test.py",
                "line": 10,
                "commit_id": "abc123",
                "category": "bug",
                "description": "Test issue",
                "proposed_fix": "Test fix",
            }
        ],
    }

    with open(review_file, "w") as f:
        json.dump(review_data, f)

    review = load_review(review_file)

    assert review.pr_summary.number == 123
    assert review.pr_summary.title == "Test PR"
    assert len(review.issues) == 1
    assert review.issues[0].agent == "claude"


def test_merge_reviews(tmp_path: Path) -> None:
    """Test merging multiple reviews."""
    claude_review = {
        "pr_summary": {"number": 123, "title": "Test PR", "description": "Claude description"},
        "issues": [
            {
                "agent": "claude",
                "priority": "P0",
                "file": "test.py",
                "line": 10,
                "commit_id": "abc123",
                "category": "bug",
                "description": "Claude issue",
                "proposed_fix": "Claude fix",
            }
        ],
    }

    codex_review = {
        "pr_summary": {"number": 123, "title": "Test PR", "description": "Codex description"},
        "issues": [
            {
                "agent": "codex",
                "priority": "P1",
                "file": "test.py",
                "line": 20,
                "commit_id": "abc123",
                "category": "performance",
                "description": "Codex issue",
                "proposed_fix": "Codex fix",
            }
        ],
    }

    gemini_review = {
        "pr_summary": {"number": 123, "title": "Test PR", "description": "Gemini description"},
        "issues": [],
    }

    claude_file = tmp_path / "claude.json"
    codex_file = tmp_path / "codex.json"
    gemini_file = tmp_path / "gemini.json"

    with open(claude_file, "w") as f:
        json.dump(claude_review, f)
    with open(codex_file, "w") as f:
        json.dump(codex_review, f)
    with open(gemini_file, "w") as f:
        json.dump(gemini_review, f)

    merged = merge_reviews(claude_file, codex_file, gemini_file)

    assert merged.pr_summary.number == 123
    assert len(merged.descriptions) == 3
    assert len(merged.issues) == 2
    assert merged.issues[0].priority == "P0"
    assert merged.issues[1].priority == "P1"
