#!/usr/bin/env python3
"""Adversarial tests for the split signed-mobile workflow contract."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

import validate_mobile_release_workflow as validator


MOBILE_SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")
SECURITY_SOURCE = validator.SECURITY_WORKFLOW.read_text(encoding="utf-8")
IOS_VERIFIER_SOURCE = validator.IOS_VERIFIER.read_text(encoding="utf-8")
MATERIALIZER_SOURCE = validator.SECRET_MATERIALIZER.read_text(encoding="utf-8")


class MobileReleaseWorkflowValidationTests(unittest.TestCase):
    def _validate(
        self,
        *,
        mobile: str = MOBILE_SOURCE,
        security: str = SECURITY_SOURCE,
        ios_verifier: str = IOS_VERIFIER_SOURCE,
        materializer: str = MATERIALIZER_SOURCE,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            mobile_path = root / "mobile-release.yml"
            security_path = root / "security.yml"
            ios_path = root / "verify-ios.sh"
            materializer_path = root / "materializer.py"
            mobile_path.write_text(mobile, encoding="utf-8")
            security_path.write_text(security, encoding="utf-8")
            ios_path.write_text(ios_verifier, encoding="utf-8")
            materializer_path.write_text(materializer, encoding="utf-8")
            validator.validate(mobile_path, security_path, ios_path, materializer_path)

    def _replace_rejected(
        self, original: str, replacement: str, *, count: int = 1
    ) -> None:
        self.assertGreaterEqual(MOBILE_SOURCE.count(original), count)
        tampered = MOBILE_SOURCE.replace(original, replacement, count)
        with self.assertRaises(RuntimeError):
            self._validate(mobile=tampered)

    def _job_replace_rejected(
        self, job_id: str, original: str, replacement: str
    ) -> None:
        block = validator._job_block(MOBILE_SOURCE, job_id)
        self.assertIn(original, block)
        tampered_block = block.replace(original, replacement, 1)
        with self.assertRaises(RuntimeError):
            self._validate(mobile=MOBILE_SOURCE.replace(block, tampered_block, 1))

    def test_checked_in_contract_passes(self) -> None:
        self._validate()

    def test_exact_eight_job_surface_is_immutable(self) -> None:
        self._replace_rejected(
            "  signed-release-finalizer:\n", "  mutable-finalizer:\n"
        )

    def test_exact_production_job_display_names_are_bound(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "    name: ${{ inputs.environment }} isolated Android store upload\n",
            "    name: production store upload\n",
        )

    def test_candidate_preparation_is_outside_protected_environment(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            "    runs-on: macos-26\n",
            "    environment: ${{ inputs.environment }}\n    runs-on: macos-26\n",
        )

    def test_candidate_preparation_cannot_receive_a_secret(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            "    runs-on: macos-26\n",
            "    env:\n      LEAK: ${{ secrets.PAKPERK_ANDROID_KEYSTORE_BASE64 }}\n    runs-on: macos-26\n",
        )

    def test_prepared_config_is_retained_before_tooling_and_tests(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            "      - name: Retain immutable credential-free prepared mobile config\n",
            "      - name: Retain mutable config\n",
        )

    def test_protected_feature_flags_are_exact_and_default_off(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            "          RELEASE_READING_FEED_ENABLED: ${{ vars.PAKPERK_READING_FEED_ENABLED }}\n",
            "          RELEASE_READING_FEED_ENABLED: true\n",
        )
        self._job_replace_rejected(
            "candidate-preparation",
            'raw = os.environ.get(f"RELEASE_{short_name}_ENABLED", "") or "false"',
            'raw = os.environ.get(f"RELEASE_{short_name}_ENABLED", "") or "true"',
        )

    def test_checked_in_protected_defaults_cannot_be_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            paths = tuple(root / f"config-{index}.json" for index in range(3))
            values = {
                config_key: "false"
                for _, config_key, _ in validator.MOBILE_RELEASE_FEATURES
            }
            for path in paths:
                path.write_text(json.dumps(values), encoding="utf-8")
            values["PAKPERK_READING_FEED_ENABLED"] = "true"
            paths[1].write_text(json.dumps(values), encoding="utf-8")
            with mock.patch.object(validator, "MOBILE_CONFIGS", paths):
                with self.assertRaisesRegex(RuntimeError, "defaults must stay off"):
                    validator._validate_default_feature_configs()

    def test_feature_evidence_binds_exact_boolean_values_and_schema(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            '"readingFeed": config["PAKPERK_READING_FEED_ENABLED"] == "true",',
            '"readingFeed": config["PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED"] == "true",',
        )
        self._job_replace_rejected(
            "candidate-preparation",
            '"schema": 6,',
            '"schema": 5,',
        )

    def test_to_read_first_dependencies_are_bound_before_materialization(self) -> None:
        self._job_replace_rejected(
            "candidate-preparation",
            'protected["PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true"',
            'protected["PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] == "true"',
        )

    def test_each_plan02_flag_is_bound_from_protected_input_to_evidence(self) -> None:
        for short, config_key, evidence_key in validator.PLAN02_FEATURES:
            with self.subTest(short=short):
                self._job_replace_rejected(
                    "candidate-preparation",
                    f"          RELEASE_{short}_ENABLED: ${{{{ vars.{config_key} }}}}\n",
                    f"          RELEASE_{short}_ENABLED: true\n",
                )
                self._job_replace_rejected(
                    "candidate-preparation",
                    f'"{evidence_key}": config["{config_key}"] == "true",',
                    f'"{evidence_key}": False,',
                )

    def test_each_plan03_flag_is_bound_from_protected_input_to_evidence(self) -> None:
        for short, config_key, evidence_key in validator.PLAN03_FEATURES:
            with self.subTest(short=short):
                self._job_replace_rejected(
                    "candidate-preparation",
                    f"          RELEASE_{short}_ENABLED: ${{{{ vars.{config_key} }}}}\n",
                    f"          RELEASE_{short}_ENABLED: true\n",
                )
                self._job_replace_rejected(
                    "candidate-preparation",
                    f'"{evidence_key}": config["{config_key}"] == "true",',
                    f'"{evidence_key}": False,',
                )

    def test_each_plan03_dependency_check_is_tamper_bound(self) -> None:
        statements = (
            'protected["PAKPERK_DEEP_READER_ENABLED"] == "true" and (',
            'protected["PAKPERK_EVIDENCE_CARDS_ENABLED"] == "true" and protected["PAKPERK_ANNOTATIONS_ENABLED"] != "true"',
            'protected["PAKPERK_RESEARCH_MEMORY_ENABLED"] == "true" and protected["PAKPERK_EVIDENCE_CARDS_ENABLED"] != "true"',
        )
        for statement in statements:
            with self.subTest(statement=statement):
                self._job_replace_rejected(
                    "candidate-preparation",
                    statement,
                    statement.replace(' == "true"', ' != "true"', 1),
                )

    def test_each_plan02_dependency_check_is_tamper_bound(self) -> None:
        statements = (
            'protected["PAKPERK_LIBRARY_V2_ENABLED"] == "true" and (',
            'protected["PAKPERK_RECOMMENDATIONS_ENABLED"] == "true" and (',
            'protected["PAKPERK_SEARCH_EXPLORE_ENABLED"] == "true" and protected["PAKPERK_SEARCH_LOOKUP_ENABLED"] != "true"',
            'protected["PAKPERK_SAVED_QUERIES_ENABLED"] == "true" and (',
            'protected["PAKPERK_RESEARCH_PROFILES_ENABLED"] == "true" and protected["PAKPERK_ACCOUNTS_ENABLED"] != "true"',
            'protected["PAKPERK_READING_BRIEFS_ENABLED"] == "true" and protected["PAKPERK_READING_FEED_ENABLED"] != "true"',
            'protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] == "true" and (',
            'protected["PAKPERK_NOTIFICATIONS_ENABLED"] == "true" and protected["PAKPERK_SUBSCRIPTIONS_ENABLED"] != "true"',
        )
        for statement in statements:
            with self.subTest(statement=statement):
                self._job_replace_rejected(
                    "candidate-preparation",
                    statement,
                    statement.replace(' == "true"', ' != "true"', 1),
                )

    def test_both_signers_bind_dependency_checks_at_re_attestation_level(self) -> None:
        statement = '          if expected_config.get("PAKPERK_READING_FEED_ENABLED") == "true" and (\n'
        for job_id in ("android-signed-candidate", "ios-signed-candidate"):
            with self.subTest(job_id=job_id):
                self._job_replace_rejected(job_id, statement, "    " + statement)

    def test_both_signers_bind_config_and_feature_evidence_before_credentials(
        self,
    ) -> None:
        statement = '          actual_config = json.loads(root.joinpath("mobile-release-config.json").read_text(encoding="utf-8"))\n'
        for job_id in ("android-signed-candidate", "ios-signed-candidate"):
            with self.subTest(job_id=job_id):
                self._job_replace_rejected(job_id, statement, "    " + statement)

    def test_candidate_assembly_binds_feature_evidence_digest(self) -> None:
        self._job_replace_rejected(
            "signed-candidate",
            '--feature-evidence-sha256 "${{ needs.candidate-preparation.outputs.prepared_feature_evidence_sha256 }}"',
            '--feature-evidence-sha256 "${{ needs.candidate-preparation.outputs.prepared_config_sha256 }}"',
        )

    def test_store_request_is_production_only(self) -> None:
        self._replace_rejected(
            'if [[ "${{ inputs.upload_to_stores }}" == true && "$RELEASE_ENVIRONMENT" != production ]]; then',
            'if [[ "${{ inputs.upload_to_stores }}" == false ]]; then',
        )

    def test_both_signers_require_the_protected_environment(self) -> None:
        self._job_replace_rejected(
            "ios-signed-candidate",
            "    environment: ${{ inputs.environment }}\n",
            "",
        )

    def test_android_signer_cannot_receive_ios_or_store_credentials(self) -> None:
        self._job_replace_rejected(
            "android-signed-candidate",
            "          ANDROID_KEY_ALIAS: ${{ secrets.PAKPERK_ANDROID_KEY_ALIAS }}\n",
            "          ANDROID_KEY_ALIAS: ${{ secrets.PAKPERK_APP_STORE_CONNECT_KEY_ID }}\n",
        )

    def test_ios_signer_cannot_receive_android_or_store_credentials(self) -> None:
        self._job_replace_rejected(
            "ios-signed-candidate",
            "          IOS_TEAM_ID: ${{ secrets.PAKPERK_DEVELOPMENT_TEAM }}\n",
            "          IOS_TEAM_ID: ${{ secrets.PAKPERK_ANDROID_KEY_ALIAS }}\n",
        )

    def test_signing_secret_cannot_escape_its_materialization_step(self) -> None:
        self._job_replace_rejected(
            "android-signed-candidate",
            "      - name: Retain isolated signed Android candidate\n",
            "      - name: Leak duplicate signing secret\n"
            "        env:\n"
            "          LEAK: ${{ secrets.PAKPERK_ANDROID_KEY_ALIAS }}\n"
            "        run: /usr/bin/true\n"
            "      - name: Retain isolated signed Android candidate\n",
        )

    def test_signers_re_attest_prepared_transfer_before_credentials(self) -> None:
        self._job_replace_rejected(
            "android-signed-candidate",
            "EXPECTED_ARTIFACT_DIGEST: ${{ needs.candidate-preparation.outputs.prepared_artifact_digest }}",
            "EXPECTED_ARTIFACT_DIGEST: deadbeef",
        )

    def test_prepared_transfer_uses_artifact_id_and_digest_fail_closed(self) -> None:
        self._job_replace_rejected(
            "ios-signed-candidate",
            "          artifact-ids: ${{ needs.candidate-preparation.outputs.prepared_artifact_id }}\n",
            "          name: latest-prepared-config\n",
        )
        self._job_replace_rejected(
            "ios-signed-candidate", "          digest-mismatch: error\n", ""
        )

    def test_aggregator_is_credential_free_and_has_exact_dependencies(self) -> None:
        self._job_replace_rejected(
            "signed-candidate",
            "    needs: [candidate-preparation, android-signed-candidate, ios-signed-candidate]\n",
            "    needs: [android-signed-candidate, ios-signed-candidate]\n",
        )
        self._job_replace_rejected(
            "signed-candidate",
            "    runs-on: macos-26\n",
            "    environment: ${{ inputs.environment }}\n    runs-on: macos-26\n",
        )

    def test_aggregator_requires_three_distinct_raw_transfer_identities(self) -> None:
        self._job_replace_rejected(
            "signed-candidate",
            '[[ "$PREPARED_ARTIFACT_ID" != "$ANDROID_ARTIFACT_ID" && \\\n',
            '[[ "$PREPARED_ARTIFACT_ID" == "$ANDROID_ARTIFACT_ID" && \\\n',
        )
        self._job_replace_rejected(
            "signed-candidate",
            'for value in "$PREPARED_ARTIFACT_DIGEST" "$ANDROID_ARTIFACT_DIGEST" "$IOS_ARTIFACT_DIGEST"; do',
            'for value in "$PREPARED_ARTIFACT_DIGEST"; do',
        )

    def test_aggregator_downloads_all_inputs_by_immutable_artifact_id(self) -> None:
        self._job_replace_rejected(
            "signed-candidate",
            "          artifact-ids: ${{ needs.android-signed-candidate.outputs.artifact_id }}\n",
            "          name: android-latest\n",
        )
        block = validator._job_block(MOBILE_SOURCE, "signed-candidate")
        self.assertEqual(3, block.count("          digest-mismatch: error\n"))

    def test_assembler_and_post_retention_revalidation_are_hash_bound(self) -> None:
        digest = validator.EXPECTED_HELPER_SHA256["assemble_mobile_signed_candidate.py"]
        self._job_replace_rejected("signed-candidate", digest, "0" * 64)
        self._job_replace_rejected(
            "signed-candidate",
            'assemble_mobile_signed_candidate.py" verify',
            'assemble_mobile_signed_candidate.py" assemble',
        )

    def test_bootstrap_is_credential_free_and_upload_only(self) -> None:
        self._job_replace_rejected(
            "store-client-bootstrap",
            "    if: inputs.upload_to_stores\n",
            "    if: always()\n",
        )
        self._job_replace_rejected(
            "store-client-bootstrap",
            "    runs-on: macos-26\n",
            "    environment: ${{ inputs.environment }}\n    runs-on: macos-26\n",
        )

    def test_bootstrap_transfers_complete_hash_bound_control_closure(self) -> None:
        self._job_replace_rejected(
            "store-client-bootstrap",
            "scripts/finalize_mobile_signed_release.py",
            "scripts/unreviewed_finalizer.py",
        )
        self._job_replace_rejected(
            "store-client-bootstrap", "mobile/Gemfile.lock", "mobile/Gemfile.unlocked"
        )

    def test_each_store_upload_is_protected_and_upload_only(self) -> None:
        for job_id in ("android-store-upload", "ios-store-upload"):
            with self.subTest(job_id=job_id):
                block = validator._job_block(MOBILE_SOURCE, job_id)
                self.assertIn("    if: inputs.upload_to_stores\n", block)
                self.assertIn("    environment: ${{ inputs.environment }}\n", block)

    def test_store_upload_jobs_cannot_checkout_or_execute_workspace_code(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "    steps:\n",
            "    steps:\n      - uses: actions/checkout@evil\n",
        )
        self._job_replace_rejected(
            "ios-store-upload",
            "    steps:\n",
            "    steps:\n      - run: $GITHUB_WORKSPACE/scripts/unreviewed.py\n",
        )

    def test_android_upload_receives_only_google_credential(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "          GOOGLE_PLAY_JSON_BASE64: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}\n",
            "          APP_STORE_KEY_ID: ${{ secrets.PAKPERK_APP_STORE_CONNECT_KEY_ID }}\n",
        )

    def test_ios_upload_receives_only_app_store_credentials(self) -> None:
        self._job_replace_rejected(
            "ios-store-upload",
            "          APP_STORE_KEY_ID: ${{ secrets.PAKPERK_APP_STORE_CONNECT_KEY_ID }}\n",
            "          GOOGLE: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}\n",
        )

    def test_store_credential_cannot_escape_upload_step(self) -> None:
        self._job_replace_rejected(
            "ios-store-upload",
            "      - name: Retain isolated iOS upload evidence\n",
            "      - name: Leak duplicate store secret\n"
            "        env:\n"
            "          LEAK: ${{ secrets.PAKPERK_APP_STORE_CONNECT_KEY_ID }}\n"
            "        run: /usr/bin/true\n"
            "      - name: Retain isolated iOS upload evidence\n",
        )

    def test_uploads_re_attest_both_artifact_ids_and_raw_digests_before_secrets(
        self,
    ) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "EXPECTED_STORE_CLIENT_ARTIFACT_DIGEST: ${{ needs.store-client-bootstrap.outputs.archive_artifact_digest }}",
            "EXPECTED_STORE_CLIENT_ARTIFACT_DIGEST: deadbeef",
        )
        self._job_replace_rejected(
            "ios-store-upload",
            '[[ "$EXPECTED_CANDIDATE_ARTIFACT_ID" != "$EXPECTED_STORE_CLIENT_ARTIFACT_ID" ]] || exit 1',
            "/usr/bin/true",
        )

    def test_platform_store_clients_cannot_cross(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "manage_google_play_rollout.rb",
            "manage_app_store_phased_release.rb",
        )
        self._job_replace_rejected(
            "ios-store-upload",
            "manage_app_store_phased_release.rb",
            "manage_google_play_rollout.rb",
        )

    def test_platform_outcomes_bind_succeeded_verified_and_raw_transfers(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            '"status": "succeeded_verified"',
            '"status": "succeeded"',
        )
        self._job_replace_rejected(
            "ios-store-upload",
            "STORE_CLIENT_ARTIFACT_DIGEST: ${{ needs.store-client-bootstrap.outputs.archive_artifact_digest }}",
            "STORE_CLIENT_ARTIFACT_DIGEST: deadbeef",
        )

    def test_platform_evidence_is_retained_before_failure(self) -> None:
        self._job_replace_rejected(
            "android-store-upload",
            "      - name: Fail isolated Android upload after evidence retention\n",
            "      - name: Fail Android before evidence retention\n",
        )
        self._job_replace_rejected(
            "ios-store-upload",
            "      - name: Retain isolated iOS upload evidence\n        id: ios_evidence_upload\n        if: always()\n",
            "      - name: Retain isolated iOS upload evidence\n        id: ios_evidence_upload\n        if: success()\n",
        )

    def test_finalizer_is_always_run_credential_free_and_depends_on_both_platforms(
        self,
    ) -> None:
        self._job_replace_rejected(
            "signed-release-finalizer", "    if: always()\n", "    if: success()\n"
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            "    runs-on: macos-26\n",
            "    environment: ${{ inputs.environment }}\n    runs-on: macos-26\n",
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            "    needs: [signed-candidate, store-client-bootstrap, android-store-upload, ios-store-upload]\n",
            "    needs: [signed-candidate, android-store-upload]\n",
        )

    def test_finalizer_downloads_all_evidence_by_immutable_id(self) -> None:
        self._job_replace_rejected(
            "signed-release-finalizer",
            "          artifact-ids: ${{ needs.ios-store-upload.outputs.evidence_artifact_id }}\n",
            "          name: ios-latest\n",
        )
        block = validator._job_block(MOBILE_SOURCE, "signed-release-finalizer")
        self.assertEqual(4, block.count("          digest-mismatch: error\n"))

    def test_handoff_requires_both_successful_verified_platform_jobs(self) -> None:
        self._job_replace_rejected(
            "signed-release-finalizer",
            "needs.ios-store-upload.result == 'success'",
            "needs.ios-store-upload.result != 'cancelled'",
        )

    def test_final_outcome_receives_both_job_results_and_raw_evidence_digests(
        self,
    ) -> None:
        self._job_replace_rejected(
            "signed-release-finalizer",
            '--environment "${{ inputs.environment }}"',
            '--environment "production"',
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            '--android-application-id "${{ needs.signed-candidate.outputs.bundle_id }}"',
            '--android-application-id "app.pakperk.pakperk"',
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            '--ios-application-id "${{ needs.signed-candidate.outputs.bundle_id }}"',
            '--ios-application-id "app.pakperk.pakperk"',
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            '--ios-job-result "${{ needs.ios-store-upload.result }}"',
            '--ios-job-result "success"',
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            '--android-evidence-artifact-digest "${{ needs.android-store-upload.outputs.evidence_artifact_digest }}"',
            '--android-evidence-artifact-digest "deadbeef"',
        )

    def test_final_outcome_is_retained_before_the_final_failure_gate(self) -> None:
        self._job_replace_rejected(
            "signed-release-finalizer",
            "      - name: Retain unconditional aggregate signed-release evidence\n        id: final_outcome_upload\n        if: always()\n",
            "      - name: Retain unconditional aggregate signed-release evidence\n        id: final_outcome_upload\n        if: success()\n",
        )
        self._job_replace_rejected(
            "signed-release-finalizer",
            "RETENTION_STEP: ${{ steps.final_outcome_upload.outcome }}",
            "RETENTION_STEP: success",
        )

    def test_action_pins_and_loader_sanitization_are_immutable(self) -> None:
        self._replace_rejected(
            validator.DOWNLOAD_ACTION, "actions/download-artifact@main"
        )
        self._replace_rejected('          NODE_OPTIONS: ""\n', "", count=1)

    def test_helper_materializer_and_ios_verifier_bytes_are_pinned(self) -> None:
        digest = validator.EXPECTED_HELPER_SHA256["finalize_mobile_signed_release.py"]
        self._replace_rejected(digest, "0" * 64)
        with self.assertRaises(RuntimeError):
            self._validate(materializer=MATERIALIZER_SOURCE + "\n# tamper\n")
        with self.assertRaises(RuntimeError):
            self._validate(ios_verifier=IOS_VERIFIER_SOURCE + "\n# tamper\n")

    def test_security_toolchain_contract_is_required(self) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(
                security=SECURITY_SOURCE.replace(
                    "  FLUTTER_VERSION: 3.44.8\n", "  FLUTTER_VERSION: stable\n", 1
                )
            )


if __name__ == "__main__":
    unittest.main()
