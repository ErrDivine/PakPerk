#!/usr/bin/env python3
"""Validate and package protected physical-device acceptance evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import io
import json
import os
import pathlib
import re
import stat
import sys
import tarfile
import urllib.parse
from typing import Any, Optional


CANDIDATE_ROOT = pathlib.Path("/opt/pakperk/mobile-candidates")
PROVENANCE_ROOT = pathlib.Path("/opt/pakperk/mobile-release-provenance")
RUNNER_SESSION_ROOT = pathlib.Path("/opt/pakperk/mobile-runner-sessions")
STAGING_CONFIG = (
    pathlib.Path(__file__).resolve().parents[1] / "mobile/config/staging.json"
)
STAGING_ANDROID_APPLICATION_ID = "app.pakperk.pakperk.staging"
STAGING_IOS_APPLICATION_ID = "app.pakperk.pakperk.staging"
EVIDENCE_ARCHIVE_NAME = "mobile-acceptance-evidence.json"
CHECKSUM_ARCHIVE_NAME = "SHA256SUMS"

SCENARIO_ASSERTIONS = {
    "cold_cache_launch": (
        "populated_local_cache_seeded",
        "first_readable_frame_measured",
        "native_launch_continuity_verified",
    ),
    "vertical_20_papers_latency": (
        "physical_vertical_gestures_used",
        "controlled_latency_enabled",
        "controlled_packet_loss_enabled",
        "no_blank_cards_observed",
        "sequential_cache_hits_observed",
    ),
    "introduction_intent_only": (
        "no_prepare_before_horizontal_intent",
        "prepare_started_after_horizontal_intent",
    ),
    "branch_state_restoration": (
        "exact_paper_restored",
        "exact_stage_restored",
        "exact_vertical_offset_restored",
        "exact_horizontal_offset_restored",
    ),
    "oidc_pkce_sign_in": (
        "system_browser_used",
        "embedded_webview_not_used",
        "pkce_s256_verified",
        "release_tenant_callback_completed",
    ),
    "library_save_relaunch_sync": (
        "save_acknowledged_by_staging",
        "os_process_terminated",
        "installed_app_relaunched",
        "saved_state_resynchronized",
    ),
    "two_device_library_sync": (
        "same_test_account_used",
        "independent_installations_verified",
        "remote_save_converged",
    ),
    "comment_create_edit_delete": (
        "comment_created_on_staging",
        "comment_version_advanced_on_edit",
        "comment_deleted_on_staging",
    ),
    "report_and_block": (
        "report_acknowledged_by_staging",
        "blocked_content_hidden_immediately",
        "blocked_content_hidden_after_relaunch",
    ),
    "expired_token_refresh": (
        "real_access_token_expired",
        "exactly_one_refresh_completed",
        "original_action_continued",
    ),
    "account_deletion_reauthentication": (
        "recent_authentication_completed",
        "account_immediately_deactivated",
        "sessions_revoked",
        "provider_cleanup_verified",
        "deletion_status_path_verified",
    ),
    "offline_outbox_process_death_recovery": (
        "cached_paper_read_offline",
        "save_queued_offline",
        "os_process_terminated_with_pending_outbox",
        "same_uuid_recovered_after_relaunch",
        "single_server_mutation_after_reconnect",
    ),
    "reduced_motion_startup": (
        "cold_start_reduced_motion_verified",
        "warm_start_reduced_motion_verified",
        "stationary_bounded_transitions_verified",
    ),
    "strict_full_text_policy": (
        "strict_signed_flavor_verified",
        "metadata_save_comments_available",
        "original_arxiv_link_available",
        "derived_fallback_masked_online",
        "derived_fallback_masked_offline_cache",
    ),
    "root_navigation_safe_area": (
        "android_gesture_safe_area_verified",
        "android_three_button_safe_area_verified",
        "iphone_home_indicator_safe_area_verified",
        "composer_above_root_navigation_verified",
        "single_keyboard_inset_verified",
        "android_gesture_system_back_verified",
        "android_three_button_system_back_verified",
        "ios_edge_back_gesture_verified",
    ),
    "hardware_keyboard_navigation": (
        "android_physical_keyboard_attached",
        "ipad_physical_keyboard_attached",
        "tab_forward_verified",
        "shift_tab_reverse_verified",
        "enter_activation_verified",
        "escape_dismissal_or_back_verified",
        "focus_order_matches_visual_order",
        "visible_focus_indicator_verified",
        "two_hundred_percent_text_scale_verified",
        "minimum_interactive_targets_verified",
    ),
}

SCENARIO_IDS = tuple(SCENARIO_ASSERTIONS)

SCENARIO_DEVICE_ROLES = {
    scenario_id: ("android_gesture",) for scenario_id in SCENARIO_IDS
}
SCENARIO_DEVICE_ROLES.update(
    {
        "two_device_library_sync": (
            "android_gesture",
            "ipad_keyboard_secondary_sync",
        ),
        "strict_full_text_policy": (
            "android_gesture",
            "ios_home_indicator",
        ),
        "root_navigation_safe_area": (
            "android_gesture",
            "android_three_button",
            "ios_home_indicator",
        ),
        "hardware_keyboard_navigation": (
            "android_gesture",
            "ipad_keyboard_secondary_sync",
        ),
    }
)

# Rules are (operator, lower/equal, optional upper). Values are closed integers.
SCENARIO_METRIC_RULES = {
    "cold_cache_launch": {
        "populated_cache_records": ("min", 1, None),
        "first_readable_frame_ms": ("range", 1, 10_000),
    },
    "vertical_20_papers_latency": {
        "papers_swiped": ("min", 20, None),
        "simulated_latency_ms": ("range", 1, 60_000),
        "simulated_packet_loss_percent": ("range", 1, 100),
        "blank_cards": ("eq", 0, None),
        "sequential_cache_hits": ("min", 20, None),
    },
    "introduction_intent_only": {
        "prepare_calls_before_intent": ("eq", 0, None),
        "prepare_calls_after_intent": ("min", 1, None),
    },
    "branch_state_restoration": {
        "exact_state_fields_restored": ("eq", 4, None),
    },
    "oidc_pkce_sign_in": {
        "pkce_verifier_entropy_bits": ("min", 256, None),
        "embedded_webview_count": ("eq", 0, None),
    },
    "library_save_relaunch_sync": {
        "process_relaunches": ("min", 1, None),
        "sync_confirmations": ("min", 1, None),
    },
    "two_device_library_sync": {
        "independent_installations": ("eq", 2, None),
        "convergence_checks": ("min", 1, None),
    },
    "comment_create_edit_delete": {
        "lifecycle_operations": ("eq", 3, None),
    },
    "report_and_block": {
        "persistence_checks": ("min", 1, None),
        "visible_blocked_items": ("eq", 0, None),
    },
    "expired_token_refresh": {
        "refresh_attempts": ("eq", 1, None),
        "continued_actions": ("eq", 1, None),
    },
    "account_deletion_reauthentication": {
        "reauthentication_prompts": ("eq", 1, None),
        "cleanup_checks": ("min", 4, None),
    },
    "offline_outbox_process_death_recovery": {
        "process_relaunches": ("min", 1, None),
        "recovered_same_uuid_operations": ("min", 1, None),
        "duplicate_server_mutations": ("eq", 0, None),
    },
    "reduced_motion_startup": {
        "startup_modes": ("eq", 2, None),
        "unbounded_motion_events": ("eq", 0, None),
    },
    "strict_full_text_policy": {
        "allowed_surface_checks": ("min", 4, None),
        "derived_fallback_exposures": ("eq", 0, None),
    },
    "root_navigation_safe_area": {
        "navigation_modes_tested": ("eq", 3, None),
        "system_back_paths_tested": ("eq", 3, None),
        "unsafe_inset_failures": ("eq", 0, None),
    },
    "hardware_keyboard_navigation": {
        "platform_keyboard_runs": ("eq", 2, None),
        "key_commands_per_platform": ("min", 4, None),
        "text_scale_percent": ("min", 200, None),
        "clipped_action_labels": ("eq", 0, None),
    },
}

DEVICE_CONTRACT = {
    "android_gesture": ("android", "gesture", "phone", True),
    "android_three_button": ("android", "three_button", "phone", False),
    "ios_home_indicator": ("ios", "home_indicator", "phone", False),
    "ipad_keyboard_secondary_sync": ("ios", "home_indicator", "tablet", True),
}

CANDIDATE_TOP_LEVEL_KEYS = {
    "schema",
    "classification",
    "source_revision",
    "environment",
    "app_version",
    "build_number",
    "strict_full_text",
    "provenance_id",
    "android",
    "ios",
}
CANDIDATE_ANDROID_KEYS = {
    "aab_sha256",
    "apk_sha256",
    "application_id",
    "signer_sha256",
}
CANDIDATE_IOS_KEYS = {
    "ipa_sha256",
    "application_id",
    "signer_sha256",
    "team_id",
}
CANDIDATE_BINDING_KEYS = {
    "manifest_id",
    "provenance_id",
    "signed_workflow",
    "strict_full_text",
    "android",
    "ios",
}

PROVENANCE_TOP_LEVEL_KEYS = {
    "schema",
    "classification",
    "source_revision",
    "environment",
    "app_version",
    "build_number",
    "created_at",
    "workflow",
    "android",
    "ios",
}
PROVENANCE_WORKFLOW_KEYS = {
    "repository",
    "path",
    "job",
    "workflow_sha",
    "github_run_id",
    "github_run_attempt",
    "stage",
}

RUNNER_SESSION_TOP_LEVEL_KEYS = {
    "schema",
    "classification",
    "source_revision",
    "session_id",
    "host_identity_hash",
    "runner_class",
    "physical_identities",
    "dedicated",
    "ephemeral",
    "created_at",
    "expires_at",
}
RUNNER_SESSION_BINDING_KEYS = {
    "attestation_id",
    "session_id",
    "host_identity_hash",
    "runner_class",
    "created_at",
    "expires_at",
}
RUNNER_SESSION_VALIDATED_KEYS = RUNNER_SESSION_BINDING_KEYS | {"physical_identities"}

TOP_LEVEL_KEYS = {
    "schema",
    "classification",
    "source_revision",
    "candidate_id",
    "app_version",
    "build_number",
    "environment",
    "coordinates",
    "candidate",
    "runner_session",
    "driver",
    "run",
    "started_at",
    "finished_at",
    "devices",
    "scenarios",
    "redaction",
}

SAFE_VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
CANDIDATE_ID = re.compile(r"sha256:[0-9a-f]{64}")
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]{0,19}")
OS_VERSION = re.compile(r"[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}")
APP_VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?"
)
BUILD_NUMBER = re.compile(r"[1-9][0-9]{0,9}")
HARDWARE_MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9,._()+-]{0,79}")
CLIENT_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}")
APPLICATION_ID = re.compile(
    r"[A-Za-z][A-Za-z0-9_-]{0,62}(?:\.[A-Za-z][A-Za-z0-9_-]{0,62}){1,9}"
)
APPLE_TEAM_ID = re.compile(r"[A-Z0-9]{10}")
RFC3339_SECONDS = re.compile(
    r"[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z"
)
JWT_LIKE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{20,}\."
    r"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"
)
FORBIDDEN_KEY = re.compile(
    r"(?:token|password|secret|authorization|cookie|email|username|handle|comment_text|device_id(?!entity_hash))",
    re.IGNORECASE,
)


class EvidenceError(ValueError):
    """A closed validation error which never includes untrusted values."""


def canonical_json_bytes(value: Any) -> bytes:
    try:
        serialized = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise EvidenceError("JSON value is not canonicalizable") from error
    return (serialized + "\n").encode("ascii")


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise EvidenceError("JSON object contains a duplicate key")
        value[key] = child
    return value


def _reject_nonfinite_constant(_value: str) -> None:
    raise EvidenceError("JSON contains a non-finite number")


def _parse_canonical_json(data: bytes, label: str) -> Any:
    try:
        text = data.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
    except EvidenceError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise EvidenceError(f"{label} is not UTF-8 JSON") from error
    if data != canonical_json_bytes(value):
        raise EvidenceError(f"{label} is not exact canonical JSON")
    return value


def _read_regular_file_once(path: pathlib.Path, maximum: int, label: str) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError(f"{label} is not an accessible regular file") from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum
        ):
            raise EvidenceError(f"{label} is outside the accepted file bounds")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        before_identity = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        after_identity = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if before_identity != after_identity or len(data) != before.st_size:
            raise EvidenceError(f"{label} changed while it was being read")
        return data
    finally:
        os.close(descriptor)


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise EvidenceError(f"{label} does not match its closed key contract")


def _string(value: Any, label: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise EvidenceError(f"{label} has an invalid value")
    return value


def _exact_integer(value: Any, expected: int, label: str) -> None:
    if type(value) is not int or value != expected:
        raise EvidenceError(f"{label} must be the exact integer {expected}")


def _timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or RFC3339_SECONDS.fullmatch(value) is None:
        raise EvidenceError(f"{label} must be a whole-second UTC RFC3339 timestamp")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise EvidenceError(f"{label} is not a real timestamp") from error


def _https_coordinate(value: Any, label: str, *, allow_path: bool) -> str:
    if not isinstance(value, str) or len(value) > 512:
        raise EvidenceError(f"{label} is not a bounded string")
    parsed = urllib.parse.urlsplit(value)
    try:
        port = parsed.port
    except ValueError as error:
        raise EvidenceError(f"{label} has an invalid port") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or (port is not None and not 1 <= port <= 65535)
        or (not allow_path and parsed.path not in {"", "/"})
    ):
        raise EvidenceError(f"{label} is not an exact safe HTTPS coordinate")
    return value


def load_staging_contract(path: pathlib.Path = STAGING_CONFIG) -> dict[str, str]:
    raw_bytes = _read_regular_file_once(path, 32 * 1024, "staging mobile config")
    try:
        payload = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite_constant,
        )
    except EvidenceError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise EvidenceError("staging mobile config is not UTF-8 JSON") from error
    if not isinstance(payload, dict):
        raise EvidenceError("staging mobile config must be an object")
    expected = {
        "api_origin": payload.get("PAKPERK_API_BASE_URL"),
        "oidc_issuer": payload.get("PAKPERK_OIDC_ISSUER_URL"),
        "oidc_client_id": payload.get("PAKPERK_OIDC_CLIENT_ID"),
    }
    _https_coordinate(expected["api_origin"], "staging API origin", allow_path=False)
    _https_coordinate(expected["oidc_issuer"], "staging OIDC issuer", allow_path=True)
    _string(expected["oidc_client_id"], "staging OIDC client ID", CLIENT_ID)
    if payload.get("PAKPERK_ENV") != "staging":
        raise EvidenceError("staging mobile config has the wrong environment")
    if payload.get("PAKPERK_FULLTEXT_POLICY") != "strict":
        raise EvidenceError("staging mobile config must use strict full-text policy")
    return expected


def _reject_sensitive_data(value: Any, label: str = "evidence") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str) or FORBIDDEN_KEY.search(key):
                raise EvidenceError(f"{label} contains a forbidden key")
            _reject_sensitive_data(child, label)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive_data(child, label)
    elif isinstance(value, str):
        lowered = value.lower()
        if "bearer " in lowered or JWT_LIKE.search(value):
            raise EvidenceError(f"{label} contains credential-shaped content")
        if len(value.encode("utf-8")) > 512:
            raise EvidenceError(f"{label} contains an oversized string")


def _validate_protected_content_path(
    path: pathlib.Path,
    content_id: str,
    *,
    root: pathlib.Path,
    label: str,
    owner_uid: int = 0,
) -> None:
    digest = _string(content_id, f"{label} ID", CANDIDATE_ID).removeprefix("sha256:")
    if not path.is_absolute() or path.parent != root or path.name != f"{digest}.json":
        raise EvidenceError(f"{label} path is outside the fixed content-addressed root")

    directories: list[pathlib.Path] = []
    current = root
    while True:
        directories.append(current)
        if current == current.parent:
            break
        current = current.parent
    for directory in reversed(directories):
        try:
            metadata = os.lstat(directory)
        except OSError as error:
            raise EvidenceError(f"{label} root is unavailable") from error
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != owner_uid
            or metadata.st_mode & 0o022
        ):
            raise EvidenceError(f"{label} root is not protected")

    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise EvidenceError(f"{label} is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != owner_uid
        or metadata.st_mode & 0o022
        or metadata.st_nlink != 1
    ):
        raise EvidenceError(f"{label} is not a protected regular file")


def _validate_protected_candidate_path(
    path: pathlib.Path,
    candidate_id: str,
    *,
    root: pathlib.Path = CANDIDATE_ROOT,
    owner_uid: int = 0,
) -> None:
    _validate_protected_content_path(
        path,
        candidate_id,
        root=root,
        label="candidate manifest",
        owner_uid=owner_uid,
    )


def load_signed_release_provenance(
    path: pathlib.Path,
    *,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    android_signer_sha256: str,
    ios_team_id: str,
    ios_signer_sha256: str,
    require_protected_path: bool,
) -> dict[str, Any]:
    if require_protected_path:
        _validate_protected_content_path(
            path,
            provenance_id,
            root=PROVENANCE_ROOT,
            label="signed-release provenance manifest",
        )
    raw_bytes = _read_regular_file_once(
        path, 64 * 1024, "signed-release provenance manifest"
    )
    payload = _parse_canonical_json(raw_bytes, "signed-release provenance manifest")
    if not isinstance(payload, dict):
        raise EvidenceError("signed-release provenance manifest must be an object")
    _exact_keys(payload, PROVENANCE_TOP_LEVEL_KEYS, "signed-release provenance")
    _reject_sensitive_data(payload, "signed-release provenance")
    observed_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    if observed_id != provenance_id:
        raise EvidenceError("signed-release provenance content digest does not match")
    _exact_integer(payload["schema"], 1, "signed-release provenance schema")
    if payload["classification"] != "protected signed mobile release provenance":
        raise EvidenceError("signed-release provenance classification is invalid")
    if payload["source_revision"] != source_revision:
        raise EvidenceError("signed-release provenance source revision does not match")
    if payload["environment"] != "staging":
        raise EvidenceError("signed-release provenance must identify staging")
    if payload["app_version"] != app_version or payload["build_number"] != build_number:
        raise EvidenceError(
            "signed-release provenance app version/build does not match"
        )
    _timestamp(payload["created_at"], "signed-release provenance created_at")

    workflow = payload["workflow"]
    if not isinstance(workflow, dict):
        raise EvidenceError("signed-release provenance workflow must be an object")
    _exact_keys(workflow, PROVENANCE_WORKFLOW_KEYS, "signed-release workflow")
    if (
        workflow["repository"] != "ErrDivine/PakPerk"
        or workflow["path"] != ".github/workflows/mobile-release.yml"
        or workflow["job"] != "signed-candidate"
        or workflow["workflow_sha"] != source_revision
        or workflow["stage"] != "artifacts_verified"
    ):
        raise EvidenceError("signed-release provenance workflow identity is invalid")
    _string(
        workflow["github_run_id"], "signed-release workflow run ID", POSITIVE_INTEGER
    )
    _string(
        workflow["github_run_attempt"],
        "signed-release workflow run attempt",
        POSITIVE_INTEGER,
    )

    android = payload["android"]
    ios = payload["ios"]
    if not isinstance(android, dict) or not isinstance(ios, dict):
        raise EvidenceError("signed-release platform provenance must be objects")
    _exact_keys(android, CANDIDATE_ANDROID_KEYS, "Android signed-release provenance")
    _exact_keys(ios, CANDIDATE_IOS_KEYS, "iOS signed-release provenance")
    _string(android["aab_sha256"], "Android AAB digest", HEX_64)
    _string(android["apk_sha256"], "Android APK digest", HEX_64)
    _string(ios["ipa_sha256"], "iOS IPA digest", HEX_64)
    if (
        android["application_id"] != STAGING_ANDROID_APPLICATION_ID
        or android["signer_sha256"] != android_signer_sha256
    ):
        raise EvidenceError("Android signed-release provenance identity does not match")
    if (
        ios["application_id"] != STAGING_IOS_APPLICATION_ID
        or ios["team_id"] != ios_team_id
        or ios["signer_sha256"] != ios_signer_sha256
    ):
        raise EvidenceError("iOS signed-release provenance identity does not match")
    return {
        "manifest_id": observed_id,
        "workflow": dict(workflow),
        "android": dict(android),
        "ios": dict(ios),
    }


def validate_candidate_manifest_payload(
    payload: Any,
    raw_bytes: bytes,
    *,
    source_revision: str,
    candidate_id: str,
    provenance_id: str,
    provenance_binding: dict[str, Any],
    app_version: str,
    build_number: str,
    android_signer_sha256: str,
    ios_team_id: str,
    ios_signer_sha256: str,
) -> dict[str, Any]:
    _string(source_revision, "expected source revision", SOURCE_REVISION)
    _string(candidate_id, "expected candidate ID", CANDIDATE_ID)
    _string(provenance_id, "expected provenance ID", CANDIDATE_ID)
    _string(app_version, "expected app version", APP_VERSION)
    _string(build_number, "expected build number", BUILD_NUMBER)
    _string(android_signer_sha256, "expected Android signer digest", HEX_64)
    _string(ios_team_id, "expected Apple team ID", APPLE_TEAM_ID)
    _string(ios_signer_sha256, "expected iOS signer digest", HEX_64)
    if not isinstance(provenance_binding, dict):
        raise EvidenceError("expected signed-release provenance binding is invalid")
    if not isinstance(payload, dict):
        raise EvidenceError("candidate manifest root must be an object")
    _exact_keys(payload, CANDIDATE_TOP_LEVEL_KEYS, "candidate manifest")
    _reject_sensitive_data(payload, "candidate manifest")
    observed_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    if observed_id != candidate_id:
        raise EvidenceError(
            "candidate manifest content digest does not match candidate ID"
        )
    _exact_integer(payload["schema"], 1, "candidate manifest schema")
    if payload["classification"] != "protected signed mobile candidate":
        raise EvidenceError("candidate manifest classification is invalid")
    if payload["source_revision"] != source_revision:
        raise EvidenceError("candidate manifest source revision does not match")
    if payload["environment"] != "staging":
        raise EvidenceError("candidate manifest must identify staging")
    if payload["app_version"] != app_version or payload["build_number"] != build_number:
        raise EvidenceError("candidate manifest app version/build does not match")
    if payload["strict_full_text"] is not True:
        raise EvidenceError("candidate manifest must identify the strict signed flavor")
    if payload["provenance_id"] != provenance_id:
        raise EvidenceError("candidate manifest provenance ID does not match")

    android = payload["android"]
    ios = payload["ios"]
    if not isinstance(android, dict) or not isinstance(ios, dict):
        raise EvidenceError("candidate platform records must be objects")
    _exact_keys(android, CANDIDATE_ANDROID_KEYS, "Android candidate")
    _exact_keys(ios, CANDIDATE_IOS_KEYS, "iOS candidate")
    _string(android["aab_sha256"], "Android AAB digest", HEX_64)
    _string(android["apk_sha256"], "Android APK digest", HEX_64)
    _string(ios["ipa_sha256"], "iOS IPA digest", HEX_64)
    if android["application_id"] != STAGING_ANDROID_APPLICATION_ID:
        raise EvidenceError("Android candidate application ID does not match")
    if android["signer_sha256"] != android_signer_sha256:
        raise EvidenceError("Android candidate signer digest does not match")
    if ios["application_id"] != STAGING_IOS_APPLICATION_ID:
        raise EvidenceError("iOS candidate bundle ID does not match")
    if ios["team_id"] != ios_team_id:
        raise EvidenceError("iOS candidate team ID does not match")
    if ios["signer_sha256"] != ios_signer_sha256:
        raise EvidenceError("iOS candidate signer digest does not match")
    if android != provenance_binding.get("android") or ios != provenance_binding.get(
        "ios"
    ):
        raise EvidenceError(
            "candidate artifact identities do not match signed provenance"
        )
    signed_workflow = provenance_binding.get("workflow")
    if not isinstance(signed_workflow, dict):
        raise EvidenceError("signed-release workflow provenance is invalid")

    return {
        "manifest_id": observed_id,
        "provenance_id": provenance_id,
        "signed_workflow": dict(signed_workflow),
        "strict_full_text": True,
        "android": dict(android),
        "ios": dict(ios),
    }


def load_candidate_manifest(
    path: pathlib.Path,
    *,
    provenance_manifest_path: pathlib.Path,
    source_revision: str,
    candidate_id: str,
    provenance_id: str,
    app_version: str,
    build_number: str,
    android_signer_sha256: str,
    ios_team_id: str,
    ios_signer_sha256: str,
    require_protected_path: bool,
) -> dict[str, Any]:
    if require_protected_path:
        _validate_protected_candidate_path(path, candidate_id)
    provenance_binding = load_signed_release_provenance(
        provenance_manifest_path,
        provenance_id=provenance_id,
        source_revision=source_revision,
        app_version=app_version,
        build_number=build_number,
        android_signer_sha256=android_signer_sha256,
        ios_team_id=ios_team_id,
        ios_signer_sha256=ios_signer_sha256,
        require_protected_path=require_protected_path,
    )
    raw_bytes = _read_regular_file_once(path, 64 * 1024, "candidate manifest")
    payload = _parse_canonical_json(raw_bytes, "candidate manifest")
    return validate_candidate_manifest_payload(
        payload,
        raw_bytes,
        source_revision=source_revision,
        candidate_id=candidate_id,
        provenance_id=provenance_id,
        provenance_binding=provenance_binding,
        app_version=app_version,
        build_number=build_number,
        android_signer_sha256=android_signer_sha256,
        ios_team_id=ios_team_id,
        ios_signer_sha256=ios_signer_sha256,
    )


def load_runner_session_attestation(
    path: pathlib.Path,
    *,
    attestation_id: str,
    source_revision: str,
    validated_at: Optional[dt.datetime] = None,
    require_protected_path: bool,
) -> dict[str, Any]:
    if require_protected_path:
        _validate_protected_content_path(
            path,
            attestation_id,
            root=RUNNER_SESSION_ROOT,
            label="runner session attestation",
        )
    raw_bytes = _read_regular_file_once(path, 32 * 1024, "runner session attestation")
    payload = _parse_canonical_json(raw_bytes, "runner session attestation")
    if not isinstance(payload, dict):
        raise EvidenceError("runner session attestation must be an object")
    _exact_keys(payload, RUNNER_SESSION_TOP_LEVEL_KEYS, "runner session attestation")
    _reject_sensitive_data(payload, "runner session attestation")
    observed_id = f"sha256:{hashlib.sha256(raw_bytes).hexdigest()}"
    if observed_id != attestation_id:
        raise EvidenceError("runner session attestation content digest does not match")
    _exact_integer(payload["schema"], 1, "runner session attestation schema")
    if (
        payload["classification"]
        != "dedicated ephemeral mobile acceptance runner session"
    ):
        raise EvidenceError("runner session attestation classification is invalid")
    if payload["source_revision"] != source_revision:
        raise EvidenceError("runner session attestation source revision does not match")
    _string(payload["session_id"], "runner session ID", HEX_64)
    _string(payload["host_identity_hash"], "runner host identity hash", HEX_64)
    if payload["runner_class"] != "dedicated-macos-physical-mobile":
        raise EvidenceError("runner session class is invalid")
    physical_identities = payload["physical_identities"]
    if not isinstance(physical_identities, dict):
        raise EvidenceError("runner physical identities must be an object")
    _exact_keys(
        physical_identities,
        set(DEVICE_CONTRACT),
        "runner physical identities",
    )
    observed_identities = []
    for role in DEVICE_CONTRACT:
        observed_identities.append(
            _string(
                physical_identities[role],
                "root-attested physical identity commitment",
                HEX_64,
            )
        )
    if len(set(observed_identities)) != len(observed_identities):
        raise EvidenceError("root-attested physical identities must be distinct")
    if payload["dedicated"] is not True or payload["ephemeral"] is not True:
        raise EvidenceError("runner session must be explicitly dedicated and ephemeral")
    created = _timestamp(payload["created_at"], "runner session created_at")
    expires = _timestamp(payload["expires_at"], "runner session expires_at")
    if expires <= created or expires - created > dt.timedelta(hours=8):
        raise EvidenceError(
            "runner session lifetime must be positive and at most eight hours"
        )
    if validated_at is None:
        validated_at = dt.datetime.now(dt.timezone.utc)
    if validated_at.tzinfo is None:
        raise EvidenceError("runner session validation clock must be timezone-aware")
    validated_at = validated_at.astimezone(dt.timezone.utc)
    if created > validated_at + dt.timedelta(minutes=5):
        raise EvidenceError("runner session creation time is in the future")
    if validated_at >= expires:
        raise EvidenceError("runner session attestation has expired")
    return {
        "attestation_id": observed_id,
        "session_id": payload["session_id"],
        "host_identity_hash": payload["host_identity_hash"],
        "runner_class": payload["runner_class"],
        "physical_identities": {
            role: physical_identities[role] for role in DEVICE_CONTRACT
        },
        "created_at": payload["created_at"],
        "expires_at": payload["expires_at"],
    }


def public_runner_session_binding(binding: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(binding, dict):
        raise EvidenceError("validated runner session binding must be an object")
    _exact_keys(
        binding,
        RUNNER_SESSION_VALIDATED_KEYS,
        "validated runner session binding",
    )
    return {key: binding[key] for key in RUNNER_SESSION_BINDING_KEYS}


def challenge_keyed_device_identity_hash(
    run_challenge: str,
    identity_commitment: str,
) -> str:
    _string(run_challenge, "run challenge", HEX_64)
    _string(identity_commitment, "physical identity commitment", HEX_64)
    return hmac.new(
        bytes.fromhex(run_challenge),
        bytes.fromhex(identity_commitment),
        hashlib.sha256,
    ).hexdigest()


def _validate_metric(value: Any, rule: tuple[Any, ...], label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvidenceError(f"{label} must be an integer")
    operator, expected, upper = rule
    if operator == "eq" and value != expected:
        raise EvidenceError(f"{label} does not equal its required value")
    if operator == "min" and value < expected:
        raise EvidenceError(f"{label} is below its required minimum")
    if operator == "range" and (value < expected or value > upper):
        raise EvidenceError(f"{label} is outside its required range")


def validate_payload(
    payload: Any,
    *,
    source_revision: str,
    candidate_id: str,
    candidate_binding: dict[str, Any],
    runner_session_binding: dict[str, Any],
    driver_sha256: str,
    app_version: str,
    build_number: str,
    api_origin: str,
    oidc_issuer: str,
    oidc_client_id: str,
    run_id: str,
    run_attempt: str,
    run_challenge: str,
    not_before: str,
    validated_at: Optional[dt.datetime] = None,
) -> None:
    _string(source_revision, "expected source revision", SOURCE_REVISION)
    _string(candidate_id, "expected candidate ID", CANDIDATE_ID)
    _string(driver_sha256, "expected driver SHA-256", HEX_64)
    _string(app_version, "expected app version", APP_VERSION)
    _string(build_number, "expected build number", BUILD_NUMBER)
    _https_coordinate(api_origin, "expected API origin", allow_path=False)
    _https_coordinate(oidc_issuer, "expected OIDC issuer", allow_path=True)
    _string(oidc_client_id, "expected OIDC client ID", CLIENT_ID)
    _string(run_id, "expected workflow run ID", POSITIVE_INTEGER)
    _string(run_attempt, "expected workflow run attempt", POSITIVE_INTEGER)
    _string(run_challenge, "expected run challenge", HEX_64)
    staging_contract = load_staging_contract()
    if {
        "api_origin": api_origin,
        "oidc_issuer": oidc_issuer,
        "oidc_client_id": oidc_client_id,
    } != staging_contract:
        raise EvidenceError(
            "protected coordinates differ from mobile/config/staging.json"
        )
    not_before_time = _timestamp(not_before, "expected run not-before time")
    if validated_at is None:
        validated_at = dt.datetime.now(dt.timezone.utc)
    if validated_at.tzinfo is None:
        raise EvidenceError("validation clock must be timezone-aware")
    validated_at = validated_at.astimezone(dt.timezone.utc)
    if not isinstance(candidate_binding, dict):
        raise EvidenceError("expected candidate binding must be an object")
    _exact_keys(candidate_binding, CANDIDATE_BINDING_KEYS, "expected candidate binding")
    if not isinstance(runner_session_binding, dict):
        raise EvidenceError("expected runner session binding must be an object")
    _exact_keys(
        runner_session_binding,
        RUNNER_SESSION_VALIDATED_KEYS,
        "expected runner session binding",
    )
    public_session_binding = public_runner_session_binding(runner_session_binding)
    physical_identities = runner_session_binding["physical_identities"]
    if not isinstance(physical_identities, dict):
        raise EvidenceError("expected root-attested physical identities are invalid")
    _exact_keys(
        physical_identities,
        set(DEVICE_CONTRACT),
        "expected root-attested physical identities",
    )
    identity_commitments = [
        _string(
            physical_identities[role],
            "expected physical identity commitment",
            HEX_64,
        )
        for role in DEVICE_CONTRACT
    ]
    if len(set(identity_commitments)) != len(identity_commitments):
        raise EvidenceError(
            "expected root-attested physical identities are not distinct"
        )
    expected_device_identity_hashes = {
        role: challenge_keyed_device_identity_hash(
            run_challenge,
            physical_identities[role],
        )
        for role in DEVICE_CONTRACT
    }

    if not isinstance(payload, dict):
        raise EvidenceError("evidence root must be an object")
    _exact_keys(payload, TOP_LEVEL_KEYS, "evidence")
    _reject_sensitive_data(payload)

    _exact_integer(payload["schema"], 2, "evidence schema")
    if payload["classification"] != "protected staging physical-device acceptance":
        raise EvidenceError(
            "evidence classification is not protected staging acceptance"
        )
    if payload["source_revision"] != source_revision:
        raise EvidenceError(
            "evidence source revision does not match the reviewed source"
        )
    if payload["candidate_id"] != candidate_id:
        raise EvidenceError(
            "evidence candidate ID does not match the reviewed candidate"
        )
    if payload["app_version"] != app_version or payload["build_number"] != build_number:
        raise EvidenceError(
            "evidence app version/build does not match the reviewed source"
        )
    if payload["environment"] != "staging":
        raise EvidenceError("physical-device acceptance must target staging")

    coordinates = payload["coordinates"]
    if not isinstance(coordinates, dict):
        raise EvidenceError("deployment coordinates must be an object")
    _exact_keys(
        coordinates, {"api_origin", "oidc_issuer", "oidc_client_id"}, "coordinates"
    )
    _https_coordinate(
        coordinates["api_origin"], "evidence API origin", allow_path=False
    )
    _https_coordinate(
        coordinates["oidc_issuer"], "evidence OIDC issuer", allow_path=True
    )
    _string(coordinates["oidc_client_id"], "evidence OIDC client ID", CLIENT_ID)
    if coordinates != {
        "api_origin": api_origin,
        "oidc_issuer": oidc_issuer,
        "oidc_client_id": oidc_client_id,
    }:
        raise EvidenceError(
            "evidence deployment coordinates do not match protected staging"
        )

    if payload["candidate"] != candidate_binding:
        raise EvidenceError(
            "evidence candidate artifacts or signing identities do not match"
        )
    if payload["runner_session"] != public_session_binding:
        raise EvidenceError("evidence runner session attestation does not match")

    driver = payload["driver"]
    if not isinstance(driver, dict):
        raise EvidenceError("driver evidence must be an object")
    _exact_keys(driver, {"name", "version", "sha256"}, "driver")
    if driver["name"] != "pakperk-mobile-acceptance-driver":
        raise EvidenceError("unexpected mobile acceptance driver")
    _string(driver["version"], "driver version", SAFE_VERSION)
    if driver["sha256"] != driver_sha256:
        raise EvidenceError(
            "driver digest does not match the protected reviewed digest"
        )

    run = payload["run"]
    if not isinstance(run, dict):
        raise EvidenceError("run binding must be an object")
    _exact_keys(
        run, {"github_run_id", "github_run_attempt", "challenge", "not_before"}, "run"
    )
    if run != {
        "github_run_id": run_id,
        "github_run_attempt": run_attempt,
        "challenge": run_challenge,
        "not_before": not_before,
    }:
        raise EvidenceError(
            "evidence does not match the protected workflow run challenge"
        )

    started = _timestamp(payload["started_at"], "started_at")
    finished = _timestamp(payload["finished_at"], "finished_at")
    elapsed = finished - started
    if elapsed <= dt.timedelta(0) or elapsed > dt.timedelta(hours=6):
        raise EvidenceError(
            "acceptance duration must be positive and at most six hours"
        )
    if started < not_before_time:
        raise EvidenceError("acceptance started before the protected run challenge")
    if not_before_time < validated_at - dt.timedelta(hours=6, minutes=15):
        raise EvidenceError("protected run challenge is stale")
    if not_before_time > validated_at + dt.timedelta(minutes=5):
        raise EvidenceError("protected run challenge is in the future")
    if finished < validated_at - dt.timedelta(minutes=15):
        raise EvidenceError("acceptance evidence is stale or replayed")
    if finished > validated_at + dt.timedelta(minutes=5):
        raise EvidenceError("acceptance evidence finish time is in the future")

    devices = payload["devices"]
    if not isinstance(devices, list) or len(devices) != len(DEVICE_CONTRACT):
        raise EvidenceError("evidence must contain exactly four physical-device roles")
    by_role: dict[str, dict[str, Any]] = {}
    installation_hashes: set[str] = set()
    device_identity_hashes: set[str] = set()
    for index, device in enumerate(devices):
        if not isinstance(device, dict):
            raise EvidenceError(f"device {index} must be an object")
        _exact_keys(
            device,
            {
                "role",
                "platform",
                "navigation_mode",
                "device_class",
                "os_version",
                "hardware_model",
                "physical",
                "physical_keyboard_attached",
                "installation_hash",
                "device_identity_hash",
                "candidate_id",
                "install_artifact_sha256",
                "application_id",
                "signer_sha256",
                "team_id",
            },
            f"device {index}",
        )
        role = device["role"]
        if not isinstance(role, str) or role not in DEVICE_CONTRACT or role in by_role:
            raise EvidenceError("device roles must exactly match the required role set")
        platform = device["platform"]
        navigation_mode = device["navigation_mode"]
        device_class = device["device_class"]
        keyboard_attached = device["physical_keyboard_attached"]
        expected_platform, expected_mode, expected_class, expected_keyboard = (
            DEVICE_CONTRACT[role]
        )
        if platform != expected_platform:
            raise EvidenceError(f"device {role} has the wrong platform")
        if navigation_mode != expected_mode:
            raise EvidenceError(f"device {role} has the wrong navigation mode")
        if device_class != expected_class:
            raise EvidenceError(f"device {role} has the wrong device class")
        if keyboard_attached is not expected_keyboard:
            raise EvidenceError(f"device {role} has the wrong physical-keyboard state")
        _string(device["os_version"], f"device {role} OS version", OS_VERSION)
        _string(
            device["hardware_model"], f"device {role} hardware model", HARDWARE_MODEL
        )
        if device["physical"] is not True:
            raise EvidenceError(f"device {role} is not physical")
        installation_hash = _string(
            device["installation_hash"],
            f"device {role} installation hash",
            HEX_64,
        )
        if installation_hash in installation_hashes:
            raise EvidenceError("device installation hashes must be distinct")
        installation_hashes.add(installation_hash)
        device_identity_hash = _string(
            device["device_identity_hash"],
            f"device {role} challenge-keyed identity hash",
            HEX_64,
        )
        if device_identity_hash in device_identity_hashes:
            raise EvidenceError(
                "challenge-keyed physical-device identities must be distinct"
            )
        if device_identity_hash != expected_device_identity_hashes[role]:
            raise EvidenceError(
                "device identity hash does not match root attestation and run challenge"
            )
        device_identity_hashes.add(device_identity_hash)
        if device["candidate_id"] != candidate_id:
            raise EvidenceError(f"device {role} did not run the reviewed candidate")

        platform_candidate = candidate_binding[platform]
        if not isinstance(platform_candidate, dict):
            raise EvidenceError("candidate platform binding is invalid")
        expected_team_id: Any = None
        if platform == "android":
            expected_install_digest = platform_candidate["apk_sha256"]
        else:
            expected_team_id = platform_candidate["team_id"]
            expected_install_digest = platform_candidate["ipa_sha256"]
        if (
            device["install_artifact_sha256"] != expected_install_digest
            or device["application_id"] != platform_candidate["application_id"]
            or device["signer_sha256"] != platform_candidate["signer_sha256"]
            or device["team_id"] != expected_team_id
        ):
            raise EvidenceError(
                f"device {role} installed-candidate binding does not match"
            )
        by_role[role] = device
    if tuple(by_role) != tuple(DEVICE_CONTRACT):
        raise EvidenceError("device roles are incomplete or reordered")

    scenarios = payload["scenarios"]
    if not isinstance(scenarios, list) or len(scenarios) != len(SCENARIO_IDS):
        raise EvidenceError("scenario evidence is incomplete")
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            raise EvidenceError(f"scenario {index} must be an object")
        _exact_keys(
            scenario,
            {"id", "status", "device_roles", "assertions", "metrics"},
            f"scenario {index}",
        )
        scenario_id = scenario["id"]
        if scenario_id != SCENARIO_IDS[index]:
            raise EvidenceError("scenarios must exactly match the required ordered set")
        if scenario["status"] != "passed":
            raise EvidenceError(f"scenario {scenario_id} did not pass")
        if scenario["device_roles"] != list(SCENARIO_DEVICE_ROLES[scenario_id]):
            raise EvidenceError(f"scenario {scenario_id} lacks exact device coverage")
        if scenario["assertions"] != list(SCENARIO_ASSERTIONS[scenario_id]):
            raise EvidenceError(
                f"scenario {scenario_id} lacks exact assertion evidence"
            )
        metrics = scenario["metrics"]
        rules = SCENARIO_METRIC_RULES[scenario_id]
        if not isinstance(metrics, dict):
            raise EvidenceError(f"scenario {scenario_id} metrics must be an object")
        _exact_keys(metrics, set(rules), f"scenario {scenario_id} metrics")
        for metric_name, rule in rules.items():
            _validate_metric(
                metrics[metric_name],
                rule,
                f"scenario {scenario_id} metric {metric_name}",
            )

    redaction = payload["redaction"]
    if not isinstance(redaction, dict):
        raise EvidenceError("redaction evidence must be an object")
    _exact_keys(
        redaction, {"contains_credentials", "contains_personal_data"}, "redaction"
    )
    if (
        redaction["contains_credentials"] is not False
        or redaction["contains_personal_data"] is not False
    ):
        raise EvidenceError("evidence is not explicitly sanitized")


def _write_exclusive(path: pathlib.Path, data: bytes, mode: int) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, mode)
    except OSError as error:
        raise EvidenceError("output path is not fresh") from error
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceError("exclusive output write did not make progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_candidate_binding(path: pathlib.Path, binding: dict[str, Any]) -> None:
    _write_exclusive(path, canonical_json_bytes(binding), 0o600)


def _tar_info(name: str, size: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = 0o400
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    return info


def _publish_archive(
    archive: pathlib.Path,
    evidence_bytes: bytes,
) -> str:
    checksum = (
        f"{hashlib.sha256(evidence_bytes).hexdigest()}  {EVIDENCE_ARCHIVE_NAME}\n"
    ).encode("ascii")
    buffer = io.BytesIO()
    with tarfile.open(
        fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT
    ) as archive_file:
        archive_file.addfile(
            _tar_info(EVIDENCE_ARCHIVE_NAME, len(evidence_bytes)),
            io.BytesIO(evidence_bytes),
        )
        archive_file.addfile(
            _tar_info(CHECKSUM_ARCHIVE_NAME, len(checksum)),
            io.BytesIO(checksum),
        )
    archive_bytes = buffer.getvalue()
    archive_digest = hashlib.sha256(archive_bytes).hexdigest()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(archive, flags, 0o600)
    except OSError as error:
        raise EvidenceError("final evidence archive path is not fresh") from error
    try:
        view = memoryview(archive_bytes)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceError(
                    "final evidence archive write did not make progress"
                )
            view = view[written:]
        os.fchmod(descriptor, 0o400)
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o400
            or metadata.st_nlink != 1
            or metadata.st_size != len(archive_bytes)
        ):
            raise EvidenceError(
                "final evidence archive inode is not closed and private"
            )
        inode = (metadata.st_dev, metadata.st_ino)
    finally:
        os.close(descriptor)
    try:
        metadata = os.lstat(archive)
        if (
            (metadata.st_dev, metadata.st_ino) != inode
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o400
            or metadata.st_nlink != 1
            or metadata.st_size != len(archive_bytes)
        ):
            raise EvidenceError("final evidence archive changed before publication")
        directory_descriptor = os.open(archive.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as error:
        raise EvidenceError("final evidence archive could not be verified") from error
    return archive_digest


def verify_archive(archive: pathlib.Path, expected_sha256: str) -> None:
    _string(expected_sha256, "expected archive SHA-256", HEX_64)
    try:
        metadata = os.lstat(archive)
    except OSError as error:
        raise EvidenceError("evidence archive is unavailable") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o400
        or metadata.st_nlink != 1
    ):
        raise EvidenceError("evidence archive is not one owner-only immutable file")
    archive_bytes = _read_regular_file_once(archive, 512 * 1024, "evidence archive")
    if hashlib.sha256(archive_bytes).hexdigest() != expected_sha256:
        raise EvidenceError("evidence archive digest does not match packaged bytes")
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive_file:
            members = archive_file.getmembers()
            if [member.name for member in members] != [
                EVIDENCE_ARCHIVE_NAME,
                CHECKSUM_ARCHIVE_NAME,
            ]:
                raise EvidenceError("evidence archive member surface is not closed")
            for member in members:
                if (
                    not member.isfile()
                    or member.mode != 0o400
                    or member.uid != 0
                    or member.gid != 0
                ):
                    raise EvidenceError("evidence archive member metadata is invalid")
            evidence_file = archive_file.extractfile(EVIDENCE_ARCHIVE_NAME)
            checksum_file = archive_file.extractfile(CHECKSUM_ARCHIVE_NAME)
            if evidence_file is None or checksum_file is None:
                raise EvidenceError("evidence archive members are unreadable")
            evidence_bytes = evidence_file.read()
            expected_checksum = (
                f"{hashlib.sha256(evidence_bytes).hexdigest()}  "
                f"{EVIDENCE_ARCHIVE_NAME}\n"
            ).encode("ascii")
            if checksum_file.read() != expected_checksum:
                raise EvidenceError("evidence archive checksum does not match")
    except (tarfile.TarError, OSError) as error:
        raise EvidenceError("evidence archive is not a valid closed tar") from error


def validate_and_package(
    evidence_path: pathlib.Path,
    archive_path: pathlib.Path,
    *,
    candidate_manifest_path: pathlib.Path,
    provenance_manifest_path: pathlib.Path,
    runner_session_manifest_path: pathlib.Path,
    source_revision: str,
    candidate_id: str,
    provenance_id: str,
    runner_session_id: str,
    driver_sha256: str,
    app_version: str,
    build_number: str,
    api_origin: str,
    oidc_issuer: str,
    oidc_client_id: str,
    android_signer_sha256: str,
    ios_team_id: str,
    ios_signer_sha256: str,
    run_id: str,
    run_attempt: str,
    run_challenge: str,
    not_before: str,
    validated_at: Optional[dt.datetime] = None,
    require_protected_candidate_path: bool = True,
) -> str:
    candidate_binding = load_candidate_manifest(
        candidate_manifest_path,
        provenance_manifest_path=provenance_manifest_path,
        source_revision=source_revision,
        candidate_id=candidate_id,
        provenance_id=provenance_id,
        app_version=app_version,
        build_number=build_number,
        android_signer_sha256=android_signer_sha256,
        ios_team_id=ios_team_id,
        ios_signer_sha256=ios_signer_sha256,
        require_protected_path=require_protected_candidate_path,
    )
    runner_session_binding = load_runner_session_attestation(
        runner_session_manifest_path,
        attestation_id=runner_session_id,
        source_revision=source_revision,
        validated_at=validated_at,
        require_protected_path=require_protected_candidate_path,
    )
    evidence_bytes = _read_regular_file_once(
        evidence_path,
        256 * 1024,
        "acceptance evidence",
    )
    payload = _parse_canonical_json(evidence_bytes, "acceptance evidence")
    validate_payload(
        payload,
        source_revision=source_revision,
        candidate_id=candidate_id,
        candidate_binding=candidate_binding,
        runner_session_binding=runner_session_binding,
        driver_sha256=driver_sha256,
        app_version=app_version,
        build_number=build_number,
        api_origin=api_origin,
        oidc_issuer=oidc_issuer,
        oidc_client_id=oidc_client_id,
        run_id=run_id,
        run_attempt=run_attempt,
        run_challenge=run_challenge,
        not_before=not_before,
        validated_at=validated_at,
    )
    return _publish_archive(archive_path, evidence_bytes)


def _add_candidate_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--candidate-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--provenance-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--provenance-id", required=True)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--android-signer-sha256", required=True)
    parser.add_argument("--ios-team-id", required=True)
    parser.add_argument("--ios-signer-sha256", required=True)


def _add_runner_session_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--runner-session-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--runner-session-id", required=True)


def _append_github_output(path: pathlib.Path, name: str, value: str) -> None:
    if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name) is None or "\n" in value:
        raise EvidenceError("GitHub output binding is invalid")
    flags = os.O_WRONLY | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError("GitHub output file is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise EvidenceError("GitHub output file is not runner-owned and regular")
        view = memoryview(f"{name}={value}\n".encode("ascii"))
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EvidenceError("GitHub output write did not make progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    candidate = commands.add_parser("validate-candidate")
    _add_candidate_arguments(candidate)
    _add_runner_session_arguments(candidate)
    candidate.add_argument("--binding-output", required=True, type=pathlib.Path)
    candidate.add_argument("--session-binding-output", required=True, type=pathlib.Path)

    package = commands.add_parser("validate-and-package")
    package.add_argument("evidence", type=pathlib.Path)
    package.add_argument("archive", type=pathlib.Path)
    _add_candidate_arguments(package)
    _add_runner_session_arguments(package)
    package.add_argument("--driver-sha256", required=True)
    package.add_argument("--api-origin", required=True)
    package.add_argument("--oidc-issuer", required=True)
    package.add_argument("--oidc-client-id", required=True)
    package.add_argument("--run-id", required=True)
    package.add_argument("--run-attempt", required=True)
    package.add_argument("--run-challenge", required=True)
    package.add_argument("--not-before", required=True)
    package.add_argument("--github-output", required=True, type=pathlib.Path)

    verify = commands.add_parser("verify-archive")
    verify.add_argument("archive", type=pathlib.Path)
    verify.add_argument("--expected-sha256", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        if arguments.command == "validate-candidate":
            binding = load_candidate_manifest(
                arguments.candidate_manifest,
                provenance_manifest_path=arguments.provenance_manifest,
                source_revision=arguments.source_revision,
                candidate_id=arguments.candidate_id,
                provenance_id=arguments.provenance_id,
                app_version=arguments.app_version,
                build_number=arguments.build_number,
                android_signer_sha256=arguments.android_signer_sha256,
                ios_team_id=arguments.ios_team_id,
                ios_signer_sha256=arguments.ios_signer_sha256,
                require_protected_path=True,
            )
            session_binding = load_runner_session_attestation(
                arguments.runner_session_manifest,
                attestation_id=arguments.runner_session_id,
                source_revision=arguments.source_revision,
                require_protected_path=True,
            )
            write_candidate_binding(arguments.binding_output, binding)
            write_candidate_binding(
                arguments.session_binding_output,
                public_runner_session_binding(session_binding),
            )
            print("Protected signed-candidate manifest validated.")
            return 0

        if arguments.command == "verify-archive":
            verify_archive(arguments.archive, arguments.expected_sha256)
            print("Protected mobile acceptance archive verified.")
            return 0

        archive_digest = validate_and_package(
            arguments.evidence,
            arguments.archive,
            candidate_manifest_path=arguments.candidate_manifest,
            provenance_manifest_path=arguments.provenance_manifest,
            runner_session_manifest_path=arguments.runner_session_manifest,
            source_revision=arguments.source_revision,
            candidate_id=arguments.candidate_id,
            provenance_id=arguments.provenance_id,
            runner_session_id=arguments.runner_session_id,
            driver_sha256=arguments.driver_sha256,
            app_version=arguments.app_version,
            build_number=arguments.build_number,
            api_origin=arguments.api_origin,
            oidc_issuer=arguments.oidc_issuer,
            oidc_client_id=arguments.oidc_client_id,
            android_signer_sha256=arguments.android_signer_sha256,
            ios_team_id=arguments.ios_team_id,
            ios_signer_sha256=arguments.ios_signer_sha256,
            run_id=arguments.run_id,
            run_attempt=arguments.run_attempt,
            run_challenge=arguments.run_challenge,
            not_before=arguments.not_before,
            require_protected_candidate_path=True,
        )
        _append_github_output(
            arguments.github_output,
            "archive_sha256",
            archive_digest,
        )
    except (OSError, EvidenceError) as error:
        print(f"mobile acceptance evidence validation failed: {error}", file=sys.stderr)
        return 1
    print("Protected mobile acceptance evidence validated and packaged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
