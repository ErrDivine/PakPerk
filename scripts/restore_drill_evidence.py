#!/usr/bin/env python3
"""Fail-closed helpers for the protected backup/restore drill harness.

Only Python's standard library is used so the shell entry point remains usable
on the small recovery hosts where the drill is expected to run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import pathlib
import re
import resource
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
from typing import Any, Iterable


MAX_JSON_BYTES = 256 * 1024
MAX_WORKER_OUTPUT_BYTES = 64 * 1024
MAX_ARCHIVE_BYTES = 4 * 1024 * 1024
WORKER_TIMEOUT_SECONDS = 120
STAGE_PREFIX = ".pakperk-restore-drill-"
CONTENT_DOMAIN = b"pakperk-restore-evidence-v2\0"
CONTENT_PREFIX = "pakperk-restore-evidence-v2:sha256:"
SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
CONTENT_ID_RE = re.compile(
    r"pakperk-restore-evidence-v2:sha256:[0-9a-f]{64}\Z"
)
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")

ATTESTATION_KEYS = {
    "schema",
    "database",
    "environment",
    "marker",
    "backup_id",
    "source_revision",
    "worker_sha256",
    "expected_migration",
    "expected_ledger_records",
    "expected_ledger_inventory_sha256",
    "recovery_point",
    "latest_recoverable_point",
    "backup_observed_at",
    "restore_started_at",
    "restore_completed_at",
}
GUARD_KEYS = {
    "database",
    "marker",
    "backup_id",
    "recovery_point",
    "restore_attestation_sha256",
    "expected_ledger_inventory_sha256",
}
SNAPSHOT_KEYS = {
    "migration",
    "users",
    "papers",
    "core_jobs",
    "library_items",
    "library_operations",
    "paper_comments",
    "comment_reports",
    "user_reports",
    "user_blocks",
    "ledger_records",
    "deletion_jobs",
    "local_deletion_bindings_sha256",
    "unfinished_jobs",
    "terminal_jobs",
    "matching_restored_users",
    "unsafe_restored_users",
    "missing_jobs",
}
VERIFY_KEYS = {"verified_records", "ledger_inventory_sha256"}
REAPPLY_KEYS = {
    "verified_records",
    "ledger_inventory_sha256",
    "unchanged",
    "restored_and_queued",
    "requeued_resurrected_data",
    "requeued_provider_reconciliation",
}
CONTEXT_KEYS = {
    "schema",
    "phase",
    "database",
    "environment",
    "ledger_environment",
    "marker",
    "backup_id",
    "recovery_point",
    "latest_recoverable_point",
    "backup_observed_at",
    "restore_started_at",
    "restore_completed_at",
    "rpo_seconds",
    "rto_seconds",
    "expected_ledger_records",
    "database_ledger_records",
    "expected_ledger_inventory_sha256",
    "verified_ledger_inventory_sha256",
    "reapplied_ledger_inventory_sha256",
    "expected_migration",
    "source_revision",
    "source_tree_clean",
    "worker_sha256",
    "restore_attestation_sha256",
    "restore_guard_verified",
    "prior_reapply_content_id",
    "recorded_at",
    "evidence_limitations",
}
EVIDENCE_LIMITATIONS = [
    "provider_attestation_is_bound_not_independently_verified",
    "session_count_is_point_in_time_not_network_isolation_proof",
    "empty_inventory_digest_does_not_prove_physical_storage_identity",
]


class DrillError(Exception):
    """An expected validation failure whose details must not expose input."""


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def _closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DrillError("duplicate JSON member")
        result[key] = value
    return result


def _reject_constant(_: str) -> Any:
    raise DrillError("non-finite JSON number")


def strict_json(data: bytes, *, require_canonical: bool = False) -> Any:
    if len(data) > MAX_JSON_BYTES:
        raise DrillError("oversized JSON")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise DrillError("non-UTF-8 JSON") from error
    decoder = json.JSONDecoder(
        object_pairs_hook=_closed_object,
        parse_constant=_reject_constant,
    )
    leading = len(text) - len(text.lstrip())
    try:
        value, end = decoder.raw_decode(text, leading)
    except (json.JSONDecodeError, DrillError) as error:
        raise DrillError("invalid JSON document") from error
    if text[end:].strip():
        raise DrillError("multiple JSON documents")
    if require_canonical and data != canonical_json(value):
        raise DrillError("non-canonical JSON")
    return value


def _safe_flags(read_only: bool = True) -> int:
    flags = os.O_RDONLY if read_only else os.O_WRONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return flags


def read_regular(
    path: pathlib.Path,
    *,
    max_bytes: int,
    owner_only: bool = False,
    executable: bool = False,
) -> bytes:
    if not path.is_absolute():
        raise DrillError("path is not absolute")
    try:
        before = path.lstat()
        descriptor = os.open(str(path), _safe_flags())
    except OSError as error:
        raise DrillError("unavailable protected file") from error
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode):
            raise DrillError("not a regular file")
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise DrillError("file identity changed")
        if current.st_nlink != 1:
            raise DrillError("file has links")
        if current.st_uid not in {0, os.geteuid()}:
            raise DrillError("unexpected file owner")
        if owner_only and current.st_mode & 0o077:
            raise DrillError("file is not owner-only")
        if current.st_mode & 0o022:
            raise DrillError("file is group/world writable")
        if executable and not current.st_mode & stat.S_IXUSR:
            raise DrillError("file is not owner-executable")
        if current.st_size > max_bytes:
            raise DrillError("file is oversized")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise DrillError("file is oversized")
        after = os.fstat(descriptor)
        if (
            after.st_size != current.st_size
            or after.st_mtime_ns != current.st_mtime_ns
            or after.st_ctime_ns != current.st_ctime_ns
        ):
            raise DrillError("file changed while read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def write_exclusive(path: pathlib.Path, data: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(str(path), flags, mode)
    except OSError as error:
        raise DrillError("could not create protected output") from error
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise DrillError("short protected output write")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


def parse_utc(value: Any) -> dt.datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise DrillError("invalid UTC timestamp")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        raise DrillError("invalid UTC timestamp") from error


def require_exact_keys(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise DrillError("JSON object is not closed")
    return value


def require_int(value: Any, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise DrillError("expected integer")
    if value < (1 if positive else 0) or value > 9_007_199_254_740_991:
        raise DrillError("integer is out of bounds")
    return value


def require_sha256(value: Any) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise DrillError("invalid SHA-256 digest")
    return value


def env_int(name: str, *, positive: bool = False) -> int:
    raw = os.environ.get(name, "")
    if re.fullmatch(r"0|[1-9][0-9]{0,15}", raw) is None:
        raise DrillError("invalid integer environment binding")
    return require_int(int(raw), positive=positive)


def env_text(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "":
        raise DrillError("missing environment binding")
    return value


def stage_path(stage: pathlib.Path, name: str) -> pathlib.Path:
    if not stage.is_absolute() or stage.name.startswith(STAGE_PREFIX) is False:
        raise DrillError("invalid staging directory")
    try:
        info = stage.lstat()
    except OSError as error:
        raise DrillError("missing staging directory") from error
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise DrillError("invalid staging directory")
    return stage / name


def load_state(stage: pathlib.Path) -> dict[str, Any]:
    value = strict_json(
        read_regular(stage_path(stage, "state.json"), max_bytes=MAX_JSON_BYTES),
        require_canonical=True,
    )
    if not isinstance(value, dict):
        raise DrillError("invalid staging state")
    return value


def validate_attestation(value: Any, digest: str) -> dict[str, Any]:
    manifest = require_exact_keys(value, ATTESTATION_KEYS)
    if manifest["schema"] != 2:
        raise DrillError("unsupported attestation schema")
    strings = ATTESTATION_KEYS - {
        "schema",
        "expected_migration",
        "expected_ledger_records",
    }
    if any(not isinstance(manifest[key], str) or not manifest[key] for key in strings):
        raise DrillError("invalid attestation string")
    require_int(manifest["expected_migration"], positive=True)
    require_int(manifest["expected_ledger_records"])
    if re.fullmatch(r"[A-Za-z0-9_-]{1,63}", manifest["database"]) is None:
        raise DrillError("invalid attested database")
    if manifest["environment"] not in {"development", "staging"}:
        raise DrillError("invalid attested environment")
    if re.fullmatch(r"[A-Za-z0-9._:-]{8,128}", manifest["marker"]) is None:
        raise DrillError("invalid attested marker")
    if re.fullmatch(r"[0-9a-f]{40}", manifest["source_revision"]) is None:
        raise DrillError("invalid attested revision")
    if SHA256_RE.fullmatch(manifest["worker_sha256"]) is None:
        raise DrillError("invalid attested worker digest")
    require_sha256(manifest["expected_ledger_inventory_sha256"])
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", manifest["backup_id"]) is None:
        raise DrillError("invalid attested backup")
    if re.search(
        r"placeholder|change-me|example|fixture|dummy|ci-snapshot",
        manifest["backup_id"],
        re.IGNORECASE,
    ):
        raise DrillError("placeholder attested backup")

    times = {
        key: parse_utc(manifest[key])
        for key in (
            "recovery_point",
            "latest_recoverable_point",
            "backup_observed_at",
            "restore_started_at",
            "restore_completed_at",
        )
    }
    if not (
        times["recovery_point"]
        <= times["latest_recoverable_point"]
        <= times["backup_observed_at"]
        <= times["restore_started_at"]
        < times["restore_completed_at"]
    ):
        raise DrillError("inconsistent restore chronology")
    now = dt.datetime.now(dt.timezone.utc)
    if times["restore_completed_at"] > now + dt.timedelta(minutes=5):
        raise DrillError("future restore attestation")
    if times["restore_completed_at"] < now - dt.timedelta(hours=24):
        raise DrillError("stale restore attestation")

    rpo = int((times["backup_observed_at"] - times["recovery_point"]).total_seconds())
    rto = int((times["restore_completed_at"] - times["restore_started_at"]).total_seconds())
    if rpo != env_int("PAKPERK_RESTORE_DRILL_RPO_SECONDS"):
        raise DrillError("attested RPO does not match")
    if rto != env_int("PAKPERK_RESTORE_DRILL_RTO_SECONDS", positive=True):
        raise DrillError("attested RTO does not match")

    bindings: dict[str, Any] = {
        "database": env_text("PAKPERK_RESTORE_DRILL_DATABASE"),
        "environment": env_text("APP_ENV"),
        "marker": env_text("PAKPERK_RESTORE_DRILL_MARKER"),
        "backup_id": env_text("PAKPERK_RESTORE_DRILL_BACKUP_ID"),
        "source_revision": env_text("PAKPERK_RESTORE_DRILL_SOURCE_REVISION"),
        "worker_sha256": env_text("PAKPERK_RESTORE_DRILL_WORKER_SHA256"),
        "expected_migration": env_int(
            "PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION", positive=True
        ),
        "expected_ledger_records": env_int(
            "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS"
        ),
        "expected_ledger_inventory_sha256": require_sha256(
            env_text("PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256")
        ),
        "recovery_point": env_text("PAKPERK_RESTORE_DRILL_RECOVERY_POINT"),
    }
    if any(manifest[key] != expected for key, expected in bindings.items()):
        raise DrillError("attestation binding mismatch")
    if digest != env_text("PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256"):
        raise DrillError("attestation digest binding mismatch")
    return manifest


def cleanup_tree(stage: pathlib.Path) -> None:
    try:
        info = stage.lstat()
    except FileNotFoundError:
        return
    if (
        not stage.is_absolute()
        or not stage.name.startswith(STAGE_PREFIX)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
    ):
        raise DrillError("refusing unsafe cleanup")
    for root, directories, files in os.walk(str(stage), topdown=False, followlinks=False):
        root_path = pathlib.Path(root)
        os.chmod(root_path, 0o700)
        for name in files:
            (root_path / name).unlink()
        for name in directories:
            candidate = root_path / name
            if candidate.is_symlink():
                candidate.unlink()
            else:
                candidate.rmdir()
    stage.rmdir()


def command_prepare(_: argparse.Namespace) -> None:
    _validate_fresh_evidence_target(
        pathlib.Path(env_text("PAKPERK_RESTORE_DRILL_EVIDENCE_DIR"))
    )
    stage = pathlib.Path(tempfile.mkdtemp(prefix=STAGE_PREFIX)).resolve()
    os.chmod(stage, 0o700)
    try:
        worker = pathlib.Path(env_text("PAKPERK_DELETION_WORKER_BIN"))
        worker_bytes = read_regular(
            worker,
            max_bytes=1024 * 1024 * 1024,
            executable=True,
        )
        worker_digest = "sha256:" + hashlib.sha256(worker_bytes).hexdigest()
        if worker_digest != env_text("PAKPERK_RESTORE_DRILL_WORKER_SHA256"):
            raise DrillError("reviewed worker digest mismatch")

        attestation_path = pathlib.Path(env_text("PAKPERK_RESTORE_DRILL_ATTESTATION"))
        attestation_bytes = read_regular(
            attestation_path,
            max_bytes=MAX_JSON_BYTES,
            owner_only=True,
        )
        attestation_digest = "sha256:" + hashlib.sha256(attestation_bytes).hexdigest()
        if SHA256_RE.fullmatch(env_text("PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256")) is None:
            raise DrillError("invalid attestation digest")
        manifest = validate_attestation(
            strict_json(attestation_bytes, require_canonical=True),
            attestation_digest,
        )

        worker_directory = stage / "worker-bin"
        os.mkdir(worker_directory, 0o700)
        write_exclusive(worker_directory / "reviewed-worker", worker_bytes, 0o500)
        os.chmod(worker_directory, 0o500)
        write_exclusive(stage / "restore-attestation.json", attestation_bytes, 0o600)
        state = {
            "schema": 1,
            "attestation_sha256": attestation_digest,
            "worker_sha256": worker_digest,
            "rpo_seconds": int(
                (
                    parse_utc(manifest["backup_observed_at"])
                    - parse_utc(manifest["recovery_point"])
                ).total_seconds()
            ),
            "rto_seconds": int(
                (
                    parse_utc(manifest["restore_completed_at"])
                    - parse_utc(manifest["restore_started_at"])
                ).total_seconds()
            ),
        }
        write_exclusive(stage / "state.json", canonical_json(state), 0o600)
    except BaseException:
        cleanup_tree(stage)
        raise
    print(stage)


def _git(repo: pathlib.Path, arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DrillError("source verification command failed") from error


def command_check_source(arguments: argparse.Namespace) -> None:
    repo = pathlib.Path(arguments.repository)
    expected = env_text("PAKPERK_RESTORE_DRILL_SOURCE_REVISION")
    head = _git(repo, ["rev-parse", "--verify", "HEAD"])
    if head.returncode != 0 or head.stdout.strip().decode("ascii", "replace") != expected:
        raise DrillError("source revision mismatch")

    sparse = _git(repo, ["config", "--bool", "core.sparseCheckout"])
    if sparse.returncode not in {0, 1}:
        raise DrillError("sparse checkout state unavailable")
    if sparse.returncode == 0 and sparse.stdout.strip().lower() == b"true":
        raise DrillError("sparse checkout is not allowed")

    listed = _git(repo, ["ls-files", "-v", "-z"])
    if listed.returncode != 0:
        raise DrillError("index flags unavailable")
    for record in listed.stdout.split(b"\0"):
        if not record:
            continue
        if len(record) < 3 or record[:2] != b"H ":
            raise DrillError("concealed or abnormal index entry")

    for diff_arguments in (["diff", "--quiet", "--"], ["diff", "--cached", "--quiet", "--"]):
        result = _git(repo, list(diff_arguments))
        if result.returncode != 0:
            raise DrillError("source tree is dirty")
    status_result = _git(
        repo,
        [
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=matching",
            "--ignore-submodules=none",
        ],
    )
    if status_result.returncode != 0 or status_result.stdout:
        raise DrillError("source tree is dirty")


def command_validate_guard(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    raw_path = stage_path(stage, arguments.input)
    try:
        guard = require_exact_keys(
            strict_json(read_regular(raw_path, max_bytes=MAX_JSON_BYTES)),
            GUARD_KEYS,
        )
    finally:
        try:
            raw_path.unlink()
        except FileNotFoundError:
            pass
    if any(not isinstance(guard[key], str) for key in GUARD_KEYS):
        raise DrillError("invalid restore guard")
    manifest = strict_json(
        read_regular(stage_path(stage, "restore-attestation.json"), max_bytes=MAX_JSON_BYTES),
        require_canonical=True,
    )
    state = load_state(stage)
    expected = {
        "database": manifest["database"],
        "marker": manifest["marker"],
        "backup_id": manifest["backup_id"],
        "recovery_point": manifest["recovery_point"],
        "restore_attestation_sha256": state["attestation_sha256"],
        "expected_ledger_inventory_sha256": manifest[
            "expected_ledger_inventory_sha256"
        ],
    }
    if guard != expected:
        raise DrillError("restore guard binding mismatch")
    write_exclusive(stage / "restore-guard.json", canonical_json(guard), 0o600)


def command_capture_raw(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    destination = stage_path(stage, arguments.output)
    data = sys.stdin.buffer.read(MAX_JSON_BYTES + 1)
    if len(data) > MAX_JSON_BYTES:
        raise DrillError("database output exceeded limit")
    write_exclusive(destination, data, 0o600)


def _snapshot(value: Any) -> dict[str, int | str]:
    snapshot = require_exact_keys(value, SNAPSHOT_KEYS)
    result: dict[str, int | str] = {
        key: require_int(snapshot[key])
        for key in SNAPSHOT_KEYS - {"local_deletion_bindings_sha256"}
    }
    result["local_deletion_bindings_sha256"] = require_sha256(
        snapshot["local_deletion_bindings_sha256"]
    )
    return result


def command_validate_snapshot(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    raw_path = stage_path(stage, arguments.input)
    try:
        snapshot = _snapshot(
            strict_json(read_regular(raw_path, max_bytes=MAX_JSON_BYTES))
        )
    finally:
        try:
            raw_path.unlink()
        except FileNotFoundError:
            pass
    manifest = strict_json(
        read_regular(stage_path(stage, "restore-attestation.json"), max_bytes=MAX_JSON_BYTES),
        require_canonical=True,
    )
    expected_records = manifest["expected_ledger_records"]
    if snapshot["migration"] != manifest["expected_migration"]:
        raise DrillError("snapshot migration mismatch")
    if arguments.position == "before":
        if snapshot["ledger_records"] > expected_records:
            raise DrillError("database ledger exceeds attested inventory")
    else:
        before = _snapshot(
            strict_json(
                read_regular(stage_path(stage, "database-before.json"), max_bytes=MAX_JSON_BYTES),
                require_canonical=True,
            )
        )
        if snapshot["ledger_records"] != expected_records:
            raise DrillError("database ledger count mismatch")
        if snapshot["papers"] != before["papers"] or snapshot["core_jobs"] != before["core_jobs"]:
            raise DrillError("protected core counts changed")
        if snapshot["unsafe_restored_users"] != 0 or snapshot["missing_jobs"] != 0:
            raise DrillError("unsafe restored deletion state")
        if arguments.position == "final":
            if snapshot != before:
                raise DrillError("read-only finalization changed the database snapshot")
            if (
                snapshot["matching_restored_users"] != 0
                or snapshot["unfinished_jobs"] != 0
                or snapshot["terminal_jobs"] != 0
            ):
                raise DrillError("restore finalization is incomplete")
    write_exclusive(stage / arguments.output, canonical_json(snapshot), 0o600)


def _limit_worker() -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _worker_environment(command: str) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("PAKPERK_RESTORE_DRILL_")
        and key
        not in {
            "PAKPERK_DELETION_WORKER_BIN",
            "PAKPERK_ADMIN_ACTOR",
            "GITHUB_ENV",
            "GITHUB_OUTPUT",
            "GITHUB_PATH",
            "GITHUB_STEP_SUMMARY",
            "BASH_ENV",
            "ENV",
            "PYTHONPATH",
            "PYTHONHOME",
        }
    }
    # A drill must inspect the restored migration history exactly as recovered.
    # Development-mode workers otherwise default this to true and could repair
    # an old restore before readiness evaluates it.
    environment["RUN_MIGRATIONS"] = "false"
    if command == "reapply-ledger":
        environment["PAKPERK_ADMIN_ACTOR"] = env_text(
            "PAKPERK_RESTORE_DRILL_MARKER"
        )
    return environment


def _run_worker(worker: pathlib.Path, command: str, expected_digest: str) -> Any:
    worker_bytes = read_regular(
        worker,
        max_bytes=1024 * 1024 * 1024,
        executable=True,
    )
    if "sha256:" + hashlib.sha256(worker_bytes).hexdigest() != expected_digest:
        raise DrillError("protected worker digest mismatch")
    protected_stage = worker.parent.parent
    work_directory = pathlib.Path(
        tempfile.mkdtemp(prefix="worker-cwd-", dir=str(protected_stage))
    )
    os.chmod(work_directory, 0o700)
    os.chmod(protected_stage, 0o500)
    try:
        try:
            process = subprocess.Popen(
                [str(worker), command],
                cwd=str(work_directory),
                env=_worker_environment(command),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                close_fds=True,
                bufsize=0,
                start_new_session=True,
                preexec_fn=_limit_worker,
            )
        except OSError as error:
            raise DrillError("worker execution failed") from error

        stdout_chunks: list[bytes] = []
        capture_status = {
            "stdout_overflow": False,
            "stderr_overflow": False,
            "read_error": False,
        }

        def drain(stream: Any, *, retain: bool, key: str) -> None:
            total = 0
            try:
                while True:
                    chunk = stream.read(8192)
                    if not chunk:
                        break
                    total += len(chunk)
                    if retain and total <= MAX_WORKER_OUTPUT_BYTES:
                        stdout_chunks.append(chunk)
                    if total > MAX_WORKER_OUTPUT_BYTES:
                        capture_status[key] = True
            except OSError:
                capture_status["read_error"] = True
            finally:
                stream.close()

        assert process.stdout is not None and process.stderr is not None
        readers = (
            threading.Thread(
                target=drain,
                kwargs={
                    "stream": process.stdout,
                    "retain": True,
                    "key": "stdout_overflow",
                },
                daemon=True,
            ),
            threading.Thread(
                target=drain,
                kwargs={
                    "stream": process.stderr,
                    "retain": False,
                    "key": "stderr_overflow",
                },
                daemon=True,
            ),
        )
        for reader in readers:
            reader.start()
        timed_out = False
        try:
            return_code = process.wait(timeout=WORKER_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                process.kill()
            return_code = process.wait()
        for reader in readers:
            reader.join(timeout=5)
        if any(reader.is_alive() for reader in readers):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            for reader in readers:
                reader.join(timeout=5)
            raise DrillError("worker output capture failed")
        if (
            timed_out
            or return_code != 0
            or capture_status["stdout_overflow"]
            or capture_status["stderr_overflow"]
            or capture_status["read_error"]
        ):
            raise DrillError("worker execution failed")
        output = b"".join(stdout_chunks)
    finally:
        os.chmod(protected_stage, 0o700)
        for child in work_directory.iterdir():
            if child.is_dir() and not child.is_symlink():
                raise DrillError("worker created an unexpected directory")
            child.unlink()
        work_directory.rmdir()
    return strict_json(output)


def command_run_worker(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    state = load_state(stage)
    manifest = strict_json(
        read_regular(stage_path(stage, "restore-attestation.json"), max_bytes=MAX_JSON_BYTES),
        require_canonical=True,
    )
    expected = manifest["expected_ledger_records"]
    expected_inventory = manifest["expected_ledger_inventory_sha256"]
    worker = stage_path(stage, "worker-bin") / "reviewed-worker"

    verified = require_exact_keys(
        _run_worker(worker, "verify-ledger", state["worker_sha256"]), VERIFY_KEYS
    )
    if require_int(verified["verified_records"]) != expected:
        raise DrillError("worker ledger count mismatch")
    if require_sha256(verified["ledger_inventory_sha256"]) != expected_inventory:
        raise DrillError("worker ledger inventory mismatch")

    reapplied: dict[str, Any] | None = None
    if arguments.phase == "reapply":
        reapplied = require_exact_keys(
            _run_worker(worker, "reapply-ledger", state["worker_sha256"]),
            REAPPLY_KEYS,
        )
        values = {
            key: require_int(reapplied[key])
            for key in REAPPLY_KEYS - {"ledger_inventory_sha256"}
        }
        reapplied_inventory = require_sha256(reapplied["ledger_inventory_sha256"])
        if values["verified_records"] != expected:
            raise DrillError("worker reapply count mismatch")
        if (
            reapplied_inventory != expected_inventory
            or reapplied_inventory != verified["ledger_inventory_sha256"]
        ):
            raise DrillError("worker reapply inventory mismatch")
        if (
            values["unchanged"]
            + values["restored_and_queued"]
            + values["requeued_resurrected_data"]
            + values["requeued_provider_reconciliation"]
            != expected
        ):
            raise DrillError("worker reapply accounting mismatch")

    final_worker = read_regular(
        worker,
        max_bytes=1024 * 1024 * 1024,
        executable=True,
    )
    if "sha256:" + hashlib.sha256(final_worker).hexdigest() != state["worker_sha256"]:
        raise DrillError("protected worker changed")
    write_exclusive(stage / "ledger-verification.json", canonical_json(verified), 0o600)
    if reapplied is not None:
        write_exclusive(stage / "ledger-reapply.json", canonical_json(reapplied), 0o600)


def command_build_context(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    state = load_state(stage)
    attestation_bytes = read_regular(
        stage_path(stage, "restore-attestation.json"), max_bytes=MAX_JSON_BYTES
    )
    manifest = strict_json(
        attestation_bytes,
        require_canonical=True,
    )
    final_name = (
        "database-after-reapply.json"
        if arguments.phase == "reapply"
        else "database-final.json"
    )
    final_snapshot = _snapshot(
        strict_json(
            read_regular(stage_path(stage, final_name), max_bytes=MAX_JSON_BYTES),
            require_canonical=True,
        )
    )
    verified = require_exact_keys(
        strict_json(
            read_regular(
                stage_path(stage, "ledger-verification.json"),
                max_bytes=MAX_JSON_BYTES,
            ),
            require_canonical=True,
        ),
        VERIFY_KEYS,
    )
    expected_inventory = manifest["expected_ledger_inventory_sha256"]
    verified_inventory = require_sha256(verified["ledger_inventory_sha256"])
    if (
        require_int(verified["verified_records"])
        != manifest["expected_ledger_records"]
        or verified_inventory != expected_inventory
    ):
        raise DrillError("ledger verification evidence mismatch")
    reapplied_inventory: str | None = None
    if arguments.phase == "reapply":
        reapplied = require_exact_keys(
            strict_json(
                read_regular(
                    stage_path(stage, "ledger-reapply.json"),
                    max_bytes=MAX_JSON_BYTES,
                ),
                require_canonical=True,
            ),
            REAPPLY_KEYS,
        )
        reapplied_inventory = require_sha256(reapplied["ledger_inventory_sha256"])
        if reapplied_inventory != expected_inventory:
            raise DrillError("ledger reapply evidence mismatch")
    recorded_at_value = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    restore_completed_at = parse_utc(manifest["restore_completed_at"])
    if not (
        restore_completed_at
        <= recorded_at_value
        <= restore_completed_at + dt.timedelta(hours=24)
    ):
        raise DrillError("restore evidence timestamp is outside its window")
    if recorded_at_value > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise DrillError("restore evidence timestamp is future dated")
    recorded_at = recorded_at_value.strftime("%Y-%m-%dT%H:%M:%SZ")

    prior: str | None = None
    if arguments.phase == "finalize":
        prior = env_text("PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID")
        if CONTENT_ID_RE.fullmatch(prior) is None:
            raise DrillError("invalid prior reapply content ID")
        prior_target = pathlib.Path(
            env_text("PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR")
        )
        if not prior_target.is_absolute():
            raise DrillError("prior reapply evidence path is not absolute")
        finalize_database_before = _snapshot(
            strict_json(
                read_regular(
                    stage_path(stage, "database-before.json"),
                    max_bytes=MAX_JSON_BYTES,
                ),
                require_canonical=True,
            )
        )
        _validate_prior_reapply_chain(
            prior_target,
            prior,
            attestation_bytes,
            finalize_database_before,
            recorded_at,
        )
    elif (
        os.environ.get("PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID")
        or os.environ.get("PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR")
    ):
        raise DrillError("prior reapply evidence is finalize-only")
    context = {
        "schema": 4,
        "phase": arguments.phase,
        "database": manifest["database"],
        "environment": manifest["environment"],
        "ledger_environment": env_text("ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID"),
        "marker": manifest["marker"],
        "backup_id": manifest["backup_id"],
        "recovery_point": manifest["recovery_point"],
        "latest_recoverable_point": manifest["latest_recoverable_point"],
        "backup_observed_at": manifest["backup_observed_at"],
        "restore_started_at": manifest["restore_started_at"],
        "restore_completed_at": manifest["restore_completed_at"],
        "rpo_seconds": state["rpo_seconds"],
        "rto_seconds": state["rto_seconds"],
        "expected_ledger_records": manifest["expected_ledger_records"],
        "database_ledger_records": final_snapshot["ledger_records"],
        "expected_ledger_inventory_sha256": expected_inventory,
        "verified_ledger_inventory_sha256": verified_inventory,
        "reapplied_ledger_inventory_sha256": reapplied_inventory,
        "expected_migration": manifest["expected_migration"],
        "source_revision": manifest["source_revision"],
        "source_tree_clean": True,
        "worker_sha256": state["worker_sha256"],
        "restore_attestation_sha256": state["attestation_sha256"],
        "restore_guard_verified": True,
        "prior_reapply_content_id": prior,
        "recorded_at": recorded_at,
        "evidence_limitations": EVIDENCE_LIMITATIONS,
    }
    write_exclusive(stage / "drill-context.json", canonical_json(context), 0o600)


def evidence_names(phase: str) -> list[str]:
    common = [
        "restore-attestation.json",
        "restore-guard.json",
        "database-before.json",
        "ledger-verification.json",
        "drill-context.json",
    ]
    if phase == "reapply":
        common.extend(["ledger-reapply.json", "database-after-reapply.json"])
    else:
        common.append("database-final.json")
    return sorted(common)


def _tar_bytes(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in sorted(files):
            data = files[name]
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o400
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mtime = 0
            info.type = tarfile.REGTYPE
            archive.addfile(info, io.BytesIO(data))
    archive_bytes = buffer.getvalue()
    if len(archive_bytes) > MAX_ARCHIVE_BYTES:
        raise DrillError("evidence archive is oversized")
    return archive_bytes


def build_archive(stage: pathlib.Path, phase: str) -> bytes:
    files: dict[str, bytes] = {}
    for name in evidence_names(phase):
        data = read_regular(stage_path(stage, name), max_bytes=MAX_JSON_BYTES)
        strict_json(data, require_canonical=True)
        files[name] = data
    checksums = "".join(
        f"{hashlib.sha256(files[name]).hexdigest()}  {name}\n" for name in sorted(files)
    ).encode("ascii")
    files["SHA256SUMS"] = checksums
    return _tar_bytes(files)


def package_manifest(archive_bytes: bytes) -> dict[str, Any]:
    return {
        "schema": 2,
        "archive_sha256": "sha256:" + hashlib.sha256(archive_bytes).hexdigest(),
        "content_id": CONTENT_PREFIX
        + hashlib.sha256(CONTENT_DOMAIN + archive_bytes).hexdigest(),
    }


def _check_parent_without_links(path: pathlib.Path) -> None:
    current = pathlib.Path(path.anchor)
    for component in path.parent.parts[1:]:
        current = current / component
        try:
            info = current.lstat()
        except OSError as error:
            raise DrillError("evidence parent is unavailable") from error
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise DrillError("evidence parent contains a link")


def _validate_fresh_evidence_target(target: pathlib.Path) -> None:
    if not target.is_absolute() or target.name in {"", ".", ".."}:
        raise DrillError("invalid evidence target")
    _check_parent_without_links(target)
    try:
        target.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        raise DrillError("evidence target is unavailable") from error
    raise DrillError("evidence target is not fresh")


def _remove_published(path: pathlib.Path) -> None:
    for name in ("pakperk-restore-evidence.tar", "PACKAGE_SHA256.json"):
        try:
            (path / name).unlink()
        except FileNotFoundError:
            pass
    try:
        path.rmdir()
    except FileNotFoundError:
        pass


def command_publish(arguments: argparse.Namespace) -> None:
    stage = pathlib.Path(arguments.stage)
    target = pathlib.Path(arguments.target)
    _validate_fresh_evidence_target(target)
    archive_bytes = build_archive(stage, arguments.phase)
    manifest_bytes = canonical_json(package_manifest(archive_bytes))
    created = False
    try:
        os.mkdir(str(target), 0o700)
        created = True
        target_info = target.lstat()
        if (
            not stat.S_ISDIR(target_info.st_mode)
            or target_info.st_uid != os.geteuid()
            or target_info.st_mode & 0o077
        ):
            raise DrillError("evidence directory is not owner-only")
        write_exclusive(target / "pakperk-restore-evidence.tar", archive_bytes, 0o400)
        write_exclusive(target / "PACKAGE_SHA256.json", manifest_bytes, 0o400)
        os.chmod(target, 0o500)
    except BaseException:
        if created:
            try:
                os.chmod(target, 0o700)
            except OSError:
                pass
            _remove_published(target)
        raise
    print(package_manifest(archive_bytes)["content_id"])


def _archive_members(archive_bytes: bytes) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
            for member in archive.getmembers():
                if (
                    not member.isfile()
                    or member.name.startswith("/")
                    or ".." in pathlib.PurePosixPath(member.name).parts
                    or member.mode != 0o400
                    or member.uid != 0
                    or member.gid != 0
                    or member.uname != ""
                    or member.gname != ""
                    or member.mtime != 0
                    or member.name in files
                ):
                    raise DrillError("unsafe evidence archive member")
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise DrillError("unreadable evidence archive member")
                data = extracted.read(MAX_JSON_BYTES + 1)
                if len(data) > MAX_JSON_BYTES:
                    raise DrillError("oversized evidence archive member")
                files[member.name] = data
    except (tarfile.TarError, OSError) as error:
        raise DrillError("invalid evidence archive") from error
    return files


def _artifact_attestation(value: Any) -> dict[str, Any]:
    manifest = require_exact_keys(value, ATTESTATION_KEYS)
    if manifest["schema"] != 2:
        raise DrillError("unsupported evidence attestation schema")
    require_int(manifest["expected_migration"], positive=True)
    require_int(manifest["expected_ledger_records"])
    require_sha256(manifest["worker_sha256"])
    require_sha256(manifest["expected_ledger_inventory_sha256"])
    strings = ATTESTATION_KEYS - {
        "schema",
        "expected_migration",
        "expected_ledger_records",
    }
    if any(not isinstance(manifest[key], str) or not manifest[key] for key in strings):
        raise DrillError("invalid evidence attestation")
    if re.fullmatch(r"[A-Za-z0-9_-]{1,63}", manifest["database"]) is None:
        raise DrillError("invalid evidence database")
    if manifest["environment"] not in {"development", "staging"}:
        raise DrillError("invalid evidence environment")
    if re.fullmatch(r"[A-Za-z0-9._:-]{8,128}", manifest["marker"]) is None:
        raise DrillError("invalid evidence marker")
    if re.fullmatch(r"[0-9a-f]{40}", manifest["source_revision"]) is None:
        raise DrillError("invalid evidence source revision")
    if re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", manifest["backup_id"]
    ) is None or re.search(
        r"placeholder|change-me|example|fixture|dummy|ci-snapshot",
        manifest["backup_id"],
        re.IGNORECASE,
    ):
        raise DrillError("invalid evidence backup")
    times = {
        key: parse_utc(manifest[key])
        for key in (
            "recovery_point",
            "latest_recoverable_point",
            "backup_observed_at",
            "restore_started_at",
            "restore_completed_at",
        )
    }
    if not (
        times["recovery_point"]
        <= times["latest_recoverable_point"]
        <= times["backup_observed_at"]
        <= times["restore_started_at"]
        < times["restore_completed_at"]
    ):
        raise DrillError("invalid evidence chronology")
    return manifest


def _validate_evidence_contract(
    files: dict[str, bytes], context: dict[str, Any], phase: str
) -> None:
    manifest = _artifact_attestation(
        strict_json(files["restore-attestation.json"], require_canonical=True)
    )
    attestation_sha256 = "sha256:" + hashlib.sha256(
        files["restore-attestation.json"]
    ).hexdigest()
    expected_inventory = manifest["expected_ledger_inventory_sha256"]
    expected_records = manifest["expected_ledger_records"]

    guard = require_exact_keys(
        strict_json(files["restore-guard.json"], require_canonical=True), GUARD_KEYS
    )
    expected_guard = {
        "database": manifest["database"],
        "marker": manifest["marker"],
        "backup_id": manifest["backup_id"],
        "recovery_point": manifest["recovery_point"],
        "restore_attestation_sha256": attestation_sha256,
        "expected_ledger_inventory_sha256": expected_inventory,
    }
    if guard != expected_guard:
        raise DrillError("evidence guard binding mismatch")

    verified = require_exact_keys(
        strict_json(files["ledger-verification.json"], require_canonical=True),
        VERIFY_KEYS,
    )
    if (
        require_int(verified["verified_records"]) != expected_records
        or require_sha256(verified["ledger_inventory_sha256"])
        != expected_inventory
    ):
        raise DrillError("evidence ledger verification mismatch")

    reapplied_inventory: str | None = None
    if phase == "reapply":
        reapplied = require_exact_keys(
            strict_json(files["ledger-reapply.json"], require_canonical=True),
            REAPPLY_KEYS,
        )
        reapply_values = {
            key: require_int(reapplied[key])
            for key in REAPPLY_KEYS - {"ledger_inventory_sha256"}
        }
        reapplied_inventory = require_sha256(reapplied["ledger_inventory_sha256"])
        if (
            reapply_values["verified_records"] != expected_records
            or reapplied_inventory != expected_inventory
            or sum(
                reapply_values[key]
                for key in (
                    "unchanged",
                    "restored_and_queued",
                    "requeued_resurrected_data",
                    "requeued_provider_reconciliation",
                )
            )
            != expected_records
        ):
            raise DrillError("evidence ledger reapply mismatch")

    before = _snapshot(
        strict_json(files["database-before.json"], require_canonical=True)
    )
    final_name = (
        "database-after-reapply.json" if phase == "reapply" else "database-final.json"
    )
    final_snapshot = _snapshot(
        strict_json(files[final_name], require_canonical=True)
    )
    if (
        before["migration"] != manifest["expected_migration"]
        or before["ledger_records"] > expected_records
        or final_snapshot["migration"] != manifest["expected_migration"]
        or final_snapshot["ledger_records"] != expected_records
        or final_snapshot["papers"] != before["papers"]
        or final_snapshot["core_jobs"] != before["core_jobs"]
        or final_snapshot["unsafe_restored_users"] != 0
        or final_snapshot["missing_jobs"] != 0
        or (phase == "finalize" and final_snapshot != before)
        or (
            phase == "finalize"
            and (
                final_snapshot["matching_restored_users"] != 0
                or final_snapshot["unfinished_jobs"] != 0
                or final_snapshot["terminal_jobs"] != 0
            )
        )
    ):
        raise DrillError("evidence database snapshot mismatch")

    times = {
        key: parse_utc(manifest[key])
        for key in (
            "recovery_point",
            "backup_observed_at",
            "restore_started_at",
            "restore_completed_at",
        )
    }
    require_int(context["rpo_seconds"])
    require_int(context["rto_seconds"], positive=True)
    require_int(context["expected_ledger_records"])
    require_int(context["database_ledger_records"])
    require_int(context["expected_migration"], positive=True)
    if (
        context["source_tree_clean"] is not True
        or context["restore_guard_verified"] is not True
    ):
        raise DrillError("evidence context boolean mismatch")
    expected_context = {
        "schema": 4,
        "phase": phase,
        "database": manifest["database"],
        "environment": manifest["environment"],
        "ledger_environment": manifest["environment"],
        "marker": manifest["marker"],
        "backup_id": manifest["backup_id"],
        "recovery_point": manifest["recovery_point"],
        "latest_recoverable_point": manifest["latest_recoverable_point"],
        "backup_observed_at": manifest["backup_observed_at"],
        "restore_started_at": manifest["restore_started_at"],
        "restore_completed_at": manifest["restore_completed_at"],
        "rpo_seconds": int(
            (times["backup_observed_at"] - times["recovery_point"]).total_seconds()
        ),
        "rto_seconds": int(
            (times["restore_completed_at"] - times["restore_started_at"]).total_seconds()
        ),
        "expected_ledger_records": expected_records,
        "database_ledger_records": final_snapshot["ledger_records"],
        "expected_ledger_inventory_sha256": expected_inventory,
        "verified_ledger_inventory_sha256": expected_inventory,
        "reapplied_ledger_inventory_sha256": reapplied_inventory,
        "expected_migration": manifest["expected_migration"],
        "source_revision": manifest["source_revision"],
        "source_tree_clean": True,
        "worker_sha256": manifest["worker_sha256"],
        "restore_attestation_sha256": attestation_sha256,
        "restore_guard_verified": True,
        "evidence_limitations": EVIDENCE_LIMITATIONS,
    }
    if any(context.get(key) != value for key, value in expected_context.items()):
        raise DrillError("evidence context binding mismatch")
    recorded_at = parse_utc(context["recorded_at"])
    if recorded_at < times["restore_completed_at"]:
        raise DrillError("evidence context predates restore completion")
    if recorded_at > times["restore_completed_at"] + dt.timedelta(hours=24):
        raise DrillError("evidence context exceeds restore evidence window")
    if recorded_at > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise DrillError("evidence context is future dated")
    prior = context["prior_reapply_content_id"]
    if phase == "reapply":
        if prior is not None:
            raise DrillError("reapply evidence has a prior content ID")
    elif not isinstance(prior, str) or CONTENT_ID_RE.fullmatch(prior) is None:
        raise DrillError("final evidence has an invalid prior content ID")


def _verified_package(
    target: pathlib.Path,
) -> tuple[str, dict[str, bytes], dict[str, Any]]:
    try:
        directory_info = target.lstat()
    except OSError as error:
        raise DrillError("evidence package is unavailable") from error
    if (
        not stat.S_ISDIR(directory_info.st_mode)
        or directory_info.st_uid != os.geteuid()
        or stat.S_IMODE(directory_info.st_mode) != 0o500
    ):
        raise DrillError("evidence package directory is unsafe")
    archive_path = target / "pakperk-restore-evidence.tar"
    manifest_path = target / "PACKAGE_SHA256.json"
    archive_bytes = read_regular(archive_path, max_bytes=MAX_ARCHIVE_BYTES, owner_only=True)
    manifest_bytes = read_regular(manifest_path, max_bytes=MAX_JSON_BYTES, owner_only=True)
    for path in (archive_path, manifest_path):
        info = path.lstat()
        if stat.S_IMODE(info.st_mode) != 0o400 or info.st_nlink != 1:
            raise DrillError("evidence package file is unsafe")
    manifest = require_exact_keys(
        strict_json(manifest_bytes, require_canonical=True),
        {"schema", "archive_sha256", "content_id"},
    )
    if manifest != package_manifest(archive_bytes):
        raise DrillError("evidence package digest mismatch")
    files = _archive_members(archive_bytes)
    contexts = [name for name in files if name == "drill-context.json"]
    if len(contexts) != 1:
        raise DrillError("evidence context is missing")
    context = require_exact_keys(
        strict_json(files["drill-context.json"], require_canonical=True),
        CONTEXT_KEYS,
    )
    phase = context["phase"]
    if phase not in {"reapply", "finalize"}:
        raise DrillError("invalid evidence phase")
    expected_names = set(evidence_names(phase)) | {"SHA256SUMS"}
    if set(files) != expected_names:
        raise DrillError("evidence archive is not closed")
    expected_checksums = "".join(
        f"{hashlib.sha256(files[name]).hexdigest()}  {name}\n"
        for name in sorted(files)
        if name != "SHA256SUMS"
    ).encode("ascii")
    if files["SHA256SUMS"] != expected_checksums:
        raise DrillError("evidence member checksum mismatch")
    for name, data in files.items():
        if name.endswith(".json"):
            strict_json(data, require_canonical=True)
    _validate_evidence_contract(files, context, phase)
    if archive_bytes != _tar_bytes(files):
        raise DrillError("evidence archive is not canonical")
    if CONTENT_ID_RE.fullmatch(manifest["content_id"]) is None:
        raise DrillError("invalid evidence content ID")
    return manifest["content_id"], files, context


def _validate_prior_reapply_chain(
    prior_target: pathlib.Path,
    expected_content_id: str,
    restore_attestation: bytes,
    finalize_database_before: dict[str, int | str],
    finalize_recorded_at: str,
) -> None:
    prior_content_id, prior_files, prior_context = _verified_package(prior_target)
    if prior_context["phase"] != "reapply":
        raise DrillError("prior restore evidence is not a reapply package")
    if prior_content_id != expected_content_id:
        raise DrillError("prior reapply content ID mismatch")
    if prior_files["restore-attestation.json"] != restore_attestation:
        raise DrillError("prior reapply attestation mismatch")
    prior_database_after = _snapshot(
        strict_json(
            prior_files["database-after-reapply.json"], require_canonical=True
        )
    )
    if any(
        prior_database_after[key] != finalize_database_before[key]
        for key in (
            "migration",
            "papers",
            "core_jobs",
            "ledger_records",
            "local_deletion_bindings_sha256",
        )
    ):
        raise DrillError("prior reapply protected snapshot mismatch")
    if parse_utc(prior_context["recorded_at"]) > parse_utc(finalize_recorded_at):
        raise DrillError("finalize evidence predates prior reapply evidence")


def verify_package(
    target: pathlib.Path, prior_reapply_target: pathlib.Path | None = None
) -> str:
    content_id, files, context = _verified_package(target)
    if context["phase"] == "finalize":
        if prior_reapply_target is None:
            raise DrillError("finalize package requires prior reapply evidence")
        _validate_prior_reapply_chain(
            prior_reapply_target,
            context["prior_reapply_content_id"],
            files["restore-attestation.json"],
            _snapshot(
                strict_json(
                    files["database-before.json"], require_canonical=True
                )
            ),
            context["recorded_at"],
        )
    elif prior_reapply_target is not None:
        raise DrillError("prior reapply evidence is finalize-only")
    return content_id


def command_verify_package(arguments: argparse.Namespace) -> None:
    prior = (
        pathlib.Path(arguments.prior_reapply_evidence_dir)
        if arguments.prior_reapply_evidence_dir is not None
        else None
    )
    print(verify_package(pathlib.Path(arguments.target), prior))


def command_remove_package(arguments: argparse.Namespace) -> None:
    target = pathlib.Path(arguments.target)
    if not target.is_absolute():
        raise DrillError("invalid evidence target")
    try:
        info = target.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise DrillError("unsafe evidence cleanup target")
    names = {entry.name for entry in target.iterdir()}
    if not names.issubset(
        {"pakperk-restore-evidence.tar", "PACKAGE_SHA256.json"}
    ):
        raise DrillError("unexpected evidence cleanup member")
    os.chmod(target, 0o700)
    _remove_published(target)


def command_cleanup(arguments: argparse.Namespace) -> None:
    cleanup_tree(pathlib.Path(arguments.stage))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(add_help=False)
    subparsers = result.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", add_help=False)
    prepare.set_defaults(handler=command_prepare)

    source = subparsers.add_parser("check-source", add_help=False)
    source.add_argument("repository")
    source.set_defaults(handler=command_check_source)

    guard = subparsers.add_parser("validate-guard", add_help=False)
    guard.add_argument("stage")
    guard.add_argument("input")
    guard.set_defaults(handler=command_validate_guard)

    capture = subparsers.add_parser("capture-raw", add_help=False)
    capture.add_argument("stage")
    capture.add_argument("output")
    capture.set_defaults(handler=command_capture_raw)

    snapshot = subparsers.add_parser("validate-snapshot", add_help=False)
    snapshot.add_argument("stage")
    snapshot.add_argument("input")
    snapshot.add_argument("output")
    snapshot.add_argument("position", choices=("before", "after", "final"))
    snapshot.set_defaults(handler=command_validate_snapshot)

    worker = subparsers.add_parser("run-worker", add_help=False)
    worker.add_argument("stage")
    worker.add_argument("phase", choices=("reapply", "finalize"))
    worker.set_defaults(handler=command_run_worker)

    context = subparsers.add_parser("build-context", add_help=False)
    context.add_argument("stage")
    context.add_argument("phase", choices=("reapply", "finalize"))
    context.set_defaults(handler=command_build_context)

    publish = subparsers.add_parser("publish", add_help=False)
    publish.add_argument("stage")
    publish.add_argument("target")
    publish.add_argument("phase", choices=("reapply", "finalize"))
    publish.set_defaults(handler=command_publish)

    verify = subparsers.add_parser("verify-package", add_help=False)
    verify.add_argument("target")
    verify.add_argument("--prior-reapply-evidence-dir")
    verify.set_defaults(handler=command_verify_package)

    remove = subparsers.add_parser("remove-package", add_help=False)
    remove.add_argument("target")
    remove.set_defaults(handler=command_remove_package)

    cleanup = subparsers.add_parser("cleanup", add_help=False)
    cleanup.add_argument("stage")
    cleanup.set_defaults(handler=command_cleanup)
    return result


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
        return 0
    except DrillError:
        print("Restore drill verification failed.", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        print("Restore drill verification failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
