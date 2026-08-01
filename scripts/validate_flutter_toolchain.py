#!/usr/bin/env python3
"""Validate the exact reviewed Flutter release identity."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


EXPECTED_FLUTTER_VERSION = "3.44.8"
EXPECTED_FRAMEWORK_REVISION = "058e0af2c2b57e369d905a03ac9748b0ebf543c6"
EXPECTED_DART_SDK_VERSION = "3.12.2"
EXPECTED_CHANNEL = "stable"
EXPECTED_REPOSITORY = "https://github.com/flutter/flutter.git"
LOWERCASE_REVISION = re.compile(r"[0-9a-f]{40}")


def validate(payload: object) -> None:
    if not isinstance(payload, dict):
        raise RuntimeError("Flutter toolchain metadata must be a JSON object")
    expected = {
        "frameworkVersion": EXPECTED_FLUTTER_VERSION,
        "flutterVersion": EXPECTED_FLUTTER_VERSION,
        "frameworkRevision": EXPECTED_FRAMEWORK_REVISION,
        "dartSdkVersion": EXPECTED_DART_SDK_VERSION,
        "channel": EXPECTED_CHANNEL,
        "repositoryUrl": EXPECTED_REPOSITORY,
    }
    mismatches = {
        key: payload.get(key)
        for key, value in expected.items()
        if payload.get(key) != value
    }
    if mismatches:
        raise RuntimeError(
            f"Flutter toolchain differs from the reviewed release: {mismatches}"
        )
    for key in ("engineRevision", "engineContentHash"):
        if LOWERCASE_REVISION.fullmatch(str(payload.get(key, ""))) is None:
            raise RuntimeError(f"Flutter toolchain metadata has no immutable {key}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("metadata", type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        validate(json.loads(arguments.metadata.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, RuntimeError) as error:
        print(f"Flutter toolchain validation failed: {error}", file=sys.stderr)
        return 1
    print("Reviewed Flutter 3.44.8 toolchain validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
