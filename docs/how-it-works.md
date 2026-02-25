# How It Works

## High-level workflow

1. Validate dependencies (`git`, `gh`, and `docker` unless `--resume`).
2. Detect the repository from `MARX_REPO`, `gh repo view`, or git remotes.
3. Fetch open PRs and prompt for selection (or use `--pr`).
4. Create a run directory under `runs/pr-<number>-<branch>/`.
5. Start one container per agent to clone the PR and run its review.
6. Merge results and display a unified review (and optionally JSON).

## Containers and artifacts

Each agent runs in an isolated container with:

- A fresh clone of the PR inside the container workspace
- A mounted run directory for artifacts
- Optional agent config directories mounted read-only from the host
- Environment variables for tokens and API keys

Artifacts are copied back to the host run directory on completion.

## Docker image

By default, Marx uses `ghcr.io/forketyfork/marx:latest`.
You can override this with:

- `MARX_DOCKER_IMAGE` (environment variable)
- `DOCKER_IMAGE` in `~/.marx`

The image must include:

- `/bin/bash` and core utilities
- `git` and `gh`
- `rg`, `fd`, `tree`, `socat`, `fastmod`, `ast-grep` (with `sg` alias)
- The agent CLIs you intend to run (`claude`, `codex`, `gemini`)

## Security notes

- Agents run in isolated containers.
- Config directories are mounted read-only and copied into container home.
- GitHub tokens and API keys are passed as environment variables.
- No destructive operations are performed against your local repository.
