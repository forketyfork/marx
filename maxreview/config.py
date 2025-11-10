"""Configuration and constants for MaxReview."""

from typing import Final

DOCKER_IMAGE: Final[str] = "maxreview:latest"
CONTAINER_RUNNER_DIR: Final[str] = "/runner"
CONTAINER_WORKSPACE_DIR: Final[str] = "/workspace"

SUPPORTED_AGENTS: Final[set[str]] = {"claude", "codex", "gemini"}

AGENT_COMMANDS: Final[dict[str, str]] = {
    "claude": "claude --print --output-format stream-json --verbose --dangerously-skip-permissions",
    "codex": "codex exec --yolo",
    "gemini": "gemini --output-format text --yolo",
}

AGENT_CONFIG_DIRS: Final[dict[str, str]] = {
    "claude": ".claude",
    "codex": ".codex",
    "gemini": ".gemini",
}

PRIORITY_ORDER: Final[dict[str, int]] = {
    "P0": 0,
    "P1": 1,
    "P2": 2,
}


class Colors:
    """ANSI color codes for terminal output."""

    RED: Final[str] = "\033[0;31m"
    GREEN: Final[str] = "\033[0;32m"
    YELLOW: Final[str] = "\033[1;33m"
    BLUE: Final[str] = "\033[0;34m"
    MAGENTA: Final[str] = "\033[0;35m"
    CYAN: Final[str] = "\033[0;36m"
    BOLD: Final[str] = "\033[1m"
    RESET: Final[str] = "\033[0m"
