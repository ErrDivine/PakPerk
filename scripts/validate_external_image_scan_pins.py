#!/usr/bin/env python3
"""Keep external chart image digests and security scans fail-closed and aligned."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def chart_image(values: pathlib.Path, section: str) -> str:
    lines = values.read_text(encoding="utf-8").splitlines()
    in_section = False
    in_image = False
    repository: str | None = None
    digest: str | None = None
    for line in lines:
        if line and not line.startswith(" "):
            if in_section:
                break
            in_section = line == f"{section}:"
            continue
        if not in_section:
            continue
        if line == "  image:":
            in_image = True
            continue
        if in_image and line.startswith("  ") and not line.startswith("    "):
            break
        if not in_image:
            continue
        stripped = line.strip()
        if stripped.startswith("repository:"):
            repository = stripped.partition(":")[2].strip().strip("'\"")
        elif stripped.startswith("digest:"):
            digest = stripped.partition(":")[2].strip().strip("'\"")
    if not repository or not digest or not DIGEST.fullmatch(digest):
        raise RuntimeError(f"{section}.image must use a repository and full sha256 digest")
    return f"{repository}@{digest}"


def workflow_env(workflow: pathlib.Path, name: str) -> str:
    pattern = re.compile(rf"^\s{{2}}{re.escape(name)}:\s*(\S+)\s*$")
    matches = [
        match.group(1).strip("'\"")
        for line in workflow.read_text(encoding="utf-8").splitlines()
        if (match := pattern.match(line))
    ]
    if len(matches) != 1:
        raise RuntimeError(f"security workflow must define exactly one {name}")
    value = matches[0]
    repository, separator, digest = value.rpartition("@")
    if not separator or not repository or not DIGEST.fullmatch(digest):
        raise RuntimeError(f"{name} must be an immutable repository@sha256 reference")
    return value


def validate(values: pathlib.Path, workflow: pathlib.Path) -> None:
    expected = {
        "GROBID_IMAGE": chart_image(values, "grobid"),
        "OTEL_COLLECTOR_IMAGE": chart_image(values, "otelCollector"),
    }
    workflow_text = workflow.read_text(encoding="utf-8")
    for variable, chart_reference in expected.items():
        scan_reference = workflow_env(workflow, variable)
        if scan_reference != chart_reference:
            raise RuntimeError(
                f"{variable} ({scan_reference}) does not match chart image "
                f"({chart_reference})"
            )
        occurrences = workflow_text.count(f"image-ref: ${{{{ env.{variable} }}}}")
        if occurrences != 2:
            raise RuntimeError(
                f"{variable} must have exactly one vulnerability scan and one SBOM scan"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--values",
        type=pathlib.Path,
        default=ROOT / "deploy/helm/pakperk/values.yaml",
    )
    parser.add_argument(
        "--workflow",
        type=pathlib.Path,
        default=ROOT / ".github/workflows/security.yml",
    )
    arguments = parser.parse_args()
    try:
        validate(arguments.values, arguments.workflow)
    except (OSError, RuntimeError) as error:
        print(f"external image scan validation failed: {error}", file=sys.stderr)
        return 1
    print("External GROBID and OpenTelemetry image scan pins match the chart.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
