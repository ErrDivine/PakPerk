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
IOS_VERIFIER = ROOT / "scripts/verify_ios_release_artifact.sh"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
EXPECTED_TRIGGER_SHA256 = (
    "0fb2be1cd95989cfab15d87f6eebb2ad2edf0a53928a190e7ca8ebeb1675970f"
)
EXPECTED_STEP_ITEMS_SHA256 = (
    "b3122f9f51fdb3113f9f2c77dfe35bbe222348fb6d2d5f02e14fcc20eab21048"
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
EXPECTED_MANIFEST_STEP_SHA256 = (
    "ccb8d20246d5e2d676a075d6a7381022a5d23fe3b3bbf43b9d8d46ee13d04fd8"
)
EXPECTED_ANDROID_BUILD_STEP_SHA256 = (
    "8db56d32003950e3ce768438bbdea04c651adf47b4cfb7b9fcc6bf23e9b4f026"
)
EXPECTED_IOS_BUILD_STEP_SHA256 = (
    "5a428a670360b679c85e2e45debfbc2b47e007af974306e08f7fbac651114d9a"
)
EXPECTED_POST_UPLOAD_REVALIDATION_STEP_SHA256 = (
    "481eb832b411b879e43f1a70667064191740be85a145ee8dec18ad80b88fc71a"
)
EXPECTED_EVIDENCE_UPLOAD_STEP_SHA256 = (
    "f2563c86345137320d55fb88d78b2b897b8e2ee9f9e3d4b2dceff540fd5ba6de"
)
EXPECTED_IOS_VERIFIER_SHA256 = (
    "e5e0193a51b71f1455eeadae610d82155abaf5257ddf7fad1d927c1fcadeaee5"
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
    ios_verifier: pathlib.Path = IOS_VERIFIER,
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
            'checksum_path = root / "release-sha256.txt"',
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
            "config[key] != expected_document_version",
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

    for step_name, expected_digest in (
        (
            "Build and inspect signed Android artifacts",
            EXPECTED_ANDROID_BUILD_STEP_SHA256,
        ),
        ("Build and inspect signed iOS artifact", EXPECTED_IOS_BUILD_STEP_SHA256),
    ):
        build_step = _step_block(source, step_name, "signed mobile workflow")
        if hashlib.sha256(build_step.encode("utf-8")).hexdigest() != expected_digest:
            raise RuntimeError(f"{step_name} contract changed")

    manifest_step = _step_block(
        source,
        "Generate SBOM, notices, and immutable evidence hashes",
        "signed mobile workflow",
    )
    if (
        hashlib.sha256(manifest_step.encode("utf-8")).hexdigest()
        != EXPECTED_MANIFEST_STEP_SHA256
    ):
        raise RuntimeError("signed candidate manifest generation step changed")
    if re.findall(r"(?m)^        ([a-z][a-z0-9-]*):", manifest_step) != [
        "id",
        "shell",
        "env",
        "run",
    ]:
        raise RuntimeError(
            "signed candidate manifest step has unexpected or reordered keys"
        )
    expected_manifest_environment = (
        "        env:\n"
        "          RELEASE_SOURCE_REVISION: ${{ steps.source.outputs.source_revision }}\n"
        "          RELEASE_ENVIRONMENT: ${{ inputs.environment }}\n"
        "          RELEASE_APP_VERSION: ${{ steps.release.outputs.version_name }}\n"
        "          RELEASE_ANDROID_VERSION_NAME: ${{ steps.release.outputs.android_version_name }}\n"
        "          RELEASE_BUILD_NUMBER: ${{ steps.release.outputs.build_number }}\n"
        "          RELEASE_APPLICATION_ID: ${{ steps.release.outputs.bundle_id }}\n"
        "          RELEASE_WORKFLOW_SHA: ${{ github.workflow_sha }}\n"
        "          RELEASE_REPOSITORY: ${{ github.repository }}\n"
        "          RELEASE_JOB: ${{ github.job }}\n"
        "          RELEASE_RUN_ID: ${{ github.run_id }}\n"
        "          RELEASE_RUN_ATTEMPT: ${{ github.run_attempt }}\n"
    )
    environment_start = manifest_step.index("        env:\n")
    run_start = manifest_step.index("        run: |\n")
    if manifest_step[environment_start:run_start] != expected_manifest_environment:
        raise RuntimeError("signed candidate manifest environment bindings changed")
    _require_fragments(
        manifest_step,
        (
            'artifact(".aab")',
            'artifact(".apk")',
            'artifact(".ipa")',
            'identity_file("android-upload-identity.txt")',
            'identity_file("android-retained-digests.txt")',
            'identity_file("apple-installed-identity.txt")',
            'android_identity.get("android_upload_sha256", "")',
            'ios_identity.get("apple_signer_sha256", "")',
            '"stage": "artifacts_verified"',
            '"workflow_sha": workflow_sha',
            '"repository": repository',
            'android_artifact_digests["android_aab_artifact_sha256"] != aab_sha256',
            'ios_identity.get("apple_ipa_sha256") != ipa_sha256',
            '"aab_sha256": aab_sha256',
            '"apk_sha256": apk_sha256',
            '"ipa_sha256": ipa_sha256',
            'provenance_id = "sha256:" + hashlib.sha256(provenance_bytes).hexdigest()',
            '"provenance_id": provenance_id',
            'candidate_id = "sha256:" + hashlib.sha256(candidate_bytes).hexdigest()',
            '("mobile-release-provenance.json", provenance_bytes)',
            '("mobile-candidate.json", candidate_bytes)',
            "allow_nan=False",
            'separators=(",", ":")',
            "sort_keys=True",
            "for name, release_root in release_roots.items():",
            "if not stat.S_ISDIR(metadata.st_mode):",
            "if observed_release_digests != set(expected_release_digests):",
        ),
        "canonical signed-candidate provenance",
    )
    provenance_write = manifest_step.index(
        '("mobile-release-provenance.json", provenance_bytes)'
    )
    candidate_write = manifest_step.index('("mobile-candidate.json", candidate_bytes)')
    recursive_hashes = manifest_step.index(
        "for name, release_root in release_roots.items():"
    )
    if not provenance_write < candidate_write < recursive_hashes:
        raise RuntimeError(
            "canonical candidate manifests must be emitted before release evidence hashing"
        )

    upload_step = _step_block(
        source,
        "Retain signed candidates, symbols, SBOM, and release evidence",
        "signed mobile workflow",
    )
    if (
        hashlib.sha256(upload_step.encode("utf-8")).hexdigest()
        != EXPECTED_EVIDENCE_UPLOAD_STEP_SHA256
    ):
        raise RuntimeError("signed mobile evidence upload step changed")
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
    post_upload_revalidation = _step_block(
        source,
        "Revalidate retained release evidence after upload",
        "signed mobile workflow",
    )
    if (
        hashlib.sha256(post_upload_revalidation.encode("utf-8")).hexdigest()
        != EXPECTED_POST_UPLOAD_REVALIDATION_STEP_SHA256
    ):
        raise RuntimeError("post-upload release evidence revalidation changed")
    if (
        not evidence_upload
        < source.index("- name: Revalidate retained release evidence after upload")
        < source.index("- name: Upload Android candidate to Google Play internal track")
    ):
        raise RuntimeError(
            "retained evidence must be revalidated after upload and before store delivery"
        )

    ios_verifier_source = ios_verifier.read_text(encoding="utf-8")
    if (
        hashlib.sha256(ios_verifier_source.encode("utf-8")).hexdigest()
        != EXPECTED_IOS_VERIFIER_SHA256
    ):
        raise RuntimeError("signed iOS artifact verifier changed")
    _require_fragments(
        ios_verifier_source,
        (
            'codesign -d --extract-certificates "$certificate_prefix" "$app"',
            'leaf_certificate="${certificate_prefix}0"',
            'verified_ipa="$temporary_dir/candidate.ipa"',
            'unzip -q "$verified_ipa"',
            'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)',
            'developer_certificates = profile.get("DeveloperCertificates")',
            "if sys.argv[8] not in authorized_signer_digests:",
            '[[ "$apple_signer_sha256" =~ ^[a-f0-9]{64}$ ]]',
            "printf 'apple_signer_sha256=%s\\n' \"$apple_signer_sha256\"",
            "printf 'apple_ipa_sha256=%s\\n' \"$apple_ipa_sha256\"",
        ),
        "observed signed IPA certificate identity",
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
