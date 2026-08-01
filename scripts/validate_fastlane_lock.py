#!/usr/bin/env python3
"""Validate the checksum-complete Fastlane release-tool lockfile."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_GEMFILE = ROOT / "mobile/Gemfile"
DEFAULT_LOCKFILE = ROOT / "mobile/Gemfile.lock"
FASTLANE_VERSION = "2.235.0"
FASTLANE_SHA256 = "7de12cf4c4e242b68836aef859ba8e6b25bb1db7f6c8e2d705b024fb16a2ed65"
BUNDLER_VERSION = "2.6.9"
MULTI_JSON_VERSION = "1.21.1"
MULTI_JSON_SHA256 = "e6126a31808e3b4d19f483c775ceac34df190dffa62adfb63a165ee14ba68080"
SHA256 = re.compile(r"[0-9a-f]{64}")


def section(source: str, name: str) -> list[str]:
    marker = f"{name}\n"
    start = source.find(marker)
    if start < 0:
        raise RuntimeError(f"Gemfile.lock is missing {name}")
    start += len(marker)
    remaining = source[start:]
    end_match = re.search(r"(?m)^[A-Z][A-Z ]+\n", remaining)
    return (remaining[: end_match.start()] if end_match else remaining).splitlines()


def validate(gemfile: pathlib.Path, lockfile: pathlib.Path) -> None:
    gemfile_source = gemfile.read_text(encoding="utf-8")
    if gemfile_source != (
        'source "https://rubygems.org"\n\n'
        f'gem "fastlane", "{FASTLANE_VERSION}"\n'
        "# Fastlane's Google API action path loads this at runtime without a complete\n"
        "# transitive declaration. Keep it explicit so `bundle exec fastlane` works.\n"
        f'gem "multi_json", "{MULTI_JSON_VERSION}"\n'
    ):
        raise RuntimeError("mobile/Gemfile must contain only the exact Fastlane pin")

    source = lockfile.read_text(encoding="utf-8")
    if "remote: https://rubygems.org/" not in source or "\nGIT\n" in source or "\nPATH\n" in source:
        raise RuntimeError("Fastlane lockfile must use only the official HTTPS gem source")

    specs: set[tuple[str, str]] = set()
    for line in section(source, "GEM"):
        match = re.fullmatch(r"    ([A-Za-z0-9_.-]+) \(([^ )]+)(?:-[^ )]+)?\)", line)
        if match:
            specs.add(match.groups())
    if ("fastlane", FASTLANE_VERSION) not in specs or len(specs) < 50:
        raise RuntimeError("Fastlane transitive dependency graph is incomplete")

    checksums: dict[tuple[str, str], str] = {}
    for line in section(source, "CHECKSUMS"):
        match = re.fullmatch(
            r"  ([A-Za-z0-9_.-]+) \(([^ )]+)(?:-[^ )]+)?\) sha256=([0-9a-f]{64})",
            line,
        )
        if match:
            name, version, digest = match.groups()
            checksums[(name, version)] = digest
    missing = sorted(specs - checksums.keys())
    if missing:
        raise RuntimeError(f"Fastlane gems are missing checksums: {missing[:3]}")
    if checksums.get(("fastlane", FASTLANE_VERSION)) != FASTLANE_SHA256:
        raise RuntimeError("reviewed Fastlane package checksum changed")
    if checksums.get(("multi_json", MULTI_JSON_VERSION)) != MULTI_JSON_SHA256:
        raise RuntimeError("reviewed Fastlane compatibility checksum changed")
    if any(SHA256.fullmatch(value) is None for value in checksums.values()):
        raise RuntimeError("Fastlane lockfile contains an unsafe checksum")

    dependencies = "\n".join(section(source, "DEPENDENCIES"))
    if f"  fastlane (= {FASTLANE_VERSION})" not in dependencies:
        raise RuntimeError("Fastlane dependency is not exact")
    if f"  multi_json (= {MULTI_JSON_VERSION})" not in dependencies:
        raise RuntimeError("Fastlane compatibility dependency is not exact")
    platforms = set(value.strip() for value in section(source, "PLATFORMS") if value.strip())
    if not {"ruby", "arm64-darwin-25", "x86_64-darwin-25"}.issubset(platforms):
        raise RuntimeError("Fastlane lockfile lacks required macOS release platforms")
    bundled_with = "".join(value.strip() for value in section(source, "BUNDLED WITH"))
    if bundled_with != BUNDLER_VERSION:
        raise RuntimeError("Fastlane lockfile uses an unreviewed Bundler version")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gemfile", type=pathlib.Path, default=DEFAULT_GEMFILE)
    parser.add_argument("--lockfile", type=pathlib.Path, default=DEFAULT_LOCKFILE)
    arguments = parser.parse_args()
    try:
        validate(arguments.gemfile, arguments.lockfile)
    except (OSError, RuntimeError) as error:
        print(f"Fastlane lock validation failed: {error}", file=sys.stderr)
        return 1
    print("Fastlane dependency lock and checksums validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
