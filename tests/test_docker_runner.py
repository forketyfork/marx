"""Tests for the Docker runner script generation."""

import os
from pathlib import Path
from unittest.mock import MagicMock, patch

from marx.docker_runner import DockerRunner, ReviewPrompt


def test_runner_script_passes_workspace_review_path() -> None:
    """Ensure the user shell receives the workspace review path."""

    runner = DockerRunner.__new__(DockerRunner)

    script = runner._generate_runner_script()

    assert "MODEL_REVIEW_PATH=%q MODEL_REVIEW_WORKSPACE_PATH=%q" in script


def test_runner_script_sources_pre_agent_hook() -> None:
    """Ensure the runner script sources the hook rather than executing it."""

    runner = DockerRunner.__new__(DockerRunner)

    script = runner._generate_runner_script()

    assert ". /host-configs/pre-agent.sh" in script
    assert '[ -f "/host-configs/pre-agent.sh" ]' in script


def _make_runner() -> tuple[DockerRunner, ReviewPrompt]:
    runner = DockerRunner.__new__(DockerRunner)
    runner.client = MagicMock()
    runner.docker_image = "test-image"
    prompt_config = ReviewPrompt(
        repo="owner/repo", pr_number=1, commit_sha="abc123", agent_name="claude"
    )
    return runner, prompt_config


def _run_container_capturing_environment(
    runner: DockerRunner, prompt_config: ReviewPrompt, tmp_path: Path, env: dict
) -> dict:
    try:
        with patch.dict(os.environ, env, clear=True):
            runner._run_container(
                "gemini",
                prompt_config,
                tmp_path,
                tmp_path / "prompt.txt",
                tmp_path / "runner.sh",
                tmp_path / "stderr.txt",
            )
    except Exception:
        pass
    call = runner.client.containers.run.call_args  # type: ignore[union-attr]
    return call.kwargs.get("environment", {}) if call else {}


def test_api_keys_not_forwarded_when_empty(tmp_path: Path) -> None:
    """Empty or absent API keys must not appear in the container environment."""

    runner, prompt_config = _make_runner()

    env = _run_container_capturing_environment(runner, prompt_config, tmp_path, {})

    for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"):
        assert key not in env, f"{key} should not be forwarded when unset"


def test_api_keys_forwarded_when_set(tmp_path: Path) -> None:
    """Non-empty API keys must be included in the container environment."""

    runner, prompt_config = _make_runner()

    host_env = {
        "GOOGLE_API_KEY": "test-google-key",
        "GEMINI_API_KEY": "test-gemini-key",
        "ANTHROPIC_API_KEY": "test-anthropic-key",
    }
    env = _run_container_capturing_environment(runner, prompt_config, tmp_path, host_env)

    assert env.get("GOOGLE_API_KEY") == "test-google-key"
    assert env.get("GEMINI_API_KEY") == "test-gemini-key"
    assert env.get("ANTHROPIC_API_KEY") == "test-anthropic-key"


def _run_container_capturing_volumes(
    runner: DockerRunner, prompt_config: ReviewPrompt, tmp_path: Path
) -> dict:
    try:
        runner._run_container(
            "claude",
            prompt_config,
            tmp_path,
            tmp_path / "prompt.txt",
            tmp_path / "runner.sh",
            tmp_path / "stderr.txt",
        )
    except Exception:
        pass
    call = runner.client.containers.run.call_args  # type: ignore[union-attr]
    return call.kwargs.get("volumes", {}) if call else {}


def test_pre_agent_hook_mounted_when_present(tmp_path: Path) -> None:
    """Ensure ~/.marx.d/pre-agent.sh is mounted when it exists."""

    hook = tmp_path / ".marx.d" / "pre-agent.sh"
    hook.parent.mkdir()
    hook.write_text("#!/usr/bin/env bash\n")

    runner, prompt_config = _make_runner()

    with patch("pathlib.Path.home", return_value=tmp_path):
        volumes = _run_container_capturing_volumes(runner, prompt_config, tmp_path)

    assert str(hook) in volumes
    assert volumes[str(hook)] == {"bind": "/host-configs/pre-agent.sh", "mode": "ro"}


def test_pre_agent_hook_not_mounted_when_absent(tmp_path: Path) -> None:
    """Ensure no hook volume is added when ~/.marx.d/pre-agent.sh does not exist."""

    runner, prompt_config = _make_runner()

    with patch("pathlib.Path.home", return_value=tmp_path):
        volumes = _run_container_capturing_volumes(runner, prompt_config, tmp_path)

    hook_bind = "/host-configs/pre-agent.sh"
    assert not any(v.get("bind") == hook_bind for v in volumes.values())
