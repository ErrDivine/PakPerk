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
            'python3 -I - mobile/config/staging.json "$GITHUB_ENV"',
            'python3 -I - /tmp/staging.json "$GITHUB_ENV"',
        )

    def test_staging_config_no_follow_read_cannot_be_weakened(self) -> None:
        self.assert_tamper_rejected(
            '          if hasattr(os, "O_NOFOLLOW"):\n'
            "              flags |= os.O_NOFOLLOW\n",
            "",
        )

    def test_source_gate_early_success_exit_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            '        run: |\n          if [[ "$DISPATCH_REF"',
            '        run: |\n          exit 0\n          if [[ "$DISPATCH_REF"',
        )

    def test_driver_gate_early_success_exit_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "        run: |\n          driver=/opt/pakperk/bin/pakperk-mobile-acceptance-driver\n",
            "        run: |\n          exit 0\n"
            "          driver=/opt/pakperk/bin/pakperk-mobile-acceptance-driver\n",
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
            "validate_mobile_acceptance_evidence.py validate-candidate",
            "validate_mobile_acceptance_evidence.py --help",
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
            "python3 -I scripts/validate_mobile_acceptance_evidence.py validate-and-package",
            "python3 scripts/validate_mobile_acceptance_evidence.py validate-and-package",
        )

    def test_full_workspace_cleanliness_cannot_be_weakened(self) -> None:
        self.assert_tamper_rejected(
            "git status --porcelain=v1 --untracked-files=all --ignored=matching",
            "git status --porcelain=v1 --untracked-files=no",
        )

    def test_validator_failure_cannot_be_ignored(self) -> None:
        self.assert_tamper_rejected(
            "validate_mobile_acceptance_evidence.py validate-and-package \\\n",
            "validate_mobile_acceptance_evidence.py validate-and-package || true \\\n",
        )

    def test_archive_digest_output_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            '            --github-output "$GITHUB_OUTPUT"\n',
            "",
        )

    def test_pre_upload_archive_verifier_cannot_be_removed(self) -> None:
        self.assert_tamper_rejected(
            "python3 -I scripts/validate_mobile_acceptance_evidence.py verify-archive",
            "python3 -I scripts/validate_mobile_acceptance_evidence.py --help",
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
