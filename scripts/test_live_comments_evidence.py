#!/usr/bin/env python3
"""Hermetic regressions for the retained live-comments evidence contract."""

from __future__ import annotations

import ast
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from live_comments_evidence import (
    CLEANUP_SCENARIO_ID,
    CONTENT_ID,
    DATABASE_MIGRATION_VERSION,
    MANUAL_CI_ENVIRONMENT,
    RUNTIME_SCENARIO_IDS,
    SCENARIO_IDS,
    STATE_SCHEMA_VERSION,
    EvidenceError,
    build_evidence,
    initial_scenario_state,
    read_evidence,
    validate_evidence,
    write_evidence,
)


SOURCE_REVISION = "a" * 40
UGC_SENTINEL = "private report detail that must never be retained"
TOKEN_SENTINEL = "eyJhbGciOiJSUzI1NiJ9.private.signature-material"
SUBJECT_SENTINEL = "00000000-0000-4000-8000-000000000123"
EMAIL_SENTINEL = "private-user@pakperk.test"


def completed_state() -> dict[str, object]:
    return {
        "schema_version": STATE_SCHEMA_VERSION,
        "acceptance_outcome": "passed",
        "cleaned": True,
        "scenarios": {scenario_id: "passed" for scenario_id in SCENARIO_IDS},
        # The private cleanup state contains runtime values. The evidence
        # builder must select no value from these fields.
        "comment_ids": [SUBJECT_SENTINEL],
        "keycloak_user_ids": [SUBJECT_SENTINEL],
        "local_user_ids": [SUBJECT_SENTINEL],
        "paper_id": SUBJECT_SENTINEL,
        "ugc": UGC_SENTINEL,
        "token": TOKEN_SENTINEL,
        "email": EMAIL_SENTINEL,
    }


class LiveCommentsEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)

    def test_passed_evidence_is_closed_self_addressed_and_secret_free(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        validated = validate_evidence(
            evidence,
            source_revision=SOURCE_REVISION,
            expected_outcome="passed",
            environment=MANUAL_CI_ENVIRONMENT,
        )
        serialized = json.dumps(validated, sort_keys=True)
        self.assertRegex(validated["content_id"], CONTENT_ID)
        self.assertFalse(validated["content_id"].startswith("sha256:"))
        self.assertEqual(
            [item["id"] for item in validated["scenarios"]], list(SCENARIO_IDS)
        )
        scenario_ids = {item["id"] for item in validated["scenarios"]}
        self.assertTrue(
            {
                "admin_oidc_pkce_dedicated_audience_rejected_by_api",
                "admin_rejects_mobile_audience_token",
                "admin_rejects_nonallowlisted_admin_audience_identity",
                "comment_report_canonical_replay",
                "user_report_canonical_replay_without_implicit_block",
                "user_block_cross_process_filter_and_unblock",
                "captured_api_logs_exclude_ugc_headers_tokens_subjects_and_emails",
                "disposable_provider_database_and_rate_limit_state_removed",
            }.issubset(scenario_ids)
        )
        for forbidden in (
            UGC_SENTINEL,
            TOKEN_SENTINEL,
            SUBJECT_SENTINEL,
            EMAIL_SENTINEL,
        ):
            self.assertNotIn(forbidden, serialized)

    def test_evidence_rejects_a_hosted_protection_claim(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        evidence["classification"]["environment"] = (
            "protected_ci_disposable_reference"
        )
        with self.assertRaisesRegex(EvidenceError, "environment classification"):
            validate_evidence(evidence)

    def test_evidence_migration_version_matches_latest_embedded_migration(self) -> None:
        migrations = Path(__file__).resolve().parents[1] / "backend/migrations"
        versions = [
            int(path.name.split("_", 1)[0])
            for path in migrations.glob("[0-9][0-9][0-9][0-9]_*.sql")
        ]
        self.assertTrue(versions)
        self.assertEqual(max(versions), DATABASE_MIGRATION_VERSION)

    def test_driver_records_every_runtime_scenario_and_has_no_duplicate_dict_keys(self) -> None:
        driver = Path(__file__).with_name("test_live_comments.py")
        tree = ast.parse(driver.read_text(encoding="utf-8"), filename=str(driver))
        recorded: list[str] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                if node.func.id == "record_scenario_pass" and len(node.args) >= 2:
                    scenario = node.args[1]
                    if isinstance(scenario, ast.Constant) and isinstance(
                        scenario.value, str
                    ):
                        recorded.append(scenario.value)
            if isinstance(node, ast.Dict):
                constant_keys = [
                    key.value
                    for key in node.keys
                    if isinstance(key, ast.Constant) and isinstance(key.value, str)
                ]
                self.assertEqual(
                    len(constant_keys),
                    len(set(constant_keys)),
                    f"duplicate literal dictionary key at line {node.lineno}",
                )
        self.assertCountEqual(recorded, RUNTIME_SCENARIO_IDS)

    def test_shell_rechecks_exact_clean_source_after_cleanup_before_evidence(self) -> None:
        shell_path = Path(__file__).with_name("test_live_comments.sh")
        source = shell_path.read_text(encoding="utf-8")
        helper_start = source.index("verify_evidence_source() {")
        helper_end = source.index("\n}\n", helper_start)
        helper = source[helper_start:helper_end]
        self.assertIn('git -C "$project_dir" rev-parse HEAD', helper)
        self.assertIn(
            'git -C "$project_dir" status --porcelain --untracked-files=normal',
            helper,
        )
        self.assertEqual(source.count("if ! verify_evidence_source; then"), 2)

        cleanup = source[source.index("cleanup() {") : source.index("\ntrap cleanup")]
        state_cleanup = cleanup.index(
            'python3 "$project_dir/scripts/test_live_comments.py" cleanup'
        )
        private_fixture_cleanup = cleanup.index('if ! rm -f \\\n')
        final_source_check = cleanup.index("if ! verify_evidence_source; then")
        evidence_write = cleanup.index(
            'python3 "$project_dir/scripts/test_live_comments.py" evidence'
        )
        self.assertLess(state_cleanup, private_fixture_cleanup)
        self.assertLess(private_fixture_cleanup, final_source_check)
        self.assertLess(final_source_check, evidence_write)

        driver = Path(__file__).with_name("test_live_comments.py").read_text(
            encoding="utf-8"
        )
        emit = driver[driver.index("def emit_evidence()") : driver.index("\ndef parse_args")]
        source_recheck = emit.index("assert_evidence_source_unchanged()")
        evidence_build = emit.index("evidence = build_evidence(")
        evidence_write = emit.index("write_evidence(EVIDENCE_FILE, evidence)")
        self.assertLess(source_recheck, evidence_build)
        self.assertLess(evidence_build, evidence_write)

    def test_failed_evidence_records_one_failure_and_cannot_validate_as_passed(self) -> None:
        state = completed_state()
        statuses = initial_scenario_state()
        failure_index = 7
        for scenario_id in RUNTIME_SCENARIO_IDS[:failure_index]:
            statuses[scenario_id] = "passed"
        statuses[RUNTIME_SCENARIO_IDS[failure_index]] = "failed"
        statuses[CLEANUP_SCENARIO_ID] = "passed"
        state["scenarios"] = statuses
        state["acceptance_outcome"] = "failed"
        evidence = build_evidence(
            state,
            SOURCE_REVISION,
            MANUAL_CI_ENVIRONMENT,
            expected_outcome="failed",
        )
        validate_evidence(evidence, expected_outcome="failed")
        with self.assertRaises(EvidenceError):
            validate_evidence(evidence, expected_outcome="passed")
        with self.assertRaises(EvidenceError):
            build_evidence(
                state,
                SOURCE_REVISION,
                MANUAL_CI_ENVIRONMENT,
                expected_outcome="passed",
            )

    def test_extra_fields_and_content_id_tampering_fail_closed(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        extra = copy.deepcopy(evidence)
        extra["operator_email"] = EMAIL_SENTINEL
        with self.assertRaises(EvidenceError):
            validate_evidence(extra)
        tampered = copy.deepcopy(evidence)
        tampered["run"]["outcome"] = "failed"
        with self.assertRaises(EvidenceError):
            validate_evidence(tampered)

    def test_invalid_failed_sequence_is_rejected(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        evidence["run"]["outcome"] = "failed"
        evidence["scenarios"][3]["outcome"] = "failed"
        evidence["scenarios"][5]["outcome"] = "failed"
        with self.assertRaises(EvidenceError):
            validate_evidence(evidence)

    def test_owner_only_writer_and_cli_validator(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        path = self.directory / "live-comments-evidence.json"
        write_evidence(path, evidence)
        self.assertEqual(path.stat().st_mode & 0o777, 0o400)
        self.assertEqual(read_evidence(path), evidence)

        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("validate_live_comments_evidence.py")),
                str(path),
                "--source-revision",
                SOURCE_REVISION,
                "--environment",
                MANUAL_CI_ENVIRONMENT,
                "--expected-outcome",
                "passed",
            ],
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(EvidenceError):
            write_evidence(path, evidence)

    def test_reader_rejects_symlink_and_broad_permissions(self) -> None:
        evidence = build_evidence(
            completed_state(), SOURCE_REVISION, MANUAL_CI_ENVIRONMENT
        )
        target = self.directory / "target.json"
        write_evidence(target, evidence)
        broad = self.directory / "broad.json"
        broad.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        broad.chmod(0o644)
        with self.assertRaises(EvidenceError):
            read_evidence(broad)
        link = self.directory / "link.json"
        link.symlink_to(target)
        with self.assertRaises(EvidenceError):
            read_evidence(link)

        broad_directory = self.directory / "broad-directory"
        broad_directory.mkdir(mode=0o755)
        broad_directory.chmod(0o755)
        with self.assertRaises(EvidenceError):
            write_evidence(broad_directory / "evidence.json", evidence)


if __name__ == "__main__":
    unittest.main()
