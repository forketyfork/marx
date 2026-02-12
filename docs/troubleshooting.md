# Troubleshooting

## "GITHUB_TOKEN environment variable is not set"

Set `GITHUB_TOKEN` in your shell or `~/.marx`.

## "Unable to determine repository automatically"

Set `MARX_REPO=owner/repo` in your environment or `~/.marx`.

## "Missing required dependencies"

Install the tools listed in the error message (`git`, `gh`, `docker`).

## "Your token has not been granted the required scopes"

The GitHub token needs to be a **classic** PAT with the `repo` scope.
Fine-grained tokens are not supported. Create or update your token at
<https://github.com/settings/tokens>.

If the repository belongs to an organization with SAML SSO, you must also authorize
the token for that organization on the same settings page.

## Agent fails or returns invalid output

Marx will fall back to an empty review and show errors in the output. Common causes:

- Missing authentication (API keys or local CLI configs)
- Invalid credentials in `~/.claude`, `~/.codex`, or `~/.gemini`
- Network connectivity or rate limiting

If you are using local CLI configs, verify they work on the host first.
