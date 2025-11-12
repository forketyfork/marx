"""Tests for CLI helper functions."""

import click
import pytest

from marx.cli import parse_agent_argument


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
