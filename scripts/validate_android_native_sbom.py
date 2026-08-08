#!/usr/bin/env python3
"""Validate the signed Android runtime dependency inventory fail-closed."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_INVENTORY = ROOT / "scripts/android-prod-runtime-purls.txt"
BUILD_CONTRACT_FILES = (
    pathlib.Path("mobile/pubspec.yaml"),
    pathlib.Path("mobile/pubspec.lock"),
    pathlib.Path("mobile/android/app/build.gradle.kts"),
    pathlib.Path("mobile/android/build.gradle.kts"),
    pathlib.Path("mobile/android/settings.gradle.kts"),
    pathlib.Path("mobile/android/gradle/wrapper/gradle-wrapper.properties"),
    pathlib.Path("mobile/android/gradle/verification-metadata.xml"),
    pathlib.Path("scripts/cyclonedx-gradle.init.gradle.kts"),
)
CONTRACT_DIGEST = re.compile(r"contract-sha256:([0-9a-f]{64})")

REQUIRED_COMPONENTS = {
    ("net.openid", "appauth"): {
        "version": "0.11.1",
        "license": "Apache-2.0",
        "sha256": "d9ff43b14f7ee8e81bc802148190ad808beb5389953e6e6ffa53cd5575ea611e",
    },
    ("com.google.crypto.tink", "tink-android"): {
        "version": "1.21.0",
        "license": "Apache-2.0",
        "sha256": "61d60f28640b16a92f74c5c34191432f639da4fd79ce7b50a4b7af35fbafaf7d",
    },
}
REVIEWED_LOCAL_PROJECTS = {
    ("com.github.dart_lang.jni", "jni"): ":jni",
    ("com.github.dart_lang.jni_flutter", "jni_flutter"): ":jni_flutter",
    ("com.it_nomads.fluttersecurestorage", "flutter_secure_storage"): ":flutter_secure_storage",
    ("io.crossingthestreams.flutterappauth", "flutter_appauth"): ":flutter_appauth",
    ("io.flutter.plugins.sharedpreferences", "shared_preferences_android"): ":shared_preferences_android",
    ("io.flutter.plugins.urllauncher", "url_launcher_android"): ":url_launcher_android",
}
SHA256 = re.compile(r"[0-9a-f]{64}")


def build_contract_digest(root: pathlib.Path = ROOT) -> str:
    digest = hashlib.sha256()
    for relative in BUILD_CONTRACT_FILES:
        path = root / relative
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def load_reviewed_inventory(
    path: pathlib.Path = DEFAULT_INVENTORY,
    root: pathlib.Path = ROOT,
) -> set[str]:
    meaningful = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not meaningful:
        raise RuntimeError("reviewed Android runtime inventory is empty")
    contract_match = CONTRACT_DIGEST.fullmatch(meaningful[0])
    if contract_match is None:
        raise RuntimeError("reviewed Android runtime inventory has no contract digest")
    if contract_match.group(1) != build_contract_digest(root):
        raise RuntimeError(
            "Android runtime build inputs changed without a reviewed inventory update"
        )
    purls = meaningful[1:]
    if not purls or purls != sorted(purls) or len(purls) != len(set(purls)):
        raise RuntimeError(
            "reviewed Android runtime purls must be non-empty, unique, and sorted"
        )
    if any(not purl.startswith("pkg:maven/") for purl in purls):
        raise RuntimeError("reviewed Android runtime inventory contains a non-Maven purl")
    return set(purls)


def application_version(root: pathlib.Path = ROOT) -> str:
    source = (root / "mobile/pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+[1-9]\d*\s*$", source)
    if match is None:
        raise RuntimeError("mobile/pubspec.yaml has no production application version")
    return match.group(1)


def license_ids(component: dict) -> set[str]:
    values: set[str] = set()
    for choice in component.get("licenses", []):
        if not isinstance(choice, dict):
            continue
        license_value = choice.get("license")
        if isinstance(license_value, dict):
            identifier = license_value.get("id") or license_value.get("name")
            if isinstance(identifier, str) and identifier.strip():
                values.add(identifier.strip())
        expression = choice.get("expression")
        if isinstance(expression, str) and expression.strip():
            values.add(expression.strip())
    return values


def validate_sbom(
    payload: object,
    *,
    expected_purls: set[str] | None = None,
    expected_version: str | None = None,
) -> None:
    if not isinstance(payload, dict):
        raise RuntimeError("native SBOM root must be an object")
    if payload.get("bomFormat") != "CycloneDX" or payload.get("specVersion") != "1.6":
        raise RuntimeError("native SBOM must use CycloneDX 1.6")
    components = payload.get("components")
    if not isinstance(components, list) or not components:
        raise RuntimeError("native SBOM contains no components")
    if expected_purls is None:
        expected_purls = load_reviewed_inventory()
    if expected_version is None:
        expected_version = application_version()

    metadata = payload.get("metadata")
    root_component = metadata.get("component") if isinstance(metadata, dict) else None
    expected_root_purl = (
        f"pkg:maven/app.pakperk/pakperk-android@{expected_version}"
        "?project_path=%3Aapp"
    )
    if not isinstance(root_component, dict) or any(
        root_component.get(key) != value
        for key, value in {
            "type": "application",
            "group": "app.pakperk",
            "name": "pakperk-android",
            "version": expected_version,
            "purl": expected_root_purl,
            "bom-ref": expected_root_purl,
            "modified": False,
        }.items()
    ):
        raise RuntimeError("native SBOM metadata.component identity is not the exact app release")

    by_identity: dict[tuple[str, str], dict] = {}
    seen_purls: set[str] = set()
    release_engine = False
    for component in components:
        if not isinstance(component, dict):
            raise RuntimeError("native SBOM contains a malformed component")
        group = component.get("group")
        name = component.get("name")
        version = component.get("version")
        purl = component.get("purl")
        bom_ref = component.get("bom-ref")
        if not all(
            isinstance(value, str) and value.strip()
            for value in (group, name, version, purl, bom_ref)
        ):
            raise RuntimeError("every native component must have group/name/version/purl")
        if bom_ref != purl:
            raise RuntimeError(f"native component bom-ref does not equal its purl: {purl}")
        if not purl.startswith("pkg:maven/"):
            raise RuntimeError(f"native component has a non-Maven purl: {purl}")
        if purl in seen_purls:
            raise RuntimeError(f"native SBOM repeats a purl: {purl}")
        seen_purls.add(purl)
        identity = (group, name)
        if identity in by_identity:
            raise RuntimeError(f"native SBOM repeats a group/name identity: {identity}")
        by_identity[identity] = component

        parsed_purl = urllib.parse.urlsplit(purl)
        expected_path = f"maven/{group}/{name}@{version}"
        if (
            parsed_purl.scheme != "pkg"
            or parsed_purl.netloc
            or urllib.parse.unquote(parsed_purl.path) != expected_path
            or parsed_purl.fragment
        ):
            raise RuntimeError(f"native component purl does not match its identity: {purl}")
        try:
            qualifiers = urllib.parse.parse_qs(
                parsed_purl.query, keep_blank_values=True, strict_parsing=True
            )
        except ValueError as error:
            raise RuntimeError(f"native component has malformed purl qualifiers: {purl}") from error

        lowered_name = name.lower()
        if group == "io.flutter" and lowered_name == "flutter_embedding_release":
            release_engine = True
        if group == "io.flutter" and (
            lowered_name.endswith("_debug") or lowered_name.endswith("_profile")
        ):
            raise RuntimeError("native SBOM contains a non-release Flutter engine")

        project_paths = qualifiers.get("project_path", [])
        is_local_project = bool(project_paths)
        if is_local_project:
            if (
                set(qualifiers) != {"project_path"}
                or project_paths != [REVIEWED_LOCAL_PROJECTS.get(identity)]
            ):
                raise RuntimeError(
                    f"native SBOM contains an unreviewed local project identity: {purl}"
                )
        elif set(qualifiers) != {"type"} or qualifiers["type"] not in (
            ["aar"],
            ["jar"],
            ["pom"],
        ):
            raise RuntimeError(f"native component has unsupported purl qualifiers: {purl}")
        is_flutter_engine = group == "io.flutter"
        if not is_local_project and not is_flutter_engine and not license_ids(component):
            raise RuntimeError(f"external native component has no declared license: {purl}")

    if seen_purls != expected_purls:
        missing = sorted(expected_purls - seen_purls)
        unexpected = sorted(seen_purls - expected_purls)
        raise RuntimeError(
            "native SBOM differs from the reviewed production runtime inventory: "
            f"missing={missing[:3]}, unexpected={unexpected[:3]}"
        )

    dependency_values = payload.get("dependencies")
    if not isinstance(dependency_values, list):
        raise RuntimeError("native SBOM dependency graph is missing")
    declared_refs = seen_purls | {expected_root_purl}
    graph: dict[str, set[str]] = {}
    for index, dependency in enumerate(dependency_values):
        if not isinstance(dependency, dict) or set(dependency) != {"ref", "dependsOn"}:
            raise RuntimeError(f"native SBOM dependency node {index} is malformed")
        reference = dependency["ref"]
        depends_on = dependency["dependsOn"]
        if (
            not isinstance(reference, str)
            or reference in graph
            or not isinstance(depends_on, list)
            or any(not isinstance(value, str) for value in depends_on)
            or len(depends_on) != len(set(depends_on))
            or reference in depends_on
        ):
            raise RuntimeError(f"native SBOM dependency node {index} is malformed")
        graph[reference] = set(depends_on)
    if set(graph) != declared_refs:
        raise RuntimeError("native SBOM dependency node refs are not closed over components")
    dangling = {
        dependency
        for dependencies in graph.values()
        for dependency in dependencies
        if dependency not in declared_refs
    }
    if dangling:
        raise RuntimeError(f"native SBOM dependency graph has dangling refs: {sorted(dangling)[:3]}")
    reachable: set[str] = set()
    pending = list(graph[expected_root_purl])
    while pending:
        reference = pending.pop()
        if reference in reachable:
            continue
        reachable.add(reference)
        pending.extend(graph[reference])
    if reachable != seen_purls:
        raise RuntimeError("native SBOM contains components unreachable from the app release")

    if not release_engine:
        raise RuntimeError("native SBOM does not contain the release Flutter engine")

    for identity, expected in REQUIRED_COMPONENTS.items():
        component = by_identity.get(identity)
        if component is None:
            raise RuntimeError(f"native SBOM is missing required component: {identity}")
        if component["version"] != expected["version"]:
            raise RuntimeError(f"native component version changed without review: {identity}")
        if expected["license"] not in license_ids(component):
            raise RuntimeError(f"native component license changed without review: {identity}")
        hashes = {
            value.get("content")
            for value in component.get("hashes", [])
            if isinstance(value, dict) and value.get("alg") == "SHA-256"
        }
        if expected["sha256"] not in hashes or not SHA256.fullmatch(expected["sha256"]):
            raise RuntimeError(f"native component checksum changed without review: {identity}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sbom", type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        validate_sbom(json.loads(arguments.sbom.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, RuntimeError) as error:
        print(f"Android native SBOM validation failed: {error}", file=sys.stderr)
        return 1
    print("Android production runtime SBOM validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
