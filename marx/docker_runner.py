"""Docker container orchestration for running AI agent reviews."""

import json
import os
import shutil
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import docker  # type: ignore[import-untyped]
from docker.errors import BuildError, ContainerError, ImageNotFound  # type: ignore[import-untyped]
from pydantic import BaseModel

from marx.config import (
    AGENT_CONFIG_DIRS,
    CONTAINER_RUNNER_DIR,
    CONTAINER_WORKSPACE_DIR,
    DEFAULT_DOCKER_IMAGE,
    get_docker_image,
    load_review_prompt_template,
)
from marx.exceptions import DockerError
from marx.ui import print_error, print_info, print_success, print_warning

MODEL_OVERRIDE_ENV_VARS: dict[str, str] = {
    "claude": "CLAUDE_MODEL_OVERRIDE",
    "codex": "CODEX_MODEL_OVERRIDE",
    "gemini": "GEMINI_MODEL_OVERRIDE",
}


class ReviewPrompt(BaseModel):
    """Model for review prompt configuration."""

    repo: str
    pr_number: int
    commit_sha: str
    agent_name: str


class DockerRunner:
    """Orchestrate Docker container execution for AI agent reviews."""

    def __init__(self, dockerfile_dir: Path) -> None:
        """Initialize Docker runner."""
        self.dockerfile_dir = dockerfile_dir
        try:
            self.client = docker.from_env()
        except Exception as e:
            raise DockerError(f"Failed to connect to Docker daemon: {e}") from e
        self.docker_image = get_docker_image()

    def ensure_image(self) -> None:
        """Ensure Docker image exists, build if necessary."""
        try:
            self.client.images.get(self.docker_image)
            print_info(f"Docker image {self.docker_image} already exists")
        except ImageNotFound:
            if self.docker_image == DEFAULT_DOCKER_IMAGE:
                self._build_image()
            else:
                self._pull_image()

    def _build_image(self) -> None:
        """Build the Docker image."""
        print_info(f"Building Docker image {self.docker_image}...")
        try:
            self.client.images.build(
                path=str(self.dockerfile_dir),
                tag=self.docker_image,
                rm=True,
            )
            print_success("Docker image built successfully")
        except BuildError as e:
            logs = "\n".join(line.get("stream", "") for line in e.build_log if "stream" in line)
            raise DockerError(f"Failed to build Docker image:\n{logs}") from e

    def _pull_image(self) -> None:
        """Pull a custom Docker image."""
        print_info(f"Pulling Docker image {self.docker_image}...")
        try:
            self.client.images.pull(self.docker_image)
            print_success(f"Docker image {self.docker_image} pulled successfully")
        except Exception as e:
            raise DockerError(
                f"Failed to pull custom Docker image {self.docker_image}: {e}\n"
                f"Make sure the image exists and is accessible, or use the default image."
            ) from e

    def run_agents_parallel(
        self,
        agents: list[str],
        prompt_config: ReviewPrompt,
        run_path: Path,
        model_overrides: dict[str, str] | None = None,
    ) -> dict[str, Path]:
        """Run multiple agents in parallel and return their output file paths."""
        results: dict[str, Path] = {}
        errors: dict[str, Exception] = {}
        resolved_overrides = model_overrides or {}

        with ThreadPoolExecutor(max_workers=len(agents)) as executor:
            future_to_agent = {
                executor.submit(
                    self._run_single_agent,
                    agent,
                    prompt_config,
                    run_path,
                    resolved_overrides.get(agent),
                ): agent
                for agent in agents
            }

            for future in as_completed(future_to_agent):
                agent = future_to_agent[future]
                try:
                    output_file = future.result()
                    results[agent] = output_file
                except Exception as e:
                    errors[agent] = e
                    print_error(f"{agent.capitalize()} analysis failed: {e}")
                    output_file = run_path / f"{agent}-review.json"
                    self._create_error_review(output_file, prompt_config.pr_number, agent, str(e))
                    results[agent] = output_file

        if errors:
            print_warning(f"Some agents failed: {', '.join(errors.keys())}")
        else:
            print_success("All AI models completed their analysis! 📝")

        return results

    def _run_single_agent(
        self,
        agent: str,
        prompt_config: ReviewPrompt,
        run_path: Path,
        model_override: str | None = None,
    ) -> Path:
        """Run a single agent in a Docker container."""
        print_info(f"Starting {agent.capitalize()} analysis...")

        output_file = run_path / f"{agent}-review.json"
        raw_output_file = run_path / f"{agent}-raw.jsonl"
        stderr_file = run_path / f"{agent}-review.json.stderr"

        output_file.unlink(missing_ok=True)
        raw_output_file.unlink(missing_ok=True)
        stderr_file.unlink(missing_ok=True)

        prompt = self._generate_prompt(prompt_config, agent)

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", dir=run_path, delete=False
        ) as prompt_file:
            prompt_file.write(prompt)
            prompt_path = Path(prompt_file.name)

        try:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".sh", dir=run_path, delete=False
            ) as runner_script:
                runner_script.write(self._generate_runner_script())
                runner_script_path = Path(runner_script.name)

            runner_script_path.chmod(0o755)

            container_output = self._run_container(
                agent,
                prompt_config,
                run_path,
                prompt_path,
                runner_script_path,
                stderr_file,
                model_override,
            )

            raw_output_file.write_text(container_output)

            workspace_review_path = run_path / "workspace_review.json"
            if workspace_review_path.exists():
                shutil.copy(workspace_review_path, output_file)
                workspace_review_path.unlink()

            if output_file.exists():
                try:
                    with open(output_file) as f:
                        json.load(f)
                    print_success(f"{agent.capitalize()} analysis completed")
                except json.JSONDecodeError:
                    print_warning(
                        f"{agent.capitalize()} produced invalid JSON, creating error review"
                    )
                    invalid_file = run_path / f"{agent}-review.json.invalid"
                    shutil.move(output_file, invalid_file)
                    self._create_error_review(
                        output_file, prompt_config.pr_number, agent, "produced invalid JSON"
                    )
            else:
                print_warning(f"{agent.capitalize()} did not create the expected review file")
                self._create_error_review(
                    output_file,
                    prompt_config.pr_number,
                    agent,
                    "did not create the expected review file",
                )

            if stderr_file.exists() and stderr_file.stat().st_size == 0:
                stderr_file.unlink()

        finally:
            prompt_path.unlink(missing_ok=True)
            if "runner_script_path" in locals():
                runner_script_path.unlink(missing_ok=True)

        return output_file

    def _run_container(
        self,
        agent: str,
        prompt_config: ReviewPrompt,
        run_path: Path,
        prompt_path: Path,
        runner_script_path: Path,
        stderr_file: Path,
        model_override: str | None = None,
    ) -> str:
        """Run a Docker container and return its output."""
        host_uid = os.getuid()
        host_gid = os.getgid()

        container_prompt = f"{CONTAINER_RUNNER_DIR}/{prompt_path.name}"
        container_runner = f"{CONTAINER_RUNNER_DIR}/{runner_script_path.name}"
        container_stderr = f"{CONTAINER_RUNNER_DIR}/{stderr_file.name}"

        volumes = {
            str(run_path): {"bind": CONTAINER_RUNNER_DIR, "mode": "rw"},
        }

        environment = {
            "GITHUB_TOKEN": os.environ.get("GITHUB_TOKEN", ""),
            "ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_API_KEY", ""),
            "OPENAI_API_KEY": os.environ.get("OPENAI_API_KEY", ""),
            "GOOGLE_API_KEY": os.environ.get("GOOGLE_API_KEY", ""),
            "GEMINI_API_KEY": os.environ.get("GEMINI_API_KEY", ""),
            "HOME_OVERRIDE": CONTAINER_WORKSPACE_DIR,
            "HOST_UID": str(host_uid),
            "HOST_GID": str(host_gid),
            "CONTAINER_RUNNER_DIR": CONTAINER_RUNNER_DIR,
            "MODEL_REVIEW_PATH": f"{CONTAINER_RUNNER_DIR}/{agent}-review.json",
            "MODEL_REVIEW_WORKSPACE_PATH": (
                f"{CONTAINER_WORKSPACE_DIR}/repo/.marx/{agent}-review.json"
            ),
        }

        if model_override:
            env_var = MODEL_OVERRIDE_ENV_VARS.get(agent)
            if env_var:
                environment[env_var] = model_override

        config_dir = AGENT_CONFIG_DIRS.get(agent)
        if config_dir:
            host_config_path = Path.home() / config_dir
            if host_config_path.exists():
                container_config_path = f"/host-configs/{agent}"
                volumes[str(host_config_path)] = {"bind": container_config_path, "mode": "ro"}
                environment[f"{agent.upper()}_CONFIG_SRC"] = container_config_path

        container_name = f"marx-{agent}-{prompt_config.pr_number}"

        try:
            container = self.client.containers.run(
                self.docker_image,
                command=[
                    "/bin/bash",
                    container_runner,
                    agent,
                    container_prompt,
                    container_stderr,
                    prompt_config.repo,
                    str(prompt_config.pr_number),
                    prompt_config.commit_sha,
                ],
                name=container_name,
                volumes=volumes,
                environment=environment,
                working_dir=CONTAINER_WORKSPACE_DIR,
                remove=True,
                detach=False,
                stdout=True,
                stderr=True,
            )

            if isinstance(container, bytes):
                return container.decode("utf-8")
            return str(container)

        except ContainerError as e:
            raise DockerError(f"Container execution failed: {e}") from e
        except Exception as e:
            raise DockerError(f"Unexpected error running container: {e}") from e

    def _generate_prompt(self, config: ReviewPrompt, agent: str) -> str:
        """Generate the review prompt for an agent."""
        template = load_review_prompt_template()
        return template.format(
            pr_number=config.pr_number,
            repo=config.repo,
            commit_sha=config.commit_sha,
            agent=agent,
            container_workspace_dir=CONTAINER_WORKSPACE_DIR,
        )

    def _generate_runner_script(self) -> str:
        """Generate the container runner script."""
        return """#!/usr/bin/env bash
set -euo pipefail

MODEL_CMD="$1"
PROMPT_FILE="$2"
STDERR_FILE="$3"
REPO_SLUG="$4"
PR_NUMBER="$5"
COMMIT_SHA="$6"

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
CONTAINER_RUNNER_DIR="${CONTAINER_RUNNER_DIR:-/runner}"
MODEL_REVIEW_PATH="${MODEL_REVIEW_PATH:-${CONTAINER_RUNNER_DIR}/${MODEL_CMD}-review.json}"
MODEL_REVIEW_WORKSPACE_PATH="${MODEL_REVIEW_WORKSPACE_PATH:-\\
/workspace/repo/.marx/${MODEL_CMD}-review.json}"

TARGET_USER="marx"
if getent passwd "$HOST_UID" >/dev/null 2>&1; then
    TARGET_USER="$(getent passwd "$HOST_UID" | cut -d: -f1)"
fi

if ! getent group "$HOST_GID" >/dev/null 2>&1; then
    groupadd -g "$HOST_GID" marx 2>/dev/null || true
fi

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash \\
        -d "/home/$TARGET_USER" "$TARGET_USER" 2>/dev/null || true
fi

mkdir -p "$(dirname "$STDERR_FILE")"
touch "$STDERR_FILE"
chown -R "$HOST_UID:$HOST_GID" "$(dirname "$STDERR_FILE")" 2>/dev/null || true

if [ -d "$CONTAINER_RUNNER_DIR" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$CONTAINER_RUNNER_DIR" 2>/dev/null || true
fi

mkdir -p /workspace
chown -R "$HOST_UID:$HOST_GID" /workspace

cat > /tmp/run-as-user.sh <<'INNERSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_CMD:?}"
: "${PROMPT_FILE:?}"
: "${STDERR_FILE:?}"
: "${REPO_SLUG:?}"
: "${PR_NUMBER:=}"
: "${COMMIT_SHA:=}"

: "${HOME_OVERRIDE:=/workspace}"
mkdir -p "$HOME_OVERRIDE"
export HOME="$HOME_OVERRIDE"

: > "$STDERR_FILE"
exec 2>>"$STDERR_FILE"

: "${MODEL_REVIEW_PATH:=/workspace/${MODEL_CMD}-review.json}"
mkdir -p "$(dirname "$MODEL_REVIEW_PATH")"
rm -f "$MODEL_REVIEW_PATH"

: "${MODEL_REVIEW_WORKSPACE_PATH:=/workspace/repo/.marx/${MODEL_CMD}-review.json}"
mkdir -p "$(dirname "$MODEL_REVIEW_WORKSPACE_PATH")"
rm -f "$MODEL_REVIEW_WORKSPACE_PATH"

setup_credentials() {
    local source_dir="$1"
    local target_dir="$2"

    if [[ -n "$source_dir" && -d "$source_dir" ]]; then
        mkdir -p "$target_dir"
        cp -a "$source_dir"/. "$target_dir"/
    else
        mkdir -p "$target_dir"
    fi
}

clone_repository() {
    local repo="$1"
    local pr_number="$2"
    local commit_sha="$3"

    export GIT_TERMINAL_PROMPT=0
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        export GH_TOKEN="${GITHUB_TOKEN}"
    fi

    mkdir -p /workspace
    cd /workspace

    rm -rf repo
    if ! gh repo clone "$repo" repo >/dev/null 2>&1; then
        if ! git clone "https://github.com/${repo}.git" repo >/dev/null 2>&1; then
            echo "Failed to clone repository ${repo}" >&2
            return 1
        fi
    fi

    cd repo

    if [ -n "$pr_number" ]; then
        if ! gh pr checkout "$pr_number" --detach >/dev/null 2>&1; then
            if ! git fetch origin "pull/${pr_number}/head:pr-${pr_number}" >/dev/null 2>&1; then
                echo "Failed to fetch PR ${pr_number}" >&2
                return 1
            fi
            if ! git checkout "pr-${pr_number}" >/dev/null 2>&1; then
                echo "Failed to checkout PR branch pr-${pr_number}" >&2
                return 1
            fi
        fi
    fi

    if [ -n "$commit_sha" ]; then
        if ! git checkout "$commit_sha" >/dev/null 2>&1; then
            echo "Failed to checkout commit ${commit_sha}" >&2
            return 1
        fi
    fi

    return 0
}

if ! clone_repository "$REPO_SLUG" "$PR_NUMBER" "$COMMIT_SHA"; then
    exit 1
fi

cd /workspace/repo

case "$MODEL_CMD" in
    claude)
        setup_credentials "${CLAUDE_CONFIG_SRC:-}" "$HOME/.claude"
        CLAUDE_MODEL_FLAGS=()
        if [[ -n "${CLAUDE_MODEL_OVERRIDE:-}" ]]; then
            CLAUDE_MODEL_FLAGS=(--model "${CLAUDE_MODEL_OVERRIDE}")
        fi
        claude "${CLAUDE_MODEL_FLAGS[@]}" --print --output-format stream-json --verbose \\
            --dangerously-skip-permissions < "$PROMPT_FILE"
        ;;
    codex)
        setup_credentials "${CODEX_CONFIG_SRC:-}" "$HOME/.codex"
        CODEX_MODEL_FLAGS=()
        if [[ -n "${CODEX_MODEL_OVERRIDE:-}" ]]; then
            CODEX_MODEL_FLAGS=(--model "${CODEX_MODEL_OVERRIDE}")
        fi
        codex exec "${CODEX_MODEL_FLAGS[@]}" --dangerously-bypass-approvals-and-sandbox \\
            < "$PROMPT_FILE"
        ;;
    gemini)
        setup_credentials "${GEMINI_CONFIG_SRC:-}" "$HOME/.gemini"
        GEMINI_MODEL_FLAGS=()
        if [[ -n "${GEMINI_MODEL_OVERRIDE:-}" ]]; then
            GEMINI_MODEL_FLAGS=(--model "${GEMINI_MODEL_OVERRIDE}")
        fi
        gemini "${GEMINI_MODEL_FLAGS[@]}" --output-format text --yolo --debug < "$PROMPT_FILE"
        ;;
    *)
        echo "Unknown model command: $MODEL_CMD" >&2
        exit 1
        ;;
esac
INNERSCRIPT

chmod +x /tmp/run-as-user.sh
chown "$HOST_UID:$HOST_GID" /tmp/run-as-user.sh

printf -v su_command \\
    "MODEL_CMD=%q PROMPT_FILE=%q STDERR_FILE=%q REPO_SLUG=%q PR_NUMBER=%q COMMIT_SHA=%q \\
HOME_OVERRIDE=%q MODEL_REVIEW_PATH=%q CLAUDE_CONFIG_SRC=%q CODEX_CONFIG_SRC=%q \\
GEMINI_CONFIG_SRC=%q CLAUDE_MODEL_OVERRIDE=%q CODEX_MODEL_OVERRIDE=%q GEMINI_MODEL_OVERRIDE=%q \\
/tmp/run-as-user.sh" \\
    "$MODEL_CMD" "$PROMPT_FILE" "$STDERR_FILE" "$REPO_SLUG" "$PR_NUMBER" "$COMMIT_SHA" \\
    "$HOME_OVERRIDE" "${MODEL_REVIEW_PATH}" "${CLAUDE_CONFIG_SRC:-}" \\
    "${CODEX_CONFIG_SRC:-}" "${GEMINI_CONFIG_SRC:-}" \\
    "${CLAUDE_MODEL_OVERRIDE:-}" "${CODEX_MODEL_OVERRIDE:-}" "${GEMINI_MODEL_OVERRIDE:-}"

su "$TARGET_USER" -c "$su_command"

if [ -f "$MODEL_REVIEW_WORKSPACE_PATH" ]; then
    cp "$MODEL_REVIEW_WORKSPACE_PATH" "$MODEL_REVIEW_PATH"
    chown "$HOST_UID:$HOST_GID" "$MODEL_REVIEW_PATH" 2>/dev/null || true
    chmod 0644 "$MODEL_REVIEW_PATH" 2>/dev/null || true
fi
"""

    @staticmethod
    def _create_error_review(output_file: Path, pr_number: int, agent: str, error_msg: str) -> None:
        """Create an error review JSON file."""
        error_review = {
            "pr_summary": {
                "number": pr_number,
                "title": "Error",
                "description": f"{agent.capitalize()} {error_msg}",
            },
            "issues": [],
        }
        with open(output_file, "w") as f:
            json.dump(error_review, f, indent=2)
