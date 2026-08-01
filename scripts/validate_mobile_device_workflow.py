#!/usr/bin/env python3
"""Validate the physical-device workflow's reproducible evidence contract."""

from __future__ import annotations

import pathlib
import re
import sys

import validate_flutter_toolchain as flutter_toolchain


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mobile-device-integration.yml"
EVIDENCE_FILES = (
    "flutter-toolchain.json",
    "device-evidence.json",
    "performance-evidence.json",
    "verification-scope.json",
)


def _require(source: str, fragment: str, label: str) -> None:
    if fragment not in source:
        raise RuntimeError(f"{label} is missing: {fragment}")


def _require_exact_scalar(source: str, key: str, expected: str, label: str) -> None:
    matches = re.findall(
        rf"(?m)^[ \t]+{re.escape(key)}:[ \t]*([^\r\n]*?)[ \t]*$",
        source,
    )
    if matches != [expected]:
        raise RuntimeError(
            f"{label} must define exactly one {key}: {expected}; found {matches!r}"
        )


def _step_block(source: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if source.count(marker) != 1:
        raise RuntimeError(f"device workflow must contain exactly one step named {name!r}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def validate(workflow: pathlib.Path = WORKFLOW) -> None:
    flutter_contract = (
        flutter_toolchain.EXPECTED_FLUTTER_VERSION,
        flutter_toolchain.EXPECTED_FRAMEWORK_REVISION,
        flutter_toolchain.EXPECTED_DART_SDK_VERSION,
    )
    if flutter_contract != (
        "3.44.8",
        "058e0af2c2b57e369d905a03ac9748b0ebf543c6",
        "3.12.2",
    ):
        raise RuntimeError("reviewed Flutter device-lane identity changed without review")

    source = workflow.read_text(encoding="utf-8")
    trigger_end = source.index("\npermissions:")
    trigger = source[:trigger_end]
    if "workflow_dispatch:" not in trigger or re.search(
        r"(?m)^  (?:pull_request|push|schedule|workflow_run):", trigger
    ):
        raise RuntimeError("mobile device evidence must be manual-dispatch only")

    permissions_end = source.index("\nconcurrency:", trigger_end)
    permissions = source[trigger_end + 1 : permissions_end].strip()
    if permissions != "permissions:\n  contents: read":
        raise RuntimeError("mobile device workflow permissions are not least privilege")

    _require_exact_scalar(source, "FLUTTER_VERSION", "3.44.8", "device workflow")
    _require_exact_scalar(
        source,
        "flutter-version",
        "${{ env.FLUTTER_VERSION }}",
        "device workflow",
    )
    for fragment in (
        "runs-on: [self-hosted, pakperk-mobile-device]",
        "environment: mobile-device-verification",
        "persist-credentials: false",
        "Verify and record the exact reviewed Flutter SDK",
        'flutter --version --machine >"$RUNNER_TEMP/flutter-toolchain.json"',
        "python3 scripts/validate_flutter_toolchain.py",
        "flutter pub get --enforce-lockfile",
        "flutter test integration_test/production_verification_test.dart",
        "--profile -d \"$PAKPERK_MOBILE_DEVICE_ID\"",
        '"flutter_toolchain": os.environ.get(',
        '"PAKPERK_FLUTTER_TOOLCHAIN_OUTCOME", "unknown"',
        '"does_not_attest_external_paths": True',
        "This workflow does not attest live OIDC, two-device, staging, signed-store,",
    ):
        _require(source, fragment, "device workflow")

    for external_path in (
        "native process cold-start p95 and launch-screen continuity",
        "system-browser OIDC/PKCE login and real expired-token refresh",
        "backend-connected save/relaunch and two independently installed devices",
        "live comment post/edit/delete plus report/block enforcement",
        "recent-auth account deletion, provider cleanup, and restore replay",
        "signed-candidate deep links, store distribution, crash window, and staging p95 targets",
    ):
        _require(source, external_path, "truthful device verification boundary")

    toolchain_step = _step_block(
        source, "Verify and record the exact reviewed Flutter SDK"
    )
    for fragment in (
        "id: flutter-toolchain",
        'flutter --version --machine >"$RUNNER_TEMP/flutter-toolchain.json"',
        "python3 scripts/validate_flutter_toolchain.py \\",
        '"$RUNNER_TEMP/flutter-toolchain.json"',
    ):
        _require(toolchain_step, fragment, "Flutter identity step")

    setup_position = source.index("uses: subosito/flutter-action@")
    toolchain_position = source.index(
        "- name: Verify and record the exact reviewed Flutter SDK"
    )
    dependencies_position = source.index("- name: Resolve locked Flutter dependencies")
    device_test_position = source.index(
        "- name: Run deterministic production contract in profile mode"
    )
    if not setup_position < toolchain_position < dependencies_position < device_test_position:
        raise RuntimeError(
            "the exact Flutter identity must be verified after setup and before dependencies or tests"
        )

    boundary_step = _step_block(source, "Record the exact verification boundary")
    for fragment in (
        "if: always()",
        "PAKPERK_FLUTTER_TOOLCHAIN_OUTCOME: ${{ steps.flutter-toolchain.outcome }}",
        '"flutter_toolchain": os.environ.get(',
        '"PAKPERK_FLUTTER_TOOLCHAIN_OUTCOME", "unknown"',
        'if all(value == "success" for value in component_outcomes.values())',
        '"does_not_attest_external_paths": True',
    ):
        _require(boundary_step, fragment, "device verification boundary")

    required_step = _step_block(source, "Require the complete scoped evidence bundle")
    required_files = tuple(
        re.findall(r'(?m)^            "\$RUNNER_TEMP/([^"/]+)"$', required_step)
    )
    if required_files != EVIDENCE_FILES:
        raise RuntimeError(
            "complete-evidence gate must require exactly "
            f"{EVIDENCE_FILES!r}; found {required_files!r}"
        )
    for fragment in (
        "if: always()",
        'if [[ ! -s "$evidence_path" ]]',
        "missing=1",
        'exit "$missing"',
    ):
        _require(required_step, fragment, "complete-evidence gate")

    upload_step = _step_block(
        source, "Retain scoped device and frame-timing evidence"
    )
    uploaded_files = tuple(
        re.findall(
            r"(?m)^            \$\{\{ runner\.temp \}\}/([^/\r\n]+)$",
            upload_step,
        )
    )
    if uploaded_files != EVIDENCE_FILES:
        raise RuntimeError(
            "device artifact must retain exactly "
            f"{EVIDENCE_FILES!r}; found {uploaded_files!r}"
        )
    for fragment in (
        "if: always()",
        "if-no-files-found: error",
        "retention-days: 30",
    ):
        _require(upload_step, fragment, "device evidence upload")
    if "if-no-files-found: warn" in source:
        raise RuntimeError("device evidence upload must fail closed when files are absent")

    required_position = source.index(
        "- name: Require the complete scoped evidence bundle"
    )
    upload_position = source.index(
        "- name: Retain scoped device and frame-timing evidence"
    )
    evidence_validation_position = source.index(
        "- name: Validate and extract deterministic performance evidence"
    )
    boundary_position = source.index("- name: Record the exact verification boundary")
    if not (
        device_test_position
        < evidence_validation_position
        < boundary_position
        < required_position
        < upload_position
    ):
        raise RuntimeError(
            "performance and scope evidence must be recorded, enforced, then uploaded"
        )


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"mobile device workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Mobile device evidence workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
