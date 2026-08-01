#!/usr/bin/env python3
"""Validate the fail-closed signed-mobile release workflow contract."""

from __future__ import annotations

import pathlib
import re
import sys

import validate_flutter_toolchain as flutter_toolchain


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mobile-release.yml"
SECURITY_WORKFLOW = ROOT / ".github/workflows/security.yml"


def _require_fragments(source: str, fragments: tuple[str, ...], label: str) -> None:
    for fragment in fragments:
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


def _step_block(source: str, name: str, label: str) -> str:
    marker = f"      - name: {name}\n"
    if source.count(marker) != 1:
        raise RuntimeError(f"{label} must contain exactly one step named {name!r}")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def validate(
    workflow: pathlib.Path = WORKFLOW,
    security_workflow: pathlib.Path = SECURITY_WORKFLOW,
) -> None:
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
        raise RuntimeError("reviewed Flutter release identity changed without review")
    source = workflow.read_text(encoding="utf-8")
    _require_exact_scalar(source, "FLUTTER_VERSION", "3.44.8", "signed mobile workflow")
    _require_exact_scalar(
        source,
        "flutter-version",
        "${{ env.FLUTTER_VERSION }}",
        "signed mobile workflow",
    )
    _require_exact_scalar(
        source, "PAKPERK_RUBY_ENGINE", "ruby", "signed mobile workflow"
    )
    _require_exact_scalar(
        source, "PAKPERK_RUBY_VERSION", "3.4.10", "signed mobile workflow"
    )
    _require_exact_scalar(
        source,
        "PAKPERK_RUBYGEMS_VERSION",
        "4.0.17",
        "signed mobile workflow",
    )
    _require_fragments(
        source,
        (
            "source_revision:",
            "if: github.ref == 'refs/heads/main'",
            "ref: ${{ inputs.source_revision }}",
            "git merge-base --is-ancestor",
            'SOURCE_REVISION="${{ steps.source.outputs.source_revision }}"',
            "runs-on: macos-26",
            "PAKPERK_JDK_RUNTIME_VERSION: 17.0.19+10",
            "PAKPERK_JDK_VENDOR: Eclipse Adoptium",
            'reviewed_java_home="${JAVA_HOME_17_arm64:-}"',
            'XCODE_VERSION: "26.6"',
            'XCODE_BUILD: "17F113"',
            'xcode-select --switch "$xcode_developer_dir"',
            "Verify and record the exact reviewed Flutter SDK",
            'flutter --version --machine >"$RUNNER_TEMP/evidence/flutter-toolchain.json"',
            "python3 scripts/validate_flutter_toolchain.py",
            "BUNDLER_SHA256: a25675ffbd055ae1186766cc1e120b4cf62588e88abb59b99c57e22b1c55c9eb",
            '"https://rubygems.org/downloads/bundler-$BUNDLER_VERSION.gem"',
            "shasum -a 256 --check",
            'gem install --user-install --local "$bundler_gem"',
            "BUNDLE_FROZEN=true",
            "BUNDLE_LOCKFILE_CHECKSUMS=true",
            '"_${BUNDLER_VERSION}_" install',
            '"_${BUNDLER_VERSION}_" exec fastlane supply',
            "validate_fastlane_lock.py",
            "validate_gradle_verification.py",
            "android-native.cdx.json",
            "Generate SBOM, notices, and immutable evidence hashes",
            'root.joinpath("release-sha256.txt").write_text',
            "Retain signed candidates, symbols, SBOM, and release evidence",
            "pakperk-${{ inputs.environment }}-${{ steps.release.outputs.version_name }}-${{ steps.release.outputs.build_number }}-${{ steps.source.outputs.source_revision }}",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        "signed mobile workflow",
    )
    for forbidden in (
        "runs-on: macos-latest",
        "gem install --user-install fastlane",
        "gem install --user-install bundler --version",
        'SOURCE_REVISION="$GITHUB_SHA"',
        "${{ github.sha }}",
        "actions/setup-java",
        "flutter-version: stable",
        "JAVA_HOME_17_X64",
        "if-no-files-found: warn",
    ):
        if forbidden in source:
            raise RuntimeError(f"signed mobile workflow contains a floating tool: {forbidden}")

    ruby_step = _step_block(
        source,
        "Select, verify, and record the reviewed Ruby runtime",
        "signed mobile workflow",
    )
    _require_fragments(
        ruby_step,
        (
            "ruby_engine=\"$(ruby -e 'print RUBY_ENGINE')\"",
            "ruby_version=\"$(ruby -e 'print RUBY_VERSION')\"",
            'if [[ "$ruby_engine" != "$PAKPERK_RUBY_ENGINE" || \\',
            '"$ruby_version" != "$PAKPERK_RUBY_VERSION" ]]',
            'rubygems_version="$(gem --version)"',
            'if [[ "$rubygems_version" != "$PAKPERK_RUBYGEMS_VERSION" ]]',
            'ruby_executable=%s\\n',
            '"$RUNNER_TEMP/evidence/ruby-toolchain.txt"',
        ),
        "reviewed Ruby runtime step",
    )
    ruby_runtime_guard = ruby_step.index(
        'if [[ "$ruby_engine" != "$PAKPERK_RUBY_ENGINE"'
    )
    rubygems_query = ruby_step.index('rubygems_version="$(gem --version)"')
    rubygems_guard = ruby_step.index(
        'if [[ "$rubygems_version" != "$PAKPERK_RUBYGEMS_VERSION" ]]'
    )
    if not ruby_runtime_guard < rubygems_query < rubygems_guard:
        raise RuntimeError("MRI Ruby must be verified before RubyGems is invoked")

    source_gate = source.index("Resolve reviewed source revision")
    flutter_gate = source.index("Verify and record the exact reviewed Flutter SDK")
    ruby_gate = source.index("Select, verify, and record the reviewed Ruby runtime")
    protected_inputs = source.index("Materialize protected mobile feature flags")
    flutter_dependencies = source.index("Resolve locked Flutter dependencies")
    bundler_install = source.index("Install and record the pinned store upload client")
    if source_gate >= protected_inputs:
        raise RuntimeError("mobile source trust must be established before protected inputs")
    if not source_gate < flutter_gate < ruby_gate < flutter_dependencies < bundler_install:
        raise RuntimeError(
            "reviewed Flutter and Ruby must be gated after source trust and before dependencies or Bundler"
        )

    evidence_hashes = source.index(
        "- name: Generate SBOM, notices, and immutable evidence hashes"
    )
    evidence_upload = source.index(
        "- name: Retain signed candidates, symbols, SBOM, and release evidence"
    )
    for required_predecessor in (
        "Build and inspect signed Android artifacts",
        "Generate and validate the exact native Android runtime SBOM",
        "Build and inspect signed iOS artifact",
    ):
        if source.index(required_predecessor) >= evidence_hashes:
            raise RuntimeError(
                "signed artifacts and native SBOM must be verified before evidence hashing"
            )
    if evidence_hashes >= evidence_upload:
        raise RuntimeError("signed evidence must be hashed before mandatory upload")

    upload_step = _step_block(
        source,
        "Retain signed candidates, symbols, SBOM, and release evidence",
        "signed mobile workflow",
    )
    _require_fragments(
        upload_step,
        (
            "${{ runner.temp }}/artifacts",
            "${{ runner.temp }}/symbols",
            "${{ runner.temp }}/native-symbols",
            "${{ runner.temp }}/evidence",
            "${{ runner.temp }}/release-sha256.txt",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        "signed mobile evidence upload",
    )

    security = security_workflow.read_text(encoding="utf-8")
    _require_exact_scalar(
        security, "FLUTTER_VERSION", "3.44.8", "security workflow"
    )
    _require_exact_scalar(
        security,
        "flutter-version",
        "${{ env.FLUTTER_VERSION }}",
        "security workflow",
    )
    _require_fragments(
        security,
        (
            "dependency-policy-and-artifacts:\n    runs-on: ubuntu-24.04",
            "PAKPERK_JDK_RUNTIME_VERSION: 17.0.19+10",
            "PAKPERK_JDK_VENDOR: Eclipse Adoptium",
            'reviewed_java_home="${JAVA_HOME_17_X64:-}"',
            "Verify and record the exact reviewed Flutter SDK",
            "flutter --version --machine >release/metadata/flutter-toolchain.json",
            "python3 scripts/validate_flutter_toolchain.py",
            "release/metadata/android-native-toolchain.txt",
            "release-security-evidence-${{ github.sha }}",
            "path: release/metadata",
            "if-no-files-found: error",
            "retention-days: 90",
        ),
        "security workflow",
    )
    if "actions/setup-java" in security:
        raise RuntimeError("security workflow contains a floating setup-java path")
    if "JAVA_HOME_17_arm64" in security:
        raise RuntimeError("security workflow must use the Ubuntu x64 JDK contract")
    if "if-no-files-found: warn" in security:
        raise RuntimeError("security evidence upload must fail when artifacts are absent")
    security_flutter_gate = security.index(
        "Verify and record the exact reviewed Flutter SDK"
    )
    security_jdk_gate = security.index(
        "Select, verify, and record the reviewed Android JDK"
    )
    security_gradle = security.index(
        "Generate and validate the Android production runtime SBOM"
    )
    if not security_flutter_gate < security_jdk_gate < security_gradle:
        raise RuntimeError("security workflow selects a reviewed toolchain after Gradle")


def main() -> int:
    try:
        validate()
    except (OSError, RuntimeError) as error:
        print(f"signed mobile workflow validation failed: {error}", file=sys.stderr)
        return 1
    print("Signed mobile release workflow validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
