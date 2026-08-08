#!/usr/bin/env python3
"""Create an unconditional closed receipt for signed-candidate store uploads."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import pathlib
import re
import stat
import sys
from typing import Any, Sequence

import validate_mobile_store_candidate as validator


STEP_OUTCOMES = {"success", "failure", "cancelled", "skipped", ""}
SAFE_ID = re.compile(r"[A-Za-z0-9-]{1,128}")


class OutcomeError(ValueError):
    """A closed store-upload evidence failure."""


def _read(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        metadata = path.lstat()
        if metadata.st_mode & 0o077:
            raise OutcomeError(f"{label} is not owner-only storage")
        raw = validator._read_manifest(path, label)
        value = validator._parse_canonical_json(raw, label)
    except (OSError, validator.ValidationError) as error:
        raise OutcomeError(f"{label} is invalid") from error
    if not isinstance(value, dict):
        raise OutcomeError(f"{label} root must be an object")
    return value


def _attempt(
    value: dict[str, Any],
    *,
    platform: str,
    artifact_sha256: str,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    repository: str,
    run_id: str,
    run_attempt: str,
) -> int:
    artifact_size = value.get("artifact_size")
    if (
        type(artifact_size) is not int
        or not 0 < artifact_size <= validator.MAXIMUM_ARTIFACT_BYTES
    ):
        raise OutcomeError(f"{platform} upload attempt artifact size is invalid")
    expected = {
        "application_id": validator.PRODUCTION_APPLICATION_ID,
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
            "path": validator.WORKFLOW_PATH,
            "repository": repository,
            "source_revision": source_revision,
        },
    }
    if value != expected:
        raise OutcomeError(f"{platform} upload attempt does not match")
    return artifact_size


def _google_result(value: dict[str, Any], *, build_number: str, sha256: str) -> None:
    expected = {
        "application_id": validator.PRODUCTION_APPLICATION_ID,
        "bundle": {"sha256": sha256, "version_code": build_number},
        "internal_target": {
            "status": "completed",
            "user_fraction": None,
            "version_codes": [build_number],
        },
        "schema": 1,
        "verification_status": "succeeded_verified",
        "version_code": build_number,
    }
    if value != expected:
        raise OutcomeError("Google Play upload verification does not match")


def _apple_result(
    value: dict[str, Any], *, app_version: str, build_number: str, sha256: str
) -> int:
    if set(value) != {
        "app_version",
        "application_id",
        "build_number",
        "operation",
        "schema",
        "upload_verification",
        "verification_status",
    }:
        raise OutcomeError("App Store upload verification key surface is invalid")
    proof = value.get("upload_verification")
    if not isinstance(proof, dict) or set(proof) != {
        "app_id",
        "build",
        "build_upload",
    }:
        raise OutcomeError("App Store upload verification identity is invalid")
    build = proof.get("build")
    if not isinstance(build, dict) or set(build) != {
        "build_id",
        "build_number",
        "pre_release_version_id",
        "processing_state",
    }:
        raise OutcomeError("App Store upload verification build is invalid")
    build_upload = proof.get("build_upload")
    if not isinstance(build_upload, dict) or set(build_upload) != {
        "asset_file",
        "build_id",
        "build_upload_id",
        "state",
    }:
        raise OutcomeError("App Store build upload verification is invalid")
    asset_file = build_upload.get("asset_file")
    if not isinstance(asset_file, dict) or set(asset_file) != {
        "asset_delivery_state",
        "asset_type",
        "build_upload_file_id",
        "file_size",
        "source_file_checksum",
        "uti",
    }:
        raise OutcomeError("App Store uploaded IPA verification is invalid")
    checksum = asset_file.get("source_file_checksum")
    if not isinstance(checksum, dict) or set(checksum) != {"algorithm", "hash"}:
        raise OutcomeError("App Store uploaded IPA checksum is invalid")
    file_size = asset_file.get("file_size")
    if (
        value.get("app_version") != app_version
        or value.get("application_id") != validator.PRODUCTION_APPLICATION_ID
        or value.get("build_number") != build_number
        or value.get("operation") != "verify-build"
        or value.get("schema") != 1
        or value.get("verification_status") != "succeeded_verified"
        or build.get("build_number") != build_number
        or build.get("processing_state") != "VALID"
        or build_upload.get("build_id") != build.get("build_id")
        or build_upload.get("state") != "COMPLETE"
        or asset_file.get("asset_delivery_state") != "COMPLETE"
        or asset_file.get("asset_type") != "ASSET"
        or type(file_size) is not int
        or not 0 < file_size <= validator.MAXIMUM_ARTIFACT_BYTES
        or checksum != {"algorithm": "SHA_256", "hash": sha256}
        or asset_file.get("uti") != "com.apple.ipa"
        or any(
            type(identifier) is not str or SAFE_ID.fullmatch(identifier) is None
            for identifier in (
                proof.get("app_id"),
                build.get("build_id"),
                build_upload.get("build_upload_id"),
                asset_file.get("build_upload_file_id"),
                build.get("pre_release_version_id"),
            )
        )
    ):
        raise OutcomeError("App Store upload verification does not match")
    return file_size


def _platform_record(
    *,
    journal_path: pathlib.Path,
    verification_path: pathlib.Path,
    upload_outcome: str,
    validate_journal: Any,
    validate_result: Any,
    require_matching_size: bool = False,
) -> dict[str, Any]:
    journal = None
    result = None
    errors: list[str] = []
    journal_present = journal_path.exists() or journal_path.is_symlink()
    result_present = verification_path.exists() or verification_path.is_symlink()
    journal_evidence = None
    result_evidence = None
    if journal_present:
        try:
            journal = _read(journal_path, "store upload attempt")
            journal_evidence = validate_journal(journal)
        except OutcomeError as error:
            errors.append(str(error))
            journal = None
    if result_present:
        try:
            result = _read(verification_path, "store upload verification")
            result_evidence = validate_result(result)
        except OutcomeError as error:
            errors.append(str(error))
            result = None
    if (
        require_matching_size
        and journal is not None
        and result is not None
        and journal_evidence != result_evidence
    ):
        errors.append("App Store remote IPA size does not match the upload attempt")
        result = None
    if journal is not None and result is not None:
        status = "succeeded_verified"
    elif journal_present:
        status = "unknown_reconcile_required"
    elif upload_outcome in {"failure", "skipped", ""}:
        status = "proven_not_committed" if upload_outcome == "failure" else "not_attempted"
    else:
        status = "unknown_reconcile_required"
    record: dict[str, Any] = {
        "attempt_journal": journal,
        "mutation_status": status,
        "upload_step_outcome": upload_outcome,
        "verification_result": result,
    }
    if errors:
        record["evidence_error"] = "; ".join(errors)
    return record


def generate(args: argparse.Namespace) -> dict[str, Any]:
    for name, pattern in (
        ("candidate_id", validator.CONTENT_ID),
        ("provenance_id", validator.CONTENT_ID),
        ("source_revision", validator.SOURCE_REVISION),
        ("app_version", validator.APP_VERSION),
        ("build_number", validator.BUILD_NUMBER),
        ("run_id", validator.RUN_ID),
        ("run_attempt", validator.RUN_ATTEMPT),
    ):
        value = getattr(args, name)
        if type(value) is not str or pattern.fullmatch(value) is None:
            raise OutcomeError("store upload outcome identity is invalid")
    if args.repository != validator.REPOSITORY:
        raise OutcomeError("store upload outcome repository is invalid")
    for name in (
        "android_upload_outcome",
        "ios_upload_outcome",
        "verification_outcome",
        "handoff_outcome",
        "handoff_upload_outcome",
    ):
        if getattr(args, name) not in STEP_OUTCOMES:
            raise OutcomeError("store upload step outcome is invalid")
    root = pathlib.Path(args.evidence_root)
    candidate = _read(pathlib.Path(args.candidate), "candidate manifest")
    if (
        "sha256:"
        + hashlib.sha256(validator.canonical_json_bytes(candidate)).hexdigest()
        != args.candidate_id
        or candidate.get("provenance_id") != args.provenance_id
        or candidate.get("source_revision") != args.source_revision
        or candidate.get("app_version") != args.app_version
        or candidate.get("build_number") != args.build_number
        or candidate.get("environment") != "production"
    ):
        raise OutcomeError("store upload outcome candidate identity does not match")
    android, ios = validator._platforms(candidate, "candidate")
    common = {
        "candidate_id": args.candidate_id,
        "provenance_id": args.provenance_id,
        "source_revision": args.source_revision,
        "app_version": args.app_version,
        "build_number": args.build_number,
        "repository": args.repository,
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
    }
    android_record = _platform_record(
        journal_path=root / "android-upload-attempt.json",
        verification_path=root / "google-upload-verification.json",
        upload_outcome=args.android_upload_outcome,
        validate_journal=lambda value: _attempt(
            value, platform="android", artifact_sha256=android["aab_sha256"], **common
        ),
        validate_result=lambda value: _google_result(
            value, build_number=args.build_number, sha256=android["aab_sha256"]
        ),
    )
    ios_record = _platform_record(
        journal_path=root / "ios-upload-attempt.json",
        verification_path=root / "apple-upload-verification.json",
        upload_outcome=args.ios_upload_outcome,
        validate_journal=lambda value: _attempt(
            value, platform="ios", artifact_sha256=ios["ipa_sha256"], **common
        ),
        validate_result=lambda value: _apple_result(
            value,
            app_version=args.app_version,
            build_number=args.build_number,
            sha256=ios["ipa_sha256"],
        ),
        require_matching_size=True,
    )
    succeeded = (
        android_record["mutation_status"] == "succeeded_verified"
        and ios_record["mutation_status"] == "succeeded_verified"
        and args.handoff_outcome == "success"
        and args.handoff_upload_outcome == "success"
    )
    receipt = {
        "android": android_record,
        "app_version": args.app_version,
        "build_number": args.build_number,
        "candidate_id": args.candidate_id,
        "classification": "protected mobile store upload outcome receipt",
        "handoff_step_outcome": args.handoff_outcome,
        "handoff_upload_step_outcome": args.handoff_upload_outcome,
        "ios": ios_record,
        "overall_result": "succeeded" if succeeded else "failed",
        "provenance_id": args.provenance_id,
        "recorded_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "schema": 1,
        "source_revision": args.source_revision,
        "verification_step_outcome": args.verification_outcome,
        "workflow": {
            "github_run_attempt": args.run_attempt,
            "github_run_id": args.run_id,
            "path": validator.WORKFLOW_PATH,
            "repository": args.repository,
        },
    }
    raw = validator.canonical_json_bytes(receipt)
    output = root / "store-upload-outcome.json"
    descriptor = os.open(
        output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OutcomeError("store upload outcome write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    digest = hashlib.sha256(raw).hexdigest()
    package = validator.canonical_json_bytes(
        {"content_id": f"store-upload-outcome-v1:sha256:{digest}", "schema": 1}
    )
    descriptor = os.open(
        root / "STORE_UPLOAD_OUTCOME_SHA256.json",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        view = memoryview(package)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OutcomeError("store upload package write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return receipt


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "candidate",
        "candidate-id",
        "provenance-id",
        "source-revision",
        "app-version",
        "build-number",
        "repository",
        "run-id",
        "run-attempt",
        "android-upload-outcome",
        "ios-upload-outcome",
        "verification-outcome",
        "handoff-outcome",
        "handoff-upload-outcome",
        "evidence-root",
    ):
        parser.add_argument(f"--{name}", required=True)
    arguments = parser.parse_args(argv)
    try:
        generate(arguments)
    except (OSError, OutcomeError, validator.ValidationError) as error:
        print(f"store upload outcome generation failed: {error}", file=sys.stderr)
        return 1
    print("Unconditional store upload outcome receipt created.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
