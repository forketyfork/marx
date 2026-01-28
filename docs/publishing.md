# Publishing

Marx ships with a GitHub Actions workflow in `.github/workflows/publish.yml` that builds
source and wheel distributions and uploads them as artifacts. When a GitHub release is
published, the same workflow also uploads the package to PyPI.

## Preparing a release

1. Update the version in `pyproject.toml`.
2. Run `just build` locally.
3. Commit and push the release changes, then create a Git tag (for example `v1.2.3`).
4. Draft and publish a GitHub release for the tag.

## Configuring credentials

- Create a PyPI API token.
- Add it to the repository secrets as `PYPI_API_TOKEN` (username should be `__token__`).
