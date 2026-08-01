#!/usr/bin/env python3
"""Generate fail-closed release notices and a CycloneDX dependency SBOM."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
LICENSE_NAMES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE")
MAX_LICENSE_BYTES = 2 * 1024 * 1024
SWIFTPM_LOCKFILES = (
    pathlib.Path("mobile/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
    pathlib.Path(
        "mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    ),
)
SWIFTPM_REVIEWED_PACKAGES = {
    "appauth-ios": {
        "location": "https://github.com/openid/AppAuth-iOS",
        "version": "2.0.0",
        "revision": "145104f5ea9d58ae21b60add007c33c1cc0c948e",
        "license": "Apache-2.0",
        "license_file": pathlib.Path(
            "third_party/licenses/AppAuth-iOS-2.0.0-LICENSE.txt"
        ),
    }
}


def command_json(arguments: list[str], cwd: pathlib.Path) -> dict:
    completed = subprocess.run(
        arguments,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return json.loads(completed.stdout)


def license_files(package_root: pathlib.Path, allow_parent_search: bool = False) -> list[pathlib.Path]:
    roots = [package_root]
    if allow_parent_search:
        roots.extend(list(package_root.parents)[:5])
    for root in roots:
        if not root.is_dir():
            continue
        matches: list[pathlib.Path] = []
        for candidate in root.iterdir():
            upper = candidate.name.upper()
            if candidate.is_file() and any(
                upper == name.upper() or upper.startswith(f"{name.upper()}-")
                for name in LICENSE_NAMES
            ):
                matches.append(candidate)
        if matches:
            return sorted(matches)
    return []


def read_license(path: pathlib.Path) -> str:
    size = path.stat().st_size
    if size <= 0 or size > MAX_LICENSE_BYTES:
        raise RuntimeError(f"license file has unsafe size: {path}")
    return path.read_text(encoding="utf-8", errors="strict").strip()


def rust_components() -> list[dict]:
    metadata = command_json(
        [
            "cargo",
            "metadata",
            "--manifest-path",
            str(ROOT / "backend/Cargo.toml"),
            "--locked",
            "--format-version",
            "1",
        ],
        ROOT,
    )
    components = []
    for package in metadata["packages"]:
        package_root = pathlib.Path(package["manifest_path"]).resolve().parent
        declared = package.get("license")
        declared_file = package.get("license_file")
        files = []
        if declared_file:
            candidate = (package_root / declared_file).resolve()
            if not candidate.is_relative_to(package_root):
                raise RuntimeError(f"license file escapes package: {package['name']}")
            files = [candidate]
        else:
            files = license_files(package_root)
        if not declared and not files:
            raise RuntimeError(
                f"Rust package {package['name']} {package['version']} has no reviewable license"
            )
        components.append(
            {
                "ecosystem": "cargo",
                "name": package["name"],
                "version": package["version"],
                "purl": f"pkg:cargo/{urllib.parse.quote(package['name'])}@{package['version']}",
                "declared_license": declared or "LicenseRef-See-Text",
                "source": package.get("source") or "workspace",
                "license_texts": [(path.name, read_license(path)) for path in files],
            }
        )
    return components


def pubspec_version(path: pathlib.Path) -> str:
    if not path.is_file():
        raise RuntimeError(f"Dart package is missing pubspec.yaml: {path.parent.name}")
    match = re.search(r"(?m)^version:\s*['\"]?([^\s'\"]+)", path.read_text(encoding="utf-8"))
    if not match or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}", match.group(1)):
        raise RuntimeError(f"Dart package has no safe parseable version: {path.parent.name}")
    return match.group(1)


def safe_version(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}", value
    ):
        raise RuntimeError(f"{label} has no safe parseable version")
    return value


def application_version() -> tuple[str, str]:
    """Return the synchronized product version name and mobile build number."""

    mobile_version = pubspec_version(ROOT / "mobile/pubspec.yaml")
    mobile_match = re.fullmatch(r"(\d+\.\d+\.\d+)\+([1-9]\d*)", mobile_version)
    if mobile_match is None:
        raise RuntimeError("mobile application version must be semantic version+positive build")
    version_name, build_number = mobile_match.groups()

    cargo_text = (ROOT / "backend/Cargo.toml").read_text(encoding="utf-8")
    workspace_package = re.search(
        r"(?ms)^\[workspace\.package\]\s*(.*?)(?=^\[|\Z)", cargo_text
    )
    cargo_match = (
        re.search(r'(?m)^version\s*=\s*"([^"]+)"\s*$', workspace_package.group(1))
        if workspace_package
        else None
    )
    chart_text = (ROOT / "deploy/helm/pakperk/Chart.yaml").read_text(encoding="utf-8")
    chart_match = re.search(r'(?m)^appVersion:\s*["\']?([^\s"\']+)', chart_text)
    build_info = (ROOT / "mobile/lib/core/build_info.dart").read_text(encoding="utf-8")
    dart_version_match = re.search(
        r"(?m)^\s*static const versionName = '([^']+)';\s*$", build_info
    )
    dart_build_match = re.search(
        r"(?m)^\s*static const buildNumber = '([^']+)';\s*$", build_info
    )
    if not all((cargo_match, chart_match, dart_version_match, dart_build_match)):
        raise RuntimeError("application version sources are missing or malformed")

    named_versions = {
        "backend workspace": cargo_match.group(1),
        "Helm appVersion": chart_match.group(1),
        "mobile build info": dart_version_match.group(1),
    }
    mismatches = {
        source: value for source, value in named_versions.items() if value != version_name
    }
    if mismatches or dart_build_match.group(1) != build_number:
        details = ", ".join(f"{source}={value}" for source, value in mismatches.items())
        if dart_build_match.group(1) != build_number:
            details = ", ".join(
                value
                for value in (
                    details,
                    f"mobile build info={dart_build_match.group(1)}",
                )
                if value
            )
        raise RuntimeError(
            f"application version sources disagree with {mobile_version}: {details}"
        )

    expected_agent = f"Pakperk/{version_name}"
    environment_text = (ROOT / ".env.example").read_text(encoding="utf-8")
    environment_agent = re.search(
        r"(?m)^ARXIV_USER_AGENT=([^\s]+)\s*$", environment_text
    )
    client_text = (ROOT / "backend/crates/arxiv_client/src/client.rs").read_text(
        encoding="utf-8"
    )
    client_agent = re.search(r'user_agent:\s*"([^"]+)"\.into\(\)', client_text)
    if (
        environment_agent is None
        or client_agent is None
        or environment_agent.group(1) != expected_agent
        or client_agent.group(1) != expected_agent
    ):
        raise RuntimeError(
            f"default arXiv user agents must both equal {expected_agent}"
        )
    return version_name, build_number


def flutter_sdk_metadata(package_root: pathlib.Path) -> tuple[str, str] | None:
    """Return the SDK version/revision for a package rooted in a Flutter SDK."""

    for sdk_root in (package_root, *package_root.parents):
        metadata_path = sdk_root / "bin/cache/flutter.version.json"
        if not metadata_path.is_file():
            continue
        try:
            package_root.relative_to(sdk_root)
        except ValueError:
            continue
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        version = safe_version(
            metadata.get("flutterVersion") or metadata.get("frameworkVersion"),
            "Flutter SDK metadata",
        )
        revision = metadata.get("frameworkRevision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise RuntimeError("Flutter SDK metadata has no full lowercase framework revision")
        return version, revision
    return None


def dart_components(expected_flutter_sdk_version: str | None = None) -> list[dict]:
    config_path = ROOT / "mobile/.dart_tool/package_config.json"
    if not config_path.is_file():
        raise RuntimeError("run `flutter pub get` before generating release metadata")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    components = []
    for package in config["packages"]:
        root_uri = urllib.parse.urljoin(config_path.as_uri(), package["rootUri"])
        parsed = urllib.parse.urlparse(root_uri)
        if parsed.scheme != "file":
            raise RuntimeError(f"unsupported Dart package URI: {root_uri}")
        package_root = pathlib.Path(urllib.parse.unquote(parsed.path)).resolve()
        if package["name"] == "pakperk":
            continue
        sdk_metadata = flutter_sdk_metadata(package_root)
        files = license_files(package_root, allow_parent_search=sdk_metadata is not None)
        if not files:
            raise RuntimeError(f"Dart package {package['name']} has no reviewable license")
        if sdk_metadata is None:
            version = pubspec_version(package_root / "pubspec.yaml")
            source = "pub.dev lockfile"
        else:
            version, revision = sdk_metadata
            if expected_flutter_sdk_version is not None and version != expected_flutter_sdk_version:
                raise RuntimeError(
                    "resolved Flutter SDK version "
                    f"{version} does not match required version {expected_flutter_sdk_version}"
                )
            source = f"Flutter SDK revision {revision}"
        components.append(
            {
                "ecosystem": "pub",
                "name": package["name"],
                "version": version,
                "purl": f"pkg:pub/{urllib.parse.quote(package['name'])}@{version}",
                "declared_license": "LicenseRef-See-Text",
                "source": source,
                "license_texts": [(path.name, read_license(path)) for path in files],
            }
        )
    return components


def swiftpm_components() -> list[dict]:
    """Return reviewed native iOS dependencies from both checked-in lockfiles."""

    lock_paths = [ROOT / relative for relative in SWIFTPM_LOCKFILES]
    payloads = []
    for path in lock_paths:
        if not path.is_file():
            raise RuntimeError(f"SwiftPM lockfile is missing: {path.relative_to(ROOT)}")
        payloads.append(path.read_bytes())
    if any(payload != payloads[0] for payload in payloads[1:]):
        raise RuntimeError("the workspace and Xcode project SwiftPM lockfiles disagree")

    lock = json.loads(payloads[0])
    if lock.get("version") != 2 or not isinstance(lock.get("pins"), list):
        raise RuntimeError("SwiftPM lockfile has an unsupported schema")

    components = []
    seen_identities: set[str] = set()
    for pin in lock["pins"]:
        if not isinstance(pin, dict):
            raise RuntimeError("SwiftPM lockfile contains a malformed pin")
        identity = pin.get("identity")
        if not isinstance(identity, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", identity):
            raise RuntimeError("SwiftPM lockfile contains an unsafe package identity")
        if identity in seen_identities:
            raise RuntimeError(f"SwiftPM lockfile repeats package identity: {identity}")
        seen_identities.add(identity)

        reviewed = SWIFTPM_REVIEWED_PACKAGES.get(identity)
        if reviewed is None:
            raise RuntimeError(f"SwiftPM package {identity} has no reviewed license mapping")
        location = pin.get("location")
        state = pin.get("state")
        if pin.get("kind") != "remoteSourceControl" or location != reviewed["location"]:
            raise RuntimeError(f"SwiftPM package {identity} does not match its reviewed source")
        if not isinstance(state, dict):
            raise RuntimeError(f"SwiftPM package {identity} has no pinned state")
        version = safe_version(state.get("version"), f"SwiftPM package {identity}")
        revision = state.get("revision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise RuntimeError(f"SwiftPM package {identity} has no full pinned revision")
        if version != reviewed["version"] or revision != reviewed["revision"]:
            raise RuntimeError(
                f"SwiftPM package {identity} version/revision changed without review"
            )

        license_path = ROOT / reviewed["license_file"]
        if not license_path.is_file():
            raise RuntimeError(f"SwiftPM package {identity} is missing its reviewed license text")
        components.append(
            {
                "ecosystem": "swiftpm",
                "name": identity,
                "version": version,
                "purl": (
                    "pkg:github/openid/AppAuth-iOS@"
                    f"{version}?commit={revision}"
                ),
                "declared_license": reviewed["license"],
                "source": f"{location} revision {revision}",
                "license_texts": [(license_path.name, read_license(license_path))],
            }
        )
    if not components:
        raise RuntimeError("SwiftPM lockfile does not contain any native dependencies")
    return components


def revision() -> str:
    checked_out = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", checked_out):
        raise RuntimeError("the checked-out Git revision is not a full lowercase commit")
    configured = os.environ.get("SOURCE_REVISION", "").strip()
    if configured:
        if not re.fullmatch(r"[0-9a-f]{40}", configured):
            raise RuntimeError("SOURCE_REVISION must be a full lowercase Git commit")
        if configured != checked_out:
            raise RuntimeError("SOURCE_REVISION does not match the checked-out Git commit")
    return checked_out


def source_timestamp() -> str:
    configured = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    if not configured:
        configured = subprocess.run(
            ["git", "show", "-s", "--format=%ct", "HEAD"],
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.strip()
    if not configured.isascii() or not configured.isdigit():
        raise RuntimeError("SOURCE_DATE_EPOCH must be non-negative integer seconds")
    seconds = int(configured)
    try:
        value = dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc)
    except (OverflowError, OSError, ValueError) as error:
        raise RuntimeError("SOURCE_DATE_EPOCH is outside the supported range") from error
    return value.replace(microsecond=0).isoformat()


def write_outputs(output_dir: pathlib.Path, components: list[dict]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated = source_timestamp()
    source_revision = revision()
    application_version_name, _ = application_version()
    components.sort(key=lambda value: (value["ecosystem"], value["name"], value["version"]))

    notices = [
        "Pakperk open-source dependency notices",
        "=======================================",
        "",
        f"Source revision: {source_revision}",
        f"Generated at: {generated}",
        "",
        "This inventory is generated from backend/Cargo.lock, mobile/pubspec.lock,",
        "the resolved Flutter SDK identity, and both checked-in SwiftPM lockfiles.",
        "It is release evidence for this exact source revision.",
    ]
    for component in components:
        notices.extend(
            [
                "",
                "-" * 78,
                f"{component['ecosystem']}:{component['name']} {component['version']}",
                f"Declared license: {component['declared_license']}",
                f"Source: {component['source']}",
            ]
        )
        seen_text = set()
        for filename, license_text in component["license_texts"]:
            digest_key = hashlib.sha256(license_text.encode("utf-8")).digest()
            if digest_key in seen_text:
                continue
            seen_text.add(digest_key)
            notices.extend(["", f"[{filename}]", license_text])

    serial_seed = f"{source_revision}:" + ",".join(component["purl"] for component in components)
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, serial_seed)}",
        "version": 1,
        "metadata": {
            "timestamp": generated,
            "component": {
                "type": "application",
                "name": "pakperk",
                "version": application_version_name,
                "bom-ref": (
                    f"pkg:generic/pakperk@{application_version_name}"
                    f"?commit={source_revision}"
                ),
            },
        },
        "components": [
            {
                "type": "library",
                "name": component["name"],
                "version": component["version"],
                "purl": component["purl"],
                "bom-ref": component["purl"],
                "licenses": [{"expression": component["declared_license"]}]
                if component["declared_license"] != "LicenseRef-See-Text"
                else [{"license": {"name": "See generated dependency notices"}}],
                "properties": [
                    {"name": "pakperk:ecosystem", "value": component["ecosystem"]},
                    {"name": "pakperk:source", "value": component["source"]},
                ],
            }
            for component in components
        ],
    }
    notices_path = output_dir / "open-source-notices.txt"
    notices_path.write_text("\n".join(notices) + "\n", encoding="utf-8")
    (output_dir / "dependencies.cdx.json").write_text(
        json.dumps(sbom, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if "deployment-safe placeholder" in notices_path.read_text(encoding="utf-8").lower():
        raise RuntimeError("generated notice inventory contains placeholder text")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=ROOT / "release/metadata",
    )
    parser.add_argument(
        "--flutter-sdk-version",
        default=os.environ.get("FLUTTER_SDK_VERSION"),
        help="require the resolved Flutter SDK to have this exact version",
    )
    arguments = parser.parse_args()
    try:
        expected_flutter_sdk_version = (
            safe_version(arguments.flutter_sdk_version, "required Flutter SDK version")
            if arguments.flutter_sdk_version
            else None
        )
        write_outputs(
            arguments.output_dir.resolve(),
            rust_components()
            + dart_components(expected_flutter_sdk_version)
            + swiftpm_components(),
        )
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"release metadata generation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
