# Development

## Nix workflow

```bash
nix develop
# or, with direnv
mkdir -p .
echo "use flake" > .envrc
direnv allow
```

## Just commands

```bash
just            # List all commands
just check      # Lint + type-check + test
just lint       # Run linters
just format     # Run black
just fix        # Auto-fix ruff issues and format
just test       # Run all tests
just run --pr 123
```

## Manual commands

```bash
pytest
pytest -v
pytest tests/test_github.py

black marx tests
ruff check marx tests
ruff check --fix marx tests
mypy marx
```

## Project structure

```
marx/
├── marx/          # Main package
├── tests/         # Test suite
├── pyproject.toml
├── requirements.txt
└── README.md
```
