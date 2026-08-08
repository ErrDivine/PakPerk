#!/usr/bin/env python3
"""Authenticate a signed-mobile release run and its immutable artifacts."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any, Sequence


REPOSITORY = "ErrDivine/PakPerk"
WORKFLOW_PATH = ".github/workflows/mobile-release.yml"
WORKFLOW_NAME = "signed-mobile-release"
JOB_NAME = "production signed candidate"
REQUIRED_JOB_NAMES = (
    "production credential-free candidate preparation",
    "production isolated Android signed candidate",
    "production isolated iOS signed candidate",
    JOB_NAME,
    "isolated store-client bootstrap",
    "production isolated Android store upload",
    "production isolated iOS store upload",
    "production signed release finalizer",
)
MAXIMUM_API_BYTES = 1024 * 1024
MAXIMUM_ARTIFACT_BYTES = 16 * 1024**3
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
RUN_ID = re.compile(r"[1-9][0-9]{0,19}")
RUN_ATTEMPT = re.compile(r"[1-9][0-9]{0,9}")
APP_VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?"
)
BUILD_NUMBER = re.compile(r"[1-9][0-9]{0,9}")
ARTIFACT_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


class RunValidationError(ValueError):
    """A fail-closed error that never reflects API or dispatch values."""


def canonical_json_bytes(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise RunValidationError("trusted run verification is not canonicalizable") from error
    return (encoded + "\n").encode("ascii")


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RunValidationError("GitHub API JSON contains a duplicate key")
        result[key] = value
    return result


def _reject_nonfinite(_value: str) -> None:
    raise RunValidationError("GitHub API JSON contains a non-finite number")


def _identity(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise RunValidationError(f"{label} is not an accessible regular file") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_nlink != 1
        or linked.st_size <= 0
        or linked.st_size > MAXIMUM_API_BYTES
        or linked.st_mode & 0o077
    ):
        raise RunValidationError(f"{label} is not bounded owner-only regular storage")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        if _identity(linked) != _identity(before):
            raise RunValidationError(f"{label} changed before it was read")
        data = b""
        while len(data) <= MAXIMUM_API_BYTES:
            chunk = os.read(descriptor, min(64 * 1024, MAXIMUM_API_BYTES + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
        if _identity(before) != _identity(after) or len(data) != before.st_size:
            raise RunValidationError(f"{label} changed while it was read")
    except OSError as error:
        raise RunValidationError(f"{label} could not be read safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except RunValidationError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise RunValidationError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise RunValidationError(f"{label} root must be an object")
    return value


def _write_private(path: pathlib.Path, value: dict[str, Any]) -> None:
    raw = canonical_json_bytes(value)
    if len(raw) > MAXIMUM_API_BYTES:
        raise RunValidationError("trusted run verification exceeds its output bound")
    if path.exists() or path.is_symlink():
        raise RunValidationError("trusted run verification output already exists")
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
                raise RunValidationError("trusted run verification write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _string(value: Any, expected: str, label: str) -> None:
    if type(value) is not str or value != expected:
        raise RunValidationError(f"{label} does not match")


def _positive_integer(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise RunValidationError(f"{label} is not a positive integer")
    return value


def _expected_artifact_names(
    *,
    app_version: str,
    build_number: str,
    source_revision: str,
    run_id: str,
    run_attempt: str,
) -> dict[str, str]:
    identity = f"{app_version}-{build_number}-{source_revision}-{run_id}-{run_attempt}"
    return {
        "candidate": f"pakperk-production-{identity}",
        "store_handoff": f"pakperk-production-store-handoff-{identity}",
        "signed_release_outcome": f"pakperk-production-store-outcome-{identity}",
    }


def _artifact_record(
    value: Any,
    *,
    name: str,
    run_number: int,
    source_revision: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RunValidationError("GitHub artifact entry is malformed")
    artifact_id = _positive_integer(value.get("id"), "GitHub artifact ID")
    _string(value.get("name"), name, "GitHub artifact name")
    digest = value.get("digest")
    if type(digest) is not str or ARTIFACT_DIGEST.fullmatch(digest) is None:
        raise RunValidationError("GitHub artifact digest is invalid")
    size = value.get("size_in_bytes")
    if type(size) is not int or size <= 0 or size > MAXIMUM_ARTIFACT_BYTES:
        raise RunValidationError("GitHub artifact size is invalid")
    if value.get("expired") is not False:
        raise RunValidationError("GitHub artifact is expired")
    workflow_run = value.get("workflow_run")
    if not isinstance(workflow_run, dict):
        raise RunValidationError("GitHub artifact workflow binding is missing")
    if (
        workflow_run.get("id") != run_number
        or workflow_run.get("head_sha") != source_revision
        or workflow_run.get("head_branch") != "main"
    ):
        raise RunValidationError("GitHub artifact workflow binding does not match")
    return {
        "digest": digest,
        "expired": False,
        "id": str(artifact_id),
        "name": name,
        "size_in_bytes": size,
    }


def validate_verification_record(
    value: Any,
    *,
    repository: str,
    run_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    run_attempt: str | None = None,
) -> dict[str, Any]:
    """Revalidate the canonical trusted record at each downstream boundary."""

    if not isinstance(value, dict) or set(value) != {
        "artifacts",
        "classification",
        "job",
        "repository",
        "run",
        "schema",
    }:
        raise RunValidationError("trusted run verification has an invalid key surface")
    if type(value["schema"]) is not int or value["schema"] != 1:
        raise RunValidationError("trusted run verification schema is invalid")
    _string(
        value["classification"],
        "trusted GitHub signed-mobile release run verification",
        "trusted run verification classification",
    )
    _string(value["repository"], repository, "trusted run repository")
    run = value["run"]
    if not isinstance(run, dict) or set(run) != {
        "conclusion",
        "event",
        "head_branch",
        "head_sha",
        "id",
        "name",
        "path",
        "path_ref",
        "run_attempt",
        "status",
    }:
        raise RunValidationError("trusted run identity has an invalid key surface")
    observed_attempt = run["run_attempt"]
    for observed, expected, label in (
        (run["id"], run_id, "trusted run ID"),
        (run["name"], WORKFLOW_NAME, "trusted workflow name"),
        (run["path"], WORKFLOW_PATH, "trusted workflow path"),
        (run["path_ref"], "main", "trusted workflow path ref"),
        (run["event"], "workflow_dispatch", "trusted workflow event"),
        (run["head_branch"], "main", "trusted workflow branch"),
        (run["head_sha"], source_revision, "trusted workflow source"),
        (run["status"], "completed", "trusted workflow status"),
        (run["conclusion"], "success", "trusted workflow conclusion"),
    ):
        _string(observed, expected, label)
    if type(observed_attempt) is not str or RUN_ATTEMPT.fullmatch(observed_attempt) is None:
        raise RunValidationError("trusted workflow run attempt is invalid")
    if run_attempt is not None:
        _string(observed_attempt, run_attempt, "trusted workflow run attempt")

    job = value["job"]
    if not isinstance(job, dict) or set(job) != {
        "conclusion",
        "head_sha",
        "id",
        "name",
        "run_attempt",
        "run_id",
        "status",
        "workflow_name",
    }:
        raise RunValidationError("trusted release job has an invalid key surface")
    for observed, expected, label in (
        (job["run_id"], run_id, "trusted release job run ID"),
        (job["run_attempt"], observed_attempt, "trusted release job run attempt"),
        (job["workflow_name"], WORKFLOW_NAME, "trusted release job workflow"),
        (job["name"], JOB_NAME, "trusted release job name"),
        (job["head_sha"], source_revision, "trusted release job source"),
        (job["status"], "completed", "trusted release job status"),
        (job["conclusion"], "success", "trusted release job conclusion"),
    ):
        _string(observed, expected, label)
    if type(job["id"]) is not str or RUN_ID.fullmatch(job["id"]) is None:
        raise RunValidationError("trusted release job ID is invalid")

    names = _expected_artifact_names(
        app_version=app_version,
        build_number=build_number,
        source_revision=source_revision,
        run_id=run_id,
        run_attempt=observed_attempt,
    )
    artifacts = value["artifacts"]
    if not isinstance(artifacts, dict) or set(artifacts) != set(names):
        raise RunValidationError("trusted artifact verification has an invalid key surface")
    for kind, expected_name in names.items():
        artifact = artifacts[kind]
        if not isinstance(artifact, dict) or set(artifact) != {
            "digest",
            "expired",
            "id",
            "name",
            "size_in_bytes",
        }:
            raise RunValidationError("trusted artifact identity has an invalid key surface")
        _string(artifact["name"], expected_name, "trusted artifact name")
        if type(artifact["id"]) is not str or RUN_ID.fullmatch(artifact["id"]) is None:
            raise RunValidationError("trusted artifact ID is invalid")
        if (
            type(artifact["digest"]) is not str
            or ARTIFACT_DIGEST.fullmatch(artifact["digest"]) is None
            or artifact["expired"] is not False
            or type(artifact["size_in_bytes"]) is not int
            or artifact["size_in_bytes"] <= 0
            or artifact["size_in_bytes"] > MAXIMUM_ARTIFACT_BYTES
        ):
            raise RunValidationError("trusted artifact metadata is invalid")
    artifact_ids = {artifact["id"] for artifact in artifacts.values()}
    if len(artifact_ids) != len(artifacts):
        raise RunValidationError("trusted artifact IDs are not distinct")
    return value


def verify(
    run_response: dict[str, Any],
    artifacts_response: dict[str, Any],
    jobs_response: dict[str, Any],
    *,
    repository: str,
    run_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
) -> dict[str, Any]:
    if repository != REPOSITORY:
        raise RunValidationError("expected repository is invalid")
    for value, pattern, label in (
        (run_id, RUN_ID, "expected signed release run ID"),
        (source_revision, SOURCE_REVISION, "expected source revision"),
        (app_version, APP_VERSION, "expected app version"),
        (build_number, BUILD_NUMBER, "expected build number"),
    ):
        if type(value) is not str or pattern.fullmatch(value) is None:
            raise RunValidationError(f"{label} is invalid")
    run_number = int(run_id)
    if run_response.get("id") != run_number:
        raise RunValidationError("GitHub workflow run ID does not match")
    repository_object = run_response.get("repository")
    head_repository = run_response.get("head_repository")
    if (
        not isinstance(repository_object, dict)
        or repository_object.get("full_name") != repository
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != repository
    ):
        raise RunValidationError("GitHub workflow run repository does not match")
    path = run_response.get("path")
    if type(path) is not str:
        raise RunValidationError("GitHub workflow run path is invalid")
    if path == WORKFLOW_PATH:
        workflow_path = path
        path_ref = "main"
    else:
        workflow_path, separator, path_ref = path.partition("@")
        if (
            separator != "@"
            or "@" in path_ref
            or workflow_path != WORKFLOW_PATH
            or path_ref not in {"main", "refs/heads/main"}
        ):
            raise RunValidationError("GitHub workflow run path is not trusted")
    normalized_path_ref = "main"
    attempt_number = _positive_integer(
        run_response.get("run_attempt"), "GitHub workflow run attempt"
    )
    for key, expected, label in (
        ("name", WORKFLOW_NAME, "GitHub workflow name"),
        ("event", "workflow_dispatch", "GitHub workflow event"),
        ("head_branch", "main", "GitHub workflow branch"),
        ("head_sha", source_revision, "GitHub workflow source"),
        ("status", "completed", "GitHub workflow status"),
        ("conclusion", "success", "GitHub workflow conclusion"),
    ):
        _string(run_response.get(key), expected, label)

    jobs = jobs_response.get("jobs")
    total_jobs = jobs_response.get("total_count")
    if (
        type(total_jobs) is not int
        or not isinstance(jobs, list)
        or total_jobs != len(jobs)
        or total_jobs != len(REQUIRED_JOB_NAMES)
    ):
        raise RunValidationError("GitHub release job lookup is not exact")
    jobs_by_name: dict[str, dict[str, Any]] = {}
    job_ids: set[int] = set()
    for job in jobs:
        if not isinstance(job, dict):
            raise RunValidationError("GitHub release job entry is malformed")
        name = job.get("name")
        if type(name) is not str or name not in REQUIRED_JOB_NAMES or name in jobs_by_name:
            raise RunValidationError("GitHub release job lookup is not exact")
        job_id = _positive_integer(job.get("id"), "GitHub release job ID")
        if job_id in job_ids:
            raise RunValidationError("GitHub release job IDs are not distinct")
        job_ids.add(job_id)
        if job.get("run_id") != run_number or job.get("run_attempt") != attempt_number:
            raise RunValidationError("GitHub release job attempt does not match")
        for key, expected, label in (
            ("workflow_name", WORKFLOW_NAME, "GitHub release job workflow"),
            ("head_sha", source_revision, "GitHub release job source"),
            ("head_branch", "main", "GitHub release job branch"),
            ("status", "completed", "GitHub release job status"),
            ("conclusion", "success", "GitHub release job conclusion"),
        ):
            _string(job.get(key), expected, label)
        jobs_by_name[name] = job
    if set(jobs_by_name) != set(REQUIRED_JOB_NAMES):
        raise RunValidationError("GitHub release job lookup is not exact")
    signed_candidate_job = jobs_by_name[JOB_NAME]
    signed_candidate_job_id = _positive_integer(
        signed_candidate_job.get("id"), "GitHub signed-candidate job ID"
    )

    artifacts = artifacts_response.get("artifacts")
    total_artifacts = artifacts_response.get("total_count")
    if (
        type(total_artifacts) is not int
        or not isinstance(artifacts, list)
        or total_artifacts != len(artifacts)
        or total_artifacts > 100
    ):
        raise RunValidationError("GitHub artifact lookup is incomplete")
    expected_names = _expected_artifact_names(
        app_version=app_version,
        build_number=build_number,
        source_revision=source_revision,
        run_id=run_id,
        run_attempt=str(attempt_number),
    )
    selected: dict[str, dict[str, Any]] = {}
    for kind, name in expected_names.items():
        matches = [item for item in artifacts if isinstance(item, dict) and item.get("name") == name]
        if len(matches) != 1:
            raise RunValidationError("GitHub signed release artifact lookup is not exact")
        selected[kind] = _artifact_record(
            matches[0],
            name=name,
            run_number=run_number,
            source_revision=source_revision,
        )

    record = {
        "artifacts": selected,
        "classification": "trusted GitHub signed-mobile release run verification",
        "job": {
            "conclusion": "success",
            "head_sha": source_revision,
            "id": str(signed_candidate_job_id),
            "name": JOB_NAME,
            "run_attempt": str(attempt_number),
            "run_id": run_id,
            "status": "completed",
            "workflow_name": WORKFLOW_NAME,
        },
        "repository": repository,
        "run": {
            "conclusion": "success",
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_sha": source_revision,
            "id": run_id,
            "name": WORKFLOW_NAME,
            "path": WORKFLOW_PATH,
            "path_ref": normalized_path_ref,
            "run_attempt": str(attempt_number),
            "status": "completed",
        },
        "schema": 1,
    }
    return validate_verification_record(
        record,
        repository=repository,
        run_id=run_id,
        source_revision=source_revision,
        app_version=app_version,
        build_number=build_number,
        run_attempt=str(attempt_number),
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-response", required=True, type=pathlib.Path)
    parser.add_argument("--artifacts-response", required=True, type=pathlib.Path)
    parser.add_argument("--jobs-response", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    arguments = parser.parse_args(argv)
    try:
        record = verify(
            _read_json(arguments.run_response, "GitHub workflow run response"),
            _read_json(arguments.artifacts_response, "GitHub artifacts response"),
            _read_json(arguments.jobs_response, "GitHub jobs response"),
            repository=arguments.repository,
            run_id=arguments.run_id,
            source_revision=arguments.source_revision,
            app_version=arguments.app_version,
            build_number=arguments.build_number,
        )
        _write_private(arguments.output, record)
        if arguments.github_output is not None:
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(
                    "candidate_artifact_id="
                    f"{record['artifacts']['candidate']['id']}\n"
                )
                output.write(
                    "store_handoff_artifact_id="
                    f"{record['artifacts']['store_handoff']['id']}\n"
                )
                output.write(
                    "signed_release_outcome_artifact_id="
                    f"{record['artifacts']['signed_release_outcome']['id']}\n"
                )
                output.write(f"run_attempt={record['run']['run_attempt']}\n")
    except (OSError, RunValidationError) as error:
        print(f"signed release run validation failed: {error}", file=sys.stderr)
        return 1
    print("Trusted completed signed-mobile release run and artifacts validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
