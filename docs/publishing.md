# Publishing

Marx ships with a GitHub Actions workflow in `.github/workflows/publish.yml` that builds
source and wheel distributions and uploads them as artifacts. When a GitHub release is
published, the same workflow also uploads the package to PyPI via Trusted Publishing (OIDC).

## Preparing a release

1. Update the version in `pyproject.toml` and `marx/__init__.py`.
2. Commit and push the changes via a PR (main is protected).
3. After merging, tag the merge commit: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`
4. Create a GitHub release for the tag: `gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."`

## Authentication

Publishing uses PyPI Trusted Publishing. The workflow authenticates via OIDC
(`id-token: write` permission) — no API tokens or secrets are needed.

The Trusted Publisher is configured on PyPI to trust releases from this repository's
`publish.yml` workflow.
