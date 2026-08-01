#!/usr/bin/env python3
"""Validate one retained live-comments evidence JSON artifact."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from live_comments_evidence import ENVIRONMENTS, EvidenceError, read_evidence, validate_evidence


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--environment", required=True, choices=ENVIRONMENTS)
    parser.add_argument("--expected-outcome", choices=("passed", "failed"))
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        evidence = read_evidence(arguments.evidence)
        validated = validate_evidence(
            evidence,
            source_revision=arguments.source_revision,
            expected_outcome=arguments.expected_outcome,
            environment=arguments.environment,
        )
    except EvidenceError as error:
        print(f"live-comments evidence validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "Live-comments evidence validated "
        f"({validated['run']['outcome']}, {len(validated['scenarios'])} scenarios)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
