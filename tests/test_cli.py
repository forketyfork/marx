"""Tests for CLI helper functions."""

from pathlib import Path

import click
import pytest

from marx.cli import build_json_output, parse_agent_argument, parse_single_agent
from marx.review import Issue, MergedReview, PRSummary


def test_parse_agent_argument_basic_list() -> None:
    agents, overrides = parse_agent_argument("claude,codex")

    assert agents == ["claude", "codex"]
    assert overrides == {}


def test_parse_agent_argument_with_models() -> None:
    agents, overrides = parse_agent_argument("claude:opus codex gemini:gemini-2.5-pro")

    assert agents == ["claude", "codex", "gemini"]
    assert overrides == {"claude": "opus", "gemini": "gemini-2.5-pro"}


def test_parse_agent_argument_duplicate_agent_preserves_first_position() -> None:
    agents, overrides = parse_agent_argument("codex,claude:haiku,codex:o1")

    assert agents == ["codex", "claude"]
    assert overrides == {"claude": "haiku", "codex": "o1"}


def test_parse_agent_argument_invalid_agent() -> None:
    with pytest.raises(click.BadParameter):
        parse_agent_argument("claude,unknown")


def test_parse_agent_argument_missing_model() -> None:
    with pytest.raises(click.BadParameter):
        parse_agent_argument("claude:")


def test_parse_single_agent_basic() -> None:
    agent, model = parse_single_agent("claude")

    assert agent == "claude"
    assert model is None


def test_parse_single_agent_with_model() -> None:
    agent, model = parse_single_agent("claude:opus")

    assert agent == "claude"
    assert model == "opus"


def test_parse_single_agent_case_insensitive() -> None:
    agent, model = parse_single_agent("CLAUDE:opus")

    assert agent == "claude"
    assert model == "opus"


def test_parse_single_agent_with_whitespace() -> None:
    agent, model = parse_single_agent("  gemini:gemini-2.5-pro  ")

    assert agent == "gemini"
    assert model == "gemini-2.5-pro"


def test_parse_single_agent_invalid_agent() -> None:
    with pytest.raises(click.BadParameter):
        parse_single_agent("unknown")


def test_parse_single_agent_missing_model() -> None:
    with pytest.raises(click.BadParameter):
        parse_single_agent("claude:")


def test_build_json_output_includes_counts_and_artifacts(tmp_path: Path) -> None:
    merged_review = MergedReview(
        descriptions=[{"agent": "claude", "description": "desc"}],
        pr_summary=PRSummary(number=42, title="Test PR"),
        issues=[
            Issue(
                agent="claude",
                priority="P1",
                file="file.py",
                line=10,
                commit_id="abc123",
                category="bug",
                description="Problem",
                proposed_fix="Fix it",
            )
        ],
    )

    payload = build_json_output(
        merged_review,
        p0_count=0,
        p1_count=1,
        p2_count=0,
        artifact_paths={
            "claude_review": tmp_path / "claude.json",
            "codex_review": tmp_path / "codex.json",
            "gemini_review": tmp_path / "gemini.json",
            "dedup_review": None,
            "merged_review": tmp_path / "merged.json",
        },
        run_dir=tmp_path,
    )

    assert payload["pr"]["number"] == 42
    assert payload["counts"] == {"total": 1, "p0": 0, "p1": 1, "p2": 0}
    assert payload["issues"][0]["agent"] == "claude"
    assert payload["artifacts"]["dedup_review"] is None
    assert payload["run_directory"] == str(tmp_path)
