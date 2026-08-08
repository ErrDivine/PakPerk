#!/usr/bin/env python3
"""Write durable evidence immediately before a signed candidate is uploaded."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys
from typing import Any, Sequence

import validate_mobile_store_candidate as candidate_validator


class UploadAttemptError(ValueError):
    """A closed pre-upload journal failure."""


def _write_exclusive(path: pathlib.Path, raw: bytes) -> None:
    if path.exists() or path.is_symlink():
        raise UploadAttemptError("store upload attempt output already exists")
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise UploadAttemptError("store upload attempt write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o077
    ):
        raise UploadAttemptError("store upload attempt is not owner-only regular storage")


def generate(
    *,
    candidate_path: pathlib.Path,
    artifact_path: pathlib.Path,
    output_path: pathlib.Path,
    platform: str,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    repository: str,
    run_id: str,
    run_attempt: str,
) -> dict[str, Any]:
    for value, pattern, label in (
        (candidate_id, candidate_validator.CONTENT_ID, "candidate ID"),
        (provenance_id, candidate_validator.CONTENT_ID, "provenance ID"),
        (source_revision, candidate_validator.SOURCE_REVISION, "source revision"),
        (app_version, candidate_validator.APP_VERSION, "app version"),
        (build_number, candidate_validator.BUILD_NUMBER, "build number"),
        (run_id, candidate_validator.RUN_ID, "run ID"),
        (run_attempt, candidate_validator.RUN_ATTEMPT, "run attempt"),
    ):
        if type(value) is not str or pattern.fullmatch(value) is None:
            raise UploadAttemptError(f"{label} is invalid")
    if repository != candidate_validator.REPOSITORY:
        raise UploadAttemptError("repository is invalid")
    if platform not in {"android", "ios"}:
        raise UploadAttemptError("store upload platform is invalid")

    try:
        candidate_raw = candidate_validator._read_manifest(
            candidate_path, "candidate manifest"
        )
        candidate = candidate_validator._parse_canonical_json(
            candidate_raw, "candidate manifest"
        )
    except candidate_validator.ValidationError as error:
        raise UploadAttemptError(str(error)) from error
    if not isinstance(candidate, dict):
        raise UploadAttemptError("candidate manifest root must be an object")
    if "sha256:" + hashlib.sha256(candidate_raw).hexdigest() != candidate_id:
        raise UploadAttemptError("candidate content ID does not match")
    if (
        candidate.get("classification") != "protected signed mobile candidate"
        or candidate.get("environment") != "production"
        or candidate.get("source_revision") != source_revision
        or candidate.get("app_version") != app_version
        or candidate.get("build_number") != build_number
        or candidate.get("provenance_id") != provenance_id
    ):
        raise UploadAttemptError("candidate release identity does not match")
    try:
        android, ios = candidate_validator._platforms(candidate, "candidate")
        artifact_sha256, artifact_size = candidate_validator._hash_artifact_evidence(
            artifact_path, f"{platform} upload artifact"
        )
    except candidate_validator.ValidationError as error:
        raise UploadAttemptError(str(error)) from error
    expected_digest = android["aab_sha256"] if platform == "android" else ios["ipa_sha256"]
    if artifact_sha256 != expected_digest:
        raise UploadAttemptError("store upload artifact digest does not match the candidate")

    journal = {
        "application_id": candidate_validator.PRODUCTION_APPLICATION_ID,
        "app_version": app_version,
        "artifact_sha256": artifact_sha256,
        "artifact_size": artifact_size,
        "build_number": build_number,
        "candidate_id": candidate_id,
        "destination": "google_play_internal" if platform == "android" else "app_store_connect",
        "mutation_status": "unknown_reconcile_required",
        "platform": platform,
        "provenance_id": provenance_id,
        "schema": 1,
        "workflow": {
            "github_run_attempt": run_attempt,
            "github_run_id": run_id,
            "path": candidate_validator.WORKFLOW_PATH,
            "repository": repository,
            "source_revision": source_revision,
        },
    }
    output_parent = output_path.parent
    try:
        metadata = output_parent.lstat()
    except OSError as error:
        raise UploadAttemptError("store upload attempt directory is unavailable") from error
    if not stat.S_ISDIR(metadata.st_mode) or output_parent.is_symlink():
        raise UploadAttemptError("store upload attempt directory is not a real directory")
    _write_exclusive(output_path, candidate_validator.canonical_json_bytes(journal))
    return journal


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=pathlib.Path)
    parser.add_argument("--artifact", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    for name in (
        "candidate-id",
        "provenance-id",
        "source-revision",
        "app-version",
        "build-number",
        "repository",
        "run-id",
        "run-attempt",
    ):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    arguments = parser.parse_args(argv)
    try:
        journal = generate(
            candidate_path=arguments.candidate,
            artifact_path=arguments.artifact,
            output_path=arguments.output,
            platform=arguments.platform,
            candidate_id=arguments.candidate_id,
            provenance_id=arguments.provenance_id,
            source_revision=arguments.source_revision,
            app_version=arguments.app_version,
            build_number=arguments.build_number,
            repository=arguments.repository,
            run_id=arguments.run_id,
            run_attempt=arguments.run_attempt,
        )
        if arguments.github_output is not None:
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"artifact_sha256={journal['artifact_sha256']}\n")
                output.write(f"artifact_size={journal['artifact_size']}\n")
    except (OSError, UploadAttemptError) as error:
        print(f"store upload attempt generation failed: {error}", file=sys.stderr)
        return 1
    print("Durable pre-upload store attempt journal created.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
