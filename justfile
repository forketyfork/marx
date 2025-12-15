# Marx development commands

# Display available commands
default:
    @just --list

# Install package in editable mode with dev dependencies
install:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "${IN_NIX_SHELL:-}" ]]; then
        echo "❌ You are in a Nix environment. pip install will fail."
        echo ""
        echo "In Nix, the marx command is already available in the dev shell."
        echo "For global installation, use: nix profile install ."
        echo "To run without installing, use: nix run ."
        exit 1
    else
        echo "📦 Installing marx in editable mode..."
        pip install -e ".[dev]"
    fi

# Run all linters (black, ruff, mypy)
lint: format-check lint-ruff type-check

# Format code with black
format:
    @echo "🎨 Formatting code with black..."
    black marx tests

# Check code formatting without modifying
format-check:
    @echo "🔍 Checking code formatting..."
    black --check marx tests

# Lint with ruff
lint-ruff:
    @echo "🔍 Linting with ruff..."
    ruff check marx tests

# Fix auto-fixable ruff issues
fix:
    @echo "🔧 Fixing auto-fixable issues..."
    ruff check --fix marx tests
    black marx tests

# Type check with mypy
type-check:
    @echo "🔍 Type checking with mypy..."
    mypy marx

# Run all tests with pytest
test:
    @echo "🧪 Running tests..."
    pytest -v

# Run tests with coverage report
test-cov:
    @echo "🧪 Running tests with coverage..."
    pytest --cov=marx --cov-report=term-missing --cov-report=html

# Run specific test file
test-file FILE:
    @echo "🧪 Running tests in {{FILE}}..."
    pytest -v {{FILE}}

# Run tests matching a pattern
test-match PATTERN:
    @echo "🧪 Running tests matching '{{PATTERN}}'..."
    pytest -v -k "{{PATTERN}}"

# Run marx CLI (pass arguments after --)
run *ARGS:
    @echo "🚀 Running marx..."
    python -m marx.cli {{ARGS}}

# Run marx with a specific PR
run-pr PR:
    @echo "🚀 Reviewing PR #{{PR}}..."
    python -m marx.cli --pr {{PR}}

# Run marx interactively
run-interactive:
    @echo "🚀 Running marx interactively..."
    python -m marx.cli

# Clean build artifacts and cache
clean:
    @echo "🧹 Cleaning build artifacts..."
    rm -rf build/
    rm -rf dist/
    rm -rf *.egg-info/
    rm -rf .pytest_cache/
    rm -rf .mypy_cache/
    rm -rf .ruff_cache/
    rm -rf htmlcov/
    rm -rf .coverage
    find . -type d -name __pycache__ -exec rm -rf {} +
    find . -type f -name "*.pyc" -delete
    @echo "✅ Cleaned"

# Build Docker image
docker-build:
    @echo "🐳 Building Docker image..."
    docker build -t marx:latest .

# Run Docker image verification
docker-verify:
    @echo "🐳 Verifying Docker image..."
    docker run --rm marx:latest /bin/bash -c "which claude && which codex && which gemini && echo 'All CLI tools found!'"

# Run all checks (lint, type-check, test)
check: lint type-check test
    @echo "✅ All checks passed!"

# Run CI-equivalent checks
ci: check
    @echo "✅ CI checks complete!"

# Watch tests (requires pytest-watch)
watch:
    @echo "👀 Watching for changes..."
    ptw -- -v

# Build package
build:
    @echo "📦 Building package..."
    python -m build

# Show project info
info:
    @echo "Marx Development Environment"
    @echo "================================="
    @echo "Python: $(python --version)"
    @echo "Pip: $(pip --version)"
    @echo "Location: $(which python)"
    @echo ""
    @echo "System Dependencies:"
    @echo "  git: $(git --version | head -1)"
    @echo "  gh: $(gh --version | head -1)"
    @echo "  jq: $(jq --version)"
    @echo "  docker: $(docker --version)"
    @echo ""
    @echo "Python Package Status:"
    @python -c "import marx; print(f'  marx: {marx.__version__}')" 2>/dev/null || echo "  marx: not installed"

# Release helper: update versions, commit, tag, and push
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{VERSION}}"

    if [[ -z "${VERSION}" ]]; then
        echo "❌ Version is required (e.g., v0.1.1)"
        exit 1
    fi

    if ! [[ "${VERSION}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "❌ Version must look like v0.1.1 or 0.1.1"
        exit 1
    fi

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "❌ Working tree is not clean. Commit or stash changes before releasing."
        exit 1
    fi

    if git rev-parse "refs/tags/${VERSION}" >/dev/null 2>&1; then
        echo "❌ Tag ${VERSION} already exists."
        exit 1
    fi

    echo "🔖 Updating versions to ${VERSION}..."
    python scripts/release.py "${VERSION}"

    git status --short

    echo "✅ Committing release..."
    git commit -am "chore: release ${VERSION}"

    echo "🏷️  Tagging ${VERSION}..."
    git tag -a "${VERSION}" -m "Release ${VERSION}"

    echo "🚀 Pushing commit and tag..."
    git push origin HEAD
    git push origin "${VERSION}"

    echo "🎉 Release ${VERSION} created and pushed."
