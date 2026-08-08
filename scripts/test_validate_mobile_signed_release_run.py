#!/usr/bin/env python3
"""Adversarial tests for trusted GitHub signed-release run validation."""

from __future__ import annotations

import copy
import json
import os
import pathlib
import tempfile
import unittest

import validate_mobile_signed_release_run as validator


RUN_ID = "123456789"
RUN_ATTEMPT = 2
SOURCE_REVISION = "a" * 40
APP_VERSION = "1.2.3"
BUILD_NUMBER = "42"


def artifact_name(kind: str) -> str:
    prefix = "pakperk-production"
    if kind == "store_handoff":
        prefix += "-store-handoff"
    elif kind == "signed_release_outcome":
        prefix += "-store-outcome"
    return f"{prefix}-{APP_VERSION}-{BUILD_NUMBER}-{SOURCE_REVISION}-{RUN_ID}-{RUN_ATTEMPT}"


def artifact(identifier: int, kind: str) -> dict[str, object]:
    return {
        "digest": "sha256:" + f"{identifier % 16:x}" * 64,
        "expired": False,
        "id": identifier,
        "name": artifact_name(kind),
        "size_in_bytes": 1024,
        "workflow_run": {
            "head_branch": "main",
            "head_sha": SOURCE_REVISION,
            "id": int(RUN_ID),
        },
    }


def valid_run() -> dict[str, object]:
    return {
        "conclusion": "success",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_repository": {"full_name": validator.REPOSITORY},
        "head_sha": SOURCE_REVISION,
        "id": int(RUN_ID),
        "name": validator.WORKFLOW_NAME,
        "path": f"{validator.WORKFLOW_PATH}@main",
        "repository": {"full_name": validator.REPOSITORY},
        "run_attempt": RUN_ATTEMPT,
        "status": "completed",
    }


def valid_artifacts() -> dict[str, object]:
    values = [
        artifact(1001, "candidate"),
        artifact(1002, "store_handoff"),
        artifact(1003, "signed_release_outcome"),
    ]
    return {"artifacts": values, "total_count": len(values)}


def valid_jobs() -> dict[str, object]:
    jobs = []
    for index, name in enumerate(validator.REQUIRED_JOB_NAMES, start=1):
        jobs.append(
            {
                "conclusion": "success",
                "head_branch": "main",
                "head_sha": SOURCE_REVISION,
                "id": 2000 + index,
                "name": name,
                "run_attempt": RUN_ATTEMPT,
                "run_id": int(RUN_ID),
                "status": "completed",
                "workflow_name": validator.WORKFLOW_NAME,
            }
        )
    return {
        "jobs": jobs,
        "total_count": len(jobs),
    }


class SignedReleaseRunValidationTests(unittest.TestCase):
    def verify(
        self,
        run: dict[str, object] | None = None,
        artifacts: dict[str, object] | None = None,
        jobs: dict[str, object] | None = None,
    ) -> dict[str, object]:
        return validator.verify(
            valid_run() if run is None else run,
            valid_artifacts() if artifacts is None else artifacts,
            valid_jobs() if jobs is None else jobs,
            repository=validator.REPOSITORY,
            run_id=RUN_ID,
            source_revision=SOURCE_REVISION,
            app_version=APP_VERSION,
            build_number=BUILD_NUMBER,
        )

    def test_completed_trusted_run_job_and_artifacts_pass(self) -> None:
        record = self.verify()
        self.assertEqual(str(RUN_ATTEMPT), record["run"]["run_attempt"])
        self.assertEqual("1001", record["artifacts"]["candidate"]["id"])
        self.assertEqual(
            "1003", record["artifacts"]["signed_release_outcome"]["id"]
        )
        validator.validate_verification_record(
            record,
            repository=validator.REPOSITORY,
            run_id=RUN_ID,
            source_revision=SOURCE_REVISION,
            app_version=APP_VERSION,
            build_number=BUILD_NUMBER,
            run_attempt=str(RUN_ATTEMPT),
        )

    def test_exact_plain_workflow_path_from_get_run_api_passes(self) -> None:
        run = valid_run()
        run["path"] = validator.WORKFLOW_PATH
        record = self.verify(run=run)
        self.assertEqual(validator.WORKFLOW_PATH, record["run"]["path"])
        self.assertEqual("main", record["run"]["path_ref"])

    def test_different_workflow_path_is_rejected(self) -> None:
        run = valid_run()
        run["path"] = ".github/workflows/forged.yml@main"
        with self.assertRaisesRegex(validator.RunValidationError, "path"):
            self.verify(run=run)

    def test_untrusted_path_ref_is_rejected(self) -> None:
        run = valid_run()
        run["path"] = f"{validator.WORKFLOW_PATH}@feature"
        with self.assertRaisesRegex(validator.RunValidationError, "path"):
            self.verify(run=run)

    def test_failed_or_incomplete_run_is_rejected(self) -> None:
        for key, value in (("status", "in_progress"), ("conclusion", "failure")):
            with self.subTest(key=key):
                run = valid_run()
                run[key] = value
                with self.assertRaises(validator.RunValidationError):
                    self.verify(run=run)

    def test_wrong_repository_branch_event_or_source_is_rejected(self) -> None:
        mutations = (
            ("repository", {"full_name": "attacker/PakPerk"}),
            ("head_branch", "feature"),
            ("event", "push"),
            ("head_sha", "b" * 40),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                run = valid_run()
                run[key] = value
                with self.assertRaises(validator.RunValidationError):
                    self.verify(run=run)

    def test_job_must_be_exact_successful_run_attempt(self) -> None:
        for key, value in (
            ("name", "forged job"),
            ("run_attempt", 1),
            ("conclusion", "failure"),
        ):
            with self.subTest(key=key):
                jobs = valid_jobs()
                jobs["jobs"][0][key] = value  # type: ignore[index]
                with self.assertRaises(validator.RunValidationError):
                    self.verify(jobs=jobs)

    def test_all_release_boundaries_must_be_exact_and_successful(self) -> None:
        for index, mutation in (
            (0, ("conclusion", "failure")),
            (1, ("name", "production signed candidate")),
            (4, ("status", "skipped")),
            (7, ("conclusion", "failure")),
        ):
            with self.subTest(index=index, mutation=mutation):
                jobs = valid_jobs()
                key, value = mutation
                jobs["jobs"][index][key] = value  # type: ignore[index]
                with self.assertRaises(validator.RunValidationError):
                    self.verify(jobs=jobs)

    def test_duplicate_expected_artifact_is_rejected(self) -> None:
        artifacts = valid_artifacts()
        artifacts["artifacts"].append(copy.deepcopy(artifacts["artifacts"][0]))  # type: ignore[union-attr,index]
        artifacts["total_count"] = 4
        with self.assertRaisesRegex(validator.RunValidationError, "not exact"):
            self.verify(artifacts=artifacts)

    def test_expired_or_digestless_artifact_is_rejected(self) -> None:
        for key, value in (("expired", True), ("digest", None)):
            with self.subTest(key=key):
                artifacts = valid_artifacts()
                artifacts["artifacts"][0][key] = value  # type: ignore[index]
                with self.assertRaises(validator.RunValidationError):
                    self.verify(artifacts=artifacts)

    def test_artifact_must_bind_the_exact_run_and_source(self) -> None:
        artifacts = valid_artifacts()
        artifacts["artifacts"][0]["workflow_run"]["id"] = 999  # type: ignore[index]
        with self.assertRaisesRegex(validator.RunValidationError, "workflow binding"):
            self.verify(artifacts=artifacts)

    def write_private(self, path: pathlib.Path, value: object) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(0o600)

    def test_cli_writes_canonical_owner_only_record_and_safe_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            run_path = root / "run.json"
            artifacts_path = root / "artifacts.json"
            jobs_path = root / "jobs.json"
            output = root / "verified.json"
            github_output = root / "github-output"
            for path, value in (
                (run_path, valid_run()),
                (artifacts_path, valid_artifacts()),
                (jobs_path, valid_jobs()),
            ):
                self.write_private(path, value)
            result = validator.main(
                [
                    "--run-response", str(run_path),
                    "--artifacts-response", str(artifacts_path),
                    "--jobs-response", str(jobs_path),
                    "--output", str(output),
                    "--repository", validator.REPOSITORY,
                    "--run-id", RUN_ID,
                    "--source-revision", SOURCE_REVISION,
                    "--app-version", APP_VERSION,
                    "--build-number", BUILD_NUMBER,
                    "--github-output", str(github_output),
                ]
            )
            self.assertEqual(0, result)
            parsed = json.loads(output.read_text(encoding="ascii"))
            self.assertEqual(validator.canonical_json_bytes(parsed), output.read_bytes())
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
            self.assertEqual(
                "candidate_artifact_id=1001\n"
                "store_handoff_artifact_id=1002\n"
                "signed_release_outcome_artifact_id=1003\n"
                "run_attempt=2\n",
                github_output.read_text(encoding="utf-8"),
            )

    def test_api_reader_rejects_duplicate_keys_and_loose_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            duplicate = root / "duplicate.json"
            duplicate.write_text('{"id":1,"id":2}', encoding="ascii")
            duplicate.chmod(0o600)
            with self.assertRaisesRegex(validator.RunValidationError, "duplicate key"):
                validator._read_json(duplicate, "test response")
            loose = root / "loose.json"
            loose.write_text("{}", encoding="ascii")
            loose.chmod(0o644)
            with self.assertRaisesRegex(validator.RunValidationError, "owner-only"):
                validator._read_json(loose, "test response")


if __name__ == "__main__":
    unittest.main()
