"""Configuration and constants for Marx."""

from __future__ import annotations

import os
from importlib import resources
from pathlib import Path
from typing import Final

DOCKER_IMAGE: Final[str] = "marx:latest"
CONTAINER_RUNNER_DIR: Final[str] = "/runner"
CONTAINER_WORKSPACE_DIR: Final[str] = "/workspace"

SUPPORTED_AGENTS: Final[set[str]] = {"claude", "codex", "gemini"}

AGENT_COMMANDS: Final[dict[str, str]] = {
    "claude": "claude --print --output-format stream-json --verbose --dangerously-skip-permissions",
    "codex": "codex exec --dangerously-bypass-approvals-and-sandbox",
    "gemini": "gemini --output-format text --yolo --debug",
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

CONFIG_FILE_NAME: Final[str] = ".marx"
DEFAULT_CONFIG_PATH: Final[Path] = Path.home() / CONFIG_FILE_NAME
REVIEW_PROMPT_CONFIG_KEY: Final[str] = "REVIEW_PROMPT_PATH"
DEFAULT_PROMPT_RESOURCE_PACKAGE: Final[str] = "marx.prompts"
DEFAULT_PROMPT_RESOURCE_NAME: Final[str] = "review_prompt.md"

_CONFIG_CACHE: dict[Path, dict[str, str]] = {}


def _parse_config_line(line: str) -> tuple[str, str] | None:
    """Parse a single configuration line into a key/value pair."""

    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None

    if "=" not in stripped:
        return None

    key, value = stripped.split("=", 1)
    key = key.strip()
    value = value.strip()

    if not key:
        return None

    if value and value[0] in {'"', "'"} and value[-1] == value[0]:
        value = value[1:-1]
    else:
        hash_index = value.find(" #")
        if hash_index != -1:
            value = value[:hash_index].strip()

    return key, value


def load_config_file(path: Path | None = None) -> dict[str, str]:
    """Load key/value configuration pairs from the Marx config file."""

    resolved_path = path or DEFAULT_CONFIG_PATH
    cached = _CONFIG_CACHE.get(resolved_path)
    if cached is not None:
        return dict(cached)

    config: dict[str, str] = {}

    try:
        with resolved_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                parsed = _parse_config_line(line)
                if parsed is None:
                    continue
                key, value = parsed
                config[key] = value
    except FileNotFoundError:
        pass

    _CONFIG_CACHE[resolved_path] = config
    return dict(config)


def get_config_value(key: str, path: Path | None = None) -> str | None:
    """Retrieve a configuration value by key."""

    return load_config_file(path).get(key)


def load_review_prompt_template(config_path: Path | None = None) -> str:
    """Load the review prompt template, honoring configuration overrides."""

    override = os.environ.get("MARX_REVIEW_PROMPT_PATH")
    if not override:
        override = get_config_value(REVIEW_PROMPT_CONFIG_KEY, config_path)

    if override:
        resolved_path = Path(override).expanduser()
        try:
            return resolved_path.read_text(encoding="utf-8")
        except FileNotFoundError as exc:
            raise FileNotFoundError(f"Review prompt override not found at {resolved_path}") from exc

    prompt_resource = resources.files(DEFAULT_PROMPT_RESOURCE_PACKAGE).joinpath(
        DEFAULT_PROMPT_RESOURCE_NAME
    )
    return prompt_resource.read_text(encoding="utf-8")


def load_environment_from_file(path: Path | None = None) -> dict[str, str]:
    """Populate ``os.environ`` with values from the Marx config file."""

    config = load_config_file(path)
    for key, value in config.items():
        os.environ.setdefault(key, value)
    return dict(config)


def clear_config_cache() -> None:
    """Clear the cached config values (useful for tests)."""

    _CONFIG_CACHE.clear()


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
