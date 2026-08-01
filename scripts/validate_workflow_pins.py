#!/usr/bin/env python3
"""Require immutable GitHub Action pins and optionally verify commits upstream."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
USES = re.compile(r"^\s*(?:-\s+)?uses\s*:\s*(.*?)\s*$")
COMMIT = re.compile(r"[0-9a-f]{40}")
DOCKER_DIGEST = re.compile(r"docker://[^@\s]+@sha256:[0-9a-f]{64}")


def _uses_value(path: pathlib.Path, line_number: int, raw_value: str) -> str:
    value = re.split(r"\s+#", raw_value, maxsplit=1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    if not value:
        raise RuntimeError(f"{path.relative_to(ROOT)}:{line_number}: uses value is empty")
    return value


def workflow_pins() -> tuple[dict[tuple[str, str], list[str]], int]:
    workflows = sorted((ROOT / ".github/workflows").glob("*.y*ml"))
    if not workflows:
        raise RuntimeError("no GitHub Actions workflows were found")
    pins: dict[tuple[str, str], list[str]] = {}
    uses_count = 0
    external_count = 0
    for path in workflows:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = USES.match(line)
            if not match:
                continue
            uses_count += 1
            action = _uses_value(path, line_number, match.group(1))
            if action.startswith("./"):
                continue
            external_count += 1
            if action.startswith("docker://"):
                if not DOCKER_DIGEST.fullmatch(action):
                    raise RuntimeError(
                        f"{path.relative_to(ROOT)}:{line_number}: Docker action must use a full lowercase sha256 digest"
                    )
                continue
            action_path, separator, commit = action.rpartition("@")
            if not separator or not COMMIT.fullmatch(commit):
                raise RuntimeError(
                    f"{path.relative_to(ROOT)}:{line_number}: action must use a full lowercase commit SHA"
                )
            parts = action_path.split("/")
            if len(parts) < 2 or any(not part for part in parts[:2]):
                raise RuntimeError(
                    f"{path.relative_to(ROOT)}:{line_number}: malformed GitHub action reference"
                )
            pins.setdefault((parts[0], parts[1]), []).append(commit)
    if uses_count == 0:
        raise RuntimeError("no GitHub Actions uses references were found")
    if external_count == 0:
        raise RuntimeError("no external action references were found")
    return pins, external_count


def verify_upstream(pins: dict[tuple[str, str], list[str]]) -> None:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    for (owner, repository), commits in sorted(pins.items()):
        for commit in sorted(set(commits)):
            url = f"https://api.github.com/repos/{owner}/{repository}/commits/{commit}"
            headers = {
                "Accept": "application/vnd.github+json",
                "User-Agent": "pakperk-workflow-pin-verifier/0.2.0",
                "X-GitHub-Api-Version": "2022-11-28",
            }
            if token:
                headers["Authorization"] = f"Bearer {token}"
            request = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    if response.status != 200:
                        raise RuntimeError(
                            f"upstream returned HTTP {response.status} for {owner}/{repository}@{commit}"
                        )
                    body = response.read(1024 * 1024 + 1)
            except (urllib.error.URLError, TimeoutError) as error:
                raise RuntimeError(
                    f"could not verify {owner}/{repository}@{commit} upstream: {error}"
                ) from error
            if len(body) > 1024 * 1024:
                raise RuntimeError(f"upstream response was oversized for {owner}/{repository}")
            payload = json.loads(body)
            if payload.get("sha") != commit:
                raise RuntimeError(
                    f"upstream did not resolve the exact commit for {owner}/{repository}@{commit}"
                )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--verify-upstream",
        action="store_true",
        help="resolve each unique pin through the GitHub commits API",
    )
    arguments = parser.parse_args()
    try:
        pins, references = workflow_pins()
        if arguments.verify_upstream:
            verify_upstream(pins)
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"workflow pin validation failed: {error}", file=sys.stderr)
        return 1
    print(
        f"Validated {references} action references across {len(pins)} upstream repositories"
        + (" and resolved every commit upstream." if arguments.verify_upstream else ".")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
