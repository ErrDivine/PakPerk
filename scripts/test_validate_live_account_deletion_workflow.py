#!/usr/bin/env python3
"""Tamper regressions for the live account-deletion dependency lock."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import validate_live_account_deletion_workflow as validator


class LiveDeletionWorkflowTests(unittest.TestCase):
    def _validate(
        self,
        requirements_source: str,
        workflow_source: str,
        compose_source: str | None = None,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            requirements = root / "requirements.txt"
            workflow = root / "workflow.yml"
            compose = root / "docker-compose.yml"
            requirements.write_text(requirements_source, encoding="utf-8")
            workflow.write_text(workflow_source, encoding="utf-8")
            compose.write_text(
                compose_source
                if compose_source is not None
                else validator.DEFAULT_COMPOSE.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            validator.validate(requirements, workflow, compose)

    def test_checked_in_contract_passes(self) -> None:
        validator.validate()

    def test_missing_hash_fails(self) -> None:
        requirements = validator.DEFAULT_REQUIREMENTS.read_text(encoding="utf-8")
        requirements = requirements.replace(
            "requests==2.32.4 --hash=sha256:", "requests==2.32.4 # sha256:", 1
        )
        with self.assertRaisesRegex(RuntimeError, "not one exact pin/hash"):
            self._validate(
                requirements,
                validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8"),
            )

    def test_direct_install_bypass_fails(self) -> None:
        workflow = validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8").replace(
            "--requirement scripts/requirements/live-account-deletion.txt",
            "requests==2.32.4",
            1,
        )
        with self.assertRaisesRegex(RuntimeError, "missing: --requirement"):
            self._validate(
                validator.DEFAULT_REQUIREMENTS.read_text(encoding="utf-8"), workflow
            )

    def test_mutable_compose_image_fails(self) -> None:
        compose = validator.DEFAULT_COMPOSE.read_text(encoding="utf-8").replace(
            validator.EXPECTED_COMPOSE_IMAGES["mailpit"],
            "axllent/mailpit:v1.30.6",
            1,
        )
        with self.assertRaisesRegex(
            RuntimeError, "Compose service mailpit must use the reviewed tag and digest"
        ):
            self._validate(
                validator.DEFAULT_REQUIREMENTS.read_text(encoding="utf-8"),
                validator.DEFAULT_WORKFLOW.read_text(encoding="utf-8"),
                compose,
            )


if __name__ == "__main__":
    unittest.main()
