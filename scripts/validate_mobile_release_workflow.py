#!/usr/bin/env python3
"""Validate the fail-closed signed-mobile release workflow contract."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

import validate_flutter_toolchain as flutter_toolchain


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mobile-release.yml"
SECURITY_WORKFLOW = ROOT / ".github/workflows/security.yml"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
EXPECTED_TRIGGER_SHA256 = (
    "0fb2be1cd95989cfab15d87f6eebb2ad2edf0a53928a190e7ca8ebeb1675970f"
)
EXPECTED_STEP_ITEMS_SHA256 = (
    "4d17e98e13297db79c4e91af4fd4bc92bfaa6def6dd03432634acb62dcd03aeb"
)
EXPECTED_CHECKOUT_STEP_SHA256 = (
    "b4a8b878bb5923badf0b69619820ec21476ed7fa3ff811b2e9e0f61b79542f86"
)
EXPECTED_ROOT_ENV_SHA256 = (
    "fb7644d3a6eb8cd652774bf4a222de6ef20641842d5d6d67667a880a41c6b2bb"
)
EXPECTED_SOURCE_STEP_SHA256 = (
    "62bdf540dd03b642475def0f869332db633cceabcae3f9fff40b1ade39f82351"
)


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


def _step_block_at_marker(source: str, marker: str, label: str) -> str:
    if source.count(marker) != 1:
        raise RuntimeError(f"{label} must contain exactly one reviewed checkout step")
    start = source.index(marker)
    end = source.find("\n      - ", start + len(marker))
    return source[start:] if end < 0 else source[start:end]


def _mapping_keys(source: str, indent: int) -> list[str]:
    prefix = " " * indent
    nested_prefix = prefix + " "
    keys: list[str] = []
    for raw_line in source.splitlines():
        if not raw_line.startswith(prefix) or raw_line.startswith(nested_prefix):
            continue
        content = raw_line[indent:]
        if not content or content.startswith("#") or ":" not in content:
            continue
        keys.append(content.partition(":")[0].strip())
    return keys


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
    if _mapping_keys(source, 0) != [
        "name",
        "on",
        "permissions",
        "concurrency",
        "env",
        "jobs",
    ]:
        raise RuntimeError("signed mobile workflow root mapping changed")
    if re.search(r"(?m)^\s*<<\s*:", source):
        raise RuntimeError("signed mobile workflow must not use YAML merge keys")
    trigger_end = source.index("\npermissions:")
    trigger = source[source.index("\non:\n") + 1 : trigger_end]
    if _mapping_keys(trigger, 2) != ["workflow_dispatch"]:
        raise RuntimeError("signed mobile release must be manual-dispatch only")
    if hashlib.sha256(trigger.encode("utf-8")).hexdigest() != EXPECTED_TRIGGER_SHA256:
        raise RuntimeError(
            "signed mobile dispatch schema or environment choices changed"
        )
    permissions_end = source.index("\nconcurrency:", trigger_end)
    if source[trigger_end + 1 : permissions_end].strip() != (
        "permissions:\n  contents: read"
    ):
        raise RuntimeError("signed mobile workflow permissions are not least privilege")
    concurrency_end = source.index("\nenv:\n", permissions_end)
    if source[permissions_end + 1 : concurrency_end].strip() != (
        "concurrency:\n"
        "  group: signed-mobile-${{ inputs.environment }}\n"
        "  cancel-in-progress: false"
    ):
        raise RuntimeError(
            "signed mobile concurrency must be scoped and non-cancelling"
        )
    env_start = concurrency_end + 1
    env_end = source.index("\njobs:\n", env_start)
    root_env = source[env_start:env_end]
    if hashlib.sha256(root_env.encode("utf-8")).hexdigest() != EXPECTED_ROOT_ENV_SHA256:
        raise RuntimeError("signed mobile inherited environment changed")

    if source.count("\njobs:\n") != 1:
        raise RuntimeError("signed mobile workflow job boundary is malformed")
    jobs = source[source.index("\njobs:\n") + len("\njobs:\n") :]
    if _mapping_keys(jobs, 2) != ["signed-candidate"]:
        raise RuntimeError(
            "signed mobile workflow must contain exactly one bounded job"
        )
    job_start = source.index("  signed-candidate:\n", env_end)
    steps_start = source.index("    steps:\n", job_start)
    expected_job_prefix = (
        "  signed-candidate:\n"
        "    name: ${{ inputs.environment }} signed candidate\n"
        "    runs-on: macos-26\n"
        "    timeout-minutes: 150\n"
        "    environment: ${{ inputs.environment }}\n"
    )
    if source[job_start:steps_start] != expected_job_prefix:
        raise RuntimeError(
            "signed mobile job execution boundary changed; job-level conditions are fail-open"
        )
    if _mapping_keys(source[job_start:], 4) != [
        "name",
        "runs-on",
        "timeout-minutes",
        "environment",
        "steps",
    ]:
        raise RuntimeError(
            "signed mobile job contains an unexpected or reordered job-level key"
        )
    step_items = re.findall(r"(?m)^      -[^\n]*$", source[steps_start:])
    if any(
        re.fullmatch(r"      - (?:name: .+|uses: [^ #]+(?: # .+)?)", item) is None
        for item in step_items
    ):
        raise RuntimeError("signed mobile workflow contains a non-canonical step item")
    step_item_contract = "\n".join(step_items) + "\n"
    if (
        hashlib.sha256(step_item_contract.encode("utf-8")).hexdigest()
        != EXPECTED_STEP_ITEMS_SHA256
    ):
        raise RuntimeError("signed mobile workflow step surface changed")
    if step_items[:2] != [
        f"      - uses: {CHECKOUT_ACTION} # v7.0.1",
        "      - name: Resolve reviewed source revision",
    ]:
        raise RuntimeError(
            "signed mobile workflow must establish source trust before executable work"
        )

    checkout = _step_block_at_marker(
        source,
        f"      - uses: {CHECKOUT_ACTION}",
        "signed mobile workflow",
    )
    if (
        hashlib.sha256(checkout.encode("utf-8")).hexdigest()
        != EXPECTED_CHECKOUT_STEP_SHA256
    ):
        raise RuntimeError("signed mobile checkout step changed")
    if re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", checkout) != ["with"]:
        raise RuntimeError("signed mobile checkout has an unexpected step key")
    expected_checkout = (
        "        with:\n"
        "          ref: ${{ inputs.source_revision }}\n"
        "          fetch-depth: 0\n"
        "          persist-credentials: false"
    )
    if checkout[checkout.index("        with:\n") :] != expected_checkout:
        raise RuntimeError("signed mobile exact-source checkout inputs changed")

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
            "ref: ${{ inputs.source_revision }}",
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

    source_step = _step_block(
        source,
        "Resolve reviewed source revision",
        "signed mobile workflow",
    )
    if (
        hashlib.sha256(source_step.encode("utf-8")).hexdigest()
        != EXPECTED_SOURCE_STEP_SHA256
    ):
        raise RuntimeError("signed mobile source trust step changed")
    _require_fragments(
        source_step,
        (
            "DISPATCH_REF: ${{ github.ref }}",
            "RELEASE_ENVIRONMENT: ${{ inputs.environment }}",
            "REQUESTED_REVISION: ${{ inputs.source_revision }}",
            'if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            'if [[ "$RELEASE_ENVIRONMENT" != "development" && "$RELEASE_ENVIRONMENT" != "staging" && "$RELEASE_ENVIRONMENT" != "production" ]]; then',
            'if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
            'if [[ "$source_revision" != "$REQUESTED_REVISION" ]]; then',
            'if ! git merge-base --is-ancestor "$source_revision" origin/main; then',
        ),
        "signed mobile source trust step",
    )
    if "continue-on-error:" in source_step:
        raise RuntimeError("signed mobile source trust step must not be recoverable")
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
            raise RuntimeError(
                f"signed mobile workflow contains a floating tool: {forbidden}"
            )

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
            "ruby_executable=%s\\n",
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
    protected_inputs_step = _step_block(
        source,
        "Materialize protected mobile feature flags",
        "signed mobile workflow",
    )
    _require_fragments(
        protected_inputs_step,
        (
            '"schema": 2',
            "RELEASE_DOCUMENT_VERSION: ${{ vars.PAKPERK_PUBLIC_DOCUMENT_VERSION }}",
            'expected_document_version = os.environ.get("RELEASE_DOCUMENT_VERSION", "")',
            'config[key] != expected_document_version',
            '"termsDocumentVersion": config["PAKPERK_TERMS_DOCUMENT_VERSION"]',
            '"communityGuidelinesDocumentVersion": config["PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION"]',
            ' / "evidence" / "mobile-feature-flags.json"',
        ),
        "signed mobile policy-version evidence",
    )
    flutter_dependencies = source.index("Resolve locked Flutter dependencies")
    bundler_install = source.index("Install and record the pinned store upload client")
    if source_gate >= protected_inputs:
        raise RuntimeError(
            "mobile source trust must be established before protected inputs"
        )
    if (
        not source_gate
        < flutter_gate
        < ruby_gate
        < flutter_dependencies
        < bundler_install
    ):
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
    _require_exact_scalar(security, "FLUTTER_VERSION", "3.44.8", "security workflow")
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
        raise RuntimeError(
            "security evidence upload must fail when artifacts are absent"
        )
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
        raise RuntimeError(
            "security workflow selects a reviewed toolchain after Gradle"
        )


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
