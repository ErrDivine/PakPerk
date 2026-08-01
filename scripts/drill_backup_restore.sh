#!/usr/bin/env bash
set -euo pipefail

ledger_record_count_matches() {
  local expected="$1"
  jq -e --argjson expected "$expected" '.verified_records == $expected'
}

run_self_test() {
  command -v jq >/dev/null 2>&1 || {
    echo "Restore drill self-test requires jq." >&2
    return 2
  }
  printf '%s\n' '{"verified_records":0}' | ledger_record_count_matches 0 >/dev/null
  printf '%s\n' '{"verified_records":7}' | ledger_record_count_matches 7 >/dev/null
  if printf '%s\n' '{"verified_records":0}' | \
    ledger_record_count_matches 1 >/dev/null 2>&1; then
    echo "Empty ledger unexpectedly matched a nonzero inventory." >&2
    return 1
  fi
  if printf '%s\n' '{"verified_records":7}' | \
    ledger_record_count_matches 0 >/dev/null 2>&1; then
    echo "Nonempty ledger unexpectedly matched a zero inventory." >&2
    return 1
  fi
  echo "Restore drill ledger-count regressions passed."
}

if [[ "${1:-}" == "--self-test" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "--self-test takes no additional arguments." >&2
    exit 2
  fi
  run_self_test
  exit
fi
if [[ $# -ne 0 ]]; then
  echo "drill_backup_restore.sh takes no arguments; use --self-test for regressions." >&2
  exit 2
fi

required_commands=(jq psql python3 shasum)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Restore drill requires $command_name." >&2
    exit 2
  }
done

: "${DATABASE_URL:?Set DATABASE_URL to the isolated restored PostgreSQL database.}"
: "${PAKPERK_DELETION_WORKER_BIN:?Set PAKPERK_DELETION_WORKER_BIN to the reviewed absolute binary path.}"
: "${PAKPERK_RESTORE_DRILL_DATABASE:?Set the exact restored database name.}"
: "${PAKPERK_RESTORE_DRILL_MARKER:?Set the expiring guard marker installed in the restored database.}"
: "${PAKPERK_RESTORE_DRILL_EVIDENCE_DIR:?Set a new absolute evidence directory.}"
: "${PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS:?Set the exact record count from the immutable pre-restore ledger inventory.}"
: "${PAKPERK_RESTORE_DRILL_CONFIRM:?Explicit non-production confirmation is required.}"

phase="${PAKPERK_RESTORE_DRILL_PHASE:-reapply}"
environment="${APP_ENV:-}"
ledger_environment="${ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID:-}"
expected_migration="${PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION:-9}"
expected_ledger_records="$PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS"
worker_bin="$PAKPERK_DELETION_WORKER_BIN"
database_name="$PAKPERK_RESTORE_DRILL_DATABASE"
marker="$PAKPERK_RESTORE_DRILL_MARKER"
evidence_dir="$PAKPERK_RESTORE_DRILL_EVIDENCE_DIR"

if [[ "$PAKPERK_RESTORE_DRILL_CONFIRM" != "isolated-nonproduction-restore" ]]; then
  echo "PAKPERK_RESTORE_DRILL_CONFIRM must equal isolated-nonproduction-restore." >&2
  exit 2
fi
if [[ "$environment" != development && "$environment" != staging ]]; then
  echo "Restore drills refuse APP_ENV values other than development or staging." >&2
  exit 2
fi
if [[ "$ledger_environment" != "$environment" ]]; then
  echo "The external ledger environment must exactly match APP_ENV." >&2
  exit 2
fi
if [[ "$phase" != reapply && "$phase" != finalize ]]; then
  echo "PAKPERK_RESTORE_DRILL_PHASE must be reapply or finalize." >&2
  exit 2
fi
if [[ "$worker_bin" != /* || ! -x "$worker_bin" ]]; then
  echo "PAKPERK_DELETION_WORKER_BIN must be an executable absolute path." >&2
  exit 2
fi
if ! [[ "$database_name" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || \
   ! [[ "$marker" =~ ^[A-Za-z0-9._:-]{8,128}$ ]] || \
   ! [[ "$expected_migration" =~ ^[1-9][0-9]*$ ]]; then
  echo "Restore drill database, marker, or migration input has an invalid format." >&2
  exit 2
fi
if ! [[ "$expected_ledger_records" =~ ^(0|[1-9][0-9]{0,15})$ ]] || \
   (( expected_ledger_records > 9007199254740991 )); then
  echo "Expected ledger records must be a non-negative JSON-safe integer." >&2
  exit 2
fi
if [[ "$evidence_dir" != /* || -e "$evidence_dir" || -L "$evidence_dir" ]]; then
  echo "Evidence path must be a new, absolute, non-symlink path." >&2
  exit 2
fi
install -d -m 0700 "$evidence_dir"

export PGAPPNAME="pakperk-restore-drill-$phase"
psql_value() {
  psql "$DATABASE_URL" --no-psqlrc --set ON_ERROR_STOP=1 \
    --tuples-only --no-align --command "$1"
}

actual_database="$(psql_value 'SELECT current_database()')"
if [[ "$actual_database" != "$database_name" ]]; then
  echo "Connected database does not match PAKPERK_RESTORE_DRILL_DATABASE." >&2
  exit 1
fi

# Operators install this one-row guard only after restoring into an isolated
# target. Its short expiry prevents a stale database from becoming a future
# drill target by accident.
guard_count="$(psql_value "
  SELECT count(*)
  FROM public.pakperk_restore_drill_guard
  WHERE marker = '$marker'
    AND expires_at > statement_timestamp()
    AND expires_at <= statement_timestamp() + interval '24 hours'
")"
if [[ "$guard_count" != 1 ]]; then
  echo "The isolated restore guard is absent, duplicate, stale, or too long-lived." >&2
  exit 1
fi

other_sessions="$(psql_value "
  SELECT count(*)
  FROM pg_stat_activity
  WHERE datname = current_database()
    AND pid <> pg_backend_pid()
    AND application_name NOT LIKE 'pakperk-restore-drill-%'
")"
if [[ "$other_sessions" != 0 ]]; then
  echo "The restored database has non-drill sessions; isolate it before continuing." >&2
  exit 1
fi

migration="$(psql_value 'SELECT COALESCE(max(version), 0) FROM _sqlx_migrations WHERE success')"
if [[ "$migration" != "$expected_migration" ]]; then
  echo "Restored schema migration does not match the reviewed release." >&2
  exit 1
fi

database_snapshot() {
  psql_value "
    SELECT json_build_object(
      'migration', (SELECT COALESCE(max(version), 0) FROM _sqlx_migrations WHERE success),
      'ledger_records', (SELECT count(*) FROM account_deletion_ledger),
      'jobs', (SELECT count(*) FROM account_deletion_jobs),
      'unfinished_jobs', (
        SELECT count(*) FROM account_deletion_jobs WHERE state <> 'completed'
      ),
      'terminal_jobs', (
        SELECT count(*) FROM account_deletion_jobs WHERE state = 'failed_terminal'
      ),
      'unsafe_restored_users', (
        SELECT count(*)
        FROM users AS u
        JOIN account_deletion_ledger AS l
          ON l.identity_fingerprint_key_id = u.identity_fingerprint_key_id
         AND l.identity_fingerprint = u.identity_fingerprint
        WHERE u.status <> 'deletion_pending'
      ),
      'missing_jobs', (
        SELECT count(*)
        FROM account_deletion_ledger AS l
        LEFT JOIN account_deletion_jobs AS j USING (operation_id)
        WHERE j.operation_id IS NULL
      )
    )::text
  "
}

database_snapshot >"$evidence_dir/database-before.json"
"$worker_bin" verify-ledger >"$evidence_dir/ledger-verification.json"
if ! ledger_record_count_matches "$expected_ledger_records" \
  <"$evidence_dir/ledger-verification.json" >/dev/null; then
  echo "Verified ledger record count does not match the immutable inventory." >&2
  exit 1
fi

if [[ "$phase" == reapply ]]; then
  PAKPERK_ADMIN_ACTOR="restore-drill:$marker" \
    "$worker_bin" reapply-ledger >"$evidence_dir/ledger-reapply.json"
  if ! ledger_record_count_matches "$expected_ledger_records" \
    <"$evidence_dir/ledger-reapply.json" >/dev/null; then
    echo "Reapplied ledger record count does not match the immutable inventory." >&2
    exit 1
  fi
  jq -e '(.unchanged + .restored_and_queued + .requeued_resurrected_data +
     .requeued_provider_reconciliation == .verified_records)' \
    "$evidence_dir/ledger-reapply.json" >/dev/null
  database_snapshot >"$evidence_dir/database-after-reapply.json"
  jq -e --slurpfile verification "$evidence_dir/ledger-verification.json" '
    .unsafe_restored_users == 0 and
    .missing_jobs == 0 and
    .ledger_records >= $verification[0].verified_records
  ' "$evidence_dir/database-after-reapply.json" >/dev/null
else
  database_snapshot >"$evidence_dir/database-final.json"
  jq -e '
    .unsafe_restored_users == 0 and
    .missing_jobs == 0 and
    .unfinished_jobs == 0 and
    .terminal_jobs == 0
  ' "$evidence_dir/database-final.json" >/dev/null
fi

python3 - "$evidence_dir/drill-context.json" <<'PY'
import datetime
import json
import os
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "database": os.environ["PAKPERK_RESTORE_DRILL_DATABASE"],
            "environment": os.environ["APP_ENV"],
            "ledger_environment": os.environ["ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID"],
            "expected_ledger_records": int(
                os.environ["PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS"]
            ),
            "marker": os.environ["PAKPERK_RESTORE_DRILL_MARKER"],
            "phase": os.environ.get("PAKPERK_RESTORE_DRILL_PHASE", "reapply"),
            "recorded_at": datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat(),
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY

(
  cd "$evidence_dir"
  shasum -a 256 ./*.json >SHA256SUMS
)
chmod 0400 "$evidence_dir"/*.json "$evidence_dir/SHA256SUMS"
echo "Restore drill $phase phase passed; immutable evidence is in $evidence_dir."
