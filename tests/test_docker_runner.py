"""Tests for the Docker runner script generation."""

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
