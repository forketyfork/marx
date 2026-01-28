# Installation

## Prerequisites

- `git`
- `gh` (GitHub CLI, authenticated)
- `docker` (not required when using `--resume`)

## Option 1: Install from PyPI

```bash
uv tool install marx-ai
```

Run without installing:

```bash
uvx marx-ai
```

## Option 2: Nix

```bash
git clone https://github.com/forketyfork/marx.git
cd marx

nix profile install .
# Or run without installing
nix run .
# Or enter the dev environment
nix develop
```

## Option 3: From source with uv

```bash
git clone https://github.com/forketyfork/marx.git
cd marx

uv pip install .
# Or install in editable mode for development
uv pip install -e ".[dev]"
```

Note: In Nix shells, `uv pip install` will fail because Python is read-only.
Use the Nix install methods instead.
