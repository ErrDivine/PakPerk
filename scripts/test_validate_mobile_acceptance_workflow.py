#!/usr/bin/env python3
"""Tamper regressions for the protected mobile acceptance workflow."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_mobile_acceptance_workflow as validator


SOURCE = validator.WORKFLOW.read_text(encoding="utf-8")


class MobileAcceptanceWorkflowTests(unittest.TestCase):
    def validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workflow = pathlib.Path(directory) / "mobile-protected-acceptance.yml"
            workflow.write_text(source, encoding="utf-8")
            validator.validate(workflow)

    def assert_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SOURCE)
        with self.assertRaises(RuntimeError):
            self.validate_source(SOURCE.replace(original, replacement, 1))

    def assert_execution_boundary_rejected(
        self, source: str, message: str
    ) -> None:
        with self.assertRaisesRegex(RuntimeError, message):
            validator._validate_candidate_execution_boundary(source)

    def test_checked_in_workflow_passes(self) -> None:
        validator.validate()

    def test_push_trigger_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "  workflow_dispatch:\n",
            "  workflow_dispatch:\n  push:\n",
        )

    def test_pull_request_target_trigger_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "  workflow_dispatch:\n",
            "  workflow_dispatch:\n  pull_request_target:\n",
        )

    def test_workflow_call_trigger_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "  workflow_dispatch:\n",
            "  workflow_dispatch:\n  workflow_call:\n",
        )

    def test_optional_candidate_input_is_rejected(self) -> None:
        original = (
            "      candidate_id:\n"
            "        description: Installed signed-candidate manifest content ID in exact sha256 lowercase digest form\n"
            "        required: true\n"
        )
        replacement = original.replace("required: true", "required: false")
        self.assert_tamper_rejected(original, replacement)

    def test_optional_provenance_input_is_rejected(self) -> None:
        original = (
            "      provenance_id:\n"
            "        description: Signed-release provenance manifest content ID in exact sha256 lowercase digest form\n"
            "        required: true\n"
        )
        replacement = original.replace("required: true", "required: false")
        self.assert_tamper_rejected(original, replacement)

    def test_extra_dispatch_input_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "      confirmation:\n",
            "      unreviewed_host:\n"
            "        description: Unreviewed host\n"
            "        required: true\n"
            "        type: string\n"
            "      confirmation:\n",
        )

    def test_top_level_permissions_tamper_is_rejected(self) -> None:
        self.assert_tamper_rejected("  contents: read\n", "  contents: write\n")

    def test_job_level_permissions_override_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "    runs-on: [self-hosted, macOS, pakperk-mobile-acceptance]\n",
            "    runs-on: [self-hosted, macOS, pakperk-mobile-acceptance]\n"
            "    permissions:\n"
            "      contents: write\n",
        )

    def test_yaml_merge_key_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "  protected-acceptance:\n",
            "  protected-acceptance:\n    <<: *unreviewed\n",
        )

    def test_extra_job_is_rejected(self) -> None:
        tampered = SOURCE + (
            "\n  unreviewed-job:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: echo bypass\n"
        )
        with self.assertRaises(RuntimeError):
            self.validate_source(tampered)

    def test_extra_step_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "      - name: Enforce protected mobile acceptance result\n",
            "      - name: Unreviewed executable step\n"
            "        shell: bash\n"
            "        run: echo bypass\n\n"
            "      - name: Enforce protected mobile acceptance result\n",
        )

    def test_extra_unpinned_action_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "      - name: Verify exact reviewed main source and protected coordinates\n",
            "      - uses: unreviewed/action@main\n\n"
            "      - name: Verify exact reviewed main source and protected coordinates\n",
        )

    def test_mutable_checkout_is_rejected(self) -> None:
        self.assert_tamper_rejected(validator.CHECKOUT_ACTION, "actions/checkout@v7")

    def test_non_macos_runner_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "runs-on: [self-hosted, macOS, pakperk-mobile-acceptance]",
            "runs-on: [self-hosted, pakperk-mobile-acceptance]",
        )

    def test_protected_tool_path_cannot_be_widened(self) -> None:
        self.assert_tamper_rejected(
            "      PATH: /usr/bin:/bin\n",
            "      PATH: /usr/local/bin:/usr/bin:/bin\n",
        )

    def test_validator_digest_must_come_from_protected_environment(self) -> None:
        self.assert_tamper_rejected(
            "      VALIDATOR_SHA256: ${{ vars.PAKPERK_MOBILE_ACCEPTANCE_VALIDATOR_SHA256 }}\n",
            "      VALIDATOR_SHA256: ${{ inputs.source_revision }}\n",
        )

    def test_bash_startup_file_cannot_point_into_candidate_checkout(self) -> None:
        self.assert_tamper_rejected(
            "      BASH_ENV: /dev/null\n",
            "      BASH_ENV: ${{ github.workspace }}/pretrust.sh\n",
        )

    def test_staging_coordinates_cannot_return_to_mutable_variables(self) -> None:
        self.assert_tamper_rejected(
            "      DRIVER_SHA256: ${{ vars.PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256 }}\n",
            "      STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}\n"
            "      DRIVER_SHA256: ${{ vars.PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256 }}\n",
        )

    def test_mutable_application_identity_cannot_be_added(self) -> None:
        self.assert_tamper_rejected(
            "      ANDROID_SIGNER_SHA256: ${{ vars.PAKPERK_ANDROID_SIGNER_SHA256 }}\n",
            "      ANDROID_APPLICATION_ID: ${{ vars.PAKPERK_ANDROID_APPLICATION_ID }}\n"
            "      ANDROID_SIGNER_SHA256: ${{ vars.PAKPERK_ANDROID_SIGNER_SHA256 }}\n",
        )

    def test_staging_config_source_cannot_be_replaced(self) -> None:
        self.assert_tamper_rejected(
            "            mobile/config/staging.json \\\n",
            "            /tmp/staging.json \\\n",
        )

    def test_source_binding_schema_cannot_drop_app_link_contract(self) -> None:
        original = '              "schema": 2,\n'
        self.assertIn(original, SOURCE)
        tampered = SOURCE.replace(original, '              "schema": 1,\n', 1)
        with self.assertRaisesRegex(RuntimeError, "exact staging source contract"):
            validator._validate_semantic_contract(tampered)

    def test_app_link_origin_cannot_be_removed_from_driver_request(self) -> None:
        original = '              "app_link_origin": source_binding["app_link_origin"],\n'
        self.assertIn(original, SOURCE)
        tampered = SOURCE.replace(original, "", 1)
        with self.assertRaisesRegex(RuntimeError, "private protected driver invocation"):
            validator._validate_semantic_contract(tampered)

    def test_staging_config_no_follow_read_cannot_be_weakened(self) -> None:
        self.assert_tamper_rejected(
            '          if hasattr(os, "O_NOFOLLOW"):\n'
            "              flags |= os.O_NOFOLLOW\n",
            "",
        )

    def test_staging_control_character_guard_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "                  or any(ord(character) < 0x20 or ord(character) == 0x7f for character in value)\n",
            "",
        )

    def test_github_environment_file_poisoning_is_rejected(self) -> None:
        marker = (
            "          PY\n\n"
            "      - name: Verify protected macOS runner, pinned tools, and signed candidate manifest\n"
        )
        self.assertIn(marker, SOURCE)
        tampered = SOURCE.replace(
            marker,
            "          PY\n"
            '          echo "BASH_ENV=$GITHUB_WORKSPACE/pretrust.sh" >>"$GITHUB_ENV"\n\n'
            "      - name: Verify protected macOS runner, pinned tools, and signed candidate manifest\n",
            1,
        )
        self.assert_execution_boundary_rejected(tampered, "data-only")

    def test_background_process_persistence_is_rejected(self) -> None:
        marker = (
            "          PY\n\n"
            "      - name: Verify protected macOS runner, pinned tools, and signed candidate manifest\n"
        )
        self.assertIn(marker, SOURCE)
        tampered = SOURCE.replace(
            marker,
            "          PY\n"
            "          /usr/bin/python3 mobile/pretrust.py &\n\n"
            "      - name: Verify protected macOS runner, pinned tools, and signed candidate manifest\n",
            1,
        )
        self.assert_execution_boundary_rejected(tampered, "background process")

    def test_candidate_authored_python_execution_is_rejected(self) -> None:
        marker = '          if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then\n'
        self.assertIn(marker, SOURCE)
        tampered = SOURCE.replace(
            marker,
            "          /usr/bin/python3 mobile/pretrust.py\n" + marker,
            1,
        )
        self.assert_execution_boundary_rejected(tampered, "candidate-authored code")

    def test_protected_secrets_cannot_be_bound_before_driver_step(self) -> None:
        self.assert_tamper_rejected(
            "          PAKPERK_BUILD_NUMBER: ${{ steps.source.outputs.build_number }}\n"
            "        run: |\n",
            "          PAKPERK_BUILD_NUMBER: ${{ steps.source.outputs.build_number }}\n"
            "          PRETRUST_SECRET: ${{ secrets.PAKPERK_PRIMARY_TEST_PASSWORD }}\n"
            "        run: |\n",
        )

    def test_source_gate_early_success_exit_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            '        run: |\n          if [[ "$DISPATCH_REF"',
            '        run: |\n          exit 0\n          if [[ "$DISPATCH_REF"',
        )

    def test_driver_gate_early_success_exit_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            '        run: |\n          if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then\n',
            "        run: |\n          exit 0\n"
            '          if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then\n',
        )

    def test_package_early_success_exit_is_rejected(self) -> None:
        marker = (
            "      - name: Validate and atomically package sanitized acceptance evidence\n"
            "        id: evidence-package\n"
            "        if: always()\n"
            "        continue-on-error: true\n"
            "        shell: bash\n"
            "        env:\n"
        )
        self.assertIn(marker, SOURCE)
        tampered = SOURCE.replace(
            '        run: |\n          evidence_dir="$RUNNER_TEMP/pakperk-mobile-acceptance-evidence"\n',
            "        run: |\n          exit 0\n"
            '          evidence_dir="$RUNNER_TEMP/pakperk-mobile-acceptance-evidence"\n',
            1,
        )
        with self.assertRaises(RuntimeError):
            self.validate_source(tampered)

    def test_if_false_on_acceptance_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "        id: acceptance\n        continue-on-error: true\n",
            "        id: acceptance\n"
            "        if: false\n"
            "        continue-on-error: true\n",
        )

    def test_duplicate_continue_on_error_key_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "        id: acceptance\n        continue-on-error: true\n",
            "        id: acceptance\n"
            "        continue-on-error: false\n"
            "        continue-on-error: true\n",
        )

    def test_candidate_manifest_validation_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '/usr/bin/python3 -I "$validator" validate-candidate',
            '/usr/bin/python3 -I "$validator" --help',
        )

    def test_candidate_validator_cannot_be_replaced_by_checkout_script(self) -> None:
        self.assert_tamper_rejected(
            '/usr/bin/python3 -I "$validator" validate-candidate',
            "/usr/bin/python3 -I scripts/validate_mobile_acceptance_evidence.py validate-candidate",
        )

    def test_candidate_manifest_root_cannot_be_changed(self) -> None:
        self.assert_tamper_rejected(
            'candidate_manifest="/opt/pakperk/mobile-candidates/$candidate_digest.json"',
            'candidate_manifest="$RUNNER_TEMP/$candidate_digest.json"',
        )

    def test_release_provenance_root_cannot_be_changed(self) -> None:
        self.assert_tamper_rejected(
            'provenance_manifest="/opt/pakperk/mobile-release-provenance/$provenance_digest.json"',
            'provenance_manifest="$RUNNER_TEMP/$provenance_digest.json"',
        )

    def test_runner_session_attestation_root_cannot_be_changed(self) -> None:
        self.assert_tamper_rejected(
            'runner_session_manifest="/opt/pakperk/mobile-runner-sessions/$runner_session_digest.json"',
            'runner_session_manifest="$RUNNER_TEMP/$runner_session_digest.json"',
        )

    def test_release_provenance_validation_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '            --provenance-id "$PROVENANCE_ID" \\\n',
            "",
        )

    def test_runner_session_validation_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '            --session-binding-output "$runner_session_binding"\n',
            "",
        )

    def test_signer_binding_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '            --ios-signer-sha256 "$IOS_SIGNER_SHA256" \\\n',
            "",
        )

    def test_run_nonce_generation_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '              output.write(f"challenge={secrets.token_hex(32)}\\n")\n',
            '              output.write("challenge=" + "0" * 64 + "\\n")\n',
        )

    def test_driver_parent_protection_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '              pathlib.Path("/opt/pakperk/bin"),\n', ""
        )

    def test_driver_descriptor_identity_check_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "          if identity(before) != identity(after) or identity(after) != identity(current):\n",
            "          if False:\n",
        )

    def test_ipad_keyboard_role_cannot_be_replaced_by_phone(self) -> None:
        self.assert_tamper_rejected(
            '                  "ipad_keyboard_secondary_sync",\n',
            '                  "ios_home_indicator",\n',
        )

    def test_required_scenario_removal_is_rejected(self) -> None:
        self.assert_tamper_rejected('                  "expired_token_refresh",\n', "")

    def test_schema_v6_request_cannot_be_downgraded(self) -> None:
        self.assert_tamper_rejected(
            '          request = {\n              "schema": 6,\n',
            '          request = {\n              "schema": 5,\n',
        )

    def test_schema_v6_contract_count_cannot_be_changed(self) -> None:
        for field, expected in (
            ("scenario_count", 42),
            ("assertion_count", 317),
            ("metric_count", 254),
        ):
            with self.subTest(field=field):
                self.assert_tamper_rejected(
                    f'                  "{field}": {expected},\n',
                    f'                  "{field}": {expected - 1},\n',
                )

    def test_schema_v6_contract_digest_cannot_be_changed(self) -> None:
        self.assert_tamper_rejected(
            '                  "sha256": "7483820afc6b2111f4886177dd120e72ab8ca47164757ca1eda9e10f64d70ad5",\n',
            '                  "sha256": "0483820afc6b2111f4886177dd120e72ab8ca47164757ca1eda9e10f64d70ad5",\n',
        )

    def test_each_plan02_schema_v5_scenario_removal_is_rejected(self) -> None:
        for scenario_id in (
            "plan02_search_lookup_explore_saved_queries",
            "plan02_research_profile_personalization",
            "plan02_why_and_feedback",
            "plan02_reading_brief_progress_authority",
            "plan02_subscription_notification_safety",
        ):
            with self.subTest(scenario_id=scenario_id):
                self.assert_tamper_rejected(
                    f'                  "{scenario_id}",\n', ""
                )

    def test_each_plan03_schema_v6_scenario_removal_is_rejected(self) -> None:
        for scenario_id in validator.evidence.SCENARIO_IDS[-10:]:
            with self.subTest(scenario_id=scenario_id):
                self.assert_tamper_rejected(
                    f'                  "{scenario_id}",\n', ""
                )

    def test_cached_first_readable_p95_limit_cannot_be_weakened(self) -> None:
        original = (
            '                      "cached_first_readable_frame_p95_ms": '
            '["range", 1, 1500],\n'
        )
        self.assertIn(original, SOURCE)
        tampered = SOURCE.replace(original, original.replace("1500", "1501"), 1)
        with self.assertRaisesRegex(RuntimeError, "exact performance metric rules"):
            validator._validate_semantic_contract(tampered)

    def test_opening_transition_limit_cannot_be_weakened(self) -> None:
        original = (
            '                      "opening_transition_ms": '
            '["range", 1, 700],\n'
        )
        self.assertIn(original, SOURCE)
        tampered = SOURCE.replace(original, original.replace("700", "701"), 1)
        with self.assertRaisesRegex(RuntimeError, "exact performance metric rules"):
            validator._validate_semantic_contract(tampered)

    def test_large_document_device_budget_cannot_be_weakened(self) -> None:
        cases = (
            (
                '                      "large_document_minimum_frame_samples_per_device": '
                '["min", 120, None],\n',
                '["min", 119, None]',
            ),
            (
                '                      "large_document_minimum_scroll_window_seconds_per_device": '
                '["min", 30, None],\n',
                '["min", 29, None]',
            ),
            (
                '                      "large_document_peak_retained_blocks": '
                '["range", 1, 2000],\n',
                '["range", 1, 2001]',
            ),
            (
                '                      "large_document_worst_device_scroll_frame_p95_us": '
                '["range", 1, 16667],\n',
                '["range", 1, 16668]',
            ),
        )
        for original, weakened in cases:
            with self.subTest(metric=original):
                self.assertIn(original, SOURCE)
                tampered = SOURCE.replace(original, weakened + "\n", 1)
                with self.assertRaisesRegex(
                    RuntimeError, "exact performance metric rules"
                ):
                    validator._validate_semantic_contract(tampered)

    def test_challenge_keyed_device_identity_contract_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '              "device_identity_hash_contract": {\n',
            '              "ignored_identity_contract": {\n',
        )

    def test_runner_session_binding_cannot_be_removed_from_request(self) -> None:
        self.assert_tamper_rejected(
            '              "runner_session": runner_session_binding,\n',
            "",
        )

    def test_mobile_feature_evidence_cannot_be_removed_from_request(self) -> None:
        self.assert_tamper_rejected(
            '              "mobile_feature_evidence": mobile_feature_evidence,\n',
            "",
        )

    def test_mobile_feature_evidence_digest_validation_cannot_be_weakened(
        self,
    ) -> None:
        self.assert_tamper_rejected(
            '              or len(mobile_feature_evidence["sha256"]) != 64\n',
            '              or len(mobile_feature_evidence["sha256"]) != 32\n',
        )

    def test_mobile_feature_evidence_v6_cannot_be_downgraded(self) -> None:
        self.assert_tamper_rejected(
            '              or mobile_feature_evidence["schema"] != 6\n',
            '              or mobile_feature_evidence["schema"] != 5\n',
        )

    def test_each_new_mobile_feature_flag_is_bound_into_request(self) -> None:
        for key in (
            "paperTitleSearch",
            "libraryImportWrites",
            "readingFeed",
            "toReadFirstEnforcement",
            "libraryV2",
            "recommendations",
            "recommendationEvents",
            "searchLookup",
            "searchExplore",
            "savedQueries",
            "researchProfiles",
            "readingBriefs",
            "subscriptions",
            "notifications",
            "deepReader",
            "paperPassport",
            "semanticFacets",
            "documentVisualObjects",
            "readingCheckpoints",
            "annotations",
            "evidenceCards",
            "researchMemory",
            "versionDiff",
            "assistantV2",
        ):
            with self.subTest(key=key):
                self.assert_tamper_rejected(
                    f'                  "{key}",\n',
                    f'                  "tampered{key}",\n',
                )

    def test_protected_acceptance_requires_new_mobile_features_enabled(
        self,
    ) -> None:
        self.assert_tamper_rejected(
            "                  mobile_feature_evidence[key] is not True\n",
            "                  False\n",
        )

    def test_driver_output_redirection_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '          ) >"$driver_log" 2>&1; then\n',
            "          ); then\n",
        )

    def test_private_log_cleanup_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected("          trap cleanup_driver_log EXIT\n", "")

    def test_log_cannot_be_printed(self) -> None:
        self.assert_tamper_rejected(
            '          echo "Protected physical-device acceptance completed."\n',
            '          cat "$driver_log"\n'
            '          echo "Protected physical-device acceptance completed."\n',
        )

    def test_xtrace_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "        run: |\n          evidence_dir=",
            "        run: |\n          set -x\n          evidence_dir=",
        )

    def test_isolated_python_cannot_be_weakened(self) -> None:
        self.assert_tamper_rejected(
            "/usr/bin/python3 -I \\\n"
            "            /opt/pakperk/bin/pakperk-mobile-acceptance-validator.py \\\n"
            "            validate-and-package",
            "/usr/bin/python3 \\\n"
            "            /opt/pakperk/bin/pakperk-mobile-acceptance-validator.py \\\n"
            "            validate-and-package",
        )

    def test_full_workspace_cleanliness_cannot_be_weakened(self) -> None:
        self.assert_tamper_rejected(
            "git status --porcelain=v1 --untracked-files=all --ignored=matching",
            "git status --porcelain=v1 --untracked-files=no",
        )

    def test_validator_failure_cannot_be_ignored(self) -> None:
        self.assert_tamper_rejected(
            "            validate-and-package \\\n"
            '            "$evidence" "$archive" \\\n',
            "            validate-and-package \\\n"
            '            "$evidence" "$archive" || true \\\n',
        )

    def test_archive_digest_output_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '            --github-output "$GITHUB_OUTPUT"\n',
            "",
        )

    def test_packaged_tooling_manifest_must_bind_validator_digest(self) -> None:
        self.assert_tamper_rejected(
            '            --validator-sha256 "$VALIDATOR_SHA256" \\\n',
            "",
        )

    def test_archive_verifier_must_compare_validator_digest(self) -> None:
        self.assert_tamper_rejected(
            '            --expected-validator-sha256 "$VALIDATOR_SHA256" \\\n',
            "",
        )

    def test_pre_upload_archive_verifier_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "            verify-archive \\\n"
            '            "$archive" \\\n',
            "            --help \\\n"
            '            "$archive" \\\n',
        )

    def test_upload_cannot_run_without_archive_verification(self) -> None:
        self.assert_tamper_rejected(
            "        if: steps.evidence-package.outcome == 'success' && steps.archive-verify.outcome == 'success'\n",
            "        if: steps.evidence-package.outcome == 'success'\n",
        )

    def test_upload_name_must_bind_packaged_archive_digest(self) -> None:
        self.assert_tamper_rejected(
            "          name: protected-mobile-acceptance-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}-${{ steps.evidence-package.outputs.archive_sha256 }}\n",
            "          name: protected-mobile-acceptance-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}\n",
        )

    def test_missing_evidence_warning_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "if-no-files-found: error", "if-no-files-found: warn"
        )

    def test_final_upload_failure_cannot_be_accepted(self) -> None:
        self.assert_tamper_rejected(
            '[[ "$ACCEPTANCE_OUTCOME" != "success" || "$PACKAGE_OUTCOME" != "success" || "$ARCHIVE_VERIFY_OUTCOME" != "success" || "$UPLOAD_OUTCOME" != "success" ]]',
            '[[ "$ACCEPTANCE_OUTCOME" != "success" || "$PACKAGE_OUTCOME" != "success" || "$ARCHIVE_VERIFY_OUTCOME" != "success" ]]',
        )

    def test_final_artifact_digest_binding_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "          UPLOADED_ARTIFACT_DIGEST: ${{ steps.evidence-upload.outputs.artifact-digest }}\n",
            "",
        )


if __name__ == "__main__":
    unittest.main()
