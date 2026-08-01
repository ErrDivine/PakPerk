#!/usr/bin/env python3
"""Regression tests for the signed-mobile workflow contract validator."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import tempfile
import textwrap
import unittest
from unittest import mock

import validate_mobile_release_workflow as validator


MOBILE_SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")
SECURITY_SOURCE = validator.SECURITY_WORKFLOW.read_text(encoding="utf-8")
IOS_VERIFIER_SOURCE = validator.IOS_VERIFIER.read_text(encoding="utf-8")


def _embedded_manifest_python() -> str:
    step = validator._step_block(
        MOBILE_SOURCE,
        "Generate SBOM, notices, and immutable evidence hashes",
        "test workflow",
    )
    marker = "          python3 - <<'PY'\n"
    start = step.index(marker) + len(marker)
    end = step.index("\n          PY", start)
    return textwrap.dedent(step[start:end]) + "\n"


def _move_step_after(source: str, moving_name: str, anchor_name: str) -> str:
    moving_marker = f"      - name: {moving_name}\n"
    moving_start = source.index(moving_marker)
    moving_end = source.find("\n      - ", moving_start + len(moving_marker))
    if moving_end < 0:
        raise AssertionError(f"moving step has no following step: {moving_name}")
    moving_block = source[moving_start:moving_end]
    without_moving = source[:moving_start] + source[moving_end + 1 :]

    anchor_marker = f"      - name: {anchor_name}\n"
    anchor_start = without_moving.index(anchor_marker)
    anchor_end = without_moving.find("\n      - ", anchor_start + len(anchor_marker))
    if anchor_end < 0:
        raise AssertionError(f"anchor step has no following step: {anchor_name}")
    return (
        without_moving[:anchor_end] + "\n" + moving_block + without_moving[anchor_end:]
    )


class MobileReleaseWorkflowValidationTests(unittest.TestCase):
    def _validate(
        self,
        mobile: str = MOBILE_SOURCE,
        security: str = SECURITY_SOURCE,
        ios_verifier: str = IOS_VERIFIER_SOURCE,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            mobile_path = root / "mobile-release.yml"
            security_path = root / "security.yml"
            ios_verifier_path = root / "verify_ios_release_artifact.sh"
            mobile_path.write_text(mobile, encoding="utf-8")
            security_path.write_text(security, encoding="utf-8")
            ios_verifier_path.write_text(ios_verifier, encoding="utf-8")
            validator.validate(mobile_path, security_path, ios_verifier_path)

    def _assert_mobile_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, MOBILE_SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate(mobile=MOBILE_SOURCE.replace(original, replacement, 1))

    def _assert_security_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SECURITY_SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate(security=SECURITY_SOURCE.replace(original, replacement, 1))

    def _assert_ios_verifier_tamper_rejected(
        self, original: str, replacement: str
    ) -> None:
        self.assertIn(original, IOS_VERIFIER_SOURCE)
        with self.assertRaises(RuntimeError):
            self._validate(
                ios_verifier=IOS_VERIFIER_SOURCE.replace(original, replacement, 1)
            )

    def test_checked_in_contract_passes(self) -> None:
        self._validate()

    def test_embedded_generator_emits_content_addressed_actual_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            artifacts = root / "artifacts"
            evidence = root / "evidence"
            artifacts.mkdir()
            evidence.mkdir()
            root.joinpath("symbols").mkdir()
            root.joinpath("native-symbols").mkdir()
            artifact_bytes = {
                "candidate.aab": b"signed aab fixture",
                "candidate.apk": b"signed apk fixture",
                "candidate.ipa": b"signed ipa fixture",
            }
            for name, data in artifact_bytes.items():
                artifacts.joinpath(name).write_bytes(data)
            evidence.joinpath("android-upload-identity.txt").write_text(
                "android_package=app.pakperk.pakperk.staging\n"
                "android_version_name=0.2.0-staging\n"
                "android_version_code=2\n"
                f"android_upload_sha256={':'.join(['AA'] * 32)}\n",
                encoding="utf-8",
            )
            evidence.joinpath("android-retained-digests.txt").write_text(
                "android_aab_artifact_sha256="
                + hashlib.sha256(artifact_bytes["candidate.aab"]).hexdigest()
                + "\nandroid_apk_artifact_sha256="
                + hashlib.sha256(artifact_bytes["candidate.apk"]).hexdigest()
                + "\n",
                encoding="utf-8",
            )
            evidence.joinpath("apple-installed-identity.txt").write_text(
                "apple_bundle_id=app.pakperk.pakperk.staging\n"
                "apple_version=0.2.0\n"
                "apple_build=2\n"
                "apple_team_id=PAKPERK001\n"
                f"apple_signer_sha256={'b' * 64}\n"
                "apple_ipa_sha256="
                + hashlib.sha256(artifact_bytes["candidate.ipa"]).hexdigest()
                + "\n",
                encoding="utf-8",
            )
            config = root / "mobile-release-config.json"
            config.write_text(
                json.dumps(
                    {
                        "PAKPERK_ENV": "staging",
                        "PAKPERK_FULLTEXT_POLICY": "strict",
                    }
                ),
                encoding="utf-8",
            )
            output = root / "github-output.txt"
            summary = root / "github-summary.md"
            environment = {
                "RUNNER_TEMP": str(root),
                "PAKPERK_MOBILE_RELEASE_CONFIG": str(config),
                "RELEASE_SOURCE_REVISION": "a" * 40,
                "RELEASE_ENVIRONMENT": "staging",
                "RELEASE_APP_VERSION": "0.2.0",
                "RELEASE_ANDROID_VERSION_NAME": "0.2.0-staging",
                "RELEASE_BUILD_NUMBER": "2",
                "RELEASE_APPLICATION_ID": "app.pakperk.pakperk.staging",
                "RELEASE_WORKFLOW_SHA": "a" * 40,
                "RELEASE_REPOSITORY": "ErrDivine/PakPerk",
                "RELEASE_JOB": "signed-candidate",
                "RELEASE_RUN_ID": "123456789",
                "RELEASE_RUN_ATTEMPT": "2",
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(summary),
            }
            with mock.patch.dict(os.environ, environment, clear=False):
                exec(
                    compile(
                        _embedded_manifest_python(),
                        "mobile-release-manifest-generator",
                        "exec",
                    ),
                    {"__name__": "__main__"},
                )

            provenance_bytes = evidence.joinpath(
                "mobile-release-provenance.json"
            ).read_bytes()
            candidate_bytes = evidence.joinpath("mobile-candidate.json").read_bytes()
            provenance = json.loads(provenance_bytes)
            candidate = json.loads(candidate_bytes)
            self.assertEqual(
                provenance_bytes,
                (
                    json.dumps(provenance, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode("ascii"),
            )
            self.assertEqual(
                candidate_bytes,
                (
                    json.dumps(candidate, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode("ascii"),
            )
            self.assertEqual(
                provenance["android"]["aab_sha256"],
                hashlib.sha256(artifact_bytes["candidate.aab"]).hexdigest(),
            )
            self.assertEqual(
                provenance["android"]["apk_sha256"],
                hashlib.sha256(artifact_bytes["candidate.apk"]).hexdigest(),
            )
            self.assertEqual(
                provenance["ios"]["ipa_sha256"],
                hashlib.sha256(artifact_bytes["candidate.ipa"]).hexdigest(),
            )
            self.assertEqual(provenance["android"]["signer_sha256"], "a" * 64)
            self.assertEqual(provenance["ios"]["signer_sha256"], "b" * 64)
            self.assertEqual(provenance["workflow"]["stage"], "artifacts_verified")
            self.assertEqual(candidate["android"], provenance["android"])
            self.assertEqual(candidate["ios"], provenance["ios"])
            provenance_id = "sha256:" + hashlib.sha256(provenance_bytes).hexdigest()
            candidate_id = "sha256:" + hashlib.sha256(candidate_bytes).hexdigest()
            self.assertEqual(candidate["provenance_id"], provenance_id)
            output_lines = output.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                output_lines,
                [f"provenance_id={provenance_id}", f"candidate_id={candidate_id}"],
            )
            checksums = root.joinpath("release-sha256.txt").read_text(encoding="utf-8")
            for path in (
                "artifacts/candidate.aab",
                "artifacts/candidate.apk",
                "artifacts/candidate.ipa",
                "evidence/mobile-release-provenance.json",
                "evidence/mobile-candidate.json",
            ):
                self.assertIn(f"  {path}\n", checksums)

            artifacts.joinpath("candidate.ipa").write_bytes(
                b"post-verification replacement"
            )
            with mock.patch.dict(os.environ, environment, clear=False):
                with self.assertRaisesRegex(
                    SystemExit, "retained signed artifact changed after verification"
                ):
                    exec(
                        compile(
                            _embedded_manifest_python(),
                            "mobile-release-manifest-generator",
                            "exec",
                        ),
                        {"__name__": "__main__"},
                    )

    def test_automatic_trigger_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n"
        )

    def test_quoted_automatic_trigger_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  workflow_dispatch:\n",
            '  workflow_dispatch:\n  "push": {}\n',
        )

    def test_dispatch_environment_cannot_be_widened(self) -> None:
        self._assert_mobile_tamper_rejected(
            "        type: choice\n"
            "        options: [development, staging, production]",
            "        type: string",
        )

    def test_inherited_bash_environment_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8\n",
            "  BASH_ENV: ${{ github.workspace }}/pretrust.sh\n"
            "  FLUTTER_VERSION: 3.44.8\n",
        )

    def test_inflight_candidate_cannot_be_cancelled(self) -> None:
        self._assert_mobile_tamper_rejected(
            "cancel-in-progress: false", "cancel-in-progress: true"
        )

    def test_quoted_checkout_key_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "        with:\n",
            '        "uses": attacker/execute@deadbeef\n        with:\n',
        )

    def test_permission_expansion_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "permissions:\n  contents: read",
            "permissions:\n  contents: read\n  actions: write",
        )

    def test_job_level_main_guard_is_rejected_as_fail_open(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  signed-candidate:\n    name:",
            "  signed-candidate:\n"
            "    if: github.ref == 'refs/heads/main'\n"
            "    name:",
        )

    def test_job_level_continue_on_error_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  signed-candidate:\n    name:",
            "  signed-candidate:\n    continue-on-error: true\n    name:",
        )

    def test_trailing_job_level_if_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "job-level key"):
            self._validate(mobile=MOBILE_SOURCE + "    if: false\n")

    def test_quoted_sibling_job_is_rejected(self) -> None:
        source = MOBILE_SOURCE + (
            '  "bypass":\n'
            "    runs-on: macos-26\n"
            "    steps:\n"
            '      - run: "true"\n'
        )
        with self.assertRaisesRegex(RuntimeError, "exactly one bounded job"):
            self._validate(mobile=source)

    def test_executable_step_before_source_trust_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "          persist-credentials: false\n"
            "      - name: Resolve reviewed source revision",
            "          persist-credentials: false\n"
            "      - run: echo bypass\n"
            "      - name: Resolve reviewed source revision",
        )

    def test_bare_sequence_step_before_source_trust_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "    steps:\n",
            "    steps:\n      -\n        run: echo bypass\n",
        )

    def test_dispatch_ref_must_be_bound_to_github_context(self) -> None:
        self._assert_mobile_tamper_rejected(
            "          DISPATCH_REF: ${{ github.ref }}\n",
            "          DISPATCH_REF: refs/heads/main\n",
        )

    def test_release_environment_must_be_bound_to_dispatch_input(self) -> None:
        self._assert_mobile_tamper_rejected(
            "          RELEASE_ENVIRONMENT: ${{ inputs.environment }}\n",
            "          RELEASE_ENVIRONMENT: staging\n",
        )

    def test_runtime_environment_allowlist_cannot_be_weakened(self) -> None:
        self._assert_mobile_tamper_rejected(
            'if [[ "$RELEASE_ENVIRONMENT" != "development" && "$RELEASE_ENVIRONMENT" != "staging" && "$RELEASE_ENVIRONMENT" != "production" ]]; then',
            'if [[ -z "$RELEASE_ENVIRONMENT" ]]; then',
        )

    def test_non_main_guard_cannot_be_short_circuited(self) -> None:
        self._assert_mobile_tamper_rejected(
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            '          true || if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
        )

    def test_non_main_guard_cannot_be_commented_out(self) -> None:
        self._assert_mobile_tamper_rejected(
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            '          # if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
        )

    def test_mobile_flutter_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8", "  FLUTTER_VERSION: 3.44.9"
        )

    def test_policy_version_evidence_cannot_be_removed(self) -> None:
        self._assert_mobile_tamper_rejected(
            '                      "termsDocumentVersion": config["PAKPERK_TERMS_DOCUMENT_VERSION"],\n',
            "",
        )

    def test_protected_public_policy_binding_cannot_be_removed(self) -> None:
        self._assert_mobile_tamper_rejected(
            "          RELEASE_DOCUMENT_VERSION: ${{ vars.PAKPERK_PUBLIC_DOCUMENT_VERSION }}\n",
            "",
        )

    def test_mobile_flutter_action_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "flutter-version: ${{ env.FLUTTER_VERSION }}",
            "flutter-version: stable",
        )

    def test_mobile_flutter_identity_gate_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
        )

    def test_security_flutter_version_tamper_is_rejected(self) -> None:
        self._assert_security_tamper_rejected(
            "  FLUTTER_VERSION: 3.44.8", "  FLUTTER_VERSION: 3.44.9"
        )

    def test_security_flutter_identity_gate_tamper_is_rejected(self) -> None:
        self._assert_security_tamper_rejected(
            "python3 scripts/validate_flutter_toolchain.py",
            "python3 scripts/record_flutter_toolchain.py",
        )

    def test_ruby_engine_probe_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "ruby -e 'print RUBY_ENGINE'", "ruby -e 'print RUBY_PLATFORM'"
        )

    def test_ruby_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_RUBY_VERSION: 3.4.10",
            "  PAKPERK_RUBY_VERSION: 3.4.11",
        )

    def test_rubygems_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_RUBYGEMS_VERSION: 4.0.17",
            "  PAKPERK_RUBYGEMS_VERSION: 4.0.16",
        )

    def test_ruby_gate_after_dependency_resolution_is_rejected(self) -> None:
        tampered = _move_step_after(
            MOBILE_SOURCE,
            "Select, verify, and record the reviewed Ruby runtime",
            "Resolve locked Flutter dependencies",
        )
        with self.assertRaises(RuntimeError):
            self._validate(mobile=tampered)

    def test_jdk_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "  PAKPERK_JDK_RUNTIME_VERSION: 17.0.19+10",
            "  PAKPERK_JDK_RUNTIME_VERSION: 17.0.20+8",
        )

    def test_mobile_x64_jdk_contract_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected("JAVA_HOME_17_arm64", "JAVA_HOME_17_X64")

    def test_security_arm64_jdk_contract_is_rejected(self) -> None:
        self._assert_security_tamper_rejected("JAVA_HOME_17_X64", "JAVA_HOME_17_arm64")

    def test_xcode_version_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            '  XCODE_VERSION: "26.6"', '  XCODE_VERSION: "26.7"'
        )

    def test_source_ancestry_gate_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "git merge-base --is-ancestor", "git merge-base --is-descendant"
        )

    def test_mobile_missing_evidence_is_not_a_warning(self) -> None:
        self._assert_mobile_tamper_rejected(
            "if-no-files-found: error", "if-no-files-found: warn"
        )

    def test_mobile_evidence_upload_cannot_continue_on_error(self) -> None:
        self._assert_mobile_tamper_rejected(
            "      - name: Retain signed candidates, symbols, SBOM, and release evidence\n"
            "        uses:",
            "      - name: Retain signed candidates, symbols, SBOM, and release evidence\n"
            "        continue-on-error: true\n"
            "        uses:",
        )

    def test_mobile_evidence_hash_removal_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            'checksum_path = root / "release-sha256.txt"',
            'checksum_path = root / "release-files.txt"',
        )

    def test_candidate_artifact_hash_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            '"aab_sha256": aab_sha256',
            '"aab_sha256": "0" * 64',
        )

    def test_android_identity_must_be_observed_from_retained_artifacts(self) -> None:
        self._assert_mobile_tamper_rejected(
            '            "$retained_aab" "$retained_apk" "${{ steps.release.outputs.bundle_id }}"',
            '            "$aab" "$apk" "${{ steps.release.outputs.bundle_id }}"',
        )

    def test_ios_identity_must_be_observed_from_retained_artifact(self) -> None:
        self._assert_mobile_tamper_rejected(
            '            "$retained_ipa" "${{ steps.release.outputs.bundle_id }}"',
            '            "$ipa" "${{ steps.release.outputs.bundle_id }}"',
        )

    def test_retained_evidence_must_be_revalidated_after_upload(self) -> None:
        self._assert_mobile_tamper_rejected(
            "        run: /usr/bin/shasum -a 256 --check release-sha256.txt",
            "        run: /usr/bin/true",
        )

    def test_candidate_workflow_run_binding_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            "          RELEASE_RUN_ATTEMPT: ${{ github.run_attempt }}\n",
            "          RELEASE_RUN_ATTEMPT: 1\n",
        )

    def test_candidate_canonical_json_contract_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected("                      sort_keys=True,", "")

    def test_candidate_provenance_binding_tamper_is_rejected(self) -> None:
        self._assert_mobile_tamper_rejected(
            '              "provenance_id": provenance_id,',
            '              "provenance_id": "sha256:" + "0" * 64,',
        )

    def test_candidate_stage_cannot_claim_whole_job_success(self) -> None:
        self._assert_mobile_tamper_rejected(
            '                  "stage": "artifacts_verified",',
            '                  "conclusion": "success",',
        )

    def test_ios_leaf_certificate_extraction_tamper_is_rejected(self) -> None:
        self._assert_ios_verifier_tamper_rejected(
            'codesign -d --extract-certificates "$certificate_prefix" "$app"',
            "true # signer certificate not observed",
        )

    def test_ios_signer_fingerprint_evidence_tamper_is_rejected(self) -> None:
        self._assert_ios_verifier_tamper_rejected(
            "printf 'apple_signer_sha256=%s\\n' \"$apple_signer_sha256\"",
            "printf 'apple_signer_sha256=%s\\n' \"$IOS_SIGNER_SHA256\"",
        )

    def test_ios_profile_certificate_authorization_tamper_is_rejected(self) -> None:
        self._assert_ios_verifier_tamper_rejected(
            'developer_certificates = profile.get("DeveloperCertificates")',
            'developer_certificates = [b"unbound"]',
        )

    def test_mobile_evidence_cannot_be_hashed_before_ios_verification(self) -> None:
        tampered = _move_step_after(
            MOBILE_SOURCE,
            "Generate SBOM, notices, and immutable evidence hashes",
            "Build and inspect signed Android artifacts",
        )
        with self.assertRaisesRegex(RuntimeError, "step surface changed"):
            self._validate(mobile=tampered)

    def test_security_missing_evidence_is_not_a_warning(self) -> None:
        self._assert_security_tamper_rejected(
            "if-no-files-found: error", "if-no-files-found: warn"
        )


if __name__ == "__main__":
    unittest.main()
