#!/usr/bin/env python3
"""Generate a closed, content-addressed receipt for protected store attempts."""

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
from typing import Any, Callable

# ``python -I`` removes the entrypoint directory from ``sys.path``. Both rollout
# call sites literal-hash this sibling closure before execution, so add only that
# reviewed directory instead of trusting PYTHONPATH or the working directory.
_CONTROL_ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_CONTROL_ROOT))

import validate_mobile_signed_release_run as signed_run_validator


APPLICATION_ID = "app.pakperk.pakperk"
REPOSITORY = "ErrDivine/PakPerk"
MAX_EVIDENCE_BYTES = 64 * 1024
SAFE_REMOTE_ID = re.compile(r"^[A-Za-z0-9-]{1,128}$")
PLAY_FRACTIONS = {"0.01", "0.02", "0.05", "0.10", "0.20", "0.50"}
STEP_OUTCOMES = {"success", "failure", "cancelled", "skipped", ""}
MUTATION_STATUSES = {
    "not_attempted",
    "rejected_pre_mutation",
    "proven_not_committed",
    "succeeded_verified",
    "unknown_reconcile_required",
}
MAX_INTENT_VALUE_BYTES = 512
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]{1,32})?$")
POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]{0,19}$")
BUILD_NUMBER = re.compile(r"^[1-9][0-9]{0,9}$")
CONTENT_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
HANDOFF_ID = re.compile(r"^store-handoff-v1:sha256:[0-9a-f]{64}$")
CHANGE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
REPOSITORY_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
RFC3339_SECONDS = re.compile(
    r"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$"
)
SENSITIVE_VALUE = re.compile(
    r"(?i)(?:-----BEGIN[^\r\n]{0,80}(?:PRIVATE\s+KEY|OPENSSH)|"
    r"\bbearer\s+|\b(?:token|password|passwd|secret|private[ _-]?key|"
    r"api[ _-]?key)\b|\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.)"
)


class ReceiptError(RuntimeError):
    """Raised when the receipt itself cannot be generated safely."""


class EvidenceError(ValueError):
    """Raised when store API evidence does not match the dispatch contract."""


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise EvidenceError("store API result contains a duplicate key")
        value[key] = child
    return value


def _reject_nonfinite_constant(_value: str) -> None:
    raise EvidenceError("store API result contains a non-finite number")


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
        raise EvidenceError("store API result is not canonicalizable") from error
    return (encoded + "\n").encode("ascii")


def _file_identity(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def read_private_json(path: pathlib.Path) -> dict[str, Any]:
    """Read one bounded owner-only regular JSON object without following links."""

    descriptor: int | None = None
    try:
        linked = path.lstat()
        if (
            not stat.S_ISREG(linked.st_mode)
            or linked.st_nlink != 1
            or linked.st_size <= 0
            or linked.st_size > MAX_EVIDENCE_BYTES
            or linked.st_mode & 0o077
        ):
            raise EvidenceError("store API result is not bounded owner-only regular storage")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        before = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = MAX_EVIDENCE_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            _file_identity(linked) != _file_identity(before)
            or _file_identity(before) != _file_identity(after)
            or len(data) != before.st_size
        ):
            raise EvidenceError("store API result changed while it was read")
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
        if not isinstance(value, dict):
            raise EvidenceError("store API result is not a JSON object")
        if data != canonical_json_bytes(value):
            raise EvidenceError("store API result is not exact canonical JSON")
        return value
    except FileNotFoundError as error:
        raise EvidenceError("store API result is missing") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError("store API result could not be read") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _exact_keys(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} has an unexpected schema")
    return value


def _play_snapshot(
    value: Any,
    *,
    version_code: str,
    status: str,
    fraction: str | None,
    label: str,
) -> None:
    snapshot = _exact_keys(
        value,
        {"status", "user_fraction", "version_codes"},
        label,
    )
    if (
        type(snapshot["status"]) is not str
        or snapshot["status"] != status
        or snapshot["user_fraction"] != fraction
        or snapshot["version_codes"] != [version_code]
    ):
        raise EvidenceError(f"{label} does not match the exact rollout state")
    if fraction is not None and fraction not in PLAY_FRACTIONS:
        raise EvidenceError(f"{label} has an unreviewed fraction")


def validate_google_play_result(
    value: dict[str, Any],
    *,
    version_code: str,
    previous_version_code: str,
    operation: str,
    expected_fraction: str,
    target_fraction: str,
) -> None:
    result = _exact_keys(
        value,
        {
            "after",
            "application_id",
            "before",
            "mutation_status",
            "operation",
            "previous_production_version_code",
            "requested",
            "schema",
            "version_code",
        },
        "Google Play result",
    )
    if (
        result["application_id"] != APPLICATION_ID
        or result["version_code"] != version_code
        or result["previous_production_version_code"] != previous_version_code
        or result["operation"] != operation
        or result["mutation_status"] != "succeeded_verified"
        or type(result["schema"]) is not int
        or result["schema"] != 1
        or result["requested"]
        != {
            "expected_current_fraction": expected_fraction,
            "target_fraction": target_fraction,
        }
    ):
        raise EvidenceError("Google Play result does not match the dispatch")

    before = _exact_keys(
        result["before"],
        {"fallback", "internal_target", "target"},
        "Google Play preflight",
    )
    after = _exact_keys(
        result["after"],
        {"fallback", "target"},
        "Google Play postflight",
    )
    _play_snapshot(
        before["fallback"],
        version_code=previous_version_code,
        status="completed",
        fraction=None,
        label="Google Play preflight fallback",
    )
    _play_snapshot(
        after["fallback"],
        version_code=previous_version_code,
        status="completed",
        fraction=None,
        label="Google Play postflight fallback",
    )

    before_status: str | None
    before_fraction: str | None
    after_status: str
    after_fraction: str | None
    if operation == "start":
        if before["target"] is not None:
            raise EvidenceError("Google Play start unexpectedly found a production target")
        _play_snapshot(
            before["internal_target"],
            version_code=version_code,
            status="completed",
            fraction=None,
            label="Google Play internal target",
        )
        before_status = None
        before_fraction = None
        after_status = "inProgress"
        after_fraction = target_fraction
    else:
        if before["internal_target"] is not None:
            raise EvidenceError("Google Play non-start result contains an internal target")
        if operation in {"advance", "halt", "complete"}:
            before_status = "inProgress"
            before_fraction = expected_fraction
        elif operation == "rollback":
            before_status = "completed"
            before_fraction = None
        else:
            raise EvidenceError("Google Play operation is unsupported")
        after_status = {
            "advance": "inProgress",
            "halt": "halted",
            "complete": "completed",
            "rollback": "halted",
        }[operation]
        after_fraction = target_fraction if operation in {"advance", "halt"} else None

    if before_status is not None:
        _play_snapshot(
            before["target"],
            version_code=version_code,
            status=before_status,
            fraction=before_fraction,
            label="Google Play preflight target",
        )
    _play_snapshot(
        after["target"],
        version_code=version_code,
        status=after_status,
        fraction=after_fraction,
        label="Google Play postflight target",
    )


def validate_google_play_journal(
    value: dict[str, Any],
    *,
    version_code: str,
    previous_version_code: str,
    operation: str,
    expected_fraction: str,
    target_fraction: str,
) -> None:
    """Validate the durable record written immediately before Play commit."""

    journal = _exact_keys(
        value,
        {
            "application_id",
            "before",
            "mutation_status",
            "operation",
            "previous_production_version_code",
            "requested",
            "schema",
            "version_code",
        },
        "Google Play attempt journal",
    )
    if (
        journal["application_id"] != APPLICATION_ID
        or journal["version_code"] != version_code
        or journal["previous_production_version_code"] != previous_version_code
        or journal["operation"] != operation
        or journal["mutation_status"] != "unknown_reconcile_required"
        or type(journal["schema"]) is not int
        or journal["schema"] != 1
        or journal["requested"]
        != {
            "expected_current_fraction": expected_fraction,
            "target_fraction": target_fraction,
        }
    ):
        raise EvidenceError("Google Play attempt journal does not match the dispatch")

    before = _exact_keys(
        journal["before"],
        {"fallback", "internal_target", "target"},
        "Google Play journal preflight",
    )
    _play_snapshot(
        before["fallback"],
        version_code=previous_version_code,
        status="completed",
        fraction=None,
        label="Google Play journal fallback",
    )
    if operation == "start":
        if before["target"] is not None:
            raise EvidenceError("Google Play start journal found a production target")
        _play_snapshot(
            before["internal_target"],
            version_code=version_code,
            status="completed",
            fraction=None,
            label="Google Play journal internal target",
        )
        return
    if before["internal_target"] is not None:
        raise EvidenceError("Google Play non-start journal contains an internal target")
    if operation in {"advance", "halt", "complete"}:
        status, fraction = "inProgress", expected_fraction
    elif operation == "rollback":
        status, fraction = "completed", None
    else:
        raise EvidenceError("Google Play journal operation is unsupported")
    _play_snapshot(
        before["target"],
        version_code=version_code,
        status=status,
        fraction=fraction,
        label="Google Play journal target",
    )


def _optional_nonnegative_integer(value: Any, label: str) -> None:
    if value is not None and (type(value) is not int or value < 0):
        raise EvidenceError(f"{label} must be a non-negative integer or null")


def _safe_remote_id(value: Any, label: str) -> None:
    if type(value) is not str or SAFE_REMOTE_ID.fullmatch(value) is None:
        raise EvidenceError(f"{label} is invalid")


def _validate_app_build(
    value: Any, *, build_number: str, label: str, pre_release: bool = False
) -> None:
    keys = {"build_id", "build_number", "processing_state"}
    if pre_release:
        keys.add("pre_release_version_id")
    build = _exact_keys(
        value,
        keys,
        label,
    )
    _safe_remote_id(build["build_id"], f"{label} ID")
    if pre_release:
        _safe_remote_id(
            build["pre_release_version_id"], f"{label} pre-release version ID"
        )
    if (
        build["build_number"] != build_number
        or build["processing_state"] != "VALID"
    ):
        raise EvidenceError(f"{label} does not match the exact processed build")


def _validate_app_phased_release(
    value: Any,
    *,
    build_number: str,
    expected_state: str,
    mutating: bool,
    label: str,
) -> dict[str, Any]:
    base_keys = {
        "app_id",
        "app_version_id",
        "build",
        "current_day_number",
        "phased_release_id",
        "start_date",
        "state",
        "total_pause_duration",
    }
    expected_keys = base_keys | (
        {"idempotent", "mutation_status", "previous_state"} if mutating else set()
    )
    phased = _exact_keys(value, expected_keys, label)
    for key in ("app_id", "app_version_id", "phased_release_id"):
        _safe_remote_id(phased[key], f"App Store {key}")
    _validate_app_build(
        phased["build"], build_number=build_number, label="App Store build"
    )
    _optional_nonnegative_integer(phased["current_day_number"], "current_day_number")
    _optional_nonnegative_integer(
        phased["total_pause_duration"], "total_pause_duration"
    )
    if phased["start_date"] is not None and (
        type(phased["start_date"]) is not str or len(phased["start_date"]) > 64
    ):
        raise EvidenceError("App Store start_date is invalid")
    if phased["state"] != expected_state:
        raise EvidenceError("App Store phased release is not in the requested state")
    return phased


def validate_app_store_result(
    value: dict[str, Any], *, app_version: str, build_number: str, operation: str
) -> None:
    api_operation = {
        "start": "verify-submission",
        "advance": "observe",
        "halt": "pause",
        "complete": "complete",
    }.get(operation)
    if api_operation is None:
        raise EvidenceError("App Store operation is unsupported")
    result = _exact_keys(
        value,
        {
            "application_id",
            "app_version",
            "build_number",
            "operation",
            "phased_release",
            "schema",
        },
        "App Store result",
    )
    if (
        result["application_id"] != APPLICATION_ID
        or result["app_version"] != app_version
        or result["build_number"] != build_number
        or result["operation"] != api_operation
        or type(result["schema"]) is not int
        or result["schema"] != 1
    ):
        raise EvidenceError("App Store result does not match the dispatch")

    expected_state = {
        "verify-submission": "INACTIVE",
        "observe": "ACTIVE",
        "pause": "PAUSED",
        "complete": "COMPLETE",
    }[api_operation]
    mutating = api_operation in {"pause", "complete"}
    phased = _validate_app_phased_release(
        result["phased_release"],
        build_number=build_number,
        expected_state=expected_state,
        mutating=mutating,
        label="App Store phased release",
    )
    if api_operation in {"pause", "complete"}:
        idempotent = phased["idempotent"]
        previous_state = phased["previous_state"]
        if (
            type(idempotent) is not bool
            or (idempotent and previous_state != expected_state)
            or (not idempotent and previous_state != "ACTIVE")
            or phased["mutation_status"] != "succeeded_verified"
        ):
            raise EvidenceError("App Store transition metadata is invalid")


def validate_app_update_preflight(
    value: dict[str, Any],
    *,
    app_version: str,
    build_number: str,
    previous_public_version: str,
) -> None:
    result = _exact_keys(
        value,
        {
            "application_id",
            "app_version",
            "build_number",
            "mutation_status",
            "operation",
            "schema",
            "update_preflight",
        },
        "App Store update preflight",
    )
    if (
        result["application_id"] != APPLICATION_ID
        or result["app_version"] != app_version
        or result["build_number"] != build_number
        or result["mutation_status"] != "unknown_reconcile_required"
        or result["operation"] != "verify-update"
        or type(result["schema"]) is not int
        or result["schema"] != 1
    ):
        raise EvidenceError("App Store update preflight does not match the dispatch")
    proof = _exact_keys(
        result["update_preflight"],
        {"app_id", "previous", "target", "target_build"},
        "App Store update proof",
    )
    _safe_remote_id(proof["app_id"], "App Store app_id")
    _validate_app_build(
        proof["target_build"],
        build_number=build_number,
        label="App Store preflight target build",
        pre_release=True,
    )
    previous = _exact_keys(
        proof["previous"],
        {"app_version_id", "state", "version"},
        "previous public App Store version",
    )
    target = _exact_keys(
        proof["target"],
        {"app_version_id", "state", "version"},
        "target App Store version",
    )
    _safe_remote_id(previous["app_version_id"], "previous App Store version ID")
    _safe_remote_id(target["app_version_id"], "target App Store version ID")
    if (
        previous["version"] != previous_public_version
        or previous["state"] != "READY_FOR_DISTRIBUTION"
        or target["version"] != app_version
        or target["state"] not in {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW"}
    ):
        raise EvidenceError("App Store update proof does not match the reviewed states")


def validate_app_store_journal(
    value: dict[str, Any], *, app_version: str, build_number: str, operation: str
) -> None:
    api_operation = {"halt": "pause", "complete": "complete"}.get(operation)
    if api_operation is None:
        raise EvidenceError("App Store journal operation is unsupported")
    journal = _exact_keys(
        value,
        {
            "application_id",
            "app_version",
            "before",
            "build_number",
            "mutation_status",
            "operation",
            "schema",
        },
        "App Store attempt journal",
    )
    if (
        journal["application_id"] != APPLICATION_ID
        or journal["app_version"] != app_version
        or journal["build_number"] != build_number
        or journal["mutation_status"]
        not in {"unknown_reconcile_required", "proven_not_committed"}
        or journal["operation"] != api_operation
        or type(journal["schema"]) is not int
        or journal["schema"] != 1
    ):
        raise EvidenceError("App Store attempt journal does not match the dispatch")
    expected_state = "ACTIVE"
    if journal["mutation_status"] == "proven_not_committed":
        expected_state = {"pause": "PAUSED", "complete": "COMPLETE"}[api_operation]
    _validate_app_phased_release(
        journal["before"],
        build_number=build_number,
        expected_state=expected_state,
        mutating=False,
        label="App Store journal preflight",
    )


def cross_bind_google_play_evidence(
    result: dict[str, Any], journal: dict[str, Any]
) -> None:
    if journal["before"] != result["before"]:
        raise EvidenceError("Google Play attempt and result preflight do not match")


def cross_bind_app_store_evidence(
    result: dict[str, Any], journal: dict[str, Any], *, operation: str
) -> None:
    if operation == "start":
        operation_result = result["operation"]
        preflight = result["update_preflight"]
        if journal != preflight:
            raise EvidenceError("App Store start journal and result preflight do not match")
        proof = preflight["update_preflight"]
        phased = operation_result["phased_release"]
        if (
            proof["app_id"] != phased["app_id"]
            or proof["target"]["app_version_id"] != phased["app_version_id"]
            or proof["target_build"]["build_id"] != phased["build"]["build_id"]
            or proof["target_build"]["build_number"]
            != phased["build"]["build_number"]
        ):
            raise EvidenceError("App Store start preflight and postflight identities do not match")
        return
    if operation not in {"halt", "complete"}:
        return
    before = journal["before"]
    phased = result["phased_release"]
    if any(
        before[key] != phased[key]
        for key in ("app_id", "app_version_id", "phased_release_id", "build")
    ):
        raise EvidenceError("App Store attempt and postflight identities do not match")


def write_private(path: pathlib.Path, data: bytes) -> None:
    if path.exists() or path.is_symlink():
        raise ReceiptError("store receipt output already exists")
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise ReceiptError("store receipt write did not make progress")
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
        raise ReceiptError("store receipt is not owner-only regular storage")


def _load_evidence(
    path: pathlib.Path,
    validator: Callable[[dict[str, Any]], None],
) -> tuple[dict[str, Any] | None, str | None, bool]:
    try:
        value = read_private_json(path)
        validator(value)
        return value, None, True
    except EvidenceError as error:
        try:
            present = path.lstat() is not None
        except OSError:
            present = False
        return None, str(error), present


def _sensitive_or_unbounded(value: Any) -> bool:
    return (
        type(value) is not str
        or len(value.encode("utf-8", errors="ignore")) > MAX_INTENT_VALUE_BYTES
        or SENSITIVE_VALUE.search(value) is not None
    )


def _validate_intent(
    args: argparse.Namespace,
) -> tuple[dict[str, str | None], dict[str, Any], bool]:
    """Independently validate and redact every dispatch-derived value."""

    fields = (
        "source_revision",
        "signed_release_run_id",
        "candidate_id",
        "provenance_id",
        "store_handoff_id",
        "app_version",
        "build_number",
        "platforms",
        "operation",
        "android_previous_version",
        "android_expected_fraction",
        "android_target_fraction",
        "ios_previous_public_version",
        "android_outcome",
        "ios_outcome",
        "change_id",
        "confirmation",
        "intent_outcome",
        "workflow_sha",
        "repository",
        "run_id",
        "run_attempt",
    )
    raw = {name: getattr(args, name, "") for name in fields}
    invalid = set(getattr(args, "_cli_errors", ()))
    for name, value in raw.items():
        if _sensitive_or_unbounded(value):
            invalid.add(name)

    checks: dict[str, Callable[[str], bool]] = {
        "source_revision": lambda value: re.fullmatch(r"[0-9a-f]{40}", value)
        is not None,
        "signed_release_run_id": lambda value: POSITIVE_INTEGER.fullmatch(value)
        is not None,
        "candidate_id": lambda value: CONTENT_ID.fullmatch(value) is not None,
        "provenance_id": lambda value: CONTENT_ID.fullmatch(value) is not None,
        "store_handoff_id": lambda value: HANDOFF_ID.fullmatch(value) is not None,
        "app_version": lambda value: SEMVER.fullmatch(value) is not None,
        "build_number": lambda value: BUILD_NUMBER.fullmatch(value) is not None,
        "platforms": lambda value: value in {"android", "ios", "both"},
        "operation": lambda value: value
        in {"start", "advance", "halt", "complete", "rollback"},
        "android_previous_version": lambda value: value == "none"
        or BUILD_NUMBER.fullmatch(value) is not None,
        "android_expected_fraction": lambda value: value
        in PLAY_FRACTIONS | {"none", "1.00"},
        "android_target_fraction": lambda value: value
        in PLAY_FRACTIONS | {"none", "1.00"},
        "ios_previous_public_version": lambda value: value == "none"
        or SEMVER.fullmatch(value) is not None,
        "android_outcome": lambda value: value in STEP_OUTCOMES,
        "ios_outcome": lambda value: value in STEP_OUTCOMES,
        "change_id": lambda value: CHANGE_ID.fullmatch(value) is not None,
        "confirmation": lambda value: value == "MUTATE_PRODUCTION_MOBILE_STORES",
        "intent_outcome": lambda value: value in STEP_OUTCOMES,
        "workflow_sha": lambda value: re.fullmatch(r"[0-9a-f]{40}", value)
        is not None,
        "repository": lambda value: REPOSITORY_NAME.fullmatch(value) is not None
        and value == REPOSITORY,
        "run_id": lambda value: POSITIVE_INTEGER.fullmatch(value) is not None,
        "run_attempt": lambda value: POSITIVE_INTEGER.fullmatch(value) is not None,
    }
    for name, check in checks.items():
        value = raw[name]
        if name not in invalid and not check(value):
            invalid.add(name)

    def reject(*names: str) -> None:
        invalid.update(names)

    candidate = raw["candidate_id"]
    provenance = raw["provenance_id"]
    if not ({"candidate_id", "provenance_id"} & invalid) and candidate == provenance:
        reject("candidate_id", "provenance_id")

    platforms = raw["platforms"]
    operation = raw["operation"]
    build = raw["build_number"]
    previous = raw["android_previous_version"]
    expected = raw["android_expected_fraction"]
    target = raw["android_target_fraction"]
    if "platforms" not in invalid and "operation" not in invalid:
        if platforms == "ios":
            if operation == "rollback":
                reject("operation", "platforms")
            if (previous, expected, target) != ("none", "none", "none"):
                reject(
                    "android_previous_version",
                    "android_expected_fraction",
                    "android_target_fraction",
                )
        else:
            if (
                {"build_number", "android_previous_version"} & invalid
                or previous == "none"
                or int(previous) > 2_100_000_000
                or int(build) > 2_100_000_000
                or int(previous) >= int(build)
            ):
                reject("build_number", "android_previous_version")
            allowed = {
                ("start", "none", "0.01"),
                ("advance", "0.01", "0.02"),
                ("advance", "0.02", "0.05"),
                ("advance", "0.05", "0.10"),
                ("advance", "0.10", "0.20"),
                ("advance", "0.20", "0.50"),
                ("halt", "0.01", "0.01"),
                ("halt", "0.02", "0.02"),
                ("halt", "0.05", "0.05"),
                ("halt", "0.10", "0.10"),
                ("halt", "0.20", "0.20"),
                ("halt", "0.50", "0.50"),
                ("complete", "0.50", "1.00"),
                ("rollback", "1.00", "1.00"),
            }
            if (operation, expected, target) not in allowed:
                reject(
                    "operation",
                    "android_expected_fraction",
                    "android_target_fraction",
                )
            if operation == "rollback" and platforms != "android":
                reject("operation", "platforms")

    ios_previous = raw["ios_previous_public_version"]
    if "platforms" not in invalid and "operation" not in invalid:
        if platforms == "android":
            if ios_previous != "none":
                reject("ios_previous_public_version")
        elif operation == "start":
            if (
                "ios_previous_public_version" in invalid
                or "app_version" in invalid
                or ios_previous == "none"
                or ios_previous == raw["app_version"]
            ):
                reject("ios_previous_public_version")
        elif ios_previous != "none":
            reject("ios_previous_public_version")

    intent_outcome = raw["intent_outcome"]
    accepted = not invalid and intent_outcome == "success"
    safe: dict[str, str | None] = {
        name: None if name in invalid else value for name, value in raw.items()
    }
    validation = {
        "intent_step_outcome": safe["intent_outcome"],
        "redacted_fields": sorted(invalid),
        "status": "accepted" if accepted else "rejected",
    }
    return safe, validation, accepted


def _journal_path(root: pathlib.Path, value: Any, default: str) -> pathlib.Path:
    if type(value) is not str or not value:
        return root / default
    candidate = pathlib.Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    try:
        resolved_root = root.resolve(strict=False)
        resolved = candidate.resolve(strict=False)
    except OSError:
        return root / default
    if resolved.parent != resolved_root:
        return root / default
    return candidate


def _platform_record(
    *,
    selected: bool,
    outcome: str | None,
    result: dict[str, Any] | None,
    result_present: bool,
    journal: dict[str, Any] | None,
    journal_present: bool,
    evidence_error: str | None,
    journal_error: str | None,
    intent_rejected: bool = False,
    dependency_failed: bool = False,
    journal_required: bool = False,
) -> dict[str, Any]:
    if not selected:
        return {
            "attempt_state": "not_selected",
            "mutation_status": "not_attempted",
            "step_outcome": outcome,
            "store_api_attempt": None,
            "store_api_result": None,
        }
    if intent_rejected:
        state = "rejected_pre_mutation"
        mutation_status = "rejected_pre_mutation"
        result = None
        journal = None
    elif (
        result is not None
        and evidence_error is None
        and (
            not journal_required
            or (journal is not None and journal_error is None)
        )
    ):
        state = "succeeded"
        mutation_status = "succeeded_verified"
    elif journal_present or result_present:
        state = "failed"
        mutation_status = "unknown_reconcile_required"
    elif dependency_failed and outcome in {"", "skipped"}:
        state = "not_attempted_dependency_failed"
        mutation_status = "not_attempted"
    elif outcome in {"", "skipped"}:
        state = "not_attempted_prerequisite_failed"
        mutation_status = "not_attempted"
    elif outcome in {"failure", "cancelled"}:
        state = "failed"
        mutation_status = "proven_not_committed"
    else:
        state = "failed"
        mutation_status = "unknown_reconcile_required"
    if mutation_status not in MUTATION_STATUSES:
        raise ReceiptError("internal mutation status is invalid")
    record: dict[str, Any] = {
        "attempt_state": state,
        "mutation_status": mutation_status,
        "step_outcome": outcome,
        "store_api_attempt": journal,
        "store_api_result": result,
    }
    errors = []
    if evidence_error is not None and (
        result_present or outcome == "success"
    ):
        errors.append(evidence_error)
    if journal_error is not None and (
        journal_present or journal_required
    ):
        errors.append(journal_error)
    if errors and not intent_rejected:
        record["evidence_error"] = "; ".join(errors)
    return record


def generate(args: argparse.Namespace) -> dict[str, Any]:
    root = pathlib.Path(args.evidence_root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    safe, input_validation, accepted = _validate_intent(args)
    selected_android = safe["platforms"] in {"android", "both"}
    selected_ios = safe["platforms"] in {"ios", "both"}

    signed_run_verification: dict[str, Any] | None = None
    signed_run_verification_error: str | None = None
    if accepted:
        try:
            signed_run_verification = read_private_json(
                _journal_path(
                    root,
                    getattr(args, "run_verification", ""),
                    "signed-release-run-verification.json",
                )
            )
            signed_run_validator.validate_verification_record(
                signed_run_verification,
                repository=str(safe["repository"]),
                run_id=str(safe["signed_release_run_id"]),
                source_revision=str(safe["source_revision"]),
                app_version=str(safe["app_version"]),
                build_number=str(safe["build_number"]),
            )
        except (EvidenceError, signed_run_validator.RunValidationError) as error:
            signed_run_verification = None
            signed_run_verification_error = str(error)

    android_result: dict[str, Any] | None = None
    android_error: str | None = None
    android_result_present = False
    android_journal: dict[str, Any] | None = None
    android_journal_error: str | None = None
    android_journal_present = False
    if accepted and selected_android:
        android_result, android_error, android_result_present = _load_evidence(
            root / "google-play-rollout.json",
            lambda value: validate_google_play_result(
                value,
                version_code=str(safe["build_number"]),
                previous_version_code=str(safe["android_previous_version"]),
                operation=str(safe["operation"]),
                expected_fraction=str(safe["android_expected_fraction"]),
                target_fraction=str(safe["android_target_fraction"]),
            ),
        )
        android_journal, android_journal_error, android_journal_present = (
            _load_evidence(
                _journal_path(
                    root,
                    getattr(args, "android_journal", ""),
                    "google-play-attempt.json",
                ),
                lambda value: validate_google_play_journal(
                    value,
                    version_code=str(safe["build_number"]),
                    previous_version_code=str(safe["android_previous_version"]),
                    operation=str(safe["operation"]),
                    expected_fraction=str(safe["android_expected_fraction"]),
                    target_fraction=str(safe["android_target_fraction"]),
                ),
            )
        )
        if android_result is not None and android_journal is not None:
            try:
                cross_bind_google_play_evidence(android_result, android_journal)
            except EvidenceError as error:
                android_journal_error = str(error)
    ios_result: dict[str, Any] | None = None
    ios_error: str | None = None
    ios_result_present = False
    ios_journal: dict[str, Any] | None = None
    ios_journal_error: str | None = None
    ios_journal_present = False
    if accepted and selected_ios:
        operation_result, operation_error, operation_present = _load_evidence(
            root / "apple-store-operation.json",
            lambda value: validate_app_store_result(
                value,
                app_version=str(safe["app_version"]),
                build_number=str(safe["build_number"]),
                operation=str(safe["operation"]),
            ),
        )
        ios_result = operation_result
        ios_error = operation_error
        ios_result_present = operation_present
        if safe["operation"] == "start":
            preflight_result, preflight_error, preflight_present = _load_evidence(
                root / "apple-update-preflight.json",
                lambda value: validate_app_update_preflight(
                    value,
                    app_version=str(safe["app_version"]),
                    build_number=str(safe["build_number"]),
                    previous_public_version=str(safe["ios_previous_public_version"]),
                ),
            )
            ios_journal = preflight_result
            ios_journal_error = preflight_error
            ios_journal_present = preflight_present
            ios_result_present = operation_present or preflight_present
            ios_result = (
                {
                    "operation": operation_result,
                    "update_preflight": preflight_result,
                }
                if operation_result is not None and preflight_result is not None
                else None
            )
            errors = [
                item
                for item in (preflight_error, operation_error)
                if item is not None
            ]
            ios_error = "; ".join(errors) if errors else None
        elif safe["operation"] in {"halt", "complete"}:
            ios_journal, ios_journal_error, ios_journal_present = _load_evidence(
                _journal_path(
                    root,
                    getattr(args, "ios_journal", ""),
                    "apple-store-attempt.json",
                ),
                lambda value: validate_app_store_journal(
                    value,
                    app_version=str(safe["app_version"]),
                    build_number=str(safe["build_number"]),
                    operation=str(safe["operation"]),
                ),
            )
        if ios_result is not None and ios_journal is not None:
            try:
                cross_bind_app_store_evidence(
                    ios_result,
                    ios_journal,
                    operation=str(safe["operation"]),
                )
            except EvidenceError as error:
                ios_journal_error = str(error)

    android = _platform_record(
        selected=selected_android,
        outcome=safe["android_outcome"],
        result=android_result,
        result_present=android_result_present,
        journal=android_journal,
        journal_present=android_journal_present,
        evidence_error=android_error,
        journal_error=android_journal_error,
        intent_rejected=not accepted,
        journal_required=selected_android,
    )
    ios = _platform_record(
        selected=selected_ios,
        outcome=safe["ios_outcome"],
        result=ios_result,
        result_present=ios_result_present,
        journal=ios_journal,
        journal_present=ios_journal_present,
        evidence_error=ios_error,
        journal_error=ios_journal_error,
        intent_rejected=not accepted,
        dependency_failed=(
            safe["platforms"] == "both" and android["attempt_state"] != "succeeded"
        ),
        journal_required=(
            selected_ios and safe["operation"] in {"start", "halt", "complete"}
        ),
    )
    selected_statuses = [
        record["mutation_status"]
        for record, selected in ((android, selected_android), (ios, selected_ios))
        if selected
    ]
    if accepted and signed_run_verification is not None and selected_statuses and all(
        status == "succeeded_verified" for status in selected_statuses
    ):
        overall = "succeeded"
    elif accepted and signed_run_verification is not None and any(
        status == "succeeded_verified" for status in selected_statuses
    ):
        overall = "partial_failure"
    else:
        overall = "failed"

    receipt = {
        "android": android,
        "android_expected_current_fraction": safe["android_expected_fraction"],
        "android_previous_production_version_code": safe["android_previous_version"],
        "android_target_fraction": safe["android_target_fraction"],
        "app_version": safe["app_version"],
        "build_number": safe["build_number"],
        "candidate_id": safe["candidate_id"],
        "change_id": safe["change_id"],
        "classification": "protected mobile store rollout outcome receipt",
        "input_validation": input_validation,
        "ios": ios,
        "ios_previous_public_version": safe["ios_previous_public_version"],
        "operation": safe["operation"],
        "overall_result": overall,
        "platforms": safe["platforms"],
        "provenance_id": safe["provenance_id"],
        "recorded_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "schema": 3,
        "signed_release_run_verification": signed_run_verification,
        "signed_release_run_verification_error": signed_run_verification_error,
        "signed_release_run_id": safe["signed_release_run_id"],
        "source_revision": safe["source_revision"],
        "store_handoff_id": safe["store_handoff_id"],
        "workflow": {
            "github_run_attempt": safe["run_attempt"],
            "github_run_id": safe["run_id"],
            "path": ".github/workflows/mobile-store-rollout.yml",
            "repository": safe["repository"],
            "workflow_sha": safe["workflow_sha"],
        },
    }
    raw = (
        json.dumps(
            receipt,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("ascii")
    digest = hashlib.sha256(raw).hexdigest()
    content_id = "mobile-store-rollout-v3:sha256:" + digest
    write_private(root / "mobile-store-rollout-receipt.json", raw)
    package = {
        "content_id": content_id,
        "receipt_sha256": digest,
        "schema": 3,
    }
    write_private(
        root / "PACKAGE_SHA256.json",
        (
            json.dumps(package, separators=(",", ":"), sort_keys=True) + "\n"
        ).encode("ascii"),
    )
    with pathlib.Path(args.github_output).open("a", encoding="utf-8") as output:
        output.write(f"content_id={content_id}\n")
        output.write(f"overall_result={overall}\n")
    with pathlib.Path(args.github_step_summary).open("a", encoding="utf-8") as summary:
        summary.write("## Protected mobile store rollout\n\n")
        summary.write(f"- Receipt: `{content_id}`\n")
        summary.write(f"- Overall result: `{overall}`\n")
        summary.write(f"- Android: `{android['attempt_state']}`\n")
        summary.write(f"- iOS: `{ios['attempt_state']}`\n")
        summary.write("- Store-side audit records and approval remain required.\n")
    return receipt


PLATFORM_RECEIPT_KEYS = {
    "android",
    "android_expected_current_fraction",
    "android_previous_production_version_code",
    "android_target_fraction",
    "app_version",
    "build_number",
    "candidate_id",
    "change_id",
    "classification",
    "input_validation",
    "ios",
    "ios_previous_public_version",
    "operation",
    "overall_result",
    "platforms",
    "provenance_id",
    "recorded_at",
    "schema",
    "signed_release_run_verification",
    "signed_release_run_verification_error",
    "signed_release_run_id",
    "source_revision",
    "store_handoff_id",
    "workflow",
}
PLATFORM_RECORD_BASE_KEYS = {
    "attempt_state",
    "mutation_status",
    "step_outcome",
    "store_api_attempt",
    "store_api_result",
}
ARTIFACT_DIGEST = re.compile(r"^[0-9a-f]{64}$")
PLATFORM_CONTENT_ID = re.compile(
    r"^mobile-store-rollout-v3:sha256:[0-9a-f]{64}$"
)


def _read_artifact_json(path: pathlib.Path) -> dict[str, Any]:
    """Read canonical downloaded-artifact JSON without trusting restored modes."""

    descriptor: int | None = None
    try:
        linked = path.lstat()
        if (
            not stat.S_ISREG(linked.st_mode)
            or linked.st_uid != os.getuid()
            or linked.st_nlink != 1
            or linked.st_size <= 0
            or linked.st_size > MAX_EVIDENCE_BYTES
            or linked.st_mode & 0o022
        ):
            raise EvidenceError("downloaded platform evidence is unsafe")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        before = os.fstat(descriptor)
        data = b""
        while len(data) <= MAX_EVIDENCE_BYTES:
            chunk = os.read(descriptor, MAX_EVIDENCE_BYTES + 1 - len(data))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
        if (
            _file_identity(linked) != _file_identity(before)
            or _file_identity(before) != _file_identity(after)
            or len(data) != before.st_size
            or len(data) > MAX_EVIDENCE_BYTES
        ):
            raise EvidenceError("downloaded platform evidence changed while read")
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
        if not isinstance(value, dict) or data != canonical_json_bytes(value):
            raise EvidenceError("downloaded platform evidence is not canonical JSON")
        return value
    except FileNotFoundError as error:
        raise EvidenceError("downloaded platform evidence is missing") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError("downloaded platform evidence could not be read") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _expected_platform_values(args: argparse.Namespace, platform: str) -> dict[str, str]:
    if platform == "android":
        return {
            "android_expected_current_fraction": args.android_expected_fraction,
            "android_previous_production_version_code": args.android_previous_version,
            "android_target_fraction": args.android_target_fraction,
            "ios_previous_public_version": "none",
        }
    return {
        "android_expected_current_fraction": "none",
        "android_previous_production_version_code": "none",
        "android_target_fraction": "none",
        "ios_previous_public_version": args.ios_previous_public_version,
    }


def validate_platform_package(
    root: pathlib.Path,
    *,
    platform: str,
    args: argparse.Namespace,
    require_success: bool,
) -> dict[str, Any]:
    """Validate one immutable platform artifact and return a bounded summary."""

    if platform not in {"android", "ios"}:
        raise EvidenceError("platform package selector is invalid")
    receipt_path = root / "mobile-store-rollout-receipt.json"
    package_path = root / "PACKAGE_SHA256.json"
    receipt = _exact_keys(
        _read_artifact_json(receipt_path), PLATFORM_RECEIPT_KEYS, "platform receipt"
    )
    package = _exact_keys(
        _read_artifact_json(package_path),
        {"content_id", "receipt_sha256", "schema"},
        "platform receipt package",
    )
    receipt_digest = hashlib.sha256(canonical_json_bytes(receipt)).hexdigest()
    if (
        package["schema"] != 3
        or package["receipt_sha256"] != receipt_digest
        or package["content_id"] != "mobile-store-rollout-v3:sha256:" + receipt_digest
        or PLATFORM_CONTENT_ID.fullmatch(str(package["content_id"])) is None
    ):
        raise EvidenceError("platform receipt package digest is invalid")

    expected = {
        "app_version": args.app_version,
        "build_number": args.build_number,
        "candidate_id": args.candidate_id,
        "change_id": args.change_id,
        "operation": args.operation,
        "platforms": platform,
        "provenance_id": args.provenance_id,
        "signed_release_run_id": args.signed_release_run_id,
        "source_revision": args.source_revision,
        "store_handoff_id": args.store_handoff_id,
        **_expected_platform_values(args, platform),
    }
    if any(receipt.get(name) != value for name, value in expected.items()):
        raise EvidenceError("platform receipt identity does not match the dispatch")
    if (
        receipt["classification"]
        != "protected mobile store rollout outcome receipt"
        or receipt["schema"] != 3
        or receipt["signed_release_run_verification_error"] is not None
        or not isinstance(receipt["recorded_at"], str)
        or RFC3339_SECONDS.fullmatch(receipt["recorded_at"]) is None
    ):
        raise EvidenceError("platform receipt metadata is invalid")
    validation = _exact_keys(
        receipt["input_validation"],
        {"intent_step_outcome", "redacted_fields", "status"},
        "platform input validation",
    )
    if validation != {
        "intent_step_outcome": "success",
        "redacted_fields": [],
        "status": "accepted",
    }:
        raise EvidenceError("platform receipt intent was not accepted")
    workflow = _exact_keys(
        receipt["workflow"],
        {
            "github_run_attempt",
            "github_run_id",
            "path",
            "repository",
            "workflow_sha",
        },
        "platform workflow identity",
    )
    if workflow != {
        "github_run_attempt": args.run_attempt,
        "github_run_id": args.run_id,
        "path": ".github/workflows/mobile-store-rollout.yml",
        "repository": args.repository,
        "workflow_sha": args.workflow_sha,
    }:
        raise EvidenceError("platform workflow identity changed")
    verification = receipt["signed_release_run_verification"]
    signed_run_validator.validate_verification_record(
        verification,
        repository=args.repository,
        run_id=args.signed_release_run_id,
        source_revision=args.source_revision,
        app_version=args.app_version,
        build_number=args.build_number,
    )

    selected = _exact_keys(
        receipt[platform],
        set(receipt[platform]),
        "selected platform outcome",
    )
    if not PLATFORM_RECORD_BASE_KEYS.issubset(selected) or set(selected) - (
        PLATFORM_RECORD_BASE_KEYS | {"evidence_error"}
    ):
        raise EvidenceError("selected platform outcome has an unexpected schema")
    other_name = "ios" if platform == "android" else "android"
    other = _exact_keys(
        receipt[other_name], PLATFORM_RECORD_BASE_KEYS, "unselected platform outcome"
    )
    if other != {
        "attempt_state": "not_selected",
        "mutation_status": "not_attempted",
        "step_outcome": "skipped",
        "store_api_attempt": None,
        "store_api_result": None,
    }:
        raise EvidenceError("unselected platform outcome is not closed")

    if platform == "android" and selected["store_api_result"] is not None:
        validate_google_play_result(
            selected["store_api_result"],
            version_code=args.build_number,
            previous_version_code=args.android_previous_version,
            operation=args.operation,
            expected_fraction=args.android_expected_fraction,
            target_fraction=args.android_target_fraction,
        )
        if selected["store_api_attempt"] is None:
            raise EvidenceError("Android platform receipt is missing its attempt journal")
        validate_google_play_journal(
            selected["store_api_attempt"],
            version_code=args.build_number,
            previous_version_code=args.android_previous_version,
            operation=args.operation,
            expected_fraction=args.android_expected_fraction,
            target_fraction=args.android_target_fraction,
        )
        cross_bind_google_play_evidence(
            selected["store_api_result"], selected["store_api_attempt"]
        )
    if platform == "ios" and selected["store_api_result"] is not None:
        result = selected["store_api_result"]
        if args.operation == "start":
            result = _exact_keys(
                result,
                {"operation", "update_preflight"},
                "App Store start evidence",
            )
            validate_app_store_result(
                result["operation"],
                app_version=args.app_version,
                build_number=args.build_number,
                operation=args.operation,
            )
            validate_app_update_preflight(
                result["update_preflight"],
                app_version=args.app_version,
                build_number=args.build_number,
                previous_public_version=args.ios_previous_public_version,
            )
            if selected["store_api_attempt"] != result["update_preflight"]:
                raise EvidenceError("App Store start attempt and result do not match")
            cross_bind_app_store_evidence(
                result,
                selected["store_api_attempt"],
                operation=args.operation,
            )
        else:
            validate_app_store_result(
                result,
                app_version=args.app_version,
                build_number=args.build_number,
                operation=args.operation,
            )
        if args.operation in {"halt", "complete"}:
            if selected["store_api_attempt"] is None:
                raise EvidenceError("App Store platform receipt is missing its journal")
            validate_app_store_journal(
                selected["store_api_attempt"],
                app_version=args.app_version,
                build_number=args.build_number,
                operation=args.operation,
            )
            cross_bind_app_store_evidence(
                selected["store_api_result"],
                selected["store_api_attempt"],
                operation=args.operation,
            )

    succeeded = (
        receipt["overall_result"] == "succeeded"
        and selected["attempt_state"] == "succeeded"
        and selected["mutation_status"] == "succeeded_verified"
        and selected["step_outcome"] == "success"
        and "evidence_error" not in selected
    )
    if receipt["overall_result"] not in {"succeeded", "failed"}:
        raise EvidenceError("single-platform receipt has an invalid overall result")
    if require_success and not succeeded:
        raise EvidenceError("platform mutation was not succeeded and verified")
    return {
        "attempt_state": selected["attempt_state"],
        "content_id": package["content_id"],
        "mutation_status": selected["mutation_status"],
        "overall_result": receipt["overall_result"],
        "receipt_sha256": package["receipt_sha256"],
        "succeeded_verified": succeeded,
        "verification": verification,
    }


def _aggregate_platform(
    *,
    args: argparse.Namespace,
    platform: str,
    requested: bool,
    blocked_reason: str | None,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    job_result = getattr(args, f"{platform}_job_result")
    artifact_id = getattr(args, f"{platform}_artifact_id")
    artifact_digest = getattr(args, f"{platform}_artifact_digest")
    root = pathlib.Path(getattr(args, f"{platform}_root"))
    artifact_valid = (
        POSITIVE_INTEGER.fullmatch(artifact_id) is not None
        and ARTIFACT_DIGEST.fullmatch(artifact_digest) is not None
    )
    summary: dict[str, Any] | None = None
    validation_error: str | None = None
    if artifact_valid:
        try:
            summary = validate_platform_package(
                root, platform=platform, args=args, require_success=False
            )
        except (OSError, EvidenceError, signed_run_validator.RunValidationError):
            validation_error = "platform artifact failed closed validation"
    elif requested and blocked_reason is None:
        validation_error = "requested platform artifact identity is missing"

    if not requested:
        valid = job_result == "skipped" and not artifact_id and not artifact_digest
        status = "not_selected" if valid else "unexpected_execution"
        reason = "not_selected" if valid else "unselected_platform_ran"
    elif blocked_reason is not None:
        valid = job_result == "skipped" and not artifact_id and not artifact_digest
        status = "not_run_safety_dependency" if valid else "failed"
        reason = blocked_reason if valid else "safety_block_was_bypassed"
    elif (
        job_result == "success"
        and summary is not None
        and summary["succeeded_verified"]
        and validation_error is None
    ):
        status = "succeeded_verified"
        reason = None
        valid = True
    else:
        status = "failed"
        reason = "requested_job_or_evidence_failed"
        valid = False

    record = {
        "artifact": (
            {"digest": "sha256:" + artifact_digest, "id": artifact_id}
            if artifact_valid
            else None
        ),
        "job_result": job_result,
        "not_run_reason": reason,
        "platform_content_id": None if summary is None else summary["content_id"],
        "platform_receipt_sha256": (
            None if summary is None else summary["receipt_sha256"]
        ),
        "requested": requested,
        "status": status,
        "validation_error": validation_error,
    }
    return record, summary if valid else None


def aggregate(args: argparse.Namespace) -> dict[str, Any]:
    """Generate the credential-free canonical receipt from isolated artifacts."""

    root = pathlib.Path(args.output_root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    intent = argparse.Namespace(
        **vars(args),
        android_outcome="success",
        ios_outcome="success",
        intent_outcome="success",
        evidence_root=str(root),
    )
    safe, input_validation, accepted = _validate_intent(intent)
    if not accepted:
        raise ReceiptError("aggregate dispatch identity is invalid")
    for name in ("android_job_result", "ios_job_result"):
        if getattr(args, name) not in {"success", "failure", "cancelled", "skipped"}:
            raise ReceiptError("aggregate job result is invalid")
    selected_android = args.platforms in {"android", "both"}
    selected_ios = args.platforms in {"ios", "both"}
    if (
        selected_android
        and selected_ios
        and args.android_artifact_id
        and args.android_artifact_id == args.ios_artifact_id
    ):
        raise ReceiptError("platform artifacts must have distinct immutable IDs")
    android, android_summary = _aggregate_platform(
        args=args,
        platform="android",
        requested=selected_android,
        blocked_reason=None,
    )
    ios_blocked = (
        "android_not_succeeded_verified"
        if args.platforms == "both" and android["status"] != "succeeded_verified"
        else None
    )
    ios, ios_summary = _aggregate_platform(
        args=args,
        platform="ios",
        requested=selected_ios,
        blocked_reason=ios_blocked,
    )
    selected = [android] if args.platforms == "android" else [ios]
    if args.platforms == "both":
        selected = [android, ios]
    unselected_closed = (
        (args.platforms != "android" or ios["status"] == "not_selected")
        and (args.platforms != "ios" or android["status"] == "not_selected")
    )
    overall = (
        "succeeded"
        if unselected_closed
        and all(item["status"] == "succeeded_verified" for item in selected)
        else "failed"
    )
    verifications = [
        item["verification"]
        for item in (android_summary, ios_summary)
        if item is not None
    ]
    if len(verifications) > 1 and verifications[0] != verifications[1]:
        raise ReceiptError("platform signed-run verifications do not match")
    receipt = {
        "android": android,
        "android_expected_current_fraction": safe["android_expected_fraction"],
        "android_previous_production_version_code": safe["android_previous_version"],
        "android_target_fraction": safe["android_target_fraction"],
        "app_version": safe["app_version"],
        "build_number": safe["build_number"],
        "candidate_id": safe["candidate_id"],
        "change_id": safe["change_id"],
        "classification": "protected isolated mobile store rollout receipt",
        "input_validation": input_validation,
        "ios": ios,
        "ios_previous_public_version": safe["ios_previous_public_version"],
        "operation": safe["operation"],
        "overall_result": overall,
        "platforms": safe["platforms"],
        "provenance_id": safe["provenance_id"],
        "recorded_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "schema": 4,
        "signed_release_run_id": safe["signed_release_run_id"],
        "source_revision": safe["source_revision"],
        "store_handoff_id": safe["store_handoff_id"],
        "workflow": {
            "github_run_attempt": safe["run_attempt"],
            "github_run_id": safe["run_id"],
            "path": ".github/workflows/mobile-store-rollout.yml",
            "repository": safe["repository"],
            "workflow_sha": safe["workflow_sha"],
        },
    }
    raw = canonical_json_bytes(receipt)
    digest = hashlib.sha256(raw).hexdigest()
    content_id = "mobile-store-rollout-v4:sha256:" + digest
    write_private(root / "mobile-store-rollout-receipt.json", raw)
    write_private(
        root / "PACKAGE_SHA256.json",
        canonical_json_bytes(
            {"content_id": content_id, "receipt_sha256": digest, "schema": 4}
        ),
    )
    with pathlib.Path(args.github_output).open("a", encoding="utf-8") as output:
        output.write(f"content_id={content_id}\n")
        output.write(f"overall_result={overall}\n")
    with pathlib.Path(args.github_step_summary).open(
        "a", encoding="utf-8"
    ) as summary_output:
        summary_output.write("## Isolated mobile store rollout\n\n")
        summary_output.write(f"- Receipt: `{content_id}`\n")
        summary_output.write(f"- Overall result: `{overall}`\n")
        summary_output.write(f"- Android: `{android['status']}`\n")
        summary_output.write(f"- iOS: `{ios['status']}`\n")
    return receipt


REQUIRED_CLI_OPTIONS = (
    "source-revision",
    "signed-release-run-id",
    "candidate-id",
    "provenance-id",
    "store-handoff-id",
    "app-version",
    "build-number",
    "platforms",
    "operation",
    "android-previous-version",
    "android-expected-fraction",
    "android-target-fraction",
    "ios-previous-public-version",
    "android-outcome",
    "ios-outcome",
    "change-id",
    "confirmation",
    "intent-outcome",
    "workflow-sha",
    "repository",
    "run-id",
    "run-attempt",
    "run-verification",
    "evidence-root",
    "github-output",
    "github-step-summary",
)
OPTIONAL_CLI_OPTIONS = ("android-journal", "ios-journal")
AGGREGATE_REQUIRED_OPTIONS = (
    "source-revision",
    "signed-release-run-id",
    "candidate-id",
    "provenance-id",
    "store-handoff-id",
    "app-version",
    "build-number",
    "platforms",
    "operation",
    "android-previous-version",
    "android-expected-fraction",
    "android-target-fraction",
    "ios-previous-public-version",
    "change-id",
    "confirmation",
    "workflow-sha",
    "repository",
    "run-id",
    "run-attempt",
    "android-job-result",
    "android-artifact-id",
    "android-artifact-digest",
    "android-root",
    "ios-job-result",
    "ios-artifact-id",
    "ios-artifact-digest",
    "ios-root",
    "output-root",
    "github-output",
    "github-step-summary",
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    for name in REQUIRED_CLI_OPTIONS:
        parser.add_argument(f"--{name}", required=True)
    for name in OPTIONAL_CLI_OPTIONS:
        parser.add_argument(f"--{name}", default="")
    return parser


def _aggregate_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Aggregate isolated store receipts")
    for name in AGGREGATE_REQUIRED_OPTIONS:
        parser.add_argument(f"--{name}", required=True)
    return parser


def _verify_platform_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify one isolated store receipt")
    for name in (
        "root",
        "platform",
        "source-revision",
        "signed-release-run-id",
        "candidate-id",
        "provenance-id",
        "store-handoff-id",
        "app-version",
        "build-number",
        "operation",
        "android-previous-version",
        "android-expected-fraction",
        "android-target-fraction",
        "ios-previous-public-version",
        "change-id",
        "workflow-sha",
        "repository",
        "run-id",
        "run-attempt",
    ):
        parser.add_argument(f"--{name}", required=True)
    return parser


def _parse_untrusted_cli(argv: list[str]) -> argparse.Namespace:
    """Parse string options without interpreting a leading-dash value as an option.

    ``argparse`` exits before the always-run receipt step can redact values such as
    a PEM marker. This deliberately small parser consumes one opaque value per known
    option and records structural errors without retaining unknown tokens.
    """

    known = set(REQUIRED_CLI_OPTIONS) | set(OPTIONAL_CLI_OPTIONS)
    values: dict[str, str] = {}
    errors: set[str] = set()
    index = 0
    while index < len(argv):
        token = argv[index]
        if not token.startswith("--"):
            errors.add("command_line")
            index += 1
            continue
        option, separator, inline = token[2:].partition("=")
        if option not in known:
            errors.add("command_line")
            index += 1
            continue
        field = option.replace("-", "_")
        if field in values:
            errors.add(field)
        if separator:
            values[field] = inline
            index += 1
            continue
        if index + 1 >= len(argv):
            values[field] = ""
            errors.add(field)
            index += 1
            continue
        following = argv[index + 1]
        following_option = following[2:].partition("=")[0] if following.startswith("--") else ""
        if following_option in known:
            values[field] = ""
            errors.add(field)
            index += 1
            continue
        values[field] = following
        index += 2

    for option in REQUIRED_CLI_OPTIONS:
        field = option.replace("-", "_")
        if field not in values:
            values[field] = ""
            errors.add(field)
    for option in OPTIONAL_CLI_OPTIONS:
        values.setdefault(option.replace("-", "_"), "")
    namespace = argparse.Namespace(**values)
    namespace._cli_errors = tuple(sorted(errors))
    return namespace


def main(argv: list[str] | None = None) -> int:
    command_line = os.sys.argv[1:] if argv is None else argv
    try:
        if command_line[:1] == ["aggregate"]:
            aggregate(_aggregate_parser().parse_args(command_line[1:]))
            return 0
        if command_line[:1] == ["verify-platform"]:
            arguments = _verify_platform_parser().parse_args(command_line[1:])
            validate_platform_package(
                pathlib.Path(arguments.root),
                platform=arguments.platform,
                args=arguments,
                require_success=True,
            )
            return 0
        generate(_parse_untrusted_cli(command_line))
    except (
        OSError,
        ReceiptError,
        EvidenceError,
        signed_run_validator.RunValidationError,
    ):
        print("store receipt generation failed safely", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
