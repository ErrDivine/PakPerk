#!/usr/bin/env python3
"""Assemble isolated Android/iOS signer artifacts into one immutable candidate."""

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


MAXIMUM_FILE_BYTES = 8 * 1024**3
MAXIMUM_TREE_BYTES = 16 * 1024**3
MAXIMUM_TEXT_BYTES = 1024 * 1024
REPOSITORY = "ErrDivine/PakPerk"
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]{0,19}")
RUN_ATTEMPT = re.compile(r"[1-9][0-9]{0,9}")
APP_VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z.-]{1,32})?"
)
BUILD_NUMBER = re.compile(r"[1-9][0-9]{0,9}")
APPLICATION_ID = re.compile(
    r"[A-Za-z][A-Za-z0-9_-]{0,62}(?:\.[A-Za-z][A-Za-z0-9_-]{0,62}){1,9}"
)
ANDROID_VERSION = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+-]{0,63}")
SAFE_NAME = re.compile(r"[A-Za-z0-9._+-]{1,255}")
APPLE_TEAM_ID = re.compile(r"[A-Z0-9]{10}")
ANDROID_FINGERPRINT = re.compile(r"(?:[A-F0-9]{2}:){31}[A-F0-9]{2}")

ANDROID_EVIDENCE = {
    "evidence/android-flutter-toolchain.json",
    "evidence/android-native.cdx.json",
    "evidence/android-prepared-config-boundary.json",
    "evidence/android-retained-digests.txt",
    "evidence/android-upload-identity.txt",
}
IOS_EVIDENCE = {
    "evidence/apple-installed-identity.txt",
    "evidence/ios-flutter-toolchain.json",
    "evidence/ios-native-toolchain.txt",
    "evidence/ios-prepared-config-boundary.json",
    "evidence/ios-retained-digest.txt",
}


class AssemblyError(ValueError):
    """A signer transfer or assembled candidate violated its closed contract."""


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
        raise AssemblyError("candidate evidence is not canonicalizable") from error
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


def _real_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    if path != pathlib.Path(os.path.realpath(path)):
        raise AssemblyError(f"{label} is not an exact real path")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AssemblyError(f"{label} is not an accessible directory") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o022
    ):
        raise AssemblyError(f"{label} is not an owner-controlled directory")
    return path


def _safe_tree(path: pathlib.Path, label: str) -> dict[str, pathlib.Path]:
    root = _real_directory(path, label)
    files: dict[str, pathlib.Path] = {}
    total = 0
    for current, directories, names in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        names.sort()
        for name in directories:
            child = pathlib.Path(current, name)
            metadata = child.lstat()
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o022
            ):
                raise AssemblyError(f"{label} contains an unsafe directory")
        for name in names:
            child = pathlib.Path(current, name)
            metadata = child.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_nlink != 1
                or metadata.st_mode & 0o022
                or metadata.st_size <= 0
                or metadata.st_size > MAXIMUM_FILE_BYTES
            ):
                raise AssemblyError(f"{label} contains unsafe or unbounded storage")
            relative = child.relative_to(root).as_posix()
            if relative in files or any(
                part in {"", ".", ".."} for part in pathlib.PurePosixPath(relative).parts
            ):
                raise AssemblyError(f"{label} contains an unsafe duplicate path")
            total += metadata.st_size
            if total > MAXIMUM_TREE_BYTES:
                raise AssemblyError(f"{label} exceeds its aggregate size bound")
            files[relative] = child
    if not files:
        raise AssemblyError(f"{label} is empty")
    return files


def _read(path: pathlib.Path, label: str, maximum: int = MAXIMUM_TEXT_BYTES) -> bytes:
    try:
        linked = path.lstat()
    except OSError as error:
        raise AssemblyError(f"{label} is not an accessible regular file") from error
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o022
        or linked.st_size <= 0
        or linked.st_size > maximum
    ):
        raise AssemblyError(f"{label} is not one bounded owner-controlled file")
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        before = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    raw = b"".join(chunks)
    if (
        _identity(linked) != _identity(before)
        or _identity(before) != _identity(after)
        or len(raw) != before.st_size
        or len(raw) > maximum
    ):
        raise AssemblyError(f"{label} changed or exceeded its bound while read")
    return raw


def _sha256(path: pathlib.Path, label: str) -> str:
    linked = path.lstat()
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o022
        or not 0 < linked.st_size <= MAXIMUM_FILE_BYTES
    ):
        raise AssemblyError(f"{label} is not one bounded owner-controlled file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        observed = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            observed += len(chunk)
            if observed > MAXIMUM_FILE_BYTES:
                raise AssemblyError(f"{label} exceeded its read bound")
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        _identity(linked) != _identity(before)
        or _identity(before) != _identity(after)
        or observed != before.st_size
    ):
        raise AssemblyError(f"{label} changed while it was hashed")
    return digest.hexdigest()


def _parse_json(path: pathlib.Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = _read(path, label)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise AssemblyError(f"{label} is not UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise AssemblyError(f"{label} root is not an object")
    return value, raw


def _parse_key_values(path: pathlib.Path, label: str) -> dict[str, str]:
    try:
        text = _read(path, label).decode("utf-8")
    except UnicodeError as error:
        raise AssemblyError(f"{label} is not UTF-8") from error
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if (
            separator != "="
            or re.fullmatch(r"[a-z][a-z0-9_]{0,63}", key) is None
            or not value
            or "\x00" in value
            or key in values
        ):
            raise AssemblyError(f"{label} is malformed or duplicated")
        values[key] = value
    if not values:
        raise AssemblyError(f"{label} is empty")
    return values


def _one_artifact(
    files: dict[str, pathlib.Path], suffix: str, label: str
) -> pathlib.Path:
    matches = [
        path
        for relative, path in files.items()
        if relative.startswith("artifacts/") and path.name.endswith(suffix)
    ]
    if len(matches) != 1 or SAFE_NAME.fullmatch(matches[0].name) is None:
        raise AssemblyError(f"{label} must contain exactly one safe {suffix} artifact")
    return matches[0]


def _closed_signer_tree(
    files: dict[str, pathlib.Path], *, platform: str, environment: str
) -> None:
    if platform == "android":
        expected_evidence = set(ANDROID_EVIDENCE)
        if environment != "development":
            expected_evidence.add("evidence/android-installed-identity.txt")
        allowed = ("artifacts/", "evidence/", "symbols/")
    else:
        expected_evidence = set(IOS_EVIDENCE)
        allowed = ("artifacts/", "evidence/", "symbols/", "native-symbols/")
    observed_evidence = {name for name in files if name.startswith("evidence/")}
    if observed_evidence != expected_evidence:
        raise AssemblyError(f"{platform} signer evidence tree is not closed")
    if any(not name.startswith(allowed) for name in files):
        raise AssemblyError(f"{platform} signer transfer contains an unexpected root")


def _copy_regular(source: pathlib.Path, destination: pathlib.Path, label: str) -> None:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    source_linked = source.lstat()
    source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o400,
    )
    copied = 0
    try:
        before = os.fstat(source_descriptor)
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > MAXIMUM_FILE_BYTES:
                raise AssemblyError(f"{label} exceeded its copy bound")
            view = memoryview(chunk)
            while view:
                written = os.write(destination_descriptor, view)
                if written <= 0:
                    raise AssemblyError(f"{label} copy did not make progress")
                view = view[written:]
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
        retained = os.fstat(destination_descriptor)
    finally:
        os.close(destination_descriptor)
        os.close(source_descriptor)
    if (
        _identity(source_linked) != _identity(before)
        or _identity(before) != _identity(after)
        or not stat.S_ISREG(retained.st_mode)
        or retained.st_nlink != 1
        or retained.st_size != copied
    ):
        raise AssemblyError(f"{label} changed or was incomplete while copied")


def _write_exclusive(path: pathlib.Path, raw: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
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
                raise AssemblyError("candidate manifest write did not make progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _exact(value: str, pattern: re.Pattern[str], label: str) -> str:
    if type(value) is not str or pattern.fullmatch(value) is None:
        raise AssemblyError(f"{label} is invalid")
    return value


def _transfer(arguments: argparse.Namespace, prefix: str) -> dict[str, Any]:
    artifact_id = _exact(
        getattr(arguments, f"{prefix}_artifact_id"), POSITIVE_INTEGER, f"{prefix} artifact ID"
    )
    artifact_digest = _exact(
        getattr(arguments, f"{prefix}_artifact_digest"), SHA256, f"{prefix} artifact digest"
    )
    return {"artifact_digest": artifact_digest, "artifact_id": int(artifact_id)}


def _expected_boundary(
    *, prepared: dict[str, Any], config_sha256: str, feature_sha256: str
) -> dict[str, Any]:
    return {
        "artifactDigest": prepared["artifact_digest"],
        "artifactId": prepared["artifact_id"],
        "configSha256": config_sha256,
        "featureEvidenceSha256": feature_sha256,
        "schema": 1,
    }


def _write_checksum(root: pathlib.Path) -> None:
    lines: list[str] = []
    files = _safe_tree(root, "assembled candidate")
    if "release-sha256.txt" in files:
        raise AssemblyError("candidate checksum manifest already exists")
    for relative, path in sorted(files.items()):
        if re.fullmatch(r"[A-Za-z0-9._/-]+", relative) is None:
            raise AssemblyError("assembled candidate contains an unsafe checksum path")
        lines.append(f"{_sha256(path, 'assembled candidate file')}  {relative}")
    _write_exclusive(root / "release-sha256.txt", ("\n".join(lines) + "\n").encode("ascii"))


def verify(root: pathlib.Path, *, candidate_id: str, provenance_id: str) -> None:
    root = _real_directory(root, "assembled candidate")
    _exact(candidate_id, re.compile(r"sha256:[0-9a-f]{64}"), "candidate content ID")
    _exact(provenance_id, re.compile(r"sha256:[0-9a-f]{64}"), "provenance content ID")
    raw = _read(root / "release-sha256.txt", "candidate checksum manifest")
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeError as error:
        raise AssemblyError("candidate checksum manifest is not ASCII") from error
    expected: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        if match is None or match.group(2) in expected:
            raise AssemblyError("candidate checksum manifest is malformed or duplicated")
        expected[match.group(2)] = match.group(1)
    observed = {
        relative: _sha256(path, "assembled candidate file")
        for relative, path in _safe_tree(root, "assembled candidate").items()
        if relative != "release-sha256.txt"
    }
    if expected != observed:
        raise AssemblyError("candidate checksum manifest does not match exact files")
    candidate_raw = _read(root / "evidence/mobile-candidate.json", "candidate manifest")
    provenance_raw = _read(
        root / "evidence/mobile-release-provenance.json", "provenance manifest"
    )
    if "sha256:" + hashlib.sha256(candidate_raw).hexdigest() != candidate_id:
        raise AssemblyError("candidate manifest content ID changed")
    if "sha256:" + hashlib.sha256(provenance_raw).hexdigest() != provenance_id:
        raise AssemblyError("provenance manifest content ID changed")


def assemble(arguments: argparse.Namespace) -> tuple[str, str]:
    environment = arguments.environment
    if environment not in {"development", "staging", "production"}:
        raise AssemblyError("release environment is invalid")
    source_revision = _exact(arguments.source_revision, SOURCE_REVISION, "source revision")
    workflow_sha = _exact(arguments.workflow_sha, SOURCE_REVISION, "workflow revision")
    if source_revision != workflow_sha:
        raise AssemblyError("workflow revision does not equal candidate source")
    app_version = _exact(arguments.app_version, APP_VERSION, "app version")
    build_number = _exact(arguments.build_number, BUILD_NUMBER, "build number")
    application_id = _exact(arguments.application_id, APPLICATION_ID, "application ID")
    android_version = _exact(
        arguments.android_version_name, ANDROID_VERSION, "Android version name"
    )
    run_id = _exact(arguments.run_id, POSITIVE_INTEGER, "run ID")
    run_attempt = _exact(arguments.run_attempt, RUN_ATTEMPT, "run attempt")
    if arguments.repository != REPOSITORY:
        raise AssemblyError("repository identity is invalid")

    prepared_transfer = _transfer(arguments, "prepared")
    android_transfer = _transfer(arguments, "android")
    ios_transfer = _transfer(arguments, "ios")
    transfer_ids = {
        prepared_transfer["artifact_id"],
        android_transfer["artifact_id"],
        ios_transfer["artifact_id"],
    }
    if len(transfer_ids) != 3:
        raise AssemblyError("upstream artifact IDs must be distinct")
    config_sha256 = _exact(arguments.config_sha256, SHA256, "prepared config digest")
    feature_sha256 = _exact(
        arguments.feature_evidence_sha256, SHA256, "prepared feature evidence digest"
    )

    prepared = _safe_tree(arguments.prepared_root, "prepared config transfer")
    if set(prepared) != {
        "mobile-release-config.json",
        "evidence/mobile-feature-flags.json",
    }:
        raise AssemblyError("prepared config transfer tree is not closed")
    if _sha256(prepared["mobile-release-config.json"], "prepared config") != config_sha256:
        raise AssemblyError("prepared config digest does not match")
    if (
        _sha256(prepared["evidence/mobile-feature-flags.json"], "feature evidence")
        != feature_sha256
    ):
        raise AssemblyError("prepared feature evidence digest does not match")
    config, _ = _parse_json(prepared["mobile-release-config.json"], "prepared config")
    if config.get("PAKPERK_ENV") != environment:
        raise AssemblyError("prepared config environment does not match")

    android_files = _safe_tree(arguments.android_root, "Android signer transfer")
    ios_files = _safe_tree(arguments.ios_root, "iOS signer transfer")
    _closed_signer_tree(android_files, platform="android", environment=environment)
    _closed_signer_tree(ios_files, platform="ios", environment=environment)
    aab = _one_artifact(android_files, ".aab", "Android signer transfer")
    apk = _one_artifact(android_files, ".apk", "Android signer transfer")
    ipa = _one_artifact(ios_files, ".ipa", "iOS signer transfer")
    if len([name for name in android_files if name.startswith("artifacts/")]) != 2:
        raise AssemblyError("Android signer transfer contains unexpected artifacts")
    if len([name for name in ios_files if name.startswith("artifacts/")]) != 1:
        raise AssemblyError("iOS signer transfer contains unexpected artifacts")
    aab_sha256 = _sha256(aab, "retained AAB")
    apk_sha256 = _sha256(apk, "retained APK")
    ipa_sha256 = _sha256(ipa, "retained IPA")

    expected_boundary = _expected_boundary(
        prepared=prepared_transfer,
        config_sha256=config_sha256,
        feature_sha256=feature_sha256,
    )
    for path, label in (
        (
            android_files["evidence/android-prepared-config-boundary.json"],
            "Android prepared-config boundary",
        ),
        (
            ios_files["evidence/ios-prepared-config-boundary.json"],
            "iOS prepared-config boundary",
        ),
    ):
        value, raw = _parse_json(path, label)
        if value != expected_boundary or raw != canonical_json_bytes(value):
            raise AssemblyError(f"{label} is not the exact canonical binding")

    android_identity = _parse_key_values(
        android_files["evidence/android-upload-identity.txt"], "Android identity evidence"
    )
    android_digests = _parse_key_values(
        android_files["evidence/android-retained-digests.txt"], "Android digest evidence"
    )
    ios_identity = _parse_key_values(
        ios_files["evidence/apple-installed-identity.txt"], "iOS identity evidence"
    )
    ios_digest = _parse_key_values(
        ios_files["evidence/ios-retained-digest.txt"], "iOS digest evidence"
    )
    if (
        android_identity.get("android_package") != application_id
        or android_identity.get("android_version_name") != android_version
        or android_identity.get("android_version_code") != build_number
        or android_digests
        != {
            "android_aab_artifact_sha256": aab_sha256,
            "android_apk_artifact_sha256": apk_sha256,
        }
    ):
        raise AssemblyError("Android signer identity or raw digest does not match")
    fingerprint = android_identity.get("android_upload_sha256", "")
    if ANDROID_FINGERPRINT.fullmatch(fingerprint) is None:
        raise AssemblyError("Android signer fingerprint is invalid")
    android_signer = fingerprint.replace(":", "").lower()
    if (
        ios_identity.get("apple_bundle_id") != application_id
        or ios_identity.get("apple_version") != app_version
        or ios_identity.get("apple_build") != build_number
        or ios_identity.get("apple_ipa_sha256") != ipa_sha256
        or ios_digest != {"ios_ipa_artifact_sha256": ipa_sha256}
        or SHA256.fullmatch(ios_identity.get("apple_signer_sha256", "")) is None
        or APPLE_TEAM_ID.fullmatch(ios_identity.get("apple_team_id", "")) is None
    ):
        raise AssemblyError("iOS signer identity or raw digest does not match")

    output = arguments.output_root
    if output.exists() or output.is_symlink():
        raise AssemblyError("assembled candidate output already exists")
    output.mkdir(mode=0o700, parents=False)
    for files in (android_files, ios_files):
        for relative, source in sorted(files.items()):
            _copy_regular(source, output / relative, "signer evidence")
    _copy_regular(
        prepared["mobile-release-config.json"],
        output / "evidence/mobile-release-config.json",
        "prepared config",
    )
    _copy_regular(
        prepared["evidence/mobile-feature-flags.json"],
        output / "evidence/mobile-feature-flags.json",
        "prepared feature evidence",
    )

    android = {
        "aab_sha256": aab_sha256,
        "apk_sha256": apk_sha256,
        "application_id": application_id,
        "signer_sha256": android_signer,
    }
    ios = {
        "application_id": application_id,
        "ipa_sha256": ipa_sha256,
        "signer_sha256": ios_identity["apple_signer_sha256"],
        "team_id": ios_identity["apple_team_id"],
    }
    created_at = (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    provenance = {
        "android": android,
        "app_version": app_version,
        "build_number": build_number,
        "classification": "protected signed mobile release provenance",
        "created_at": created_at,
        "environment": environment,
        "ios": ios,
        "schema": 1,
        "source_revision": source_revision,
        "workflow": {
            "github_run_attempt": run_attempt,
            "github_run_id": run_id,
            "job": "signed-candidate",
            "path": ".github/workflows/mobile-release.yml",
            "repository": arguments.repository,
            "stage": "artifacts_verified",
            "workflow_sha": workflow_sha,
        },
    }
    provenance_raw = canonical_json_bytes(provenance)
    provenance_id = "sha256:" + hashlib.sha256(provenance_raw).hexdigest()
    candidate = {
        "android": android,
        "app_version": app_version,
        "build_number": build_number,
        "classification": "protected signed mobile candidate",
        "environment": environment,
        "ios": ios,
        "provenance_id": provenance_id,
        "schema": 1,
        "source_revision": source_revision,
        "strict_full_text": config.get("PAKPERK_FULLTEXT_POLICY") == "strict",
    }
    candidate_raw = canonical_json_bytes(candidate)
    candidate_id = "sha256:" + hashlib.sha256(candidate_raw).hexdigest()
    transfer_binding = {
        "android": {
            **android_transfer,
            "aab_sha256": aab_sha256,
            "apk_sha256": apk_sha256,
        },
        "classification": "credential-free mobile signing transfer binding",
        "ios": {**ios_transfer, "ipa_sha256": ipa_sha256},
        "prepared": {
            **prepared_transfer,
            "config_sha256": config_sha256,
            "feature_evidence_sha256": feature_sha256,
        },
        "schema": 1,
    }
    _write_exclusive(output / "evidence/mobile-release-provenance.json", provenance_raw)
    _write_exclusive(output / "evidence/mobile-candidate.json", candidate_raw)
    _write_exclusive(
        output / "evidence/mobile-signing-transfers.json",
        canonical_json_bytes(transfer_binding),
    )
    _write_checksum(output)
    verify(output, candidate_id=candidate_id, provenance_id=provenance_id)

    with arguments.github_output.open("a", encoding="utf-8") as github_output:
        github_output.write(f"candidate_id={candidate_id}\n")
        github_output.write(f"provenance_id={provenance_id}\n")
    with arguments.github_step_summary.open("a", encoding="utf-8") as summary:
        summary.write("## Signed mobile candidate\n\n")
        summary.write(f"- Candidate ID: `{candidate_id}`\n")
        summary.write(f"- Provenance ID: `{provenance_id}`\n")
    return candidate_id, provenance_id


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    assemble_parser = subparsers.add_parser("assemble")
    for name in ("prepared-root", "android-root", "ios-root", "output-root"):
        assemble_parser.add_argument(f"--{name}", required=True, type=pathlib.Path)
    for name in (
        "environment",
        "source-revision",
        "workflow-sha",
        "app-version",
        "android-version-name",
        "build-number",
        "application-id",
        "repository",
        "run-id",
        "run-attempt",
        "prepared-artifact-id",
        "prepared-artifact-digest",
        "android-artifact-id",
        "android-artifact-digest",
        "ios-artifact-id",
        "ios-artifact-digest",
        "config-sha256",
        "feature-evidence-sha256",
    ):
        assemble_parser.add_argument(f"--{name}", required=True)
    assemble_parser.add_argument("--github-output", required=True, type=pathlib.Path)
    assemble_parser.add_argument("--github-step-summary", required=True, type=pathlib.Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--root", required=True, type=pathlib.Path)
    verify_parser.add_argument("--candidate-id", required=True)
    verify_parser.add_argument("--provenance-id", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "assemble":
            assemble(arguments)
        else:
            verify(
                arguments.root,
                candidate_id=arguments.candidate_id,
                provenance_id=arguments.provenance_id,
            )
    except (OSError, AssemblyError) as error:
        print(f"mobile signed-candidate assembly failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
