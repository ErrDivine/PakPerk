#!/usr/bin/env python3
"""Verify the versioned Gradle wrapper and immutable distribution contract."""

from __future__ import annotations

import hashlib
import pathlib
import stat
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "mobile/android/gradle/wrapper"
EXPECTED_JAR_SHA256 = "76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3"
EXPECTED_DISTRIBUTION_SHA256 = (
    "b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85"
)
EXPECTED_DISTRIBUTION_URL = (
    "https\\://services.gradle.org/distributions/gradle-9.1.0-all.zip"
)
EXPECTED_LAUNCHER_SHA256 = {
    "gradlew": "fb68debc1b1acf8ec55dc0d5e5495e1dedd0bd6b61f304bee61613eeb2bd9b92",
    "gradlew.bat": "fedad02c18e266ec094995a5751b7fe1eb6e74f66bf75db64fae2e50eb22c234",
}


def main() -> int:
    jar = WRAPPER / "gradle-wrapper.jar"
    properties_path = WRAPPER / "gradle-wrapper.properties"
    launchers = (ROOT / "mobile/android/gradlew", ROOT / "mobile/android/gradlew.bat")
    protected_files = (jar, properties_path, *launchers)
    if any(not path.is_file() or path.is_symlink() for path in protected_files):
        print(
            "Gradle wrapper validation failed: required file missing or symlinked",
            file=sys.stderr,
        )
        return 1
    try:
        digest = hashlib.sha256(jar.read_bytes()).hexdigest()
        lines = properties_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        print(f"Gradle wrapper validation failed: {error}", file=sys.stderr)
        return 1
    if digest != EXPECTED_JAR_SHA256:
        print("Gradle wrapper validation failed: wrapper JAR checksum drift", file=sys.stderr)
        return 1
    properties: dict[str, str] = {}
    for line in lines:
        if not line or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or key in properties:
            print("Gradle wrapper validation failed: malformed/duplicate property", file=sys.stderr)
            return 1
        properties[key] = value
    expected = {
        "distributionBase": "GRADLE_USER_HOME",
        "distributionPath": "wrapper/dists",
        "distributionSha256Sum": EXPECTED_DISTRIBUTION_SHA256,
        "distributionUrl": EXPECTED_DISTRIBUTION_URL,
        "networkTimeout": "10000",
        "validateDistributionUrl": "true",
        "zipStoreBase": "GRADLE_USER_HOME",
        "zipStorePath": "wrapper/dists",
    }
    if properties.keys() != expected.keys():
        print(
            "Gradle wrapper validation failed: unexpected property set",
            file=sys.stderr,
        )
        return 1
    for key, value in expected.items():
        if properties.get(key) != value:
            print(f"Gradle wrapper validation failed: {key} drift", file=sys.stderr)
            return 1
    for launcher in launchers:
        launcher_digest = hashlib.sha256(launcher.read_bytes()).hexdigest()
        if launcher_digest != EXPECTED_LAUNCHER_SHA256[launcher.name]:
            print(
                f"Gradle wrapper validation failed: {launcher.name} checksum drift",
                file=sys.stderr,
            )
            return 1
    if not stat.S_IMODE(launchers[0].stat().st_mode) & stat.S_IXUSR:
        print("Gradle wrapper validation failed: gradlew is not executable", file=sys.stderr)
        return 1
    print(
        "Validated Gradle 9.1.0 wrapper JAR, launchers, and distribution contract."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
