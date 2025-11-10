# MaxReview development commands

# Display available commands
default:
    @just --list

# Install package in editable mode with dev dependencies
install:
    pip install -e ".[dev]"

# Run all linters (black, ruff, mypy)
lint: format-check lint-ruff type-check

# Format code with black
format:
    @echo "🎨 Formatting code with black..."
    black maxreview tests

# Check code formatting without modifying
format-check:
    @echo "🔍 Checking code formatting..."
    black --check maxreview tests

# Lint with ruff
lint-ruff:
    @echo "🔍 Linting with ruff..."
    ruff check maxreview tests

# Fix auto-fixable ruff issues
fix:
    @echo "🔧 Fixing auto-fixable issues..."
    ruff check --fix maxreview tests
    black maxreview tests

# Type check with mypy
type-check:
    @echo "🔍 Type checking with mypy..."
    mypy maxreview

# Run all tests with pytest
test:
    @echo "🧪 Running tests..."
    pytest -v

# Run tests with coverage report
test-cov:
    @echo "🧪 Running tests with coverage..."
    pytest --cov=maxreview --cov-report=term-missing --cov-report=html

# Run specific test file
test-file FILE:
    @echo "🧪 Running tests in {{FILE}}..."
    pytest -v {{FILE}}

# Run tests matching a pattern
test-match PATTERN:
    @echo "🧪 Running tests matching '{{PATTERN}}'..."
    pytest -v -k "{{PATTERN}}"

# Check bash scripts with shellcheck
check-sh:
    @echo "🔍 Checking bash scripts..."
    shellcheck maxreview.sh
    bash -n maxreview.sh
    @echo "✅ Bash scripts are valid"

# Run maxreview CLI (pass arguments after --)
run *ARGS:
    @echo "🚀 Running maxreview..."
    python -m maxreview.cli {{ARGS}}

# Run maxreview with a specific PR
run-pr PR:
    @echo "🚀 Reviewing PR #{{PR}}..."
    python -m maxreview.cli --pr {{PR}}

# Run maxreview interactively
run-interactive:
    @echo "🚀 Running maxreview interactively..."
    python -m maxreview.cli

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
    docker build -t maxreview:latest .

# Run Docker image verification
docker-verify:
    @echo "🐳 Verifying Docker image..."
    docker run --rm maxreview:latest /bin/bash -c "which claude && which codex && which gemini && echo 'All CLI tools found!'"

# Run all checks (lint, type-check, test)
check: lint type-check test check-sh
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
    @echo "MaxReview Development Environment"
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
    @python -c "import maxreview; print(f'  maxreview: {maxreview.__version__}')" 2>/dev/null || echo "  maxreview: not installed"
