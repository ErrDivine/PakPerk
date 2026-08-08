#!/usr/bin/env python3
"""Create the immutable handoff only after both store uploads verify remotely."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import pathlib
import re
import sys
from typing import Any, Sequence

import validate_mobile_store_candidate as candidate_validator


class HandoffError(ValueError):
    """A closed generation failure."""


def _document(path: pathlib.Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = candidate_validator._read_manifest(path, label)
        value = candidate_validator._parse_canonical_json(raw, label)
    except candidate_validator.ValidationError as error:
        raise HandoffError(str(error)) from error
    if not isinstance(value, dict):
        raise HandoffError(f"{label} root must be an object")
    return value, raw


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise HandoffError(f"{label} does not match its closed key contract")


def _write_exclusive(path: pathlib.Path, raw: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        remaining = memoryview(raw)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise HandoffError("store handoff write did not make progress")
            remaining = remaining[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def generate(
    *,
    candidate_path: pathlib.Path,
    provenance_path: pathlib.Path,
    google_verification_path: pathlib.Path,
    apple_verification_path: pathlib.Path,
    output_root: pathlib.Path,
    candidate_id: str,
    provenance_id: str,
    source_revision: str,
    app_version: str,
    build_number: str,
    repository: str,
    run_id: str,
    run_attempt: str,
    ruby_version: str,
    rubygems_version: str,
    bundler_version: str,
    tooling_root: pathlib.Path | None = None,
) -> str:
    for value, pattern, label in (
        (candidate_id, candidate_validator.CONTENT_ID, "candidate ID"),
        (provenance_id, candidate_validator.CONTENT_ID, "provenance ID"),
        (source_revision, candidate_validator.SOURCE_REVISION, "source revision"),
        (app_version, candidate_validator.APP_VERSION, "app version"),
        (build_number, candidate_validator.BUILD_NUMBER, "build number"),
        (run_id, candidate_validator.RUN_ID, "run ID"),
        (run_attempt, candidate_validator.RUN_ATTEMPT, "run attempt"),
    ):
        if pattern.fullmatch(value) is None:
            raise HandoffError(f"{label} is invalid")
    if repository != candidate_validator.REPOSITORY:
        raise HandoffError("repository is invalid")
    if (ruby_version, rubygems_version, bundler_version) != (
        "3.4.10",
        "4.0.17",
        "2.6.9",
    ):
        raise HandoffError("store upload tooling version is invalid")

    candidate, candidate_raw = _document(candidate_path, "candidate manifest")
    provenance, provenance_raw = _document(provenance_path, "provenance manifest")
    if "sha256:" + hashlib.sha256(candidate_raw).hexdigest() != candidate_id:
        raise HandoffError("candidate content ID does not match")
    if "sha256:" + hashlib.sha256(provenance_raw).hexdigest() != provenance_id:
        raise HandoffError("provenance content ID does not match")
    if candidate.get("provenance_id") != provenance_id:
        raise HandoffError("candidate provenance ID does not match")
    workflow = provenance.get("workflow")
    if not isinstance(workflow, dict) or workflow != {
        "github_run_attempt": run_attempt,
        "github_run_id": run_id,
        "job": candidate_validator.WORKFLOW_JOB,
        "path": candidate_validator.WORKFLOW_PATH,
        "repository": repository,
        "stage": candidate_validator.WORKFLOW_STAGE,
        "workflow_sha": source_revision,
    }:
        raise HandoffError("provenance workflow binding is invalid")
    for payload, label in ((candidate, "candidate"), (provenance, "provenance")):
        if (
            payload.get("environment") != "production"
            or payload.get("source_revision") != source_revision
            or payload.get("app_version") != app_version
            or payload.get("build_number") != build_number
        ):
            raise HandoffError(f"{label} release identity does not match")

    android = candidate.get("android")
    ios = candidate.get("ios")
    if not isinstance(android, dict) or not isinstance(ios, dict):
        raise HandoffError("candidate platform identities are invalid")
    aab_sha256 = android.get("aab_sha256")
    ipa_sha256 = ios.get("ipa_sha256")
    if (
        not isinstance(aab_sha256, str)
        or candidate_validator.HEX_64.fullmatch(aab_sha256) is None
        or not isinstance(ipa_sha256, str)
        or candidate_validator.HEX_64.fullmatch(ipa_sha256) is None
    ):
        raise HandoffError("candidate store artifact digest is invalid")

    google, _ = _document(google_verification_path, "Google Play upload verification")
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
    expected_google_target = {
        "status": "completed",
        "user_fraction": None,
        "version_codes": [build_number],
    }
    google_bundle = google.get("bundle")
    if not isinstance(google_bundle, dict):
        raise HandoffError("Google Play uploaded bundle verification is invalid")
    _exact_keys(
        google_bundle,
        {"sha256", "version_code"},
        "Google Play uploaded bundle verification",
    )
    if (
        google.get("schema") != 1
        or google.get("application_id") != candidate_validator.PRODUCTION_APPLICATION_ID
        or google.get("version_code") != build_number
        or google.get("verification_status") != "succeeded_verified"
        or google.get("internal_target") != expected_google_target
        or google_bundle
        != {"sha256": aab_sha256, "version_code": build_number}
    ):
        raise HandoffError("Google Play upload was not authoritatively verified")

    apple, _ = _document(apple_verification_path, "App Store upload verification")
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
    upload_verification = apple.get("upload_verification")
    if not isinstance(upload_verification, dict):
        raise HandoffError("App Store upload verification is invalid")
    _exact_keys(
        upload_verification,
        {"app_id", "build", "build_upload"},
        "App Store upload verification identity",
    )
    build = upload_verification.get("build")
    if not isinstance(build, dict):
        raise HandoffError("App Store upload verification build is invalid")
    _exact_keys(
        build,
        {"build_id", "build_number", "pre_release_version_id", "processing_state"},
        "App Store upload verification build",
    )
    build_upload = upload_verification.get("build_upload")
    if not isinstance(build_upload, dict):
        raise HandoffError("App Store build upload verification is invalid")
    _exact_keys(
        build_upload,
        {"asset_file", "build_id", "build_upload_id", "state"},
        "App Store build upload verification",
    )
    asset_file = build_upload.get("asset_file")
    if not isinstance(asset_file, dict):
        raise HandoffError("App Store uploaded IPA verification is invalid")
    _exact_keys(
        asset_file,
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
    source_file_checksum = asset_file.get("source_file_checksum")
    if not isinstance(source_file_checksum, dict):
        raise HandoffError("App Store uploaded IPA checksum is invalid")
    _exact_keys(
        source_file_checksum,
        {"algorithm", "hash"},
        "App Store uploaded IPA checksum",
    )
    safe_id = re.compile(r"[A-Za-z0-9-]{1,128}")
    if (
        apple.get("schema") != 1
        or apple.get("application_id") != candidate_validator.PRODUCTION_APPLICATION_ID
        or apple.get("app_version") != app_version
        or apple.get("build_number") != build_number
        or apple.get("operation") != "verify-build"
        or apple.get("verification_status") != "succeeded_verified"
        or not isinstance(upload_verification.get("app_id"), str)
        or safe_id.fullmatch(upload_verification["app_id"]) is None
        or build.get("build_number") != build_number
        or build.get("processing_state") != "VALID"
        or not isinstance(build.get("build_id"), str)
        or safe_id.fullmatch(build["build_id"]) is None
        or not isinstance(build.get("pre_release_version_id"), str)
        or safe_id.fullmatch(build["pre_release_version_id"]) is None
        or build_upload.get("build_id") != build.get("build_id")
        or build_upload.get("state") != "COMPLETE"
        or not isinstance(build_upload.get("build_upload_id"), str)
        or safe_id.fullmatch(build_upload["build_upload_id"]) is None
        or asset_file.get("asset_delivery_state") != "COMPLETE"
        or asset_file.get("asset_type") != "ASSET"
        or not isinstance(asset_file.get("build_upload_file_id"), str)
        or safe_id.fullmatch(asset_file["build_upload_file_id"]) is None
        or type(asset_file.get("file_size")) is not int
        or not 0 < asset_file["file_size"] <= candidate_validator.MAXIMUM_ARTIFACT_BYTES
        or source_file_checksum
        != {"algorithm": "SHA_256", "hash": ipa_sha256}
        or asset_file.get("uti") != "com.apple.ipa"
    ):
        raise HandoffError("App Store upload was not authoritatively verified")

    handoff_workflow = dict(workflow)
    handoff_workflow["stage"] = candidate_validator.UPLOAD_HANDOFF_STAGE
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    repository_root = pathlib.Path(__file__).resolve().parents[1]
    if tooling_root is None:
        tooling_paths = {
            "app_store_client": repository_root
            / "scripts/manage_app_store_phased_release.rb",
            "fastlane_lock": repository_root / "mobile/Gemfile.lock",
            "google_play_client": repository_root
            / "scripts/manage_google_play_rollout.rb",
            "handoff_generator": repository_root
            / "scripts/generate_mobile_store_upload_handoff.py",
        }
    else:
        tooling_root = pathlib.Path(os.path.realpath(tooling_root))
        tooling_paths = {
            "app_store_client": tooling_root / "manage_app_store_phased_release.rb",
            "fastlane_lock": tooling_root / "Gemfile.lock",
            "google_play_client": tooling_root / "manage_google_play_rollout.rb",
            "handoff_generator": tooling_root
            / "generate_mobile_store_upload_handoff.py",
        }

    def source_digest(name: str) -> str:
        try:
            return candidate_validator._hash_artifact(
                tooling_paths[name], f"tooling source {name}"
            )
        except candidate_validator.ValidationError as error:
            raise HandoffError(str(error)) from error

    handoff = {
        "app_version": app_version,
        "build_number": build_number,
        "candidate_id": candidate_id,
        "classification": "protected mobile store upload handoff",
        "created_at": now,
        "environment": "production",
        "provenance_id": provenance_id,
        "schema": 1,
        "source_revision": source_revision,
        "tooling": {
            "app_store_client_sha256": source_digest("app_store_client"),
            "bundler_version": bundler_version,
            "fastlane_lock_sha256": source_digest("fastlane_lock"),
            "google_play_client_sha256": source_digest("google_play_client"),
            "handoff_generator_sha256": source_digest("handoff_generator"),
            "ruby_version": ruby_version,
            "rubygems_version": rubygems_version,
        },
        "uploads": {
            "android": {
                "application_id": candidate_validator.PRODUCTION_APPLICATION_ID,
                "artifact_sha256": android.get("aab_sha256"),
                "destination": "google_play_internal",
                "status": "succeeded",
                "verification": {
                    "bundle": dict(google_bundle),
                    "internal_target": expected_google_target,
                    "status": "succeeded_verified",
                },
                "version_code": build_number,
            },
            "ios": {
                "application_id": candidate_validator.PRODUCTION_APPLICATION_ID,
                "app_version": app_version,
                "artifact_sha256": ios.get("ipa_sha256"),
                "build_number": build_number,
                "destination": "app_store_connect",
                "status": "succeeded",
                "verification": {
                    "app_id": upload_verification["app_id"],
                    "asset_delivery_state": "COMPLETE",
                    "asset_type": "ASSET",
                    "build_id": build["build_id"],
                    "build_upload_file_id": asset_file["build_upload_file_id"],
                    "build_upload_id": build_upload["build_upload_id"],
                    "build_upload_state": "COMPLETE",
                    "file_size": asset_file["file_size"],
                    "pre_release_version_id": build["pre_release_version_id"],
                    "processing_state": "VALID",
                    "source_file_checksum": dict(source_file_checksum),
                    "status": "succeeded_verified",
                    "uti": "com.apple.ipa",
                },
            },
        },
        "workflow": handoff_workflow,
    }
    raw = candidate_validator.canonical_json_bytes(handoff)
    digest = hashlib.sha256(raw).hexdigest()
    handoff_id = f"store-handoff-v1:sha256:{digest}"
    output_root.mkdir(mode=0o700, parents=False, exist_ok=False)
    _write_exclusive(output_root / "mobile-store-upload-handoff.json", raw)
    _write_exclusive(
        output_root / "mobile-store-upload-handoff.sha256",
        f"{digest}  mobile-store-upload-handoff.json\n".encode("ascii"),
    )
    return handoff_id


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in (
        "candidate",
        "provenance",
        "google-verification",
        "apple-verification",
        "output-root",
    ):
        parser.add_argument(f"--{option}", required=True, type=pathlib.Path)
    parser.add_argument("--tooling-root", type=pathlib.Path)
    for option in (
        "candidate-id",
        "provenance-id",
        "source-revision",
        "app-version",
        "build-number",
        "repository",
        "run-id",
        "run-attempt",
        "ruby-version",
        "rubygems-version",
        "bundler-version",
    ):
        parser.add_argument(f"--{option}", required=True)
    arguments = parser.parse_args(argv)
    try:
        handoff_id = generate(
            candidate_path=arguments.candidate,
            provenance_path=arguments.provenance,
            google_verification_path=arguments.google_verification,
            apple_verification_path=arguments.apple_verification,
            output_root=arguments.output_root,
            candidate_id=arguments.candidate_id,
            provenance_id=arguments.provenance_id,
            source_revision=arguments.source_revision,
            app_version=arguments.app_version,
            build_number=arguments.build_number,
            repository=arguments.repository,
            run_id=arguments.run_id,
            run_attempt=arguments.run_attempt,
            ruby_version=arguments.ruby_version,
            rubygems_version=arguments.rubygems_version,
            bundler_version=arguments.bundler_version,
            tooling_root=arguments.tooling_root,
        )
    except (OSError, HandoffError) as error:
        print(f"mobile store upload handoff generation failed: {error}", file=sys.stderr)
        return 1
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with pathlib.Path(output_path).open("a", encoding="utf-8") as output:
            output.write(f"store_handoff_id={handoff_id}\n")
    print(handoff_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
