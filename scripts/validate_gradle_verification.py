#!/usr/bin/env python3
"""Validate the checked-in Gradle artifact checksum policy."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_METADATA = ROOT / "mobile/android/gradle/verification-metadata.xml"
SHA256 = re.compile(r"[0-9a-f]{64}")
REQUIRED_ARTIFACTS = {
    ("net.openid", "appauth", "0.11.1", "appauth-0.11.1.aar"): (
        "d9ff43b14f7ee8e81bc802148190ad808beb5389953e6e6ffa53cd5575ea611e"
    ),
    ("com.google.crypto.tink", "tink-android", "1.21.0", "tink-android-1.21.0.jar"): (
        "61d60f28640b16a92f74c5c34191432f639da4fd79ce7b50a4b7af35fbafaf7d"
    ),
    (
        "org.cyclonedx",
        "cyclonedx-gradle-plugin",
        "3.2.4",
        "cyclonedx-gradle-plugin-3.2.4.jar",
    ): "777dfe976f88214947cd32a5773d22779488cdd5f92977488c53f8c0a38652bb",
    ("com.android.tools.build", "gradle", "9.0.1", "gradle-9.0.1.jar"): (
        "b212aa992a9a2ff4c374ba323e8d49d113f2c55ce1dbc153d3a6f38f18ff3086"
    ),
    (
        "com.android.tools.build",
        "aapt2",
        "9.0.1-14304508",
        "aapt2-9.0.1-14304508-osx.jar",
    ): "4cf09e80b16a217a4cc1f997208599de7158dff283ecee2bd966246541b33070",
    (
        "com.android.tools.build",
        "aapt2",
        "9.0.1-14304508",
        "aapt2-9.0.1-14304508-linux.jar",
    ): "ab04484e27480404a32df818c1da12bebaceadab4895f50880153dfaad84e748",
}


def validate(path: pathlib.Path) -> None:
    root = ET.parse(path).getroot()
    namespace_match = re.fullmatch(r"\{([^}]+)\}verification-metadata", root.tag)
    if namespace_match is None:
        raise RuntimeError("Gradle verification metadata has an unsupported root")
    namespace = {"v": namespace_match.group(1)}
    configuration = root.find("v:configuration", namespace)
    if configuration is None:
        raise RuntimeError("Gradle verification configuration is missing")
    expected_configuration = [
        (f"{{{namespace['v']}}}verify-metadata", "true"),
        (f"{{{namespace['v']}}}verify-signatures", "false"),
    ]
    actual_configuration = [
        (child.tag, (child.text or "").strip()) for child in configuration
    ]
    if (
        actual_configuration != expected_configuration
        or configuration.attrib
        or any(child.attrib or list(child) for child in configuration)
    ):
        raise RuntimeError(
            "Gradle verification configuration must contain only "
            "verify-metadata=true and verify-signatures=false without trust exceptions"
        )

    components = root.findall("v:components/v:component", namespace)
    if len(components) < 100:
        raise RuntimeError("Gradle checksum inventory is unexpectedly incomplete")
    indexed: dict[tuple[str, str, str, str], str] = {}
    for component in components:
        if set(component.attrib) != {"group", "name", "version"}:
            raise RuntimeError("Gradle checksum component has unsupported attributes")
        identity = tuple(component.get(name, "") for name in ("group", "name", "version"))
        if not all(identity):
            raise RuntimeError("Gradle checksum inventory has a malformed component")
        artifacts = list(component)
        if not artifacts or any(
            artifact.tag != f"{{{namespace['v']}}}artifact" for artifact in artifacts
        ):
            raise RuntimeError(f"Gradle component has an unsupported child: {identity}")
        for artifact in artifacts:
            if set(artifact.attrib) != {"name"}:
                raise RuntimeError(
                    f"Gradle artifact has unsupported verification attributes: {identity}"
                )
            artifact_name = artifact.get("name", "")
            hashes = list(artifact)
            if (
                not artifact_name
                or len(hashes) != 1
                or hashes[0].tag != f"{{{namespace['v']}}}sha256"
            ):
                raise RuntimeError(f"Gradle artifact must have exactly one SHA-256: {identity}")
            checksum = hashes[0]
            if (
                set(checksum.attrib) != {"value", "origin"}
                or list(checksum)
                or (checksum.text or "").strip()
                or not checksum.get("origin", "").strip()
            ):
                raise RuntimeError(
                    f"Gradle SHA-256 has unsupported verification shape: {identity}"
                )
            value = checksum.get("value", "")
            if SHA256.fullmatch(value) is None:
                raise RuntimeError(f"Gradle artifact has an unsafe SHA-256: {identity}")
            key = (*identity, artifact_name)
            if key in indexed:
                raise RuntimeError(f"Gradle artifact checksum is duplicated: {key}")
            indexed[key] = value

    for identity, expected_hash in REQUIRED_ARTIFACTS.items():
        if indexed.get(identity) != expected_hash:
            raise RuntimeError(f"reviewed Gradle artifact changed or is missing: {identity}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("metadata", nargs="?", type=pathlib.Path, default=DEFAULT_METADATA)
    arguments = parser.parse_args()
    try:
        validate(arguments.metadata)
    except (OSError, ET.ParseError, RuntimeError) as error:
        print(f"Gradle dependency verification validation failed: {error}", file=sys.stderr)
        return 1
    print("Gradle dependency verification policy validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
