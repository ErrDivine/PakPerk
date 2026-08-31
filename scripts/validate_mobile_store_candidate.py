#!/usr/bin/env python3
"""Validate a downloaded production signed-mobile candidate before store rollout."""

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

import validate_mobile_signed_release_run as run_validator


MAXIMUM_MANIFEST_BYTES = 64 * 1024
MAXIMUM_ARTIFACT_BYTES = 8 * 1024**3
PRODUCTION_APPLICATION_ID = "app.pakperk.pakperk"
REPOSITORY = "ErrDivine/PakPerk"
WORKFLOW_PATH = ".github/workflows/mobile-release.yml"
WORKFLOW_JOB = "signed-candidate"
WORKFLOW_STAGE = "artifacts_verified"
UPLOAD_HANDOFF_STAGE = "store_uploads_succeeded"

SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
CONTENT_ID = re.compile(r"sha256:[0-9a-f]{64}")
STORE_HANDOFF_ID = re.compile(r"store-handoff-v1:sha256:[0-9a-f]{64}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
APP_VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?"
)
BUILD_NUMBER = re.compile(r"[1-9][0-9]{0,9}")
RUN_ID = re.compile(r"[1-9][0-9]{0,19}")
RUN_ATTEMPT = re.compile(r"[1-9][0-9]{0,9}")
APPLE_TEAM_ID = re.compile(r"[A-Z0-9]{10}")
RFC3339_SECONDS = re.compile(
    r"[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z"
)

CANDIDATE_KEYS = {
    "android",
    "app_version",
    "build_number",
    "classification",
    "environment",
    "ios",
    "mobile_feature_evidence",
    "provenance_id",
    "schema",
    "source_revision",
    "strict_full_text",
}
PROVENANCE_KEYS = {
    "android",
    "app_version",
    "build_number",
    "classification",
    "created_at",
    "environment",
    "ios",
    "mobile_feature_evidence",
    "schema",
    "source_revision",
    "workflow",
}
ANDROID_KEYS = {
    "aab_sha256",
    "apk_sha256",
    "application_id",
    "signer_sha256",
}
IOS_KEYS = {
    "application_id",
    "ipa_sha256",
    "signer_sha256",
    "team_id",
}
MOBILE_FEATURE_EVIDENCE_KEYS = {
    "schema",
    "sha256",
    "paperTitleSearch",
    "libraryImportWrites",
    "readingFeed",
    "toReadFirstEnforcement",
    "libraryV2",
    "recommendations",
    "recommendationEvents",
    "searchLookup",
    "searchExplore",
    "savedQueries",
    "researchProfiles",
    "readingBriefs",
    "subscriptions",
    "notifications",
    "deepReader",
    "paperPassport",
    "semanticFacets",
    "documentVisualObjects",
    "readingCheckpoints",
    "annotations",
    "evidenceCards",
    "researchMemory",
    "versionDiff",
    "assistantV2",
}
MOBILE_FEATURE_FLAG_KEYS = (
    "paperTitleSearch",
    "libraryImportWrites",
    "readingFeed",
    "toReadFirstEnforcement",
    "libraryV2",
    "recommendations",
    "recommendationEvents",
    "searchLookup",
    "searchExplore",
    "savedQueries",
    "researchProfiles",
    "readingBriefs",
    "subscriptions",
    "notifications",
    "deepReader",
    "paperPassport",
    "semanticFacets",
    "documentVisualObjects",
    "readingCheckpoints",
    "annotations",
    "evidenceCards",
    "researchMemory",
    "versionDiff",
    "assistantV2",
)
MOBILE_FEATURE_DEPENDENCIES = (
    ("toReadFirstEnforcement", ("readingFeed",)),
    ("recommendations", ("readingFeed",)),
    ("searchExplore", ("searchLookup",)),
    ("savedQueries", ("searchExplore",)),
    ("readingBriefs", ("readingFeed",)),
    ("subscriptions", ("readingFeed",)),
    ("notifications", ("subscriptions",)),
    ("deepReader", ("readingFeed", "toReadFirstEnforcement")),
    ("paperPassport", ("deepReader",)),
    ("semanticFacets", ("deepReader",)),
    ("documentVisualObjects", ("deepReader",)),
    ("readingCheckpoints", ("deepReader",)),
    ("annotations", ("deepReader",)),
    ("evidenceCards", ("annotations",)),
    ("researchMemory", ("evidenceCards",)),
    ("versionDiff", ("deepReader",)),
    ("assistantV2", ("deepReader",)),
)
WORKFLOW_KEYS = {
    "github_run_attempt",
    "github_run_id",
    "job",
    "path",
    "repository",
    "stage",
    "workflow_sha",
}
STORE_HANDOFF_KEYS = {
    "app_version",
    "build_number",
    "candidate_id",
    "classification",
    "created_at",
    "environment",
    "provenance_id",
    "schema",
    "source_revision",
    "tooling",
    "uploads",
    "workflow",
}
STORE_UPLOADS_KEYS = {"android", "ios"}
ANDROID_UPLOAD_KEYS = {
    "application_id",
    "artifact_sha256",
    "destination",
    "status",
    "version_code",
    "verification",
}
IOS_UPLOAD_KEYS = {
    "application_id",
    "app_version",
    "artifact_sha256",
    "build_number",
    "destination",
    "status",
    "verification",
}
TOOLING_KEYS = {
    "app_store_client_sha256",
    "bundler_version",
    "fastlane_lock_sha256",
    "google_play_client_sha256",
    "handoff_generator_sha256",
    "ruby_version",
    "rubygems_version",
}


class ValidationError(ValueError):
    """A closed validation failure that does not echo untrusted manifest data."""


def canonical_json_bytes(value: Any) -> bytes:
    """Return the exact canonical encoding used by the signed release workflow."""

    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise ValidationError("JSON value is not canonicalizable") from error
    return (encoded + "\n").encode("ascii")


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise ValidationError("JSON object contains a duplicate key")
        value[key] = child
    return value


def _reject_nonfinite_constant(_value: str) -> None:
    raise ValidationError("JSON contains a non-finite number")


def _parse_canonical_json(data: bytes, label: str) -> Any:
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
    except ValidationError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ValidationError(f"{label} is not UTF-8 JSON") from error
    if data != canonical_json_bytes(value):
        raise ValidationError(f"{label} is not exact canonical JSON")
    return value


def _file_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_manifest(path: pathlib.Path, label: str) -> bytes:
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise ValidationError(f"{label} is not an accessible regular file") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_nlink != 1
        or linked.st_size <= 0
        or linked.st_size > MAXIMUM_MANIFEST_BYTES
    ):
        raise ValidationError(f"{label} is not one bounded regular file")

    flags = os.O_RDONLY
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValidationError(f"{label} is not an accessible regular file") from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > MAXIMUM_MANIFEST_BYTES
            or _file_identity(linked) != _file_identity(before)
        ):
            raise ValidationError(f"{label} is not one bounded regular file")
        chunks: list[bytes] = []
        remaining = MAXIMUM_MANIFEST_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            _file_identity(before) != _file_identity(after)
            or len(data) != before.st_size
        ):
            raise ValidationError(f"{label} changed while it was being read")
        return data
    finally:
        os.close(descriptor)


def _hash_artifact_evidence(path: pathlib.Path, label: str) -> tuple[str, int]:
    try:
        linked = os.lstat(path)
    except OSError as error:
        raise ValidationError(f"{label} is not an accessible regular file") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_nlink != 1
        or linked.st_size <= 0
        or linked.st_size > MAXIMUM_ARTIFACT_BYTES
    ):
        raise ValidationError(f"{label} is not one bounded regular file")

    flags = os.O_RDONLY
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValidationError(f"{label} is not an accessible regular file") from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > MAXIMUM_ARTIFACT_BYTES
            or _file_identity(linked) != _file_identity(before)
        ):
            raise ValidationError(f"{label} is not one bounded regular file")
        digest = hashlib.sha256()
        observed_size = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            observed_size += len(chunk)
            if observed_size > MAXIMUM_ARTIFACT_BYTES:
                raise ValidationError(f"{label} exceeded its read bound")
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            _file_identity(before) != _file_identity(after)
            or observed_size != before.st_size
        ):
            raise ValidationError(f"{label} changed while it was being hashed")
        return digest.hexdigest(), observed_size
    finally:
        os.close(descriptor)


def _hash_artifact(path: pathlib.Path, label: str) -> str:
    return _hash_artifact_evidence(path, label)[0]


def _artifact_evidence(root: pathlib.Path) -> dict[str, dict[str, Any]]:
    try:
        before = os.lstat(root)
    except OSError as error:
        raise ValidationError("artifact root is not an accessible directory") from error
    if not stat.S_ISDIR(before.st_mode):
        raise ValidationError("artifact root is not a real directory")
    try:
        with os.scandir(root) as iterator:
            entries = list(iterator)
    except OSError as error:
        raise ValidationError("artifact root could not be enumerated") from error

    artifacts: dict[str, pathlib.Path] = {}
    for entry in entries:
        suffixes = [
            suffix for suffix in (".aab", ".apk", ".ipa") if entry.name.endswith(suffix)
        ]
        if len(suffixes) != 1:
            raise ValidationError("artifact root contains an unexpected entry")
        suffix = suffixes[0]
        if suffix in artifacts:
            raise ValidationError("artifact root contains a duplicate artifact suffix")
        artifacts[suffix] = pathlib.Path(entry.path)
    if set(artifacts) != {".aab", ".apk", ".ipa"}:
        raise ValidationError(
            "artifact root must contain exactly one artifact per platform suffix"
        )

    evidence: dict[str, dict[str, Any]] = {}
    for suffix, path in artifacts.items():
        digest, size = _hash_artifact_evidence(path, f"{suffix} artifact")
        evidence[suffix] = {"sha256": digest, "size": size}
    try:
        after = os.lstat(root)
    except OSError as error:
        raise ValidationError(
            "artifact root changed while artifacts were hashed"
        ) from error
    if _file_identity(before) != _file_identity(after):
        raise ValidationError("artifact root changed while artifacts were hashed")
    return evidence


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ValidationError(f"{label} does not match its closed key contract")


def _matching_string(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValidationError(f"{label} has an invalid value")
    return value


def _exact_schema(value: Any, label: str, expected: int = 1) -> None:
    if type(value) is not int or value != expected:
        raise ValidationError(f"{label} schema must be the exact integer {expected}")


def _mobile_feature_evidence(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be an object")
    _exact_keys(value, MOBILE_FEATURE_EVIDENCE_KEYS, label)
    _exact_schema(value["schema"], label, 6)
    _matching_string(value["sha256"], HEX_64, f"{label} SHA-256")
    if any(type(value[key]) is not bool for key in MOBILE_FEATURE_FLAG_KEYS):
        raise ValidationError(f"{label} flags must be exact booleans")
    return dict(value)


def _validate_mobile_feature_dependencies(
    value: dict[str, Any], label: str
) -> None:
    for feature, dependencies in MOBILE_FEATURE_DEPENDENCIES:
        if value[feature] and any(not value[dependency] for dependency in dependencies):
            raise ValidationError(f"{label} dependency graph is invalid")


def _timestamp(value: Any, label: str) -> None:
    if not isinstance(value, str) or RFC3339_SECONDS.fullmatch(value) is None:
        raise ValidationError(f"{label} created_at is not a whole-second UTC timestamp")
    try:
        dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise ValidationError(f"{label} created_at is not a real timestamp") from error


def _platforms(
    payload: dict[str, Any], label: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    android = payload["android"]
    ios = payload["ios"]
    if not isinstance(android, dict) or not isinstance(ios, dict):
        raise ValidationError(f"{label} platform identities must be objects")
    _exact_keys(android, ANDROID_KEYS, f"{label} Android identity")
    _exact_keys(ios, IOS_KEYS, f"{label} iOS identity")
    for key in ("aab_sha256", "apk_sha256", "signer_sha256"):
        _matching_string(android[key], HEX_64, f"{label} Android {key}")
    for key in ("ipa_sha256", "signer_sha256"):
        _matching_string(ios[key], HEX_64, f"{label} iOS {key}")
    _matching_string(ios["team_id"], APPLE_TEAM_ID, f"{label} iOS team ID")
    if android["application_id"] != PRODUCTION_APPLICATION_ID:
        raise ValidationError(f"{label} Android application ID is not production")
    if ios["application_id"] != PRODUCTION_APPLICATION_ID:
        raise ValidationError(f"{label} iOS application ID is not production")
    return android, ios


def _expected_inputs(
    *,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    signed_release_run_id: str,
    signed_release_run_attempt: str,
    store_handoff_id: str,
) -> None:
    _matching_string(candidate_id, CONTENT_ID, "expected candidate content ID")
    _matching_string(provenance_id, CONTENT_ID, "expected provenance content ID")
    _matching_string(source_revision, SOURCE_REVISION, "expected source revision")
    _matching_string(app_version, APP_VERSION, "expected app version")
    _matching_string(build_number, BUILD_NUMBER, "expected build number")
    _matching_string(signed_release_run_id, RUN_ID, "expected signed release run ID")
    _matching_string(
        signed_release_run_attempt,
        RUN_ATTEMPT,
        "expected signed release run attempt",
    )
    _matching_string(store_handoff_id, STORE_HANDOFF_ID, "expected store handoff ID")


def _validate_store_handoff(
    handoff_bytes: bytes,
    checksum_bytes: bytes,
    *,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    signed_release_run_id: str,
    store_handoff_id: str,
    provenance_workflow: dict[str, Any],
    android: dict[str, Any],
    ios: dict[str, Any],
    ios_artifact_size: int,
) -> dict[str, Any]:
    digest = hashlib.sha256(handoff_bytes).hexdigest()
    if store_handoff_id != f"store-handoff-v1:sha256:{digest}":
        raise ValidationError("store upload handoff content ID does not match")
    expected_checksum = f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii")
    if checksum_bytes != expected_checksum:
        raise ValidationError("store upload handoff checksum package does not match")

    handoff = _parse_canonical_json(handoff_bytes, "store upload handoff")
    if not isinstance(handoff, dict):
        raise ValidationError("store upload handoff root must be an object")
    _exact_keys(handoff, STORE_HANDOFF_KEYS, "store upload handoff")
    _exact_schema(handoff["schema"], "store upload handoff")
    if handoff["classification"] != "protected mobile store upload handoff":
        raise ValidationError("store upload handoff classification is invalid")
    _timestamp(handoff["created_at"], "store upload handoff")
    expected_bindings = {
        "environment": "production",
        "source_revision": source_revision,
        "app_version": app_version,
        "build_number": build_number,
        "candidate_id": candidate_id,
        "provenance_id": provenance_id,
    }
    for key, expected in expected_bindings.items():
        if handoff[key] != expected:
            raise ValidationError(f"store upload handoff {key} does not match")

    workflow = handoff["workflow"]
    if not isinstance(workflow, dict):
        raise ValidationError("store upload handoff workflow must be an object")
    _exact_keys(workflow, WORKFLOW_KEYS, "store upload handoff workflow")
    expected_workflow = dict(provenance_workflow)
    expected_workflow["stage"] = UPLOAD_HANDOFF_STAGE
    if workflow != expected_workflow:
        raise ValidationError("store upload handoff workflow binding is invalid")
    if workflow["github_run_id"] != signed_release_run_id:
        raise ValidationError("store upload handoff signed release run ID does not match")

    uploads = handoff["uploads"]
    if not isinstance(uploads, dict):
        raise ValidationError("store upload handoff uploads must be an object")
    _exact_keys(uploads, STORE_UPLOADS_KEYS, "store upload handoff uploads")
    android_upload = uploads["android"]
    ios_upload = uploads["ios"]
    if not isinstance(android_upload, dict) or not isinstance(ios_upload, dict):
        raise ValidationError("store upload handoff platform uploads must be objects")
    _exact_keys(android_upload, ANDROID_UPLOAD_KEYS, "Android store upload handoff")
    _exact_keys(ios_upload, IOS_UPLOAD_KEYS, "iOS store upload handoff")
    if android_upload != {
        "application_id": PRODUCTION_APPLICATION_ID,
        "artifact_sha256": android["aab_sha256"],
        "destination": "google_play_internal",
        "status": "succeeded",
        "version_code": build_number,
        "verification": {
            "bundle": {
                "sha256": android["aab_sha256"],
                "version_code": build_number,
            },
            "internal_target": {
                "status": "completed",
                "user_fraction": None,
                "version_codes": [build_number],
            },
            "status": "succeeded_verified",
        },
    }:
        raise ValidationError("Android store upload handoff is invalid")
    ios_verification = ios_upload.get("verification")
    if not isinstance(ios_verification, dict):
        raise ValidationError("iOS store upload verification is invalid")
    if ios_upload != {
        "application_id": PRODUCTION_APPLICATION_ID,
        "app_version": app_version,
        "artifact_sha256": ios["ipa_sha256"],
        "build_number": build_number,
        "destination": "app_store_connect",
        "status": "succeeded",
        "verification": {
            "app_id": ios_verification.get("app_id"),
            "asset_delivery_state": "COMPLETE",
            "asset_type": "ASSET",
            "build_id": ios_verification.get("build_id"),
            "build_upload_file_id": ios_verification.get("build_upload_file_id"),
            "build_upload_id": ios_verification.get("build_upload_id"),
            "build_upload_state": "COMPLETE",
            "file_size": ios_artifact_size,
            "pre_release_version_id": ios_verification.get(
                "pre_release_version_id"
            ),
            "processing_state": "VALID",
            "source_file_checksum": {
                "algorithm": "SHA_256",
                "hash": ios["ipa_sha256"],
            },
            "status": "succeeded_verified",
            "uti": "com.apple.ipa",
        },
    }:
        raise ValidationError("iOS store upload handoff is invalid")
    for key in (
        "app_id",
        "build_id",
        "build_upload_file_id",
        "build_upload_id",
        "pre_release_version_id",
    ):
        if not isinstance(ios_verification.get(key), str) or not re.fullmatch(
            r"[A-Za-z0-9-]{1,128}", ios_verification[key]
        ):
            raise ValidationError("iOS store upload verification identifier is invalid")
    tooling = handoff["tooling"]
    if not isinstance(tooling, dict):
        raise ValidationError("store upload handoff tooling must be an object")
    _exact_keys(tooling, TOOLING_KEYS, "store upload handoff tooling")
    for key in (
        "app_store_client_sha256",
        "fastlane_lock_sha256",
        "google_play_client_sha256",
        "handoff_generator_sha256",
    ):
        _matching_string(tooling[key], HEX_64, f"store upload handoff tooling {key}")
    if tooling["ruby_version"] != "3.4.10":
        raise ValidationError("store upload handoff Ruby version is invalid")
    if tooling["rubygems_version"] != "4.0.17":
        raise ValidationError("store upload handoff RubyGems version is invalid")
    if tooling["bundler_version"] != "2.6.9":
        raise ValidationError("store upload handoff Bundler version is invalid")
    return handoff


def validate_store_candidate(
    candidate_path: pathlib.Path,
    provenance_path: pathlib.Path,
    artifact_root: pathlib.Path,
    store_handoff_path: pathlib.Path,
    store_handoff_checksum_path: pathlib.Path,
    run_verification_path: pathlib.Path,
    *,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    signed_release_run_id: str,
    signed_release_run_attempt: str,
    store_handoff_id: str,
) -> dict[str, Any]:
    """Validate downloaded manifests/binaries and return their closed store binding."""

    _expected_inputs(
        candidate_id=candidate_id,
        provenance_id=provenance_id,
        source_revision=source_revision,
        app_version=app_version,
        build_number=build_number,
        signed_release_run_id=signed_release_run_id,
        signed_release_run_attempt=signed_release_run_attempt,
        store_handoff_id=store_handoff_id,
    )

    run_verification_bytes = _read_manifest(
        run_verification_path, "trusted signed release run verification"
    )
    run_verification = _parse_canonical_json(
        run_verification_bytes, "trusted signed release run verification"
    )
    try:
        run_validator.validate_verification_record(
            run_verification,
            repository=REPOSITORY,
            run_id=signed_release_run_id,
            source_revision=source_revision,
            app_version=app_version,
            build_number=build_number,
            run_attempt=signed_release_run_attempt,
        )
    except run_validator.RunValidationError as error:
        raise ValidationError(
            f"trusted signed release run verification is invalid: {error}"
        ) from error

    provenance_bytes = _read_manifest(provenance_path, "provenance manifest")
    candidate_bytes = _read_manifest(candidate_path, "candidate manifest")
    observed_provenance_id = "sha256:" + hashlib.sha256(provenance_bytes).hexdigest()
    observed_candidate_id = "sha256:" + hashlib.sha256(candidate_bytes).hexdigest()
    if observed_provenance_id != provenance_id:
        raise ValidationError("provenance manifest content ID does not match")
    if observed_candidate_id != candidate_id:
        raise ValidationError("candidate manifest content ID does not match")

    provenance = _parse_canonical_json(provenance_bytes, "provenance manifest")
    candidate = _parse_canonical_json(candidate_bytes, "candidate manifest")
    if not isinstance(provenance, dict):
        raise ValidationError("provenance manifest root must be an object")
    if not isinstance(candidate, dict):
        raise ValidationError("candidate manifest root must be an object")
    _exact_keys(provenance, PROVENANCE_KEYS, "provenance manifest")
    _exact_keys(candidate, CANDIDATE_KEYS, "candidate manifest")

    _exact_schema(provenance["schema"], "provenance manifest", 4)
    _exact_schema(candidate["schema"], "candidate manifest", 4)
    if provenance["classification"] != "protected signed mobile release provenance":
        raise ValidationError("provenance manifest classification is invalid")
    if candidate["classification"] != "protected signed mobile candidate":
        raise ValidationError("candidate manifest classification is invalid")
    for payload, label in (
        (provenance, "provenance manifest"),
        (candidate, "candidate manifest"),
    ):
        if payload["environment"] != "production":
            raise ValidationError(f"{label} does not identify production")
        if payload["source_revision"] != source_revision:
            raise ValidationError(f"{label} source revision does not match")
        if payload["app_version"] != app_version:
            raise ValidationError(f"{label} app version does not match")
        if payload["build_number"] != build_number:
            raise ValidationError(f"{label} build number does not match")
    if candidate["strict_full_text"] is not True:
        raise ValidationError("candidate manifest must use strict full text")
    if candidate["provenance_id"] != provenance_id:
        raise ValidationError("candidate provenance content ID does not match")
    candidate_mobile_feature_evidence = _mobile_feature_evidence(
        candidate["mobile_feature_evidence"],
        "candidate mobile feature evidence",
    )
    provenance_mobile_feature_evidence = _mobile_feature_evidence(
        provenance["mobile_feature_evidence"],
        "provenance mobile feature evidence",
    )
    if candidate_mobile_feature_evidence != provenance_mobile_feature_evidence:
        raise ValidationError(
            "candidate and provenance mobile feature evidence does not match"
        )
    _validate_mobile_feature_dependencies(
        candidate_mobile_feature_evidence,
        "candidate mobile feature evidence",
    )
    _timestamp(provenance["created_at"], "provenance manifest")

    workflow = provenance["workflow"]
    if not isinstance(workflow, dict):
        raise ValidationError("provenance workflow must be an object")
    _exact_keys(workflow, WORKFLOW_KEYS, "provenance workflow")
    if (
        workflow["repository"] != REPOSITORY
        or workflow["path"] != WORKFLOW_PATH
        or workflow["job"] != WORKFLOW_JOB
        or workflow["stage"] != WORKFLOW_STAGE
        or workflow["workflow_sha"] != source_revision
    ):
        raise ValidationError("provenance workflow binding is invalid")
    if workflow["github_run_id"] != signed_release_run_id:
        raise ValidationError("provenance signed release run ID does not match")
    if workflow["github_run_attempt"] != signed_release_run_attempt:
        raise ValidationError("provenance signed release run attempt does not match")

    provenance_android, provenance_ios = _platforms(provenance, "provenance")
    candidate_android, candidate_ios = _platforms(candidate, "candidate")
    if candidate_android != provenance_android or candidate_ios != provenance_ios:
        raise ValidationError(
            "candidate and provenance platform identities do not match"
        )

    artifact_evidence = _artifact_evidence(artifact_root)
    artifact_digests = {
        suffix: evidence["sha256"] for suffix, evidence in artifact_evidence.items()
    }
    if (
        artifact_digests[".aab"] != candidate_android["aab_sha256"]
        or artifact_digests[".apk"] != candidate_android["apk_sha256"]
        or artifact_digests[".ipa"] != candidate_ios["ipa_sha256"]
    ):
        raise ValidationError(
            "downloaded artifact digests do not match the signed manifests"
        )

    handoff_bytes = _read_manifest(store_handoff_path, "store upload handoff")
    checksum_bytes = _read_manifest(
        store_handoff_checksum_path, "store upload handoff checksum"
    )
    handoff = _validate_store_handoff(
        handoff_bytes,
        checksum_bytes,
        candidate_id=candidate_id,
        provenance_id=provenance_id,
        source_revision=source_revision,
        app_version=app_version,
        build_number=build_number,
        signed_release_run_id=signed_release_run_id,
        store_handoff_id=store_handoff_id,
        provenance_workflow=workflow,
        android=candidate_android,
        ios=candidate_ios,
        ios_artifact_size=artifact_evidence[".ipa"]["size"],
    )

    return {
        "android": dict(candidate_android),
        "artifacts": dict(artifact_digests),
        "candidate_id": observed_candidate_id,
        "ios": dict(candidate_ios),
        "mobile_feature_evidence": candidate_mobile_feature_evidence,
        "provenance_id": observed_provenance_id,
        "signed_release_run_attempt": signed_release_run_attempt,
        "signed_release_run_id": signed_release_run_id,
        "source_revision": source_revision,
        "store_handoff": handoff,
        "store_handoff_id": store_handoff_id,
        "trusted_run_verification": run_verification,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate downloaded production signed-mobile artifacts before store rollout."
    )
    parser.add_argument("--candidate", required=True, type=pathlib.Path)
    parser.add_argument("--provenance", required=True, type=pathlib.Path)
    parser.add_argument("--artifact-root", required=True, type=pathlib.Path)
    parser.add_argument("--store-handoff", required=True, type=pathlib.Path)
    parser.add_argument("--store-handoff-checksum", required=True, type=pathlib.Path)
    parser.add_argument("--run-verification", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--provenance-id", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--signed-release-run-id", required=True)
    parser.add_argument("--signed-release-run-attempt", required=True)
    parser.add_argument("--store-handoff-id", required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    arguments = parser.parse_args(argv)
    try:
        binding = validate_store_candidate(
            arguments.candidate,
            arguments.provenance,
            arguments.artifact_root,
            arguments.store_handoff,
            arguments.store_handoff_checksum,
            arguments.run_verification,
            candidate_id=arguments.candidate_id,
            provenance_id=arguments.provenance_id,
            source_revision=arguments.source_revision,
            app_version=arguments.app_version,
            build_number=arguments.build_number,
            signed_release_run_id=arguments.signed_release_run_id,
            signed_release_run_attempt=arguments.signed_release_run_attempt,
            store_handoff_id=arguments.store_handoff_id,
        )
        if arguments.github_output is not None:
            app_id = binding["store_handoff"]["uploads"]["ios"]["verification"][
                "app_id"
            ]
            build_id = binding["store_handoff"]["uploads"]["ios"]["verification"][
                "build_id"
            ]
            pre_release_version_id = binding["store_handoff"]["uploads"]["ios"][
                "verification"
            ]["pre_release_version_id"]
            with arguments.github_output.open("a", encoding="utf-8") as output:
                output.write(f"app_store_app_id={app_id}\n")
                output.write(f"app_store_build_id={build_id}\n")
                output.write(
                    f"app_store_pre_release_version_id={pre_release_version_id}\n"
                )
    except (OSError, ValidationError) as error:
        print(f"mobile store candidate validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "Production signed-mobile artifacts and provenance validated for store rollout."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
