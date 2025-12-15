"""Tests for the Docker runner script generation."""

from marx.docker_runner import DockerRunner


def test_runner_script_passes_workspace_review_path() -> None:
    """Ensure the user shell receives the workspace review path."""

    runner = DockerRunner.__new__(DockerRunner)

    script = runner._generate_runner_script()

    assert "MODEL_REVIEW_PATH=%q MODEL_REVIEW_WORKSPACE_PATH=%q" in script
