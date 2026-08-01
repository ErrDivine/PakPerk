#!/usr/bin/env python3
"""Fail if local credentials or native build caches can enter Docker context."""

from __future__ import annotations

import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED_PATTERNS = {
    ".env",
    ".env.*",
    ".local",
    "**/*.jks",
    "**/*.keystore",
    "**/*.key",
    "**/*.pem",
    "**/*.mobileprovision",
    "**/*.provisionprofile",
    "**/*.p12",
    "**/*.pfx",
    "**/*.pkcs12",
    "mobile/.dart_tool",
    "mobile/build",
    "mobile/android/.gradle",
    "mobile/android/.cxx",
    "mobile/android/build",
    "mobile/android/key.properties",
    "mobile/android/local.properties",
    "mobile/ios/.symlinks",
    "mobile/ios/DerivedData",
    "mobile/ios/build",
    "mobile/ios/Flutter/Generated.xcconfig",
    "mobile/ios/Flutter/LocalSigning.xcconfig",
    "mobile/ios/Flutter/ephemeral",
    "mobile/ios/Flutter/flutter_export_environment.sh",
    "mobile/ios/Pods",
    "mobile/ios/**/xcuserdata",
    "**/__pycache__",
    "**/*.pyc",
    "**/*.pyo",
}


def main() -> int:
    dockerignore = ROOT / ".dockerignore"
    patterns = {
        line.strip()
        for line in dockerignore.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    missing = sorted(REQUIRED_PATTERNS - patterns)
    if missing:
        raise SystemExit(
            "Docker context can include local credentials or native caches; "
            f"missing .dockerignore patterns: {', '.join(missing)}"
        )
    print("Validated Docker context credential and native-cache exclusions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
