"""Update project version across all metadata files."""

from __future__ import annotations

import argparse
import pathlib
import re


def update_file(path: pathlib.Path, pattern: str, replacement: str) -> None:
    text = path.read_text()
    new_text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count == 0:
        raise SystemExit(f"Failed to update version in {path}")
    path.write_text(new_text)
    print(f"{path.name} -> updated")


def main() -> None:
    parser = argparse.ArgumentParser(description="Update version strings.")
    parser.add_argument("version", help="Version value such as v0.1.1")
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    version = args.version

    updates = {
        root / "pyproject.toml": (r'^version\s*=\s*".*"$', f'version = "{version}"'),
        root / "marx" / "__init__.py": (
            r'^__version__\s*=\s*".*"$',
            f'__version__ = "{version}"',
        ),
        root
        / "flake.nix": (
            r'^\s*version\s*=\s*".*"\s*;',
            f'    version = "{version}";',
        ),
    }

    for path, (pattern, replacement) in updates.items():
        update_file(path, pattern, replacement)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:  # bubble up explicit error text
        raise
    except Exception as exc:
        raise SystemExit(str(exc)) from exc
