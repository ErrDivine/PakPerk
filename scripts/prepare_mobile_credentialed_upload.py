#!/usr/bin/env python3
"""Re-attest a signed candidate and store client before credentials are introduced."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import tempfile
from typing import Sequence

# ``python -I`` intentionally removes the script directory from ``sys.path``.
# The workflow verifies this complete sibling module closure by literal SHA-256
# before invoking this entrypoint, so make only that reviewed directory
# importable rather than relying on PYTHONPATH or the ambient working directory.
_CONTROL_ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_CONTROL_ROOT))

import capture_mobile_credentialed_runtime as runtime_capture
import extract_mobile_store_client as extractor
import validate_mobile_store_client as client_validator


SHA256 = re.compile(r"[0-9a-f]{64}")
CONTENT_ID = re.compile(r"sha256:[0-9a-f]{64}")
SOURCE_REVISION = re.compile(r"[0-9a-f]{40}")
MAXIMUM_CHECKSUM_BYTES = 1024 * 1024
MAXIMUM_CANDIDATE_FILE_BYTES = 8 * 1024**3


class PreparationError(ValueError):
    """An immutable transfer failed its closed preparation contract."""


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


def _regular_bytes(path: pathlib.Path, label: str, maximum: int) -> bytes:
    linked = path.lstat()
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o022
        or linked.st_size < 0
        or linked.st_size > maximum
    ):
        raise PreparationError(f"{label} is not one bounded owner-controlled file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        data = b""
        while len(data) <= maximum:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if _identity(linked) != _identity(before) or _identity(before) != _identity(after):
        raise PreparationError(f"{label} changed while it was read")
    if len(data) != before.st_size or len(data) > maximum:
        raise PreparationError(f"{label} exceeded its size contract")
    return data


def _regular_sha256(path: pathlib.Path, label: str, maximum: int) -> str:
    linked = path.lstat()
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.getuid()
        or linked.st_nlink != 1
        or linked.st_mode & 0o022
        or linked.st_size <= 0
        or linked.st_size > maximum
    ):
        raise PreparationError(f"{label} is not one bounded owner-controlled file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if _identity(linked) != _identity(before) or _identity(before) != _identity(after):
        raise PreparationError(f"{label} changed while it was read")
    return digest.hexdigest()


def _candidate_files(root: pathlib.Path) -> dict[str, str]:
    if pathlib.Path(os.path.realpath(root)) != root:
        raise PreparationError("candidate root is not an exact real path")
    root_metadata = root.lstat()
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.getuid()
        or root_metadata.st_mode & 0o022
    ):
        raise PreparationError("candidate root is not owner-controlled")
    observed: dict[str, str] = {}
    total_bytes = 0
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in [*directories, *files]:
            path = pathlib.Path(current, name)
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
                    raise PreparationError("candidate directory is not owner-controlled")
                continue
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_nlink != 1
                or metadata.st_mode & 0o022
            ):
                raise PreparationError("candidate transfer contains unsafe storage")
            relative = path.relative_to(root).as_posix()
            if relative == "release-sha256.txt":
                continue
            raw = _regular_bytes(path, "candidate file", MAXIMUM_CANDIDATE_FILE_BYTES)
            total_bytes += len(raw)
            if total_bytes > MAXIMUM_CANDIDATE_FILE_BYTES:
                raise PreparationError("candidate transfer exceeded its size contract")
            observed[relative] = hashlib.sha256(raw).hexdigest()
    return observed


def _expected_files(root: pathlib.Path) -> dict[str, str]:
    raw = _regular_bytes(
        root / "release-sha256.txt",
        "candidate checksum manifest",
        MAXIMUM_CHECKSUM_BYTES,
    )
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeError as error:
        raise PreparationError("candidate checksum manifest is not ASCII") from error
    expected: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        if match is None:
            raise PreparationError("candidate checksum entry is malformed")
        relative = pathlib.PurePosixPath(match.group(2))
        name = relative.as_posix()
        if (
            relative.is_absolute()
            or any(part in {"", ".", ".."} for part in relative.parts)
            or name in expected
        ):
            raise PreparationError("candidate checksum path is unsafe or duplicated")
        expected[name] = match.group(1)
    if not expected:
        raise PreparationError("candidate checksum manifest is empty")
    return expected


def prepare(arguments: argparse.Namespace) -> None:
    for value, pattern, label in (
        (arguments.source_revision, SOURCE_REVISION, "source revision"),
        (arguments.candidate_id, CONTENT_ID, "candidate ID"),
        (arguments.provenance_id, CONTENT_ID, "provenance ID"),
        (arguments.archive_sha256, SHA256, "archive digest"),
        (arguments.bundle_sha256, SHA256, "bundle digest"),
        (arguments.tree_sha256, SHA256, "tree digest"),
    ):
        if pattern.fullmatch(value) is None:
            raise PreparationError(f"expected {label} is malformed")
    candidate_root = pathlib.Path(os.path.realpath(arguments.candidate_root))
    if candidate_root != arguments.candidate_root:
        raise PreparationError("candidate root path changed")
    if _candidate_files(candidate_root) != _expected_files(candidate_root):
        raise PreparationError("candidate checksum manifest does not match exact files")
    candidate_raw = _regular_bytes(
        candidate_root / "evidence/mobile-candidate.json",
        "candidate manifest",
        64 * 1024,
    )
    provenance_raw = _regular_bytes(
        candidate_root / "evidence/mobile-release-provenance.json",
        "provenance manifest",
        64 * 1024,
    )
    if "sha256:" + hashlib.sha256(candidate_raw).hexdigest() != arguments.candidate_id:
        raise PreparationError("candidate content ID changed")
    if "sha256:" + hashlib.sha256(provenance_raw).hexdigest() != arguments.provenance_id:
        raise PreparationError("provenance content ID changed")
    try:
        candidate = json.loads(candidate_raw)
        provenance = json.loads(provenance_raw)
    except (UnicodeError, ValueError) as error:
        raise PreparationError("candidate manifests are invalid JSON") from error
    expected = {
        "source_revision": arguments.source_revision,
        "app_version": arguments.version_name,
        "build_number": arguments.build_number,
    }
    if any(candidate.get(key) != value for key, value in expected.items()) or any(
        provenance.get(key) != value for key, value in expected.items()
    ):
        raise PreparationError("candidate release identity changed")
    if any(
        document.get(platform, {}).get("application_id") != arguments.bundle_id
        for document in (candidate, provenance)
        for platform in ("android", "ios")
    ):
        raise PreparationError("candidate application identity changed")

    if _regular_sha256(
        arguments.archive, "store-client archive", extractor.MAXIMUM_TREE_BYTES
    ) != arguments.archive_sha256:
        raise PreparationError("store-client archive digest changed")
    parent = pathlib.Path(
        tempfile.mkdtemp(prefix="pakperk-store-client-restore.", dir=arguments.temp_root)
    ).resolve()
    parent.chmod(0o700)
    root = extractor.extract(
        archive=arguments.archive,
        parent=parent,
        output=arguments.github_output,
    )
    bundle_bin = root / "gem-home/bin/bundle"
    gem_home = root / "gem-home"
    bundle_gemfile = root / "manifest/Gemfile"
    bundle_lockfile = root / "manifest/Gemfile.lock"
    bundle_path = root / "bundle"
    bundle_app_config = root / "config"
    client_home = root / "home"
    attestation = client_validator.attest(
        root=root,
        bundle_bin=bundle_bin,
        gem_home=gem_home,
        bundle_gemfile=bundle_gemfile,
        bundle_lockfile=bundle_lockfile,
        bundle_path=bundle_path,
        bundle_app_config=bundle_app_config,
        client_home=client_home,
    )
    if (
        attestation.bundle_sha256 != arguments.bundle_sha256
        or attestation.tree_sha256 != arguments.tree_sha256
    ):
        raise PreparationError("restored store-client content identity changed")
    runtime_values = runtime_capture.capture(output=arguments.github_output)
    with arguments.github_output.open("a", encoding="utf-8") as output:
        for name in ("reviewed_path", "ruby_bin", "ruby_sha256"):
            output.write(f"{name.replace('_', '-')}={runtime_values[name]}\n")
        for name, value in (
            ("bundle_id", arguments.bundle_id),
            ("version_name", arguments.version_name),
            ("build_number", arguments.build_number),
            ("candidate_id", arguments.candidate_id),
            ("provenance_id", arguments.provenance_id),
            ("client_root", root),
            ("client_root_device", attestation.root_device),
            ("client_root_inode", attestation.root_inode),
            ("client_tree_sha256", attestation.tree_sha256),
            ("bundle_bin", bundle_bin),
            ("bundle_bin_sha256", attestation.bundle_sha256),
            ("gem_home", gem_home),
            ("bundle_gemfile", bundle_gemfile),
            ("bundle_lockfile", bundle_lockfile),
            ("bundle_path", bundle_path),
            ("bundle_app_config", bundle_app_config),
            ("client_home", client_home),
            ("bundler_version", "2.6.9"),
        ):
            output.write(f"{name}={value}\n")
            output.write(f"{name.replace('_', '-')}={value}\n")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-root", required=True, type=pathlib.Path)
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    parser.add_argument("--temp-root", required=True, type=pathlib.Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--provenance-id", required=True)
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--bundle-sha256", required=True)
    parser.add_argument("--tree-sha256", required=True)
    parser.add_argument("--github-output", required=True, type=pathlib.Path)
    arguments = parser.parse_args(argv)
    try:
        prepare(arguments)
    except (OSError, PreparationError, extractor.ExtractionError, client_validator.ValidationError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
