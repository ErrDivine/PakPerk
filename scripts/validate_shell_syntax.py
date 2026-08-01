#!/usr/bin/env python3
"""Parse every checked-in repository shell script with Bash."""

from __future__ import annotations

import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SCRIPTS_DIRECTORY = ROOT / "scripts"


def validate(scripts_directory: pathlib.Path = DEFAULT_SCRIPTS_DIRECTORY) -> int:
    if not scripts_directory.is_dir():
        raise RuntimeError("shell-script directory is missing")

    scripts = sorted(scripts_directory.glob("*.sh"))
    if not scripts:
        raise RuntimeError("shell-script directory contains no .sh files")

    for script in scripts:
        if script.is_symlink() or not script.is_file():
            raise RuntimeError(
                f"shell-script path is not a regular file: {script.name}"
            )
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or "Bash rejected the file"
            raise RuntimeError(f"{script.name} failed syntax validation: {detail}")

    return len(scripts)


def main() -> int:
    try:
        count = validate()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Shell syntax validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Validated Bash syntax for {count} shell scripts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
