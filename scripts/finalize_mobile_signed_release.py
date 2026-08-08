#!/usr/bin/env python3
"""Create the credential-free final receipt for split mobile store uploads."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any, Sequence


REPOSITORY = "ErrDivine/PakPerk"
WORKFLOW_PATH = ".github/workflows/mobile-release.yml"
MAXIMUM_JSON_BYTES = 1024 * 1024
MAXIMUM_ARTIFACT_BYTES = 16 * 1024**3
APPLICATION_IDS = {
    "development": "app.pakperk.pakperk.dev",
    "staging": "app.pakperk.pakperk.staging",
    "production": "app.pakperk.pakperk",
}
PRODUCTION_APPLICATION_ID = APPLICATION_IDS["production"]
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
CONTENT_ID = re.compile(r"sha256:[0-9a-f]{64}")
HANDOFF_ID = re.compile(r"store-handoff-v1:sha256:[0-9a-f]{64}")
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]{0,19}")
RUN_ATTEMPT = re.compile(r"[1-9][0-9]{0,9}")
SAFE_STORE_ID = re.compile(r"[A-Za-z0-9-]{1,128}")
UTC_TIMESTAMP = re.compile(
    r"(?:20[0-9]{2})-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z"
)
APP_VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?"
)
BUILD_NUMBER = re.compile(r"[1-9][0-9]{0,9}")
APPLICATION_ID = re.compile(
    r"[A-Za-z][A-Za-z0-9_-]{0,62}(?:\.[A-Za-z][A-Za-z0-9_-]{0,62}){1,9}"
)
JOB_RESULTS = {"success", "failure", "cancelled", "skipped"}
EXPECTED_TOOLING = {
    "app_store_client_sha256": "ee7e55a902bfe4f1f9fe2f933871e44d51c1f8906eff93aad8c8aa6c3f05b68c",
    "bundler_version": "2.6.9",
    "fastlane_lock_sha256": "df7c9313182c54ae68a3312f720334dc9f524d17973f6a3b1339e8892d778175",
    "google_play_client_sha256": "2fb30a5ed3341e22254d2e6548d22b9b10e235176317b7b403d48d49d445c3ac",
    "handoff_generator_sha256": "aaf319c661faf1b7eb775b50e7f842c42a7c4d23cbc32a6d8fb2e4c8ff2c2f40",
    "ruby_version": "3.4.10",
    "rubygems_version": "4.0.17",
}


class FinalizationError(ValueError):
    """Local finalization evidence violated a closed contract."""


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
        raise FinalizationError("final receipt is not canonicalizable") from error
    return (encoded + "\n").encode("ascii")


def _identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_json(path: pathlib.Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        linked = path.lstat()
    except OSError as error:
        raise FinalizationError(f"{label} is unavailable") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o022
        or linked.st_size <= 0
        or linked.st_size > MAXIMUM_JSON_BYTES
    ):
        raise FinalizationError(f"{label} storage is invalid")
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        before = os.fstat(descriptor)
        raw = b""
        while len(raw) <= MAXIMUM_JSON_BYTES:
            chunk = os.read(
                descriptor, min(64 * 1024, MAXIMUM_JSON_BYTES + 1 - len(raw))
            )
            if not chunk:
                break
            raw += chunk
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        _identity(linked) != _identity(before)
        or _identity(before) != _identity(after)
        or len(raw) != before.st_size
        or len(raw) > MAXIMUM_JSON_BYTES
    ):
        raise FinalizationError(f"{label} changed while read")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise FinalizationError(f"{label} is not JSON") from error
    if not isinstance(value, dict) or raw != canonical_json_bytes(value):
        raise FinalizationError(f"{label} is not canonical")
    return value, raw


def _write_exclusive(path: pathlib.Path, raw: bytes) -> None:
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
                raise FinalizationError("final receipt write did not progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _safe(value: str, pattern: re.Pattern[str]) -> str:
    return value if type(value) is str and pattern.fullmatch(value) is not None else "invalid"


def _artifact(
    artifact_id: str,
    digest: str,
    *,
    label: str,
    errors: list[str],
    required: bool,
) -> dict[str, Any] | None:
    if not artifact_id and not digest and not required:
        return None
    if (
        type(artifact_id) is not str
        or POSITIVE_INTEGER.fullmatch(artifact_id) is None
        or type(digest) is not str
        or SHA256.fullmatch(digest) is None
    ):
        errors.append(f"{label}_artifact_metadata_invalid")
        return None
    return {"digest": digest, "id": int(artifact_id)}


def _closed_files(root: pathlib.Path, expected: set[str], label: str) -> None:
    requested = pathlib.Path(root)
    try:
        root = pathlib.Path(os.path.realpath(root))
        metadata = root.lstat()
    except OSError as error:
        raise FinalizationError(f"{label} root is unavailable") from error
    if (
        requested != root
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
    ):
        raise FinalizationError(f"{label} root is invalid")
    observed: set[str] = set()
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories:
            child = pathlib.Path(current, name).lstat()
            if not stat.S_ISDIR(child.st_mode) or child.st_uid != os.getuid() or child.st_mode & 0o022:
                raise FinalizationError(f"{label} contains unsafe storage")
        for name in files:
            path = pathlib.Path(current, name)
            child = path.lstat()
            if (
                not stat.S_ISREG(child.st_mode)
                or child.st_uid != os.getuid()
                or child.st_nlink != 1
                or child.st_mode & 0o022
                or not 0 < child.st_size <= MAXIMUM_JSON_BYTES
            ):
                raise FinalizationError(f"{label} contains unsafe storage")
            observed.add(path.relative_to(root).as_posix())
    if observed != expected:
        raise FinalizationError(f"{label} file set is not closed")


def _validate_candidate(args: argparse.Namespace) -> dict[str, Any]:
    candidate, candidate_raw = _read_json(
        args.candidate_root / "evidence/mobile-candidate.json", "candidate manifest"
    )
    provenance, provenance_raw = _read_json(
        args.candidate_root / "evidence/mobile-release-provenance.json",
        "provenance manifest",
    )
    if (
        "sha256:" + hashlib.sha256(candidate_raw).hexdigest() != args.candidate_id
        or "sha256:" + hashlib.sha256(provenance_raw).hexdigest()
        != args.provenance_id
        or candidate.get("provenance_id") != args.provenance_id
    ):
        raise FinalizationError("candidate content identity is invalid")
    expected = {
        "environment": args.environment,
        "source_revision": args.source_revision,
        "app_version": args.app_version,
        "build_number": args.build_number,
    }
    if any(candidate.get(key) != value for key, value in expected.items()) or any(
        provenance.get(key) != value for key, value in expected.items()
    ):
        raise FinalizationError("candidate release identity is invalid")
    if set(candidate) != {
        "android",
        "app_version",
        "build_number",
        "classification",
        "environment",
        "ios",
        "provenance_id",
        "schema",
        "source_revision",
        "strict_full_text",
    } or set(provenance) != {
        "android",
        "app_version",
        "build_number",
        "classification",
        "created_at",
        "environment",
        "ios",
        "schema",
        "source_revision",
        "workflow",
    }:
        raise FinalizationError("candidate manifest key surface is invalid")
    android = candidate.get("android")
    ios = candidate.get("ios")
    if (
        candidate.get("classification") != "protected signed mobile candidate"
        or candidate.get("schema") != 1
        or candidate.get("strict_full_text")
        is not (args.environment != "development")
        or provenance.get("classification")
        != "protected signed mobile release provenance"
        or provenance.get("schema") != 1
        or type(provenance.get("created_at")) is not str
        or UTC_TIMESTAMP.fullmatch(provenance["created_at"]) is None
        or not isinstance(android, dict)
        or not isinstance(ios, dict)
        or provenance.get("android") != android
        or provenance.get("ios") != ios
        or set(android)
        != {"aab_sha256", "apk_sha256", "application_id", "signer_sha256"}
        or set(ios)
        != {"application_id", "ipa_sha256", "signer_sha256", "team_id"}
        or android.get("application_id") != args.android_application_id
        or ios.get("application_id") != args.ios_application_id
        or any(
            type(android.get(key)) is not str
            or SHA256.fullmatch(android[key]) is None
            for key in ("aab_sha256", "apk_sha256", "signer_sha256")
        )
        or any(
            type(ios.get(key)) is not str or SHA256.fullmatch(ios[key]) is None
            for key in ("ipa_sha256", "signer_sha256")
        )
        or type(ios.get("team_id")) is not str
        or re.fullmatch(r"[A-Z0-9]{10}", ios["team_id"]) is None
    ):
        raise FinalizationError("candidate platform identity is invalid")
    workflow = provenance.get("workflow")
    if not isinstance(workflow, dict) or workflow != {
        "github_run_attempt": args.run_attempt,
        "github_run_id": args.run_id,
        "job": "signed-candidate",
        "path": WORKFLOW_PATH,
        "repository": REPOSITORY,
        "stage": "artifacts_verified",
        "workflow_sha": args.source_revision,
    }:
        raise FinalizationError("candidate workflow identity is invalid")
    return candidate


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise FinalizationError(f"{label} key surface is invalid")


def _validate_attempt(
    *,
    args: argparse.Namespace,
    platform: str,
    candidate: dict[str, Any],
    path: pathlib.Path,
) -> dict[str, Any]:
    attempt, _ = _read_json(path, f"{platform} upload attempt")
    _exact_keys(
        attempt,
        {
            "application_id",
            "app_version",
            "artifact_sha256",
            "artifact_size",
            "build_number",
            "candidate_id",
            "destination",
            "mutation_status",
            "platform",
            "provenance_id",
            "schema",
            "workflow",
        },
        f"{platform} upload attempt",
    )
    platform_identity = candidate.get(platform)
    if not isinstance(platform_identity, dict):
        raise FinalizationError(f"{platform} candidate identity is invalid")
    digest_key = "aab_sha256" if platform == "android" else "ipa_sha256"
    artifact_size = attempt.get("artifact_size")
    expected = {
        "application_id": (
            args.android_application_id
            if platform == "android"
            else args.ios_application_id
        ),
        "app_version": args.app_version,
        "artifact_sha256": platform_identity.get(digest_key),
        "artifact_size": artifact_size,
        "build_number": args.build_number,
        "candidate_id": args.candidate_id,
        "destination": "google_play_internal" if platform == "android" else "app_store_connect",
        "mutation_status": "unknown_reconcile_required",
        "platform": platform,
        "provenance_id": args.provenance_id,
        "schema": 1,
        "workflow": {
            "github_run_attempt": args.run_attempt,
            "github_run_id": args.run_id,
            "path": WORKFLOW_PATH,
            "repository": REPOSITORY,
            "source_revision": args.source_revision,
        },
    }
    if (
        type(artifact_size) is not int
        or not 0 < artifact_size <= MAXIMUM_ARTIFACT_BYTES
        or attempt != expected
    ):
        raise FinalizationError(f"{platform} upload attempt is invalid")
    return attempt


def _validate_google_verification(
    *, args: argparse.Namespace, candidate: dict[str, Any], path: pathlib.Path
) -> dict[str, Any]:
    google, _ = _read_json(path, "Google Play upload verification")
    _exact_keys(
        google,
        {
            "application_id",
            "bundle",
            "internal_target",
            "schema",
            "verification_status",
            "version_code",
        },
        "Google Play upload verification",
    )
    bundle = google.get("bundle")
    if not isinstance(bundle, dict):
        raise FinalizationError("Google Play bundle verification is invalid")
    _exact_keys(bundle, {"sha256", "version_code"}, "Google Play bundle verification")
    expected_bundle = {
        "sha256": candidate["android"]["aab_sha256"],
        "version_code": args.build_number,
    }
    expected_target = {
        "status": "completed",
        "user_fraction": None,
        "version_codes": [args.build_number],
    }
    if google != {
        "application_id": args.android_application_id,
        "bundle": expected_bundle,
        "internal_target": expected_target,
        "schema": 1,
        "verification_status": "succeeded_verified",
        "version_code": args.build_number,
    }:
        raise FinalizationError("Google Play upload verification is invalid")
    return google


def _validate_apple_verification(
    *,
    args: argparse.Namespace,
    candidate: dict[str, Any],
    attempt: dict[str, Any],
    path: pathlib.Path,
) -> dict[str, Any]:
    apple, _ = _read_json(path, "App Store upload verification")
    _exact_keys(
        apple,
        {
            "app_version",
            "application_id",
            "build_number",
            "operation",
            "schema",
            "upload_verification",
            "verification_status",
        },
        "App Store upload verification",
    )
    upload = apple.get("upload_verification")
    if not isinstance(upload, dict):
        raise FinalizationError("App Store upload verification identity is invalid")
    _exact_keys(upload, {"app_id", "build", "build_upload"}, "App Store upload verification identity")
    build = upload.get("build")
    build_upload = upload.get("build_upload")
    if not isinstance(build, dict) or not isinstance(build_upload, dict):
        raise FinalizationError("App Store build verification is invalid")
    _exact_keys(
        build,
        {"build_id", "build_number", "pre_release_version_id", "processing_state"},
        "App Store build verification",
    )
    _exact_keys(
        build_upload,
        {"asset_file", "build_id", "build_upload_id", "state"},
        "App Store build-upload verification",
    )
    asset = build_upload.get("asset_file")
    if not isinstance(asset, dict):
        raise FinalizationError("App Store uploaded IPA verification is invalid")
    _exact_keys(
        asset,
        {
            "asset_delivery_state",
            "asset_type",
            "build_upload_file_id",
            "file_size",
            "source_file_checksum",
            "uti",
        },
        "App Store uploaded IPA verification",
    )
    checksum = asset.get("source_file_checksum")
    if not isinstance(checksum, dict):
        raise FinalizationError("App Store uploaded IPA checksum is invalid")
    _exact_keys(checksum, {"algorithm", "hash"}, "App Store uploaded IPA checksum")
    ids = (
        upload.get("app_id"),
        build.get("build_id"),
        build.get("pre_release_version_id"),
        build_upload.get("build_upload_id"),
        asset.get("build_upload_file_id"),
    )
    if (
        apple.get("schema") != 1
        or apple.get("application_id") != args.ios_application_id
        or apple.get("app_version") != args.app_version
        or apple.get("build_number") != args.build_number
        or apple.get("operation") != "verify-build"
        or apple.get("verification_status") != "succeeded_verified"
        or any(type(value) is not str or SAFE_STORE_ID.fullmatch(value) is None for value in ids)
        or build.get("build_number") != args.build_number
        or build.get("processing_state") != "VALID"
        or build_upload.get("build_id") != build.get("build_id")
        or build_upload.get("state") != "COMPLETE"
        or asset.get("asset_delivery_state") != "COMPLETE"
        or asset.get("asset_type") != "ASSET"
        or asset.get("file_size") != attempt.get("artifact_size")
        or checksum
        != {"algorithm": "SHA_256", "hash": candidate["ios"]["ipa_sha256"]}
        or asset.get("uti") != "com.apple.ipa"
    ):
        raise FinalizationError("App Store upload verification is invalid")
    return apple


def _expected_platform_outcome(
    *,
    args: argparse.Namespace,
    platform: str,
    candidate_artifact: dict[str, Any],
    store_artifact: dict[str, Any],
) -> dict[str, Any]:
    if platform == "android":
        steps = {
            "cleanup": "success",
            "upload": "success",
            "verification": "success",
        }
    else:
        steps = {"cleanup": "success", "upload_and_verification": "success"}
    return {
        "candidate_artifact": candidate_artifact,
        "candidate_id": args.candidate_id,
        "classification": "isolated mobile store upload platform outcome",
        "platform": platform,
        "provenance_id": args.provenance_id,
        "requested": True,
        "run": {"attempt": args.run_attempt, "id": args.run_id},
        "schema": 1,
        "source_revision": args.source_revision,
        "status": "succeeded_verified",
        "steps": steps,
        "store_client_artifact": store_artifact,
    }


def _validate_platform(
    *,
    args: argparse.Namespace,
    platform: str,
    root: pathlib.Path,
    candidate: dict[str, Any],
    candidate_artifact: dict[str, Any],
    store_artifact: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    if platform == "android":
        expected_files = {
            "android-platform-outcome.json",
            "android-upload-attempt.json",
            "google-upload-verification.json",
        }
        outcome_name = "android-platform-outcome.json"
        attempt_name = "android-upload-attempt.json"
        verification_name = "google-upload-verification.json"
    else:
        expected_files = {
            "apple-upload-verification.json",
            "ios-platform-outcome.json",
            "ios-upload-attempt.json",
        }
        outcome_name = "ios-platform-outcome.json"
        attempt_name = "ios-upload-attempt.json"
        verification_name = "apple-upload-verification.json"
    _closed_files(root, expected_files, f"{platform} upload evidence")
    attempt = _validate_attempt(
        args=args,
        platform=platform,
        candidate=candidate,
        path=root / attempt_name,
    )
    if platform == "android":
        verification = _validate_google_verification(
            args=args,
            candidate=candidate,
            path=root / verification_name,
        )
    else:
        verification = _validate_apple_verification(
            args=args,
            candidate=candidate,
            attempt=attempt,
            path=root / verification_name,
        )
    outcome, _ = _read_json(root / outcome_name, f"{platform} platform outcome")
    if outcome != _expected_platform_outcome(
        args=args,
        platform=platform,
        candidate_artifact=candidate_artifact,
        store_artifact=store_artifact,
    ):
        raise FinalizationError(f"{platform} platform outcome is invalid")
    return {"attempt": attempt, "verification": verification}


def _validate_handoff(
    args: argparse.Namespace,
    *,
    candidate: dict[str, Any],
    android: dict[str, dict[str, Any]],
    ios: dict[str, dict[str, Any]],
) -> None:
    _closed_files(
        args.handoff_root,
        {"mobile-store-upload-handoff.json", "mobile-store-upload-handoff.sha256"},
        "store handoff",
    )
    handoff, raw = _read_json(
        args.handoff_root / "mobile-store-upload-handoff.json", "store handoff"
    )
    digest = hashlib.sha256(raw).hexdigest()
    if args.store_handoff_id != f"store-handoff-v1:sha256:{digest}":
        raise FinalizationError("store handoff content ID is invalid")
    checksum = (
        args.handoff_root / "mobile-store-upload-handoff.sha256"
    ).read_bytes()
    if checksum != f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii"):
        raise FinalizationError("store handoff checksum is invalid")
    created_at = handoff.get("created_at")
    if type(created_at) is not str or UTC_TIMESTAMP.fullmatch(created_at) is None:
        raise FinalizationError("store handoff timestamp is invalid")
    google = android["verification"]
    apple = ios["verification"]
    upload = apple["upload_verification"]
    build = upload["build"]
    build_upload = upload["build_upload"]
    asset = build_upload["asset_file"]
    expected = {
        "app_version": args.app_version,
        "build_number": args.build_number,
        "candidate_id": args.candidate_id,
        "classification": "protected mobile store upload handoff",
        "created_at": created_at,
        "environment": args.environment,
        "provenance_id": args.provenance_id,
        "schema": 1,
        "source_revision": args.source_revision,
        "tooling": EXPECTED_TOOLING,
        "uploads": {
            "android": {
                "application_id": args.android_application_id,
                "artifact_sha256": candidate["android"]["aab_sha256"],
                "destination": "google_play_internal",
                "status": "succeeded",
                "verification": {
                    "bundle": google["bundle"],
                    "internal_target": google["internal_target"],
                    "status": "succeeded_verified",
                },
                "version_code": args.build_number,
            },
            "ios": {
                "application_id": args.ios_application_id,
                "app_version": args.app_version,
                "artifact_sha256": candidate["ios"]["ipa_sha256"],
                "build_number": args.build_number,
                "destination": "app_store_connect",
                "status": "succeeded",
                "verification": {
                    "app_id": upload["app_id"],
                    "asset_delivery_state": "COMPLETE",
                    "asset_type": "ASSET",
                    "build_id": build["build_id"],
                    "build_upload_file_id": asset["build_upload_file_id"],
                    "build_upload_id": build_upload["build_upload_id"],
                    "build_upload_state": "COMPLETE",
                    "file_size": asset["file_size"],
                    "pre_release_version_id": build["pre_release_version_id"],
                    "processing_state": "VALID",
                    "source_file_checksum": asset["source_file_checksum"],
                    "status": "succeeded_verified",
                    "uti": "com.apple.ipa",
                },
            },
        },
        "workflow": {
            "github_run_attempt": args.run_attempt,
            "github_run_id": args.run_id,
            "job": "signed-candidate",
            "path": WORKFLOW_PATH,
            "repository": REPOSITORY,
            "stage": "store_uploads_succeeded",
            "workflow_sha": args.source_revision,
        },
    }
    if handoff != expected:
        raise FinalizationError("store handoff release identity is invalid")


def generate(args: argparse.Namespace) -> dict[str, Any]:
    errors: list[str] = []
    requested = args.requested_uploads == "true"
    if args.requested_uploads not in {"true", "false"}:
        errors.append("requested_uploads_invalid")
    if args.repository != REPOSITORY:
        errors.append("repository_invalid")
    expected_application_id = APPLICATION_IDS.get(args.environment)
    if expected_application_id is None:
        errors.append("environment_invalid")
    for platform in ("android", "ios"):
        application_id = getattr(args, f"{platform}_application_id")
        if (
            type(application_id) is not str
            or APPLICATION_ID.fullmatch(application_id) is None
            or application_id != expected_application_id
        ):
            errors.append(f"{platform}_application_id_invalid")
    if requested and args.environment != "production":
        errors.append("store_upload_environment_invalid")
    for name, pattern in (
        ("source_revision", SOURCE_REVISION),
        ("app_version", APP_VERSION),
        ("build_number", BUILD_NUMBER),
        ("run_id", POSITIVE_INTEGER),
        ("run_attempt", RUN_ATTEMPT),
        ("candidate_id", CONTENT_ID),
        ("provenance_id", CONTENT_ID),
    ):
        if pattern.fullmatch(getattr(args, name)) is None:
            errors.append(f"{name}_invalid")
    for name in (
        "candidate_job_result",
        "bootstrap_job_result",
        "android_job_result",
        "ios_job_result",
    ):
        if getattr(args, name) not in JOB_RESULTS:
            errors.append(f"{name}_invalid")

    candidate_artifact = _artifact(
        args.candidate_artifact_id,
        args.candidate_artifact_digest,
        label="candidate",
        errors=errors,
        required=True,
    )
    store_artifact = _artifact(
        args.store_client_artifact_id,
        args.store_client_artifact_digest,
        label="store_client",
        errors=errors,
        required=requested,
    )
    android_evidence = _artifact(
        args.android_evidence_artifact_id,
        args.android_evidence_artifact_digest,
        label="android_evidence",
        errors=errors,
        required=requested,
    )
    ios_evidence = _artifact(
        args.ios_evidence_artifact_id,
        args.ios_evidence_artifact_digest,
        label="ios_evidence",
        errors=errors,
        required=requested,
    )
    handoff_artifact = _artifact(
        args.handoff_artifact_id,
        args.handoff_artifact_digest,
        label="handoff",
        errors=errors,
        required=requested,
    )
    observed_ids = [
        value["id"]
        for value in (
            candidate_artifact,
            store_artifact,
            android_evidence,
            ios_evidence,
            handoff_artifact,
        )
        if value is not None
    ]
    if len(observed_ids) != len(set(observed_ids)):
        errors.append("artifact_ids_not_distinct")

    candidate: dict[str, Any] | None = None
    try:
        if candidate_artifact is None or args.candidate_job_result != "success":
            raise FinalizationError("candidate job did not succeed")
        candidate = _validate_candidate(args)
    except Exception:
        errors.append("candidate_validation_failed")

    if requested:
        if (
            args.bootstrap_job_result != "success"
            or args.android_job_result != "success"
            or args.ios_job_result != "success"
        ):
            errors.append("requested_job_result_failed")
        if args.handoff_step_outcome != "success" or args.handoff_upload_outcome != "success":
            errors.append("handoff_step_failed")
        android_documents: dict[str, dict[str, Any]] | None = None
        ios_documents: dict[str, dict[str, Any]] | None = None
        if (
            candidate is not None
            and candidate_artifact is not None
            and store_artifact is not None
        ):
            try:
                android_documents = _validate_platform(
                    args=args,
                    platform="android",
                    root=args.android_evidence_root,
                    candidate=candidate,
                    candidate_artifact=candidate_artifact,
                    store_artifact=store_artifact,
                )
            except Exception:
                errors.append("android_evidence_validation_failed")
            try:
                ios_documents = _validate_platform(
                    args=args,
                    platform="ios",
                    root=args.ios_evidence_root,
                    candidate=candidate,
                    candidate_artifact=candidate_artifact,
                    store_artifact=store_artifact,
                )
            except Exception:
                errors.append("ios_evidence_validation_failed")
        else:
            errors.extend(
                ["android_evidence_validation_failed", "ios_evidence_validation_failed"]
            )
        try:
            if (
                handoff_artifact is None
                or HANDOFF_ID.fullmatch(args.store_handoff_id) is None
                or candidate is None
                or android_documents is None
                or ios_documents is None
            ):
                raise FinalizationError("store handoff metadata is invalid")
            _validate_handoff(
                args,
                candidate=candidate,
                android=android_documents,
                ios=ios_documents,
            )
        except Exception:
            errors.append("handoff_validation_failed")
        android_status = "succeeded_verified" if "android_evidence_validation_failed" not in errors else "failed"
        ios_status = "succeeded_verified" if "ios_evidence_validation_failed" not in errors else "failed"
    else:
        if (
            args.bootstrap_job_result != "skipped"
            or args.android_job_result != "skipped"
            or args.ios_job_result != "skipped"
            or store_artifact is not None
            or android_evidence is not None
            or ios_evidence is not None
            or handoff_artifact is not None
            or args.store_handoff_id
            or args.handoff_step_outcome not in {"", "skipped"}
            or args.handoff_upload_outcome not in {"", "skipped"}
        ):
            errors.append("not_requested_boundary_invalid")
        android_status = "not_requested"
        ios_status = "not_requested"

    errors = sorted(set(errors))
    overall = "succeeded" if not errors else "failed"
    receipt = {
        "android": {
            "evidence_artifact": android_evidence,
            "job_result": args.android_job_result,
            "status": android_status,
        },
        "app_version": _safe(args.app_version, APP_VERSION),
        "build_number": _safe(args.build_number, BUILD_NUMBER),
        "candidate": {
            "artifact": candidate_artifact,
            "candidate_id": _safe(args.candidate_id, CONTENT_ID),
            "job_result": args.candidate_job_result,
            "provenance_id": _safe(args.provenance_id, CONTENT_ID),
        },
        "classification": "credential-free signed mobile release final outcome",
        "environment": (
            args.environment if args.environment in APPLICATION_IDS else "invalid"
        ),
        "errors": errors,
        "ios": {
            "evidence_artifact": ios_evidence,
            "job_result": args.ios_job_result,
            "status": ios_status,
        },
        "overall_result": overall,
        "requested_uploads": requested,
        "schema": 1,
        "source_revision": _safe(args.source_revision, SOURCE_REVISION),
        "store_client": {
            "artifact": store_artifact,
            "job_result": args.bootstrap_job_result,
        },
        "store_handoff": {
            "artifact": handoff_artifact,
            "content_id": args.store_handoff_id
            if HANDOFF_ID.fullmatch(args.store_handoff_id) is not None
            else None,
        },
        "workflow": {
            "github_run_attempt": _safe(args.run_attempt, RUN_ATTEMPT),
            "github_run_id": _safe(args.run_id, POSITIVE_INTEGER),
            "path": WORKFLOW_PATH,
            "repository": REPOSITORY,
        },
    }
    output_root = args.output_root
    output_root.mkdir(mode=0o700, parents=False, exist_ok=True)
    raw = canonical_json_bytes(receipt)
    _write_exclusive(output_root / "mobile-signed-release-outcome.json", raw)
    digest = hashlib.sha256(raw).hexdigest()
    content_id = f"signed-release-outcome-v1:sha256:{digest}"
    _write_exclusive(
        output_root / "MOBILE_SIGNED_RELEASE_OUTCOME.json",
        canonical_json_bytes({"content_id": content_id, "schema": 1}),
    )
    with args.github_output.open("a", encoding="utf-8") as github_output:
        github_output.write(f"overall_result={overall}\n")
        github_output.write(f"outcome_id={content_id}\n")
    return receipt


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "candidate-root",
        "android-evidence-root",
        "ios-evidence-root",
        "handoff-root",
        "output-root",
        "github-output",
    ):
        parser.add_argument(f"--{name}", required=True, type=pathlib.Path)
    for name in (
        "requested-uploads",
        "environment",
        "android-application-id",
        "ios-application-id",
        "repository",
        "source-revision",
        "app-version",
        "build-number",
        "run-id",
        "run-attempt",
        "candidate-id",
        "provenance-id",
        "candidate-job-result",
        "bootstrap-job-result",
        "android-job-result",
        "ios-job-result",
        "candidate-artifact-id",
        "candidate-artifact-digest",
        "store-client-artifact-id",
        "store-client-artifact-digest",
        "android-evidence-artifact-id",
        "android-evidence-artifact-digest",
        "ios-evidence-artifact-id",
        "ios-evidence-artifact-digest",
        "store-handoff-id",
        "handoff-artifact-id",
        "handoff-artifact-digest",
        "handoff-step-outcome",
        "handoff-upload-outcome",
    ):
        parser.add_argument(f"--{name}", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        generate(arguments)
    except (OSError, FinalizationError) as error:
        print(f"mobile signed-release finalization failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
