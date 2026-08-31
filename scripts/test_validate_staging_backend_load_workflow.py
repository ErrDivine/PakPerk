#!/usr/bin/env python3
"""Tamper regressions for the protected staging backend-load workflow."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_staging_backend_load_workflow as validator


class StagingBackendLoadWorkflowTests(unittest.TestCase):
    def _source(self) -> str:
        return validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8")

    def _replace(self, source: str, old: str, new: str) -> str:
        self.assertIn(old, source)
        return source.replace(old, new, 1)

    def _comment_out(self, source: str, block: str) -> str:
        commented = "".join(
            f"{line[: len(line) - len(line.lstrip())]}# {line.lstrip()}"
            for line in block.splitlines(keepends=True)
        )
        return self._replace(source, block, commented)

    def _validate(
        self,
        source: str,
        *,
        ci_source: str | None = None,
        check_source: str | None = None,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            workflow = root / "staging-backend-load.yml"
            ci = root / "ci.yml"
            check = root / "check.sh"
            workflow.write_text(source, encoding="utf-8")
            ci.write_text(
                (
                    ci_source
                    if ci_source is not None
                    else validator.DEFAULT_CI.read_text(encoding="utf-8")
                ),
                encoding="utf-8",
            )
            check.write_text(
                (
                    check_source
                    if check_source is not None
                    else validator.DEFAULT_CHECK.read_text(encoding="utf-8")
                ),
                encoding="utf-8",
            )
            validator.validate(workflow, ci, check)

    def _assert_rejected(self, source: str, **kwargs: str) -> None:
        with self.assertRaises(RuntimeError):
            self._validate(source, **kwargs)

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_automatic_trigger_is_rejected(self) -> None:
        source = self._replace(
            self._source(), "  workflow_dispatch:\n", "  push:\n  workflow_dispatch:\n"
        )
        self._assert_rejected(source)

    def test_quoted_automatic_trigger_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "  workflow_dispatch:\n",
            '  workflow_dispatch:\n  "push": {}\n',
        )
        self._assert_rejected(source)

    def test_unexpected_dispatch_input_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      source_revision:\n",
            "      unsafe_origin:\n"
            "        required: true\n"
            "        type: string\n"
            "      source_revision:\n",
        )
        self._assert_rejected(source)

    def test_dispatch_bounds_cannot_be_widened(self) -> None:
        source = self._replace(
            self._source(),
            '        options: ["30", "60", "120", "300"]',
            '        options: ["30", "60", "120", "300", "3600"]',
        )
        self._assert_rejected(source)

    def test_runtime_choice_allowlists_cannot_be_widened(self) -> None:
        for original, replacement in (
            ("30|60|120|300) ;;", "30|60|120|300|3600) ;;"),
            ("1|4|8|16) ;;", "1|4|8|16|64) ;;"),
            ("1000|5000|10000|25000) ;;", "1000|5000|10000|25000|100000) ;;"),
            ("5|10|20) ;;", "5|10|20|100) ;;"),
            ("0|100|250|500) ;;", "0|100|250|500|5000) ;;"),
            ("0|0.01|0.05) ;;", "0|0.01|0.05|1) ;;"),
        ):
            with self.subTest(original=original):
                self._assert_rejected(
                    self._replace(self._source(), original, replacement)
                )

    def test_boolean_dispatch_inputs_are_runtime_allowlisted(self) -> None:
        source = self._replace(
            self._source(), "true|false) ;;", "true|false|anything) ;;"
        )
        self._assert_rejected(source)

    def test_numeric_allowlists_must_precede_arithmetic(self) -> None:
        source = self._replace(
            self._source(),
            '          case "$MAX_MUTATIONS" in\n',
            '          case "20" in\n',
        )
        self._assert_rejected(source)

    def test_paper_import_cap_allowlist_must_precede_arithmetic(self) -> None:
        source = self._replace(
            self._source(),
            '          case "$MAX_IMPORT_REQUESTS" in\n',
            '          case "20" in\n',
        )
        self._assert_rejected(source)

    def test_paper_import_cap_cannot_consume_the_preflight_reserve(self) -> None:
        source = self._replace(
            self._source(),
            '          case "$MAX_IMPORT_REQUESTS" in\n            5|10) ;;',
            '          case "$MAX_IMPORT_REQUESTS" in\n            5|10|20) ;;',
        )
        self._assert_rejected(source)

    def test_paper_search_cap_cannot_consume_the_account_quota(self) -> None:
        source = self._replace(
            self._source(),
            "            --max-paper-search-requests 9\n",
            "            --max-paper-search-requests 10\n",
        )
        self._assert_rejected(source)

    def test_paper_import_confirmation_cannot_be_weakened(self) -> None:
        source = self._replace(
            self._source(),
            '"RUN_DEDICATED_STAGING_PAPER_IMPORT_REPLAYS"',
            '""',
        )
        self._assert_rejected(source)

    def test_optional_source_revision_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "      source_revision:\n"
            "        description: Reviewed full commit SHA reachable from main\n"
            "        required: true",
            "      source_revision:\n"
            "        description: Reviewed full commit SHA reachable from main\n"
            "        required: false",
        )
        self._assert_rejected(source)

    def test_write_permission_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(self._source(), "contents: read", "contents: write")
        )

    def test_cancelling_an_inflight_gate_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), "cancel-in-progress: false", "cancel-in-progress: true"
            )
        )

    def test_cross_workflow_concurrency_widening_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                "group: staging-backend-load",
                "group: staging-backend-${{ inputs.evidence_id }}",
            )
        )

    def test_job_level_main_guard_is_rejected_as_fail_open(self) -> None:
        source = self._replace(
            self._source(),
            "  load-gate:\n    runs-on: ubuntu-24.04",
            "  load-gate:\n"
            "    if: github.ref == 'refs/heads/main'\n"
            "    runs-on: ubuntu-24.04",
        )
        self._assert_rejected(source)

    def test_job_level_continue_on_error_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "  load-gate:\n    runs-on: ubuntu-24.04",
            "  load-gate:\n"
            "    continue-on-error: true\n"
            "    runs-on: ubuntu-24.04",
        )
        self._assert_rejected(source)

    def test_trailing_job_level_if_is_rejected(self) -> None:
        self._assert_rejected(self._source() + "    if: false\n")

    def test_quoted_sibling_job_is_rejected(self) -> None:
        source = self._source() + (
            '  "bypass":\n'
            "    runs-on: ubuntu-24.04\n"
            "    steps:\n"
            '      - run: "true"\n'
        )
        self._assert_rejected(source)

    def test_executable_step_before_source_trust_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          persist-credentials: false\n\n"
            "      - name: Verify reviewed source and protected inputs",
            "          persist-credentials: false\n\n"
            "      - run: echo bypass\n\n"
            "      - name: Verify reviewed source and protected inputs",
        )
        self._assert_rejected(source)

    def test_bare_sequence_step_before_source_trust_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "    steps:\n",
            "    steps:\n      -\n        run: echo bypass\n",
        )
        self._assert_rejected(source)

    def test_runner_image_is_exact(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), "runs-on: ubuntu-24.04", "runs-on: ubuntu-latest"
            )
        )

    def test_timeout_is_bounded(self) -> None:
        self._assert_rejected(
            self._replace(self._source(), "timeout-minutes: 15", "timeout-minutes: 150")
        )

    def test_protected_environment_is_exact(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), "environment: staging", "environment: production"
            )
        )

    def test_extra_job_is_rejected(self) -> None:
        self._assert_rejected(
            self._source() + "\n  bypass_job:\n    runs-on: ubuntu-latest\n"
        )

    def test_mutable_checkout_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), "ref: ${{ inputs.source_revision }}", "ref: main"
            )
        )

    def test_shallow_checkout_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(self._source(), "fetch-depth: 0", "fetch-depth: 1")
        )

    def test_checkout_credentials_cannot_persist(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                "persist-credentials: false",
                "persist-credentials: true",
            )
        )

    def test_quoted_checkout_key_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "        with:\n",
            '        "uses": attacker/execute@deadbeef\n        with:\n',
        )
        self._assert_rejected(source)

    def test_mutable_checkout_action_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), validator.CHECKOUT_ACTION, "actions/checkout@v7"
            )
        )

    def test_dispatch_ref_context_binding_is_required(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                "DISPATCH_REF: ${{ github.ref }}",
                "DISPATCH_REF: refs/heads/main",
            )
        )

    def test_non_main_dispatch_guard_cannot_be_weakened(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                'if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
                'if [[ -z "$DISPATCH_REF" ]]; then',
            )
        )

    def test_commented_out_non_main_dispatch_guard_is_rejected(self) -> None:
        block = (
            '          if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then\n'
            '            echo "Staging backend load verification must be dispatched from main." >&2\n'
            "            exit 2\n"
            "          fi\n"
        )
        self._assert_rejected(self._comment_out(self._source(), block))

    def test_short_circuited_non_main_dispatch_guard_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            'if [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
            'if false && [[ "$DISPATCH_REF" != "refs/heads/main" ]]; then',
        )
        self._assert_rejected(source)

    def test_dead_code_non_main_dispatch_guard_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            '        run: |\n          if [[ "$DISPATCH_REF"',
            "        run: |\n"
            "          if false; then\n"
            '          if [[ "$DISPATCH_REF"',
        )
        source = self._replace(
            source,
            "          fi\n"
            '          if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
            "          fi\n"
            "          fi\n"
            '          if ! [[ "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then',
        )
        self._assert_rejected(source)

    def test_dispatch_controlled_protected_origin_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                "STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}",
                "STAGING_API_ORIGIN: ${{ inputs.staging_api_origin }}",
            )
        )

    def test_secret_cannot_leak_into_job_environment(self) -> None:
        source = self._replace(
            self._source(),
            "      STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}\n",
            "      STAGING_LOAD_TOKEN: ${{ secrets.PAKPERK_STAGING_LOAD_TOKEN }}\n"
            "      STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}\n",
        )
        source = self._replace(
            source,
            "        env:\n"
            "          STAGING_LOAD_TOKEN: ${{ secrets.PAKPERK_STAGING_LOAD_TOKEN }}\n",
            "",
        )
        self._assert_rejected(source)

    def test_unreviewed_secret_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          STAGING_LOAD_TOKEN: ${{ secrets.PAKPERK_STAGING_LOAD_TOKEN }}\n",
            "          STAGING_LOAD_TOKEN: ${{ secrets.UNREVIEWED_TOKEN }}\n",
        )
        self._assert_rejected(source)

    def test_reading_feed_fixtures_cannot_share_a_token(self) -> None:
        source = self._replace(
            self._source(),
            "          STAGING_READING_RECOMMENDATION_TOKEN: "
            "${{ secrets.PAKPERK_STAGING_LOAD_READING_RECOMMENDATION_TOKEN }}\n",
            "          STAGING_READING_RECOMMENDATION_TOKEN: "
            "${{ secrets.PAKPERK_STAGING_LOAD_READING_QUEUE_TOKEN }}\n",
        )
        self._assert_rejected(source)

    def test_private_search_query_cannot_move_to_job_environment(self) -> None:
        source = self._replace(
            self._source(),
            "      STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}\n",
            "      STAGING_PAPER_SEARCH_QUERY: "
            "${{ secrets.PAKPERK_STAGING_LOAD_PAPER_SEARCH_QUERY }}\n"
            "      STAGING_API_ORIGIN: ${{ vars.PAKPERK_STAGING_API_ORIGIN }}\n",
        )
        self._assert_rejected(source)

    def test_runner_failure_masking_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            'python3 scripts/run_backend_load.py "${arguments[@]}"',
            'python3 scripts/run_backend_load.py "${arguments[@]}" || true',
        )
        self._assert_rejected(source)

    def test_runner_cannot_be_hidden_in_heredoc_data(self) -> None:
        source = self._replace(
            self._source(),
            '          python3 scripts/run_backend_load.py "${arguments[@]}"\n',
            "          : <<'PAKPERK_DISABLED'\n"
            '          python3 scripts/run_backend_load.py "${arguments[@]}"\n'
            "          PAKPERK_DISABLED\n",
        )
        self._assert_rejected(source)

    def test_runner_bounds_cannot_be_removed(self) -> None:
        source = self._replace(
            self._source(), "            --request-timeout-seconds 5\n", ""
        )
        self._assert_rejected(source)

    def test_private_token_mode_is_required(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), 'chmod 0600 "$token_file"', 'chmod 0644 "$token_file"'
            )
        )

    def test_token_cleanup_trap_is_required(self) -> None:
        source = self._replace(
            self._source(),
            'trap \'for private_file in "$token_file" "$queue_token_file" '
            '"$recommendation_token_file" "$search_query_file" '
            '"$import_source_file"; do if [[ -f "$private_file" ]]; then '
            'chmod u+w "$private_file"; rm -f "$private_file"; fi; done\' EXIT',
            "trap true EXIT",
        )
        self._assert_rejected(source)

    def test_upload_must_always_run(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Upload redacted staging evidence\n        if: always()",
            "      - name: Upload redacted staging evidence\n        if: success()",
        )
        self._assert_rejected(source)

    def test_missing_artifact_warning_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), "if-no-files-found: error", "if-no-files-found: warn"
            )
        )

    def test_broad_artifact_path_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(),
                "path: ${{ runner.temp }}/pakperk-backend-load-evidence.tar",
                "path: ${{ runner.temp }}",
            )
        )

    def test_hidden_file_upload_widening_is_rejected(self) -> None:
        source = self._replace(
            self._source(),
            "          if-no-files-found: error\n",
            "          if-no-files-found: error\n          include-hidden-files: true\n",
        )
        self._assert_rejected(source)

    def test_artifact_retention_is_bounded(self) -> None:
        self._assert_rejected(
            self._replace(self._source(), "retention-days: 90", "retention-days: 365")
        )

    def test_mutable_upload_action_is_rejected(self) -> None:
        self._assert_rejected(
            self._replace(
                self._source(), validator.UPLOAD_ACTION, "actions/upload-artifact@v7"
            )
        )

    def test_final_enforcement_cannot_be_removed(self) -> None:
        source = self._source()
        marker = "      - name: Enforce staging load result\n"
        source = source[: source.index(marker)]
        self._assert_rejected(source)

    def test_final_enforcement_must_always_run(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Enforce staging load result\n        if: always()",
            "      - name: Enforce staging load result\n        if: success()",
        )
        self._assert_rejected(source)

    def test_final_enforcement_cannot_be_recoverable(self) -> None:
        source = self._replace(
            self._source(),
            "      - name: Enforce staging load result\n        if: always()",
            "      - name: Enforce staging load result\n"
            "        continue-on-error: true\n"
            "        if: always()",
        )
        self._assert_rejected(source)

    def test_final_enforcement_cannot_be_short_circuited(self) -> None:
        source = self._replace(
            self._source(),
            '        run: |\n          if [[ "$LOAD_OUTCOME" != "success" ]]; then',
            "        run: |\n"
            "          exit 0\n"
            '          if [[ "$LOAD_OUTCOME" != "success" ]]; then',
        )
        self._assert_rejected(source)

    def test_final_enforcement_must_remain_last(self) -> None:
        source = self._source() + "\n      - name: Late bypass\n        run: true\n"
        self._assert_rejected(source)

    def test_ci_wiring_is_mandatory(self) -> None:
        ci_source = validator.DEFAULT_CI.read_text(encoding="utf-8").replace(
            "          python3 scripts/test_validate_staging_backend_load_workflow.py\n",
            "",
            1,
        )
        self._assert_rejected(self._source(), ci_source=ci_source)

    def test_commented_ci_wiring_is_rejected(self) -> None:
        ci_source = validator.DEFAULT_CI.read_text(encoding="utf-8").replace(
            "          python3 scripts/validate_staging_backend_load_workflow.py\n",
            "          # python3 scripts/validate_staging_backend_load_workflow.py\n",
            1,
        )
        self._assert_rejected(self._source(), ci_source=ci_source)

    def test_local_check_wiring_is_mandatory(self) -> None:
        check_source = validator.DEFAULT_CHECK.read_text(encoding="utf-8").replace(
            'python3 "$project_dir/scripts/validate_staging_backend_load_workflow.py"\n',
            "",
            1,
        )
        self._assert_rejected(self._source(), check_source=check_source)

    def test_short_circuited_local_check_wiring_is_rejected(self) -> None:
        check_source = validator.DEFAULT_CHECK.read_text(encoding="utf-8").replace(
            'python3 "$project_dir/scripts/test_validate_staging_backend_load_workflow.py"\n',
            'true || python3 "$project_dir/scripts/test_validate_staging_backend_load_workflow.py"\n',
            1,
        )
        self._assert_rejected(self._source(), check_source=check_source)


if __name__ == "__main__":
    unittest.main()
