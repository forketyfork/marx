"""Tests for Marx configuration file support."""

from __future__ import annotations

import os
from pathlib import Path

from marx import config as marx_config


def _write_config(tmp_path: Path, contents: str) -> Path:
    config_path = tmp_path / ".marx"
    config_path.write_text(contents, encoding="utf-8")
    return config_path


def test_load_environment_from_file_populates_environ(monkeypatch, tmp_path) -> None:
    """Values in the config file should populate os.environ when missing."""

    config_path = _write_config(
        tmp_path,
        """
MARX_REPO=owner/repo
GITHUB_TOKEN=abc123
OPENAI_API_KEY="open-key"
        """.strip(),
    )

    monkeypatch.delenv("MARX_REPO", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    marx_config.clear_config_cache()
    marx_config.load_environment_from_file(config_path)

    assert os.environ["MARX_REPO"] == "owner/repo"
    assert os.environ["GITHUB_TOKEN"] == "abc123"
    assert os.environ["OPENAI_API_KEY"] == "open-key"


def test_load_environment_does_not_override_existing(monkeypatch, tmp_path) -> None:
    """Environment variables should take precedence over the config file."""

    config_path = _write_config(tmp_path, "GITHUB_TOKEN=from-file\n")
    monkeypatch.setenv("GITHUB_TOKEN", "from-env")

    marx_config.clear_config_cache()
    marx_config.load_environment_from_file(config_path)

    assert os.environ["GITHUB_TOKEN"] == "from-env"
