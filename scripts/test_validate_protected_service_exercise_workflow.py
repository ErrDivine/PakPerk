#!/usr/bin/env python3
"""Focused tamper tests for the protected service-exercise workflow."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_protected_service_exercise_workflow as validator


SOURCE = validator.WORKFLOW.read_text(encoding="ascii")


class ProtectedServiceWorkflowTests(unittest.TestCase):
    def validate_source(self, source: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "protected-service-exercise.yml"
            path.write_text(source, encoding="ascii")
            validator.validate(path)

    def assert_tamper_rejected(self, original: str, replacement: str) -> None:
        self.assertIn(original, SOURCE)
        with self.assertRaises(RuntimeError):
            self.validate_source(SOURCE.replace(original, replacement, 1))

    def test_checked_in_workflow_passes(self) -> None:
        validator.validate()

    def test_trigger_permissions_environment_and_action_tampers_fail(self) -> None:
        cases = (
            ("  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n"),
            ("  contents: read\n", "  contents: write\n"),
            (
                "    environment: protected-staging-service-exercise\n",
                "    environment: unprotected-staging\n",
            ),
            (validator.CHECKOUT_ACTION, "actions/checkout@v7"),
            ("          persist-credentials: false\n", "          persist-credentials: true\n"),
        )
        for original, replacement in cases:
            with self.subTest(replacement=replacement):
                self.assert_tamper_rejected(original, replacement)

    def test_exact_main_and_protected_digest_tampers_fail(self) -> None:
        cases = (
            (
                '[[ "$REQUESTED_REVISION" != "$DISPATCH_REVISION" ]]',
                '[[ "$REQUESTED_REVISION" != "$REQUESTED_REVISION" ]]',
            ),
            (
                '$(/usr/bin/git rev-parse refs/remotes/origin/main)',
                '$(/usr/bin/git rev-parse HEAD)',
            ),
            (
                "      WORKFLOW_SHA256: ${{ vars.PAKPERK_PROTECTED_SERVICE_WORKFLOW_SHA256 }}\n",
                "      WORKFLOW_SHA256: ${{ inputs.source_revision }}\n",
            ),
            (
                f"      DRIVER_REQUEST_CONTRACT_SHA256: {validator.DRIVER_REQUEST_CONTRACT_SHA256}\n",
                "      DRIVER_REQUEST_CONTRACT_SHA256: sha256:" + "0" * 64 + "\n",
            ),
            ('"assertion_count": 29', '"assertion_count": 28'),
        )
        for original, replacement in cases:
            with self.subTest(replacement=replacement):
                self.assert_tamper_rejected(original, replacement)

    def test_secret_or_candidate_execution_boundary_tamper_fails(self) -> None:
        self.assert_tamper_rejected(
            "          RUN_CHALLENGE: ${{ steps.source.outputs.challenge }}\n",
            "          CLUSTER_TOKEN: ${{ secrets.CLUSTER_TOKEN }}\n"
            "          RUN_CHALLENGE: ${{ steps.source.outputs.challenge }}\n",
        )
        self.assert_tamper_rejected(
            "          exec /usr/bin/env -i \\\n",
            "          python3 scripts/unreviewed_cluster_driver.py\n"
            "          exec /usr/bin/env -i \\\n",
        )
        self.assert_tamper_rejected(
            "/opt/pakperk/bin/pakperk-protected-service-exercise-driver run",
            "/tmp/pakperk-protected-service-exercise-driver run",
        )

    def test_runner_session_import_cannot_be_bypassed(self) -> None:
        cases = (
            (
                "/opt/pakperk/protected-service-runner-sessions/${runner_session_digest}.json",
                "/tmp/${runner_session_digest}.json",
            ),
            ("            validate-session \\\n", "            validate \\\n"),
            (
                '--source-revision "$REQUESTED_REVISION"',
                '--source-revision "$DISPATCH_REVISION"',
            ),
        )
        for original, replacement in cases:
            with self.subTest(replacement=replacement):
                self.assert_tamper_rejected(original, replacement)

    def test_validation_and_upload_cannot_be_bypassed(self) -> None:
        cases = (
            (
                "        if: steps.exercise.outcome == 'success'\n",
                "        if: always()\n",
            ),
            (
                "        if: steps.evidence.outcome == 'success'\n",
                "        if: always()\n",
            ),
            (
                '--workflow-sha256 "sha256:$WORKFLOW_SHA256"',
                '--workflow-sha256 "sha256:$DRIVER_SHA256"',
            ),
            (validator.UPLOAD_ACTION, "actions/upload-artifact@main"),
        )
        for original, replacement in cases:
            with self.subTest(replacement=replacement):
                self.assert_tamper_rejected(original, replacement)

    def test_unreviewed_byte_change_is_rejected(self) -> None:
        self.assert_tamper_rejected(
            "name: protected service exercise\n",
            "name: protected service exercise\n# unreviewed change\n",
        )


if __name__ == "__main__":
    unittest.main()
