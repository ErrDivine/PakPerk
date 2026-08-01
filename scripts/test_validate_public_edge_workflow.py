#!/usr/bin/env python3
"""Tamper regressions for the manual public-edge workflow contract."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_public_edge_workflow as validator


class PublicEdgeWorkflowTests(unittest.TestCase):
    def _source(self) -> str:
        return validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8")

    def _replace(self, source: str, old: str, new: str) -> str:
        self.assertIn(old, source)
        return source.replace(old, new, 1)

    def _validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "public-edge-verification.yml"
            path.write_text(source, encoding="utf-8")
            validator.validate(path)

    def _assert_rejected(self, source: str) -> None:
        with self.assertRaises(RuntimeError):
            self._validate_source(source)

    def _comment_out(self, source: str, block: str) -> str:
        commented = "".join(
            f"{line[: len(line) - len(line.lstrip())]}# {line.lstrip()}"
            for line in block.splitlines(keepends=True)
        )
        return self._replace(source, block, commented)

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "  workflow_dispatch:\n", "  push:\n  workflow_dispatch:\n"
        )
        self._assert_rejected(source)

    def test_unexpected_dispatch_input_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      confirmation:\n",
            "      unsafe_origin:\n"
            "        required: true\n"
            "        type: string\n"
            "      confirmation:\n",
        )
        self._assert_rejected(source)

    def test_optional_source_revision_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      source_revision:\n"
            "        description: Reviewed full lowercase commit SHA that exactly matches the selected main revision\n"
            "        required: true",
            "      source_revision:\n"
            "        description: Reviewed full lowercase commit SHA that exactly matches the selected main revision\n"
            "        required: false",
        )
        self._assert_rejected(source)

    def test_duplicate_input_property_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      candidate_id:\n",
            "      candidate_id:\n        required: false\n",
        )
        self._assert_rejected(source)

    def test_target_environment_option_widening_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          - production\n",
            "          - production\n          - preview\n",
        )
        self._assert_rejected(source)

    def test_write_permission_is_rejected(self) -> None:
        source = self._replace(self._source(), "contents: read", "contents: write")
        self._assert_rejected(source)

    def test_oidc_permission_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "  contents: read\n",
            "  contents: read\n  id-token: write\n",
        )
        self._assert_rejected(source)

    def test_secret_consumption_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '      PYTHONDONTWRITEBYTECODE: "1"',
            '      PYTHONDONTWRITEBYTECODE: "1"\n'
            "      UNSAFE_TOKEN: ${{ secrets.UNSAFE_TOKEN }}",
        )
        self._assert_rejected(source)

    def test_unreviewed_public_variable_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '      PYTHONDONTWRITEBYTECODE: "1"',
            "      EXTRA_ORIGIN: ${{ vars.PAKPERK_EXTRA_ORIGIN }}\n"
            '      PYTHONDONTWRITEBYTECODE: "1"',
        )
        self._assert_rejected(source)

    def test_every_scoped_public_variable_is_mandatory(self) -> None:
        source = self._source()
        for name, value in validator.EXPECTED_JOB_ENV.items():
            if not value.startswith("${{ vars."):
                continue
            with self.subTest(name=name):
                changed = self._replace(source, f"      {name}: {value}\n", "")
                self._assert_rejected(changed)

    def test_python_bytecode_suppression_is_mandatory(self) -> None:
        source = self._replace(
            self._source(), '      PYTHONDONTWRITEBYTECODE: "1"\n', ""
        )
        self._assert_rejected(source)

    def test_non_main_dispatch_check_cannot_be_weakened(self) -> None:
        source = self._replace(
            self._source(),
            'if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            'if [[ -z "$DISPATCH_REF" ]]; then',
        )
        self._assert_rejected(source)

    def test_commented_out_non_main_dispatch_gate_is_rejected(self) -> None:
        source = self._comment_out(
            self._source(),
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then\n'
            '            echo "Public-edge verification must be dispatched from main." >&2\n'
            "            exit 2\n"
            "          fi\n",
        )
        self._assert_rejected(source)

    def test_job_level_main_guard_is_rejected_as_fail_open(self) -> None:
        source = self._replace(
            self._source(),
            "  verify-edge:\n    runs-on: ubuntu-24.04",
            "  verify-edge:\n"
            "    if: github.ref == 'refs/heads/main'\n"
            "    runs-on: ubuntu-24.04",
        )
        self._assert_rejected(source)

    def test_job_level_continue_on_error_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "  verify-edge:\n    runs-on: ubuntu-24.04",
            "  verify-edge:\n"
            "    continue-on-error: true\n"
            "    runs-on: ubuntu-24.04",
        )
        self._assert_rejected(source)

    def test_unexpected_root_environment_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "\njobs:\n",
            "\nenv:\n  BASH_ENV: unsafe\n\njobs:\n",
        )
        self._assert_rejected(source)

    def test_extra_job_with_underscore_is_rejected(self) -> None:
        source = self._source() + "\n  bypass_job:\n    runs-on: ubuntu-latest\n"
        self._assert_rejected(source)

    def test_dispatch_ref_context_binding_is_required(self) -> None:
        source = self._replace(
            self._source(),
            "          DISPATCH_REF: ${{ github.ref }}\n",
            "          DISPATCH_REF: refs/heads/main\n",
        )
        self._assert_rejected(source)

    def test_source_gate_environment_override_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          DISPATCH_REVISION: ${{ github.sha }}\n",
            "          DISPATCH_REVISION: ${{ github.sha }}\n"
            "          REQUESTED_REVISION: ${{ github.sha }}\n",
        )
        self._assert_rejected(source)

    def test_constant_environment_bypasses_choice_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "environment: ${{ inputs.target_environment }}",
            "environment: staging",
        )
        self._assert_rejected(source)

    def test_cross_environment_cancellation_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "group: public-edge-verification-${{ inputs.target_environment }}",
            "group: public-edge-verification",
        )
        self._assert_rejected(source)

    def test_cancelling_an_inflight_observation_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "cancel-in-progress: false", "cancel-in-progress: true"
        )
        self._assert_rejected(source)

    def test_unbounded_timeout_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "timeout-minutes: 15", "timeout-minutes: 150"
        )
        self._assert_rejected(source)

    def test_mutable_checkout_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "ref: ${{ inputs.source_revision }}", "ref: main"
        )
        self._assert_rejected(source)

    def test_shallow_checkout_is_rejected(self) -> None:
        source = self._replace(self._source(), "fetch-depth: 0", "fetch-depth: 1")
        self._assert_rejected(source)

    def test_persisted_checkout_credentials_are_rejected(self) -> None:
        source = self._replace(
            self._source(), "persist-credentials: false", "persist-credentials: true"
        )
        self._assert_rejected(source)

    def test_mutable_checkout_action_is_rejected(self) -> None:
        source = self._replace(
            self._source(), validator.CHECKOUT_ACTION, "actions/checkout@v7"
        )
        self._assert_rejected(source)

    def test_weakened_source_sha_shape_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "^sha256:[0-9a-f]{64}$",
            "^sha256:[0-9a-f]+$",
        )
        self._assert_rejected(source)

    def test_weakened_commit_sha_shape_is_rejected(self) -> None:
        source = self._replace(self._source(), "^[0-9a-f]{40}$", "^[0-9a-f]{7,40}$")
        self._assert_rejected(source)

    def test_dispatch_sha_equality_removal_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
            '[[ -z "$REQUESTED_REVISION" ]]',
        )
        self._assert_rejected(source)

    def test_commit_sha_check_polarity_cannot_be_inverted(self) -> None:
        source = self._replace(
            self._source(),
            'if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
            'if [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
        )
        self._assert_rejected(source)

    def test_head_equality_removal_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '[[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]',
            '[[ -z "$(git rev-parse HEAD)" ]]',
        )
        self._assert_rejected(source)

    def test_main_tip_equality_cannot_be_weakened_to_ancestry(self) -> None:
        source = self._replace(
            self._source(),
            'if [[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]; then',
            'if ! git merge-base --is-ancestor "$REQUESTED_REVISION" origin/main; then',
        )
        self._assert_rejected(source)

    def test_candidate_id_is_not_merely_nonempty(self) -> None:
        source = self._replace(
            self._source(),
            'if ! [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then',
            'if [[ -z "$CANDIDATE_ID" ]]; then',
        )
        self._assert_rejected(source)

    def test_candidate_id_check_polarity_cannot_be_inverted(self) -> None:
        source = self._replace(
            self._source(),
            'if ! [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then',
            'if [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then',
        )
        self._assert_rejected(source)

    def test_commented_out_candidate_digest_gate_is_rejected(self) -> None:
        source = self._comment_out(
            self._source(),
            '          if ! [[ "$CANDIDATE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then\n'
            '            echo "candidate_id must be an exact lowercase sha256 content ID." >&2\n'
            "            exit 2\n"
            "          fi\n",
        )
        self._assert_rejected(source)

    def test_commented_out_origin_main_tip_gate_is_rejected(self) -> None:
        source = self._comment_out(
            self._source(),
            '          if [[ "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]; then\n'
            '            echo "The requested revision is not the fetched origin/main tip." >&2\n'
            "            exit 2\n"
            "          fi\n",
        )
        self._assert_rejected(source)

    def test_coordinate_presence_gate_cannot_be_removed(self) -> None:
        source = self._replace(
            self._source(), '[[ -z "${!coordinate}" ]]', '[[ -v "$coordinate" ]]'
        )
        self._assert_rejected(source)

    def test_direct_network_bypass_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          ./scripts/verify_public_edge.sh \\",
            "          curl https://example.invalid\n"
            "          ./scripts/verify_public_edge.sh \\",
        )
        self._assert_rejected(source)

    def test_tracing_shell_is_rejected(self) -> None:
        source = self._replace(self._source(), "shell: bash", "shell: bash -x")
        self._assert_rejected(source)

    def test_public_coordinates_cannot_be_printed(self) -> None:
        source = self._replace(
            self._source(),
            "          ./scripts/verify_public_edge.sh \\",
            '          echo "$SITE_ORIGIN"\n'
            "          ./scripts/verify_public_edge.sh \\",
        )
        self._assert_rejected(source)

    def test_extra_step_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "    steps:\n",
            "    steps:\n" "      - name: Unreviewed helper\n" "        run: true\n",
        )
        self._assert_rejected(source)

    def test_duplicate_run_key_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '        run: |\n          if [[ "$DISPATCH_REF"',
            "        run: |\n"
            "          true\n"
            "        run: |\n"
            '          if [[ "$DISPATCH_REF"',
        )
        self._assert_rejected(source)

    def test_verifier_failure_masking_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Observe exact public-edge contract\n"
            "        id: public-edge\n"
            "        continue-on-error: true",
            "      - name: Observe exact public-edge contract\n"
            "        id: public-edge\n"
            "        continue-on-error: false",
        )
        self._assert_rejected(source)

    def test_verifier_shell_failure_cannot_be_masked(self) -> None:
        source = self._replace(
            self._source(),
            '            --apple-bundle-id "$APPLE_BUNDLE_ID"\n',
            '            --apple-bundle-id "$APPLE_BUNDLE_ID" || true\n',
        )
        self._assert_rejected(source)

    def test_verifier_must_write_the_exact_evidence_path(self) -> None:
        source = self._replace(
            self._source(),
            '--evidence-output "$PUBLIC_EDGE_EVIDENCE_FILE"',
            '--evidence-output "$RUNNER_TEMP/evidence.json"',
        )
        self._assert_rejected(source)

    def test_verifier_runtime_bindings_cannot_be_removed(self) -> None:
        source = self._source()
        bindings = (
            '--oidc-issuer "$OIDC_ISSUER" \\\n',
            '--oidc-client-id "$OIDC_CLIENT_ID" \\\n',
            '--support-email "$SUPPORT_EMAIL" \\\n',
            '--document-version "$DOCUMENT_VERSION" \\\n',
            '--android-package "$ANDROID_PACKAGE" \\\n',
            '--android-sha256 "$ANDROID_SHA256" \\\n',
            '--apple-team-id "$APPLE_TEAM_ID" \\\n',
        )
        for binding in bindings:
            with self.subTest(binding=binding.strip()):
                changed = self._replace(source, f"            {binding}", "")
                self._assert_rejected(changed)

    def test_verifier_cannot_take_a_dispatch_origin(self) -> None:
        source = self._replace(
            self._source(), '"$SITE_ORIGIN" \\', '"${{ inputs.site_origin }}" \\'
        )
        self._assert_rejected(source)

    def test_prepackage_main_tip_recheck_is_required(self) -> None:
        source = self._replace(
            self._source(),
            'if [[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" || "$(git rev-parse refs/remotes/origin/main)" != "$REQUESTED_REVISION" ]]; then',
            'if [[ "$(git rev-parse HEAD)" != "$REQUESTED_REVISION" ]]; then',
        )
        self._assert_rejected(source)

    def test_prepackage_untracked_file_rejection_is_required(self) -> None:
        source = self._replace(
            self._source(),
            "git status --porcelain --untracked-files=normal",
            "git status --porcelain --untracked-files=no",
        )
        self._assert_rejected(source)

    def test_prepackage_cleanliness_check_cannot_be_inverted(self) -> None:
        source = self._replace(
            self._source(),
            'if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then',
            'if [[ -z "$(git status --porcelain --untracked-files=normal)" ]]; then',
        )
        self._assert_rejected(source)

    def test_expected_failure_evidence_binding_is_required(self) -> None:
        source = self._replace(
            self._source(),
            "failure) evidence_outcome=failed ;;",
            "failure) evidence_outcome=passed ;;",
        )
        self._assert_rejected(source)

    def test_evidence_validator_cannot_be_replaced_by_json_parsing(self) -> None:
        source = self._replace(
            self._source(),
            'python3 scripts/validate_public_edge_evidence.py "$PUBLIC_EDGE_EVIDENCE_FILE"',
            'python3 -m json.tool "$PUBLIC_EDGE_EVIDENCE_FILE"',
        )
        self._assert_rejected(source)

    def test_evidence_validator_cannot_be_hidden_in_heredoc_data(self) -> None:
        source = self._source()
        start = source.index(
            "          python3 scripts/validate_public_edge_evidence.py"
        )
        end = source.index("\n          if [[ ! -s", start)
        changed = (
            source[:start]
            + "          : <<'PAKPERK_DISABLED'\n"
            + source[start:end]
            + "\n          PAKPERK_DISABLED"
            + source[end:]
        )
        self._assert_rejected(changed)

    def test_evidence_validator_cannot_be_short_circuited(self) -> None:
        source = self._replace(
            self._source(),
            "          python3 scripts/validate_public_edge_evidence.py",
            "          true || python3 scripts/validate_public_edge_evidence.py",
        )
        self._assert_rejected(source)

    def test_validator_runtime_binding_cannot_be_removed(self) -> None:
        source = self._source()
        verifier_end = source.index(
            "      - name: Validate and atomically package sanitized technical evidence"
        )
        validator_start = source.index(
            "python3 scripts/validate_public_edge_evidence.py", verifier_end
        )
        old = '            --support-email "$SUPPORT_EMAIL" \\\n'
        location = source.index(old, validator_start)
        changed = source[:location] + source[location + len(old) :]
        self._assert_rejected(changed)

    def test_empty_evidence_acceptance_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '[[ ! -s "$evidence_file" || -L "$evidence_file" ]]',
            '[[ ! -e "$evidence_file" ]]',
        )
        self._assert_rejected(source)

    def test_extra_evidence_files_cannot_be_packaged(self) -> None:
        source = self._replace(
            self._source(),
            '[[ "${#evidence_entries[@]}" -ne 1 || "${evidence_entries[0]}" != "$evidence_file" ]]',
            '[[ "${#evidence_entries[@]}" -lt 1 ]]',
        )
        self._assert_rejected(source)

    def test_closed_evidence_directory_scan_is_required(self) -> None:
        source = self._replace(
            self._source(),
            'find "$evidence_dir" -mindepth 1 -maxdepth 1 -print0',
            'printf "%s\\0" "$evidence_file"',
        )
        self._assert_rejected(source)

    def test_checksum_generation_is_required(self) -> None:
        source = self._replace(
            self._source(),
            "sha256sum -- public-edge-evidence.json >SHA256SUMS",
            "touch SHA256SUMS",
        )
        self._assert_rejected(source)

    def test_checksum_self_check_is_required(self) -> None:
        source = self._replace(
            self._source(), "sha256sum --check --strict SHA256SUMS", "true"
        )
        self._assert_rejected(source)

    def test_commented_checksum_self_check_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "            sha256sum --check --strict SHA256SUMS\n",
            "            # sha256sum --check --strict SHA256SUMS\n",
        )
        self._assert_rejected(source)

    def test_partial_archive_must_not_use_the_upload_path(self) -> None:
        source = self._replace(
            self._source(), '--file "$temporary_archive"', '--file "$archive"'
        )
        self._assert_rejected(source)

    def test_archive_must_be_rooted_in_closed_evidence_directory(self) -> None:
        source = self._replace(
            self._source(), '--directory "$evidence_dir"', '--directory "$RUNNER_TEMP"'
        )
        self._assert_rejected(source)

    def test_atomic_archive_move_is_required(self) -> None:
        source = self._replace(
            self._source(), 'mv -- "$temporary_archive" "$archive"', "true"
        )
        self._assert_rejected(source)

    def test_mutable_upload_action_is_rejected(self) -> None:
        source = self._replace(
            self._source(), validator.UPLOAD_ACTION, "actions/upload-artifact@v7"
        )
        self._assert_rejected(source)

    def test_artifact_name_must_include_exact_source(self) -> None:
        source = self._replace(
            self._source(),
            "-${{ github.sha }}-${{ github.run_id }}",
            "-${{ github.run_id }}",
        )
        self._assert_rejected(source)

    def test_untrusted_source_input_cannot_control_upload_coordinates(self) -> None:
        source = self._replace(
            self._source(),
            "${{ runner.temp }}/pakperk-public-edge-evidence-${{ github.sha }}.tar",
            "${{ runner.temp }}/pakperk-public-edge-evidence-${{ inputs.source_revision }}.tar",
        )
        self._assert_rejected(source)

    def test_broad_artifact_path_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "path: ${{ runner.temp }}/pakperk-public-edge-evidence-${{ github.sha }}.tar",
            "path: ${{ runner.temp }}",
        )
        self._assert_rejected(source)

    def test_hidden_upload_widening_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          if-no-files-found: error\n",
            "          if-no-files-found: error\n"
            "          include-hidden-files: true\n",
        )
        self._assert_rejected(source)

    def test_missing_artifact_warning_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "if-no-files-found: error", "if-no-files-found: warn"
        )
        self._assert_rejected(source)

    def test_unbounded_artifact_retention_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "retention-days: 90", "retention-days: 365"
        )
        self._assert_rejected(source)

    def test_candidate_id_cannot_be_claimed_as_edge_observed(self) -> None:
        source = self._replace(
            self._source(), "is not observed at the edge", "is observed at the edge"
        )
        self._assert_rejected(source)

    def test_telemetry_readiness_cannot_claim_delivery(self) -> None:
        source = self._replace(
            self._source(),
            "endpoint process readiness only, not end-to-end telemetry delivery",
            "end-to-end telemetry delivery",
        )
        self._assert_rejected(source)

    def test_summary_cannot_claim_hosted_environment_protection(self) -> None:
        source = self._replace(
            self._source(), "does not attest GitHub", "attests GitHub"
        )
        self._assert_rejected(source)

    def test_commented_out_evidence_boundary_summary_is_rejected(self) -> None:
        source = self._source()
        start = source.index('          cat >>"$GITHUB_STEP_SUMMARY"')
        end = source.index("\n\n      - name: Upload exact-source", start)
        changed = self._comment_out(source, source[start:end])
        self._assert_rejected(changed)

    def test_final_result_must_enforce_verification(self) -> None:
        source = self._replace(
            self._source(),
            '[[ "$PUBLIC_EDGE_OUTCOME" != "success" || "$EVIDENCE_PACKAGE_OUTCOME" != "success" || "$EVIDENCE_UPLOAD_OUTCOME" != "success" ]]',
            '[[ "$EVIDENCE_PACKAGE_OUTCOME" != "success" || "$EVIDENCE_UPLOAD_OUTCOME" != "success" ]]',
        )
        self._assert_rejected(source)

    def test_final_result_must_enforce_upload(self) -> None:
        source = self._replace(
            self._source(),
            '[[ "$PUBLIC_EDGE_OUTCOME" != "success" || "$EVIDENCE_PACKAGE_OUTCOME" != "success" || "$EVIDENCE_UPLOAD_OUTCOME" != "success" ]]',
            '[[ "$PUBLIC_EDGE_OUTCOME" != "success" || "$EVIDENCE_PACKAGE_OUTCOME" != "success" ]]',
        )
        self._assert_rejected(source)

    def test_final_enforcement_cannot_be_recoverable(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Enforce public-edge verification result\n"
            "        if: always()",
            "      - name: Enforce public-edge verification result\n"
            "        continue-on-error: true\n"
            "        if: always()",
        )
        self._assert_rejected(source)

    def test_duplicate_final_if_cannot_override_always(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Enforce public-edge verification result\n"
            "        if: always()",
            "      - name: Enforce public-edge verification result\n"
            "        if: always()\n"
            "        if: success()",
        )
        self._assert_rejected(source)

    def test_early_success_cannot_bypass_final_enforcement(self) -> None:
        source = self._replace(
            self._source(),
            "        run: |\n" '          if [[ "$PUBLIC_EDGE_OUTCOME" != "success"',
            "        run: |\n"
            "          exit 0\n"
            '          if [[ "$PUBLIC_EDGE_OUTCOME" != "success"',
        )
        self._assert_rejected(source)

    def test_final_enforcement_must_remain_last(self) -> None:
        source = self._source() + "\n      - name: Late bypass\n        run: true\n"
        self._assert_rejected(source)


if __name__ == "__main__":
    unittest.main()
