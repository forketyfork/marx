# Troubleshooting

## "GITHUB_TOKEN environment variable is not set"

Set `GITHUB_TOKEN` in your shell or `~/.marx`.

## "Unable to determine repository automatically"

Set `MARX_REPO=owner/repo` in your environment or `~/.marx`.

## "Missing required dependencies"

Install the tools listed in the error message (`git`, `gh`, `docker`).

## Agent fails or returns invalid output

Marx will fall back to an empty review and show errors in the output. Common causes:

- Missing authentication (API keys or local CLI configs)
- Invalid credentials in `~/.claude`, `~/.codex`, or `~/.gemini`
- Network connectivity or rate limiting

If you are using local CLI configs, verify they work on the host first.
