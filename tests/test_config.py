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


def test_load_review_prompt_template_uses_packaged_default(monkeypatch) -> None:
    """The bundled review prompt should be used when no overrides are provided."""

    monkeypatch.delenv("MARX_REVIEW_PROMPT_PATH", raising=False)
    marx_config.clear_config_cache()
    prompt = marx_config.load_review_prompt_template()

    assert "comprehensive code review" in prompt
    assert "{agent}" in prompt  # placeholders remain for formatting


def test_load_review_prompt_template_honors_override(monkeypatch, tmp_path) -> None:
    """A file path provided via environment variable should override the default."""

    custom_prompt = "Review PR #{pr_number} in {repo} for agent {agent}."
    override_path = tmp_path / "prompt.md"
    override_path.write_text(custom_prompt, encoding="utf-8")

    monkeypatch.setenv("MARX_REVIEW_PROMPT_PATH", str(override_path))
    marx_config.clear_config_cache()

    prompt = marx_config.load_review_prompt_template()

    assert prompt == custom_prompt


def test_get_docker_image_prefers_environment(monkeypatch, tmp_path) -> None:
    """Environment variable overrides should take precedence."""

    monkeypatch.setenv("MARX_DOCKER_IMAGE", "custom:image")
    config_path = _write_config(tmp_path, "DOCKER_IMAGE=config:image\n")

    marx_config.clear_config_cache()

    assert marx_config.get_docker_image(config_path) == "custom:image"


def test_get_docker_image_falls_back_to_config(monkeypatch, tmp_path) -> None:
    """Configuration file entries should be used when env var is absent."""

    monkeypatch.delenv("MARX_DOCKER_IMAGE", raising=False)
    config_path = _write_config(tmp_path, "DOCKER_IMAGE=config:image\n")

    marx_config.clear_config_cache()

    assert marx_config.get_docker_image(config_path) == "config:image"


def test_get_docker_image_uses_default(monkeypatch) -> None:
    """Default image should be returned when no overrides are present."""

    monkeypatch.delenv("MARX_DOCKER_IMAGE", raising=False)
    marx_config.clear_config_cache()

    assert marx_config.get_docker_image() == marx_config.DEFAULT_DOCKER_IMAGE
