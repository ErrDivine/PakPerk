#!/usr/bin/env python3
"""Mutation regressions for platform-isolated production store rollout."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import validate_mobile_store_rollout_workflow as validator


SOURCE = validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8")
CI_SOURCE = validator.DEFAULT_CI.read_text(encoding="utf-8")
CHECK_SOURCE = validator.DEFAULT_CHECK.read_text(encoding="utf-8")
SCRIPTS_ROOT = pathlib.Path(__file__).resolve().parent


class MobileStoreRolloutWorkflowTests(unittest.TestCase):
    def _validate(
        self,
        source: str = SOURCE,
        ci_source: str = CI_SOURCE,
        check_source: str = CHECK_SOURCE,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            workflow = root / "mobile-store-rollout.yml"
            ci = root / "ci.yml"
            check = root / "check.sh"
            workflow.write_text(source, encoding="utf-8")
            ci.write_text(ci_source, encoding="utf-8")
            check.write_text(check_source, encoding="utf-8")
            validator.validate(workflow, ci, check)

    def _replace(self, source: str, original: str, replacement: str) -> str:
        self.assertIn(original, source)
        return source.replace(original, replacement, 1)

    def _reject(self, original: str, replacement: str) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(self._replace(SOURCE, original, replacement))

    def _reject_semantically(self, original: str, replacement: str) -> None:
        mutated = self._replace(SOURCE, original, replacement)
        refreshed_lock = hashlib.sha256(mutated.encode("utf-8")).hexdigest()
        with (
            mock.patch.object(
                validator, "EXPECTED_WORKFLOW_SHA256", refreshed_lock
            ),
            self.assertRaises(RuntimeError),
        ):
            self._validate(mutated)

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_isolated_rollout_entrypoints_import_reviewed_siblings(self) -> None:
        commands = (
            (
                SCRIPTS_ROOT,
                "prepare_mobile_credentialed_upload.py",
                ("--help",),
            ),
            (
                SCRIPTS_ROOT,
                "generate_mobile_store_rollout_receipt.py",
                ("verify-platform", "--help"),
            ),
            (
                SCRIPTS_ROOT,
                "generate_mobile_store_rollout_receipt.py",
                ("aggregate", "--help"),
            ),
        )
        for root, name, arguments in commands:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(
                    [sys.executable, "-I", str(root / name), *arguments],
                    cwd=directory,
                    env={"PATH": "/usr/bin:/bin"},
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(0, result.returncode, result.stderr)

    def test_automatic_trigger_is_rejected(self) -> None:
        self._reject("  workflow_dispatch:\n", "  push:\n  workflow_dispatch:\n")

    def test_extra_job_is_rejected(self) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(SOURCE + "\n  bypass:\n    runs-on: ubuntu-latest\n")

    def test_mutable_checkout_is_rejected(self) -> None:
        self._reject(validator.CHECKOUT_ACTION, "actions/checkout@v7")

    def test_mutable_download_is_rejected(self) -> None:
        self._reject(validator.DOWNLOAD_ACTION, "actions/download-artifact@v8")

    def test_mutable_upload_is_rejected(self) -> None:
        self._reject(validator.UPLOAD_ACTION, "actions/upload-artifact@v7")

    def test_bootstrap_cannot_receive_protected_environment(self) -> None:
        self._reject(
            "    timeout-minutes: 45\n    outputs:",
            "    timeout-minutes: 45\n    environment: production-store\n    outputs:",
        )

    def test_bootstrap_cannot_receive_store_secret(self) -> None:
        self._reject(
            "      - name: Select and verify bootstrap Ruby\n",
            "      - name: Select and verify bootstrap Ruby\n"
            "        env:\n"
            "          UNSAFE: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}\n",
        )

    def test_android_job_cannot_checkout_candidate_code(self) -> None:
        marker = "      - name: Create owner-only Android outcome root\n"
        self._reject(
            marker,
            marker
            + f"      - uses: {validator.CHECKOUT_ACTION}\n"
            + "        with:\n          ref: ${{ inputs.source_revision }}\n",
        )

    def test_android_job_cannot_execute_downloaded_candidate_with_refreshed_lock(self) -> None:
        marker = "          [[ \"$TRANSFER_DIGEST\" =~ ^[0-9a-f]{64}$ ]] || exit 1\n"
        self._reject_semantically(
            marker,
            marker
            + "          /bin/bash \"$RUNNER_TEMP/release-candidate/artifacts/payload\"\n",
        )

    def test_ios_job_cannot_run_local_action(self) -> None:
        marker = "      - name: Create owner-only iOS outcome root\n"
        self._reject(marker, marker + "      - uses: ./candidate-action\n")

    def test_android_job_cannot_receive_apple_secret(self) -> None:
        self._reject(
            "          GOOGLE_PLAY_JSON_BASE64: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}",
            "          GOOGLE_PLAY_JSON_BASE64: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}\n"
            "          UNSAFE_APPLE: ${{ secrets.PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64 }}",
        )

    def test_android_secret_is_confined_to_mutation_step(self) -> None:
        secret = "${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}"
        moved = SOURCE.replace(
            "          PROMPT_COMMAND: \"\"\n",
            "          PROMPT_COMMAND: \"\"\n          EARLY_SECRET: " + secret + "\n",
            1,
        ).replace(
            "          GOOGLE_PLAY_JSON_BASE64: " + secret,
            "          GOOGLE_PLAY_JSON_BASE64: unavailable",
            1,
        )
        refreshed_lock = hashlib.sha256(moved.encode("utf-8")).hexdigest()
        with (
            mock.patch.object(
                validator, "EXPECTED_WORKFLOW_SHA256", refreshed_lock
            ),
            self.assertRaises(RuntimeError),
        ):
            self._validate(moved)

    def test_ios_job_cannot_receive_google_secret(self) -> None:
        self._reject(
            "          APP_STORE_KEY_BASE64: ${{ secrets.PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64 }}",
            "          APP_STORE_KEY_BASE64: ${{ secrets.PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64 }}\n"
            "          UNSAFE_GOOGLE: ${{ secrets.PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 }}",
        )

    def test_candidate_download_must_use_artifact_id(self) -> None:
        self._reject(
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.candidate_artifact_id }}",
            "          name: mobile-signed-candidate",
        )

    def test_handoff_download_must_use_distinct_artifact_id(self) -> None:
        self._reject(
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.handoff_artifact_id }}",
            "          artifact-ids: ${{ needs.store-client-bootstrap.outputs.candidate_artifact_id }}",
        )

    def test_transfer_digest_output_cannot_be_removed(self) -> None:
        self._reject(
            "      transfer_artifact_digest: ${{ steps.transfer_upload.outputs.artifact-digest }}\n",
            "",
        )

    def test_packaged_helper_closure_is_exact_after_lock_refresh(self) -> None:
        self._reject_semantically(
            '            "2d51f03bd21f2afa2af0396e801e0e950172210814a229ca50df67c5a8d135cd capture_mobile_credentialed_runtime.py" \\\n',
            "",
        )

    def test_downloaded_helper_closure_is_exact_after_lock_refresh(self) -> None:
        self._reject_semantically(
            '              "capture_mobile_credentialed_runtime.py": "2d51f03bd21f2afa2af0396e801e0e950172210814a229ca50df67c5a8d135cd",\n',
            "",
        )

    def test_downloaded_helper_directory_cannot_accept_extra_controls(self) -> None:
        self._reject_semantically(
            "          if {item.name for item in root.iterdir()} != set(expected):\n"
            "              raise SystemExit(\"rollout control closure changed\")\n",
            "",
        )

    def test_platform_artifact_digest_output_cannot_be_removed(self) -> None:
        self._reject(
            "      evidence_artifact_digest: ${{ steps.evidence_upload.outputs.artifact-digest }}\n",
            "",
        )

    def test_ios_must_need_android_job(self) -> None:
        self._reject(
            "    needs: [store-client-bootstrap, android-rollout]\n",
            "    needs: store-client-bootstrap\n",
        )

    def test_both_ios_job_requires_android_job_success(self) -> None:
        self._reject(
            "(inputs.platforms == 'both' && needs.android-rollout.result == 'success')",
            "inputs.platforms == 'both'",
        )

    def test_ios_downloads_android_proof_by_id(self) -> None:
        self._reject(
            "          artifact-ids: ${{ needs.android-rollout.outputs.evidence_artifact_id }}",
            "          name: mobile-android-rollout",
        )

    def test_ios_proof_must_be_validated_before_secret_step(self) -> None:
        self._reject(
            "steps.android_proof.outcome == 'success'",
            "steps.android_proof.outcome != 'failure'",
        )

    def test_android_proof_validator_cannot_be_removed(self) -> None:
        self._reject(" verify-platform \\\n", " --help \\\n")

    def test_android_proof_validator_must_run_in_isolated_mode(self) -> None:
        self._reject_semantically(
            '/usr/bin/python3 -I "$CONTROL_ROOT/generate_mobile_store_rollout_receipt.py" verify-platform',
            '/usr/bin/python3 "$CONTROL_ROOT/generate_mobile_store_rollout_receipt.py" verify-platform',
        )

    def test_candidate_validator_must_follow_client_preparation(self) -> None:
        self._reject_semantically(
            'target = os.path.join(controls, "validate_mobile_store_candidate.py")',
            'target = os.path.join(controls, "prepare_mobile_credentialed_upload.py")',
        )

    def test_android_store_client_inode_lock_cannot_be_removed(self) -> None:
        self._reject(
            '--root-device "$CLIENT_DEVICE" --root-inode "$CLIENT_INODE" \\\n',
            '--root-device "$CLIENT_DEVICE" \\\n',
        )

    def test_mutable_cross_step_environment_is_rejected(self) -> None:
        self._reject(
            "          printf 'root=%s\\n' \"$root\" >>\"$GITHUB_OUTPUT\"",
            "          printf 'ROOT=%s\\n' \"$root\" >>\"$GITHUB_ENV\"",
        )

    def test_lowercase_proxy_hook_cannot_be_reintroduced(self) -> None:
        self._reject('          https_proxy: ""\n', "")

    def test_ca_hook_cannot_be_reintroduced(self) -> None:
        self._reject('          CURL_CA_BUNDLE: ""\n', "")

    def test_android_cleanup_must_precede_receipt(self) -> None:
        cleanup = SOURCE.index("      - name: Remove Android credential and local client\n")
        receipt = SOURCE.index("      - name: Generate closed Android platform receipt after cleanup\n")
        mutated = SOURCE[:cleanup] + SOURCE[receipt:] + SOURCE[cleanup:receipt]
        with self.assertRaises(RuntimeError):
            self._validate(mutated)

    def test_ios_cleanup_must_precede_receipt(self) -> None:
        cleanup = SOURCE.index("      - name: Remove iOS credentials and local client\n")
        receipt = SOURCE.index("      - name: Generate closed iOS platform receipt after cleanup\n")
        mutated = SOURCE[:cleanup] + SOURCE[receipt:] + SOURCE[cleanup:receipt]
        with self.assertRaises(RuntimeError):
            self._validate(mutated)

    def test_outcome_artifact_must_upload_even_after_failure(self) -> None:
        self._reject_semantically(
            "      - name: Upload immutable Android outcome after cleanup\n"
            "        id: evidence_upload\n"
            "        if: always()",
            "      - name: Upload immutable Android outcome after cleanup\n"
            "        id: evidence_upload\n"
            "        if: success()",
        )

    def test_outcome_upload_failure_must_not_skip_terminal_evidence_checks(self) -> None:
        self._reject_semantically(
            "      - name: Upload immutable iOS outcome after cleanup\n"
            "        id: evidence_upload\n"
            "        if: always()\n"
            "        continue-on-error: true",
            "      - name: Upload immutable iOS outcome after cleanup\n"
            "        id: evidence_upload\n"
            "        if: always()",
        )

    def test_finalizer_must_run_always(self) -> None:
        self._reject(
            "    needs: [store-client-bootstrap, android-rollout, ios-rollout]\n"
            "    if: always()\n",
            "    needs: [store-client-bootstrap, android-rollout, ios-rollout]\n"
            "    if: success()\n",
        )

    def test_finalizer_aggregate_must_run_in_isolated_mode(self) -> None:
        self._reject_semantically(
            '/usr/bin/python3 -I "$helper" aggregate',
            '/usr/bin/python3 "$helper" aggregate',
        )

    def test_finalizer_receipt_upload_must_run_after_aggregate_failure(self) -> None:
        self._reject_semantically(
            "      - name: Upload canonical credential-free rollout receipt\n"
            "        id: receipt_upload\n"
            "        if: always()",
            "      - name: Upload canonical credential-free rollout receipt\n"
            "        id: receipt_upload\n"
            "        if: success()",
        )

    def test_finalizer_cannot_receive_protected_environment(self) -> None:
        self._reject(
            "    runs-on: ubuntu-24.04\n    timeout-minutes: 20\n",
            "    runs-on: ubuntu-24.04\n    environment: production-store\n    timeout-minutes: 20\n",
        )

    def test_finalizer_must_bind_action_digest_outputs(self) -> None:
        self._reject(
            '--android-artifact-digest "${{ needs.android-rollout.outputs.evidence_artifact_digest }}"',
            '--android-artifact-digest "${{ needs.ios-rollout.outputs.evidence_artifact_digest }}"',
        )

    def test_finalizer_must_fail_requested_skips(self) -> None:
        self._reject(
            '[[ "$IOS_RESULT" == success ]] || failed=1',
            '[[ "$IOS_RESULT" != failure ]] || failed=1',
        )

    def test_arbitrary_workflow_edit_is_content_locked(self) -> None:
        self._reject(
            "name: protected-mobile-store-rollout",
            "name: protected-mobile-store-rollout-edited",
        )

    def test_ci_receipt_test_cannot_be_removed(self) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(
                ci_source=CI_SOURCE.replace(
                    "          python3 scripts/test_generate_mobile_store_rollout_receipt.py\n",
                    "",
                    1,
                )
            )

    def test_ci_credential_boundary_test_cannot_be_removed(self) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(
                ci_source=CI_SOURCE.replace(
                    "          python3 scripts/test_prepare_mobile_credentialed_upload.py\n",
                    "",
                    1,
                )
            )

    def test_ci_validation_cannot_be_guarded_false(self) -> None:
        first = "          python3 scripts/test_generate_mobile_store_rollout_receipt.py"
        last = "          python3 scripts/validate_mobile_store_rollout_workflow.py"
        mutated = CI_SOURCE.replace(first, "          if false; then\n" + first, 1)
        mutated = mutated.replace(last, last + "\n          fi", 1)
        with self.assertRaises(RuntimeError):
            self._validate(ci_source=mutated)

    def test_local_validation_cannot_exit_early(self) -> None:
        marker = 'python3 "$project_dir/scripts/test_generate_mobile_store_rollout_receipt.py"'
        with self.assertRaises(RuntimeError):
            self._validate(check_source=CHECK_SOURCE.replace(marker, "exit 0\n" + marker, 1))

    def test_local_check_must_remain_fail_fast(self) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(check_source=CHECK_SOURCE.replace("set -euo pipefail", "set +e", 1))


if __name__ == "__main__":
    unittest.main()
