#!/usr/bin/env python3
"""Hermetic regressions for the protected restore-drill harness."""

from __future__ import annotations

import datetime as dt
import hashlib
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/drill_backup_restore.sh"
HELPER = ROOT / "scripts/restore_drill_evidence.py"
SOURCE_REVISION = "a" * 40
PRIOR_CONTENT_ID = "pakperk-restore-evidence-v2:sha256:" + "b" * 64
LEDGER_INVENTORY_SHA256 = "sha256:" + "c" * 64
LOCAL_DELETION_BINDINGS_SHA256 = "sha256:" + "e" * 64


FAKE_GIT = r"""
#!/usr/bin/env python3
import os
import sys

arguments = sys.argv[1:]
if "rev-parse" in arguments:
    print(os.environ["FAKE_GIT_HEAD"])
    raise SystemExit(0)
if "config" in arguments:
    print("true" if os.environ.get("FAKE_GIT_SPARSE") == "1" else "false")
    raise SystemExit(0)
if "ls-files" in arguments:
    tag = os.environ.get("FAKE_GIT_INDEX_TAG", "H")
    sys.stdout.buffer.write((tag + " tracked-file\0").encode("utf-8"))
    raise SystemExit(0)
if "diff" in arguments:
    raise SystemExit(1 if os.environ.get("FAKE_GIT_DIFF_DIRTY") == "1" else 0)
if "status" in arguments:
    value = os.environ.get("FAKE_GIT_STATUS", "")
    if os.environ.get("FAKE_GIT_IGNORED") == "1" and "--ignored=matching" in arguments:
        value = "!! concealed-runtime-config"
    if value:
        print(value)
    raise SystemExit(0)
raise SystemExit(2)
"""


FAKE_PSQL = r"""
#!/usr/bin/env python3
import json
import os
import pathlib
import sys

if not any(argument.startswith("--dbname=") for argument in sys.argv[1:]):
    raise SystemExit(2)
try:
    query = sys.argv[sys.argv.index("--command") + 1]
except (ValueError, IndexError):
    raise SystemExit(2)

set_search_path = "SET search_path TO public, pg_catalog;"
verify_search_path = (
    "pg_catalog.current_setting('search_path') = 'public, pg_catalog'"
    "\n          AND pg_catalog.current_schema()::pg_catalog.text = 'public';"
)
if (
    query.count(set_search_path) != 1
    or query.count(verify_search_path) != 1
    or query.index(set_search_path) > query.index(verify_search_path)
):
    raise SystemExit(4)
print("t")

failure = os.environ.get("FAKE_PSQL_FAILURE", "")
if "pakperk_restore_drill_guard" in query:
    fractional_guard_is_rejected = (
        "guard.recovery_point = pg_catalog.date_trunc('second', guard.recovery_point)"
        in query
    )
    if failure == "guard" or (
        failure == "guard_fractional" and fractional_guard_is_rejected
    ):
        print("")
    else:
        backup_id = os.environ["PAKPERK_RESTORE_DRILL_BACKUP_ID"]
        recovery_point = os.environ["PAKPERK_RESTORE_DRILL_RECOVERY_POINT"]
        digest = os.environ["PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256"]
        inventory_digest = os.environ[
            "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256"
        ]
        if failure == "guard_backup":
            backup_id = "backup-wrong-protected-record"
        if failure == "guard_recovery":
            recovery_point = "2001-01-01T00:00:00Z"
        if failure == "guard_digest":
            digest = "sha256:" + "0" * 64
        if failure == "guard_inventory":
            inventory_digest = "sha256:" + "0" * 64
        marker = os.environ["PAKPERK_RESTORE_DRILL_MARKER"]
        if failure == "guard_marker":
            marker = "restore-wrong-marker"
        print(json.dumps({
            "database": os.environ["PAKPERK_RESTORE_DRILL_DATABASE"],
            "marker": marker,
            "backup_id": backup_id,
            "recovery_point": recovery_point,
            "restore_attestation_sha256": digest,
            "expected_ledger_inventory_sha256": inventory_digest,
        }))
elif "pg_catalog.pg_extension" in query:
    required_extension_fragments = (
        "('vector')",
        "('pg_trgm')",
        "('pgcrypto')",
        "JOIN pg_catalog.pg_namespace AS namespace",
        "namespace.oid = extension.extnamespace",
        "namespace.nspname = 'public'",
        ") <> 1",
    )
    if any(fragment not in query for fragment in required_extension_fragments):
        raise SystemExit(4)
    pathlib.Path(os.environ["FAKE_EXTENSION_PREFLIGHT_STATE"]).write_text(
        "checked", encoding="utf-8"
    )
    print("1" if failure == "extension_namespace" else "0")
elif "json_build_object" in query:
    if not pathlib.Path(os.environ["FAKE_EXTENSION_PREFLIGHT_STATE"]).is_file():
        raise SystemExit(4)
    required_binding_fragments = (
        "pakperk-local-account-deletion-bindings-v1",
        "pakperk-local-account-deletion-provider-binding-v1",
        "pg_catalog.jsonb_build_array",
        "ORDER BY operation_id",
    )
    if any(fragment not in query for fragment in required_binding_fragments):
        raise SystemExit(4)
    counter_path = pathlib.Path(os.environ["FAKE_PSQL_STATE"])
    count = int(counter_path.read_text(encoding="utf-8")) if counter_path.exists() else 0
    counter_path.write_text(str(count + 1), encoding="utf-8")
    phase = os.environ.get("PAKPERK_RESTORE_DRILL_PHASE", "reapply")
    expected = int(os.environ.get("FAKE_WORKER_RECORDS", "1"))
    before_ledger = int(os.environ.get("FAKE_DB_LEDGER_BEFORE", str(expected)))
    after_ledger = int(os.environ.get("FAKE_DB_LEDGER_AFTER", str(expected)))
    ledger_records = before_ledger if count == 0 else after_ledger
    bindings_before = os.environ.get(
        "FAKE_DB_BINDINGS_BEFORE", "sha256:" + "e" * 64
    )
    bindings_after = os.environ.get("FAKE_DB_BINDINGS_AFTER", bindings_before)
    snapshot = {
        "migration": 10,
        "users": 1,
        "papers": 3,
        "core_jobs": 2,
        "library_items": 1,
        "library_operations": 1,
        "paper_comments": 1,
        "comment_reports": 1,
        "user_reports": 1,
        "user_blocks": 1,
        "ledger_records": ledger_records,
        "deletion_jobs": 1,
        "local_deletion_bindings_sha256": (
            bindings_before if count == 0 else bindings_after
        ),
        "unfinished_jobs": 0 if phase == "finalize" else 1,
        "terminal_jobs": 0,
        "matching_restored_users": 0 if phase == "finalize" else 1,
        "unsafe_restored_users": 0,
        "missing_jobs": 0,
    }
    if failure == "pending_user_final":
        snapshot["matching_restored_users"] = 1
    if count > 0 and failure == "unsafe_after":
        snapshot["unsafe_restored_users"] = 1
    if count > 0 and failure == "missing_jobs_after":
        snapshot["missing_jobs"] = 1
    if count > 0 and failure == "changed_papers_after":
        snapshot["papers"] += 1
    if count > 0 and failure == "changed_users_after":
        snapshot["users"] += 1
    if count == 0 and failure == "unsafe_before":
        snapshot["unsafe_restored_users"] = 1
    if count > 0 and failure == "unfinished_final":
        snapshot["unfinished_jobs"] = 1
    if count > 0 and failure == "terminal_final":
        snapshot["terminal_jobs"] = 1
    print(json.dumps(snapshot, sort_keys=True))
elif "pg_stat_activity" in query:
    print("1" if failure == "sessions" else "0")
elif "current_database()" in query:
    print(
        "wrong_database"
        if failure == "database"
        else os.environ["PAKPERK_RESTORE_DRILL_DATABASE"]
    )
elif "FROM (VALUES" in query:
    print("1" if failure == "tables" else "0")
elif "max(version)" in query:
    print(
        "9"
        if failure == "migration"
        else os.environ.get("PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION", "10")
    )
else:
    raise SystemExit(3)
"""


FAKE_WORKER = r"""
#!/usr/bin/env python3
import json
import os
import pathlib
import sys

command = sys.argv[1] if len(sys.argv) == 2 else ""
mode = os.environ.get("FAKE_WORKER_MODE", "")
with pathlib.Path(os.environ["FAKE_WORKER_LOG"]).open("a", encoding="utf-8") as log:
    log.write(command + "\n")
    log.write("evidence-visible=" + str("PAKPERK_RESTORE_DRILL_EVIDENCE_DIR" in os.environ) + "\n")
    log.write("run-migrations=" + os.environ.get("RUN_MIGRATIONS", "") + "\n")
    if command == "reapply-ledger":
        log.write("admin-actor=" + os.environ.get("PAKPERK_ADMIN_ACTOR", "") + "\n")

if mode in {"secret_stderr", "failure_secret"}:
    print("provider-coordinate:secret-on-stderr", file=sys.stderr)
if mode == "failure_secret":
    print('{"provider_coordinate":"secret-partial-output"}')
    raise SystemExit(7)
if mode == "failure":
    raise SystemExit(7)
if mode == "malformed":
    print("not-json")
    raise SystemExit(0)

records = int(os.environ.get("FAKE_WORKER_RECORDS", "1"))
inventory_digest = os.environ.get(
    "FAKE_WORKER_INVENTORY_SHA256", "sha256:" + "c" * 64
)
if command == "verify-ledger":
    if mode == "duplicate":
        print('{"verified_records":999,"verified_records":%d}' % records)
    elif mode == "multiple_documents":
        print('{"provider_coordinate":"secret-first-document"}')
        print(json.dumps({
            "verified_records": records,
            "ledger_inventory_sha256": inventory_digest,
        }))
    else:
        payload = {
            "verified_records": records,
            "ledger_inventory_sha256": (
                "sha256:" + "d" * 64
                if mode == "inventory_mismatch"
                else inventory_digest
            ),
        }
        if mode == "missing_inventory":
            del payload["ledger_inventory_sha256"]
        if mode == "extra":
            payload["provider_coordinate"] = "must-not-enter-evidence"
        print(json.dumps(payload))
    if mode == "tamper_original":
        original = pathlib.Path(os.environ["FAKE_ORIGINAL_WORKER"])
        original.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
    if mode == "plant_symlink":
        evidence = os.environ.get("PAKPERK_RESTORE_DRILL_EVIDENCE_DIR")
        if evidence:
            evidence_path = pathlib.Path(evidence)
            evidence_path.mkdir()
            (evidence_path / "drill-context.json").symlink_to(
                os.environ["FAKE_SYMLINK_TARGET"]
            )
    if mode == "stage_symlink":
        stage = pathlib.Path(__file__).parent.parent
        (stage / "database-after-reapply.raw").symlink_to(
            os.environ["FAKE_SYMLINK_TARGET"]
        )
elif command == "reapply-ledger":
    payload = {
        "verified_records": records,
        "ledger_inventory_sha256": (
            "sha256:" + "d" * 64
            if mode == "reapply_inventory_mismatch"
            else inventory_digest
        ),
        "unchanged": 0,
        "restored_and_queued": records,
        "requeued_resurrected_data": 0,
        "requeued_provider_reconciliation": 0,
    }
    if mode == "extra_reapply":
        payload["provider_coordinate"] = "must-not-enter-evidence"
    print(json.dumps(payload))
else:
    raise SystemExit(2)
"""


FAKE_PYTHON_FAIL_PACKAGE_VERIFY = r"""
#!/bin/sh
case "$*" in
  *restore_drill_evidence.py*verify-package*) exit 9 ;;
esac
exec "$REAL_PYTHON3" "$@"
"""


class RestoreDrillTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.temporary = pathlib.Path(temporary.name).resolve()
        self.fake_bin = self.temporary / "bin"
        self.fake_bin.mkdir()
        self._executable("git", FAKE_GIT)
        self._executable("psql", FAKE_PSQL)
        self.worker = self._executable("pakperk-deletion-worker", FAKE_WORKER)
        self.worker_digest = "sha256:" + hashlib.sha256(
            self.worker.read_bytes()
        ).hexdigest()
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        completed = now - dt.timedelta(seconds=10)
        started = completed - dt.timedelta(seconds=120)
        observed = started - dt.timedelta(seconds=30)
        recovery = observed - dt.timedelta(seconds=60)
        latest = recovery + dt.timedelta(seconds=30)
        timestamp = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
        self.attestation_value = {
            "schema": 2,
            "database": "pakperk_restore_release_42",
            "environment": "staging",
            "marker": "restore-release-42",
            "backup_id": "backup-20260802-release-42",
            "source_revision": SOURCE_REVISION,
            "worker_sha256": self.worker_digest,
            "expected_migration": 10,
            "expected_ledger_records": 1,
            "expected_ledger_inventory_sha256": LEDGER_INVENTORY_SHA256,
            "recovery_point": timestamp(recovery),
            "latest_recoverable_point": timestamp(latest),
            "backup_observed_at": timestamp(observed),
            "restore_started_at": timestamp(started),
            "restore_completed_at": timestamp(completed),
        }
        self.attestation = self._write_attestation(self.attestation_value)
        self.attestation_digest = self._digest(self.attestation)
        self.run_number = 0

    def _executable(self, name: str, source: str) -> pathlib.Path:
        destination = self.fake_bin / name
        destination.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        destination.chmod(0o700)
        return destination

    def _write_attestation(
        self,
        value: dict[str, object],
        *,
        canonical: bool = True,
        raw: bytes | None = None,
        mode: int = 0o600,
    ) -> pathlib.Path:
        path = self.temporary / f"restore-attestation-{len(list(self.temporary.glob('restore-attestation-*')))}.json"
        if raw is None:
            if canonical:
                raw = (
                    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode("utf-8")
            else:
                raw = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
        path.write_bytes(raw)
        path.chmod(mode)
        return path

    @staticmethod
    def _digest(path: pathlib.Path) -> str:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

    def _environment(self, evidence: pathlib.Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
                "DATABASE_URL": "postgres://restore-user:secret@invalid/restore",
                "PAKPERK_DELETION_WORKER_BIN": str(self.worker),
                "PAKPERK_RESTORE_DRILL_DATABASE": self.attestation_value["database"],
                "PAKPERK_RESTORE_DRILL_MARKER": self.attestation_value["marker"],
                "PAKPERK_RESTORE_DRILL_EVIDENCE_DIR": str(evidence),
                "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS": "1",
                "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256": LEDGER_INVENTORY_SHA256,
                "PAKPERK_RESTORE_DRILL_CONFIRM": "isolated-nonproduction-restore",
                "PAKPERK_RESTORE_DRILL_PHASE": "reapply",
                "PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION": "10",
                "PAKPERK_RESTORE_DRILL_SOURCE_REVISION": SOURCE_REVISION,
                "PAKPERK_RESTORE_DRILL_WORKER_SHA256": self.worker_digest,
                "PAKPERK_RESTORE_DRILL_BACKUP_ID": self.attestation_value["backup_id"],
                "PAKPERK_RESTORE_DRILL_RECOVERY_POINT": self.attestation_value["recovery_point"],
                "PAKPERK_RESTORE_DRILL_RPO_SECONDS": "60",
                "PAKPERK_RESTORE_DRILL_RTO_SECONDS": "120",
                "PAKPERK_RESTORE_DRILL_ATTESTATION": str(self.attestation),
                "PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": self.attestation_digest,
                "APP_ENV": "staging",
                "ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID": "staging",
                "FAKE_GIT_HEAD": SOURCE_REVISION,
                "FAKE_PSQL_STATE": str(self.temporary / f"psql-{self.run_number}"),
                "FAKE_EXTENSION_PREFLIGHT_STATE": str(
                    self.temporary / f"extension-preflight-{self.run_number}"
                ),
                "FAKE_WORKER_LOG": str(self.temporary / f"worker-{self.run_number}.log"),
                "FAKE_WORKER_INVENTORY_SHA256": LEDGER_INVENTORY_SHA256,
                "FAKE_ORIGINAL_WORKER": str(self.worker),
                "FAKE_SYMLINK_TARGET": str(self.temporary / "outside-secret-target"),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        return environment

    def _run(
        self,
        overrides: dict[str, str] | None = None,
        *,
        evidence: pathlib.Path | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path]:
        self.run_number += 1
        evidence_path = evidence or self.temporary / f"evidence-{self.run_number}"
        environment = self._environment(evidence_path)
        if overrides:
            environment.update(overrides)
        worker_log = pathlib.Path(environment["FAKE_WORKER_LOG"])
        result = subprocess.run(
            [str(SCRIPT)],
            cwd=ROOT,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
        return result, evidence_path, worker_log

    def _assert_failure(
        self,
        overrides: dict[str, str],
        expected: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result, evidence, _ = self._run(overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        if expected:
            self.assertIn(expected, result.stderr)
        self.assertFalse(evidence.exists(), "failed drills must not retain evidence")
        return result

    @staticmethod
    def _package_files(evidence: pathlib.Path) -> tuple[dict[str, object], dict[str, bytes]]:
        package = json.loads((evidence / "PACKAGE_SHA256.json").read_text(encoding="utf-8"))
        archive_bytes = (evidence / "pakperk-restore-evidence.tar").read_bytes()
        files: dict[str, bytes] = {}
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
            for member in archive.getmembers():
                extracted = archive.extractfile(member)
                assert extracted is not None
                files[member.name] = extracted.read()
        return package, files

    @staticmethod
    def _canonical_bytes(value: object) -> bytes:
        return (
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()

    @staticmethod
    def _rewrite_package(evidence: pathlib.Path, files: dict[str, bytes]) -> None:
        files = dict(files)
        files.pop("SHA256SUMS", None)
        files["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(files[name]).hexdigest()}  {name}\n"
            for name in sorted(files)
        ).encode("ascii")
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
        package = {
            "schema": 2,
            "archive_sha256": "sha256:"
            + hashlib.sha256(archive_bytes).hexdigest(),
            "content_id": "pakperk-restore-evidence-v2:sha256:"
            + hashlib.sha256(
                b"pakperk-restore-evidence-v2\0" + archive_bytes
            ).hexdigest(),
        }
        evidence.chmod(0o700)
        archive_path = evidence / "pakperk-restore-evidence.tar"
        manifest_path = evidence / "PACKAGE_SHA256.json"
        archive_path.chmod(0o600)
        manifest_path.chmod(0o600)
        archive_path.write_bytes(archive_bytes)
        manifest_path.write_bytes(
            (json.dumps(package, sort_keys=True, separators=(",", ":")) + "\n").encode()
        )
        archive_path.chmod(0o400)
        manifest_path.chmod(0o400)
        evidence.chmod(0o500)

    def _create_prior_reapply(self) -> tuple[pathlib.Path, str]:
        result, evidence, _ = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        package, _ = self._package_files(evidence)
        content_id = package["content_id"]
        assert isinstance(content_id, str)
        return evidence, content_id

    @staticmethod
    def _finalize_bindings(
        prior_evidence: pathlib.Path, prior_content_id: str
    ) -> dict[str, str]:
        return {
            "PAKPERK_RESTORE_DRILL_PHASE": "finalize",
            "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID": prior_content_id,
            "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR": str(
                prior_evidence
            ),
        }

    def test_reapply_publishes_closed_content_addressed_owner_only_package(self) -> None:
        result, evidence, worker_log = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Evidence content ID:", result.stdout)
        self.assertEqual(
            worker_log.read_text(encoding="utf-8").splitlines(),
            [
                "verify-ledger",
                "evidence-visible=False",
                "run-migrations=false",
                "reapply-ledger",
                "evidence-visible=False",
                "run-migrations=false",
                "admin-actor=restore-release-42",
            ],
        )
        self.assertEqual(
            {path.name for path in evidence.iterdir()},
            {"pakperk-restore-evidence.tar", "PACKAGE_SHA256.json"},
        )
        self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o500)
        for path in evidence.iterdir():
            info = path.lstat()
            self.assertTrue(stat.S_ISREG(info.st_mode))
            self.assertEqual(info.st_nlink, 1)
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o400)
        package, files = self._package_files(evidence)
        archive_bytes = (evidence / "pakperk-restore-evidence.tar").read_bytes()
        self.assertEqual(package["schema"], 2)
        self.assertEqual(
            package["archive_sha256"],
            "sha256:" + hashlib.sha256(archive_bytes).hexdigest(),
        )
        self.assertEqual(
            package["content_id"],
            "pakperk-restore-evidence-v2:sha256:"
            + hashlib.sha256(b"pakperk-restore-evidence-v2\0" + archive_bytes).hexdigest(),
        )
        self.assertEqual(
            set(files),
            {
                "SHA256SUMS",
                "database-after-reapply.json",
                "database-before.json",
                "drill-context.json",
                "ledger-reapply.json",
                "ledger-verification.json",
                "restore-attestation.json",
                "restore-guard.json",
            },
        )
        context = json.loads(files["drill-context.json"])
        self.assertEqual(context["schema"], 4)
        self.assertEqual(context["backup_id"], self.attestation_value["backup_id"])
        self.assertEqual(context["recovery_point"], self.attestation_value["recovery_point"])
        self.assertEqual(context["rpo_seconds"], 60)
        self.assertEqual(context["rto_seconds"], 120)
        self.assertEqual(context["database_ledger_records"], 1)
        self.assertEqual(
            context["expected_ledger_inventory_sha256"],
            LEDGER_INVENTORY_SHA256,
        )
        self.assertEqual(
            context["verified_ledger_inventory_sha256"],
            LEDGER_INVENTORY_SHA256,
        )
        self.assertEqual(
            context["reapplied_ledger_inventory_sha256"],
            LEDGER_INVENTORY_SHA256,
        )
        self.assertEqual(context["restore_attestation_sha256"], self.attestation_digest)
        self.assertEqual(
            json.loads(files["database-after-reapply.json"])[
                "matching_restored_users"
            ],
            1,
        )
        self.assertEqual(
            json.loads(files["database-after-reapply.json"])[
                "local_deletion_bindings_sha256"
            ],
            LOCAL_DELETION_BINDINGS_SHA256,
        )
        self.assertIn(
            "provider_attestation_is_bound_not_independently_verified",
            context["evidence_limitations"],
        )
        self.assertIn(
            "empty_inventory_digest_does_not_prove_physical_storage_identity",
            context["evidence_limitations"],
        )
        self.assertNotIn(
            "ledger_count_does_not_prove_exact_record_set",
            context["evidence_limitations"],
        )
        combined = b"\n".join(files.values())
        self.assertNotIn(b"restore-user:secret", combined)
        self.assertNotIn(str(self.worker).encode(), combined)
        verified = subprocess.run(
            ["python3", "-I", "-B", str(HELPER), "verify-package", str(evidence)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stdout.strip(), package["content_id"])

    def test_finalize_binds_prior_reapply_and_exact_database_count(self) -> None:
        prior_evidence, prior_content_id = self._create_prior_reapply()
        finalize = self._finalize_bindings(prior_evidence, prior_content_id)
        result, evidence, worker_log = self._run(finalize)
        self.assertEqual(result.returncode, 0, result.stderr)
        _, files = self._package_files(evidence)
        context = json.loads(files["drill-context.json"])
        self.assertEqual(context["prior_reapply_content_id"], prior_content_id)
        self.assertIsNone(context["reapplied_ledger_inventory_sha256"])
        self.assertIn("database-final.json", files)
        self.assertEqual(
            worker_log.read_text(encoding="utf-8").splitlines(),
            ["verify-ledger", "evidence-visible=False", "run-migrations=false"],
        )
        without_prior = subprocess.run(
            ["python3", "-I", "-B", str(HELPER), "verify-package", str(evidence)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(without_prior.returncode, 0)
        with_prior = subprocess.run(
            [
                "python3",
                "-I",
                "-B",
                str(HELPER),
                "verify-package",
                str(evidence),
                "--prior-reapply-evidence-dir",
                str(prior_evidence),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(with_prior.returncode, 0, with_prior.stderr)
        self._assert_failure(
            {
                **finalize,
                "FAKE_DB_LEDGER_AFTER": "0",
            }
        )
        self._assert_failure(
            {
                **finalize,
                "FAKE_DB_LEDGER_BEFORE": "0",
                "FAKE_DB_LEDGER_AFTER": "0",
            }
        )
        self._assert_failure(
            {
                **finalize,
                "FAKE_DB_BINDINGS_BEFORE": "sha256:" + "d" * 64,
                "FAKE_DB_BINDINGS_AFTER": "sha256:" + "d" * 64,
            }
        )
        self._assert_failure(
            {
                **finalize,
                "FAKE_DB_BINDINGS_AFTER": "sha256:" + "d" * 64,
            }
        )
        for failure in (
            "unfinished_final",
            "terminal_final",
            "changed_users_after",
            "unsafe_before",
            "pending_user_final",
        ):
            with self.subTest(failure=failure):
                self._assert_failure(
                    {
                        **finalize,
                        "FAKE_PSQL_FAILURE": failure,
                    }
                )

    def test_finalize_rejects_wrong_or_inconsistent_prior_reapply_package(self) -> None:
        prior_evidence, _ = self._create_prior_reapply()
        self._assert_failure(
            self._finalize_bindings(prior_evidence, PRIOR_CONTENT_ID),
            "prior reapply evidence content ID mismatch",
        )

        for mutation in (
            "attestation",
            "core_counts",
            "local_bindings",
            "chronology",
        ):
            with self.subTest(mutation=mutation):
                prior_evidence, _ = self._create_prior_reapply()
                _, files = self._package_files(prior_evidence)
                if mutation == "attestation":
                    attestation = json.loads(files["restore-attestation.json"])
                    attestation["marker"] = "restore-other-release-42"
                    attestation_bytes = self._canonical_bytes(attestation)
                    files["restore-attestation.json"] = attestation_bytes
                    attestation_digest = "sha256:" + hashlib.sha256(
                        attestation_bytes
                    ).hexdigest()
                    guard = json.loads(files["restore-guard.json"])
                    guard["marker"] = attestation["marker"]
                    guard["restore_attestation_sha256"] = attestation_digest
                    files["restore-guard.json"] = self._canonical_bytes(guard)
                    context = json.loads(files["drill-context.json"])
                    context["marker"] = attestation["marker"]
                    context["restore_attestation_sha256"] = attestation_digest
                    files["drill-context.json"] = self._canonical_bytes(context)
                elif mutation == "core_counts":
                    for name in (
                        "database-before.json",
                        "database-after-reapply.json",
                    ):
                        snapshot = json.loads(files[name])
                        snapshot["papers"] += 1
                        snapshot["core_jobs"] += 1
                        files[name] = self._canonical_bytes(snapshot)
                elif mutation == "local_bindings":
                    snapshot = json.loads(files["database-after-reapply.json"])
                    snapshot["local_deletion_bindings_sha256"] = (
                        "sha256:" + "d" * 64
                    )
                    files["database-after-reapply.json"] = self._canonical_bytes(
                        snapshot
                    )
                else:
                    context = json.loads(files["drill-context.json"])
                    context["recorded_at"] = (
                        dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
                        + dt.timedelta(minutes=4)
                    ).strftime("%Y-%m-%dT%H:%M:%SZ")
                    files["drill-context.json"] = self._canonical_bytes(context)
                self._rewrite_package(prior_evidence, files)
                package, _ = self._package_files(prior_evidence)
                prior_content_id = package["content_id"]
                assert isinstance(prior_content_id, str)
                self._assert_failure(
                    self._finalize_bindings(
                        prior_evidence, prior_content_id
                    )
                )

    def test_attestation_independently_binds_backup_recovery_rpo_rto_and_count(self) -> None:
        mismatches = (
            {"PAKPERK_RESTORE_DRILL_BACKUP_ID": "unrelated-backup-999999"},
            {"PAKPERK_RESTORE_DRILL_RECOVERY_POINT": "1900-01-01T00:00:00Z"},
            {"PAKPERK_RESTORE_DRILL_RPO_SECONDS": "0"},
            {"PAKPERK_RESTORE_DRILL_RTO_SECONDS": "1"},
            {"PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS": "2"},
            {
                "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256": "sha256:"
                + "d" * 64
            },
        )
        for overrides in mismatches:
            with self.subTest(overrides=overrides):
                self._assert_failure(overrides, "protected-input verification failed")

    def test_attestation_is_canonical_duplicate_safe_owner_only_and_digest_bound(self) -> None:
        original = self.attestation.read_bytes()
        duplicate = original.replace(
            b'"backup_id":"backup-20260802-release-42"',
            b'"backup_id":"duplicate-backup","backup_id":"backup-20260802-release-42"',
            1,
        )
        duplicate_path = self._write_attestation(self.attestation_value, raw=duplicate)
        cases: list[dict[str, str]] = [
            {
                "PAKPERK_RESTORE_DRILL_ATTESTATION": str(duplicate_path),
                "PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": self._digest(duplicate_path),
            },
            {"PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": "sha256:" + "0" * 64},
        ]
        noncanonical = self._write_attestation(self.attestation_value, canonical=False)
        cases.append(
            {
                "PAKPERK_RESTORE_DRILL_ATTESTATION": str(noncanonical),
                "PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": self._digest(noncanonical),
            }
        )
        exposed = self._write_attestation(self.attestation_value, mode=0o644)
        cases.append(
            {
                "PAKPERK_RESTORE_DRILL_ATTESTATION": str(exposed),
                "PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": self._digest(exposed),
            }
        )
        link = self.temporary / "attestation-link"
        link.symlink_to(self.attestation)
        cases.append({"PAKPERK_RESTORE_DRILL_ATTESTATION": str(link)})
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self._assert_failure(overrides, "protected-input verification failed")

    def test_attestation_schema_one_is_not_accepted_by_the_v2_gate(self) -> None:
        old_value = dict(self.attestation_value)
        old_value["schema"] = 1
        old_value.pop("expected_ledger_inventory_sha256")
        old_attestation = self._write_attestation(old_value)
        self._assert_failure(
            {
                "PAKPERK_RESTORE_DRILL_ATTESTATION": str(old_attestation),
                "PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256": self._digest(
                    old_attestation
                ),
            },
            "protected-input verification failed",
        )

    def test_guard_must_exactly_cross_check_attestation(self) -> None:
        for failure in (
            "guard",
            "guard_marker",
            "guard_backup",
            "guard_recovery",
            "guard_fractional",
            "guard_digest",
            "guard_inventory",
        ):
            with self.subTest(failure=failure):
                self._assert_failure(
                    {"FAKE_PSQL_FAILURE": failure},
                    "database verification failed",
                )

    def test_worker_duplicate_and_multiple_documents_are_rejected_without_leakage(self) -> None:
        for mode in (
            "duplicate",
            "multiple_documents",
            "malformed",
            "extra",
            "extra_reapply",
            "missing_inventory",
        ):
            with self.subTest(mode=mode):
                result = self._assert_failure({"FAKE_WORKER_MODE": mode})
                self.assertNotIn("provider_coordinate", result.stderr)
                self.assertNotIn("secret-first-document", result.stderr)

    def test_same_count_inventory_substitution_and_reapply_drift_fail_closed(self) -> None:
        for mode in ("inventory_mismatch", "reapply_inventory_mismatch"):
            with self.subTest(mode=mode):
                self._assert_failure(
                    {"FAKE_WORKER_MODE": mode},
                    "ledger verification failed",
                )

    def test_worker_inventory_digest_must_be_canonical_lowercase_sha256(self) -> None:
        for digest in (
            "sha256:short",
            "SHA256:" + "c" * 64,
            "sha256:" + "C" * 64,
            "sha512:" + "c" * 64,
        ):
            with self.subTest(digest=digest):
                self._assert_failure(
                    {"FAKE_WORKER_INVENTORY_SHA256": digest},
                    "ledger verification failed",
                )

    def test_worker_stdout_stderr_and_partial_failure_remain_private(self) -> None:
        successful, evidence, _ = self._run({"FAKE_WORKER_MODE": "secret_stderr"})
        self.assertEqual(successful.returncode, 0, successful.stderr)
        self.assertNotIn("secret-on-stderr", successful.stderr)
        _, files = self._package_files(evidence)
        self.assertNotIn(b"secret-on-stderr", b"\n".join(files.values()))

        failed = self._assert_failure({"FAKE_WORKER_MODE": "failure_secret"})
        self.assertNotIn("secret-partial-output", failed.stderr)
        self.assertNotIn("secret-on-stderr", failed.stderr)

    def test_reapply_actor_is_the_attested_marker_not_a_caller_override(self) -> None:
        result, _, worker_log = self._run(
            {
                "PAKPERK_ADMIN_ACTOR": "caller-controlled-actor",
                "RUN_MIGRATIONS": "true",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = worker_log.read_text(encoding="utf-8")
        self.assertIn(
            "admin-actor=" + str(self.attestation_value["marker"]),
            log,
        )
        self.assertNotIn("caller-controlled-actor", log)
        self.assertNotIn("run-migrations=true", log)
        self.assertEqual(log.count("run-migrations=false"), 2)

    def test_worker_cannot_preplant_evidence_and_original_replacement_is_not_executed(self) -> None:
        outside = self.temporary / "outside-secret-target"
        result, evidence, _ = self._run(
            {
                "FAKE_WORKER_MODE": "plant_symlink",
                "FAKE_SYMLINK_TARGET": str(outside),
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(outside.exists())
        self.assertTrue((evidence / "pakperk-restore-evidence.tar").is_file())

        outside.write_text("unchanged", encoding="utf-8")
        failed = self._assert_failure(
            {
                "FAKE_WORKER_MODE": "stage_symlink",
                "FAKE_SYMLINK_TARGET": str(outside),
            }
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(outside.read_text(encoding="utf-8"), "unchanged")

        result, evidence, worker_log = self._run({"FAKE_WORKER_MODE": "tamper_original"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(worker_log.read_text(encoding="utf-8").count("reapply-ledger"), 1)
        self.assertTrue((evidence / "PACKAGE_SHA256.json").is_file())

    def test_git_sparse_dirty_skip_worktree_assume_unchanged_and_abnormal_flags_fail(self) -> None:
        cases = (
            {"FAKE_GIT_SPARSE": "1"},
            {"FAKE_GIT_DIFF_DIRTY": "1"},
            {"FAKE_GIT_STATUS": "?? unreviewed"},
            {"FAKE_GIT_IGNORED": "1"},
            {"FAKE_GIT_INDEX_TAG": "S"},
            {"FAKE_GIT_INDEX_TAG": "h"},
            {"FAKE_GIT_INDEX_TAG": "M"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self._assert_failure(overrides, "source verification failed")

    def test_database_identity_isolation_schema_tables_and_reapply_state_fail_closed(self) -> None:
        for failure in (
            "database",
            "sessions",
            "migration",
            "extension_namespace",
            "tables",
            "unsafe_after",
            "missing_jobs_after",
            "changed_papers_after",
        ):
            with self.subTest(failure=failure):
                self._assert_failure(
                    {"FAKE_PSQL_FAILURE": failure},
                    "database verification failed",
                )
        self._assert_failure({"FAKE_DB_LEDGER_AFTER": "0"}, "database verification failed")
        self._assert_failure(
            {"FAKE_DB_BINDINGS_AFTER": "sha256:" + "D" * 64},
            "database verification failed",
        )

        hostile_url, _, _ = self._run(
            {
                "DATABASE_URL": (
                    "postgres://restore-user:secret@invalid/restore"
                    "?options=-c%20search_path%3Dattacker,public"
                )
            }
        )
        self.assertEqual(hostile_url.returncode, 0, hostile_url.stderr)

    def test_package_verifier_rejects_rehashed_cross_file_inventory_mismatch(self) -> None:
        result, evidence, _ = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        _, files = self._package_files(evidence)
        verification = json.loads(files["ledger-verification.json"])
        verification["ledger_inventory_sha256"] = "sha256:" + "d" * 64
        files["ledger-verification.json"] = (
            json.dumps(verification, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()
        self._rewrite_package(evidence, files)

        checked = subprocess.run(
            ["python3", "-I", "-B", str(HELPER), "verify-package", str(evidence)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(checked.returncode, 0)

    def test_package_verifier_rejects_rehashed_placeholder_and_future_claims(self) -> None:
        for mutation in ("placeholder_backup", "future_recorded_at"):
            with self.subTest(mutation=mutation):
                result, evidence, _ = self._run()
                self.assertEqual(result.returncode, 0, result.stderr)
                _, files = self._package_files(evidence)
                context = json.loads(files["drill-context.json"])
                if mutation == "placeholder_backup":
                    attestation = json.loads(files["restore-attestation.json"])
                    attestation["backup_id"] = "placeholder-backup-123"
                    attestation_bytes = (
                        json.dumps(
                            attestation, sort_keys=True, separators=(",", ":")
                        )
                        + "\n"
                    ).encode()
                    files["restore-attestation.json"] = attestation_bytes
                    attestation_digest = "sha256:" + hashlib.sha256(
                        attestation_bytes
                    ).hexdigest()
                    guard = json.loads(files["restore-guard.json"])
                    guard["backup_id"] = attestation["backup_id"]
                    guard["restore_attestation_sha256"] = attestation_digest
                    files["restore-guard.json"] = (
                        json.dumps(guard, sort_keys=True, separators=(",", ":"))
                        + "\n"
                    ).encode()
                    context["backup_id"] = attestation["backup_id"]
                    context["restore_attestation_sha256"] = attestation_digest
                else:
                    context["recorded_at"] = "2099-01-01T00:00:00Z"
                files["drill-context.json"] = (
                    json.dumps(context, sort_keys=True, separators=(",", ":"))
                    + "\n"
                ).encode()
                self._rewrite_package(evidence, files)

                checked = subprocess.run(
                    [
                        "python3",
                        "-I",
                        "-B",
                        str(HELPER),
                        "verify-package",
                        str(evidence),
                    ],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.assertNotEqual(checked.returncode, 0)

    def test_package_verifier_rejects_rehashed_stale_evidence_chronology(self) -> None:
        result, evidence, _ = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        _, files = self._package_files(evidence)
        attestation = json.loads(files["restore-attestation.json"])
        context = json.loads(files["drill-context.json"])
        shifted: dict[str, str] = {}
        for key in (
            "recovery_point",
            "latest_recoverable_point",
            "backup_observed_at",
            "restore_started_at",
            "restore_completed_at",
        ):
            value = dt.datetime.strptime(
                attestation[key], "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=dt.timezone.utc) - dt.timedelta(days=3)
            shifted[key] = value.strftime("%Y-%m-%dT%H:%M:%SZ")
            attestation[key] = shifted[key]
            context[key] = shifted[key]
        completed = dt.datetime.strptime(
            shifted["restore_completed_at"], "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=dt.timezone.utc)
        context["recorded_at"] = (
            completed + dt.timedelta(hours=25)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        attestation_bytes = self._canonical_bytes(attestation)
        files["restore-attestation.json"] = attestation_bytes
        attestation_digest = "sha256:" + hashlib.sha256(
            attestation_bytes
        ).hexdigest()
        guard = json.loads(files["restore-guard.json"])
        guard["recovery_point"] = shifted["recovery_point"]
        guard["restore_attestation_sha256"] = attestation_digest
        context["restore_attestation_sha256"] = attestation_digest
        files["restore-guard.json"] = self._canonical_bytes(guard)
        files["drill-context.json"] = self._canonical_bytes(context)
        self._rewrite_package(evidence, files)

        checked = subprocess.run(
            ["python3", "-I", "-B", str(HELPER), "verify-package", str(evidence)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(checked.returncode, 0)

    def test_evidence_target_must_be_fresh_and_package_mutation_is_detected(self) -> None:
        existing = self.temporary / "existing-evidence"
        existing.mkdir()
        result, _, _ = self._run(evidence=existing)
        self.assertNotEqual(result.returncode, 0)

        target = self.temporary / "evidence-target"
        target.mkdir()
        link = self.temporary / "evidence-link"
        link.symlink_to(target, target_is_directory=True)
        result, _, _ = self._run(evidence=link)
        self.assertNotEqual(result.returncode, 0)

        parent_target = self.temporary / "real-parent"
        parent_target.mkdir()
        parent_link = self.temporary / "linked-parent"
        parent_link.symlink_to(parent_target, target_is_directory=True)
        result, _, _ = self._run(evidence=parent_link / "evidence")
        self.assertNotEqual(result.returncode, 0)

        result, evidence, _ = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = evidence / "pakperk-restore-evidence.tar"
        evidence.chmod(0o700)
        archive.chmod(0o600)
        archive.write_bytes(archive.read_bytes() + b"tamper")
        verification = subprocess.run(
            ["python3", "-I", "-B", str(HELPER), "verify-package", str(evidence)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(verification.returncode, 0)

        self._executable("python3", FAKE_PYTHON_FAIL_PACKAGE_VERIFY)
        failed, partial, _ = self._run({"REAL_PYTHON3": sys.executable})
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("evidence re-verification failed", failed.stderr)
        self.assertFalse(partial.exists(), "failed final verification must roll back output")

    def test_confirmation_environment_phase_and_input_formats_are_bounded(self) -> None:
        cases = (
            ({"PAKPERK_RESTORE_DRILL_CONFIRM": "yes"}, "must equal"),
            (
                {"APP_ENV": "production", "ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID": "production"},
                "refuse APP_ENV",
            ),
            ({"ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID": "development"}, "must exactly match"),
            ({"PAKPERK_RESTORE_DRILL_PHASE": "restore"}, "must be reapply or finalize"),
            ({"PAKPERK_RESTORE_DRILL_DATABASE": "unsafe database"}, "invalid format"),
            ({"PAKPERK_RESTORE_DRILL_MARKER": "short"}, "invalid format"),
            ({"PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS": "-1"}, "JSON-safe integer"),
            ({"PAKPERK_RESTORE_DRILL_SOURCE_REVISION": "main"}, "full lowercase Git SHA"),
            (
                {
                    "PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256": (
                        "sha256:" + "C" * 64
                    )
                },
                "artifact digests must use",
            ),
            (
                {"PAKPERK_RESTORE_DRILL_PHASE": "finalize"},
                "requires the externally anchored reapply",
            ),
            (
                {
                    "PAKPERK_RESTORE_DRILL_PHASE": "finalize",
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID": (
                        "pakperk-restore-evidence-v1:sha256:" + "b" * 64
                    ),
                },
                "requires the externally anchored reapply",
            ),
            (
                {
                    "PAKPERK_RESTORE_DRILL_PHASE": "finalize",
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID": PRIOR_CONTENT_ID,
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR": str(
                        self.temporary / "missing-prior-reapply"
                    ),
                },
                "prior reapply evidence verification failed",
            ),
            (
                {
                    "PAKPERK_RESTORE_DRILL_PHASE": "finalize",
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID": PRIOR_CONTENT_ID,
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR": "relative",
                },
                "absolute evidence directory",
            ),
            (
                {
                    "PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR": str(
                        self.temporary
                    )
                },
                "valid only during finalize",
            ),
        )
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                self._assert_failure(overrides, expected)


if __name__ == "__main__":
    unittest.main()
