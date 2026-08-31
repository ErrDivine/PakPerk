#!/usr/bin/env bash
set -euo pipefail
umask 077

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_dir/scripts/restore_drill_evidence.py"

run_self_test() {
  PYTHONDONTWRITEBYTECODE=1 python3 -I -B \
    "$project_dir/scripts/test_drill_backup_restore.py"
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

required_commands=(git psql python3)
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
: "${PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS:?Set the exact record count from the protected pre-restore ledger inventory.}"
: "${PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256:?Set the exact domain-separated digest from the protected pre-restore ledger inventory.}"
: "${PAKPERK_RESTORE_DRILL_CONFIRM:?Explicit non-production confirmation is required.}"
: "${PAKPERK_RESTORE_DRILL_SOURCE_REVISION:?Set the reviewed full source revision.}"
: "${PAKPERK_RESTORE_DRILL_WORKER_SHA256:?Set the reviewed deletion-worker sha256 digest.}"
: "${PAKPERK_RESTORE_DRILL_BACKUP_ID:?Set the protected source backup identifier.}"
: "${PAKPERK_RESTORE_DRILL_RECOVERY_POINT:?Set the restored recovery point as RFC 3339 UTC.}"
: "${PAKPERK_RESTORE_DRILL_RPO_SECONDS:?Set the attested recovery-point result in seconds.}"
: "${PAKPERK_RESTORE_DRILL_RTO_SECONDS:?Set the attested recovery-time result in seconds.}"
: "${PAKPERK_RESTORE_DRILL_ATTESTATION:?Set the absolute protected restore-attestation path.}"
: "${PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256:?Set the separately recorded restore-attestation digest.}"

phase="${PAKPERK_RESTORE_DRILL_PHASE:-reapply}"
environment="${APP_ENV:-}"
ledger_environment="${ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID:-}"
expected_migration="${PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION:-18}"
expected_ledger_records="$PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS"
expected_ledger_inventory_sha256="$PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256"
database_name="$PAKPERK_RESTORE_DRILL_DATABASE"
marker="$PAKPERK_RESTORE_DRILL_MARKER"
evidence_dir="$PAKPERK_RESTORE_DRILL_EVIDENCE_DIR"
source_revision="$PAKPERK_RESTORE_DRILL_SOURCE_REVISION"
expected_worker_sha256="$PAKPERK_RESTORE_DRILL_WORKER_SHA256"
attestation_path="$PAKPERK_RESTORE_DRILL_ATTESTATION"
attestation_sha256="$PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256"

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
if ! [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "PAKPERK_RESTORE_DRILL_SOURCE_REVISION must be a full lowercase Git SHA." >&2
  exit 2
fi
if ! [[ "$expected_worker_sha256" =~ ^sha256:[0-9a-f]{64}$ ]] || \
   ! [[ "$attestation_sha256" =~ ^sha256:[0-9a-f]{64}$ ]] || \
   ! [[ "$expected_ledger_inventory_sha256" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Restore drill artifact digests must use sha256:<lowercase-hex>." >&2
  exit 2
fi
if [[ "$attestation_path" != /* || "$evidence_dir" != /* || -e "$evidence_dir" || -L "$evidence_dir" ]]; then
  echo "Attestation and fresh evidence paths must be absolute; evidence must not exist." >&2
  exit 2
fi
if [[ "$phase" == finalize ]]; then
  prior_reapply_content_id="${PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID:-}"
  prior_reapply_evidence_dir="${PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR:-}"
  if ! [[ "$prior_reapply_content_id" =~ ^pakperk-restore-evidence-v2:sha256:[0-9a-f]{64}$ ]] || \
     [[ "$prior_reapply_evidence_dir" != /* ]]; then
    echo "Finalize requires the externally anchored reapply content ID and absolute evidence directory." >&2
    exit 2
  fi
  verified_prior_reapply_content_id="$(
    python3 -I -B "$helper" verify-package "$prior_reapply_evidence_dir"
  )" || {
    echo "Finalize prior reapply evidence verification failed." >&2
    exit 1
  }
  if [[ "$verified_prior_reapply_content_id" != "$prior_reapply_content_id" ]]; then
    echo "Finalize prior reapply evidence content ID mismatch." >&2
    exit 1
  fi
elif [[ -n "${PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID:-}" || \
        -n "${PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR:-}" ]]; then
  echo "Prior reapply evidence is valid only during finalize." >&2
  exit 2
fi

staging_dir=""
package_published=0
drill_succeeded=0
cleanup_stage() {
  if [[ -n "$staging_dir" ]]; then
    python3 -I -B "$helper" cleanup "$staging_dir" >/dev/null 2>&1 || true
  fi
  if [[ "$package_published" == 1 && "$drill_succeeded" != 1 ]]; then
    python3 -I -B "$helper" remove-package "$evidence_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup_stage EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if ! python3 -I -B "$helper" check-source "$project_dir"; then
  echo "Restore drill source verification failed." >&2
  exit 1
fi
if ! staging_dir="$(python3 -I -B "$helper" prepare)" || [[ -z "$staging_dir" ]]; then
  echo "Restore drill protected-input verification failed." >&2
  exit 1
fi

export PGAPPNAME="pakperk-restore-drill-$phase"
export PGOPTIONS="-c search_path=public,pg_catalog"
psql_value() {
  local output
  local search_path_verified
  output="$(
    psql --dbname="$DATABASE_URL" --no-psqlrc --set ON_ERROR_STOP=1 \
      --quiet --tuples-only --no-align --command "
        SET search_path TO public, pg_catalog;
        SELECT
          pg_catalog.current_setting('search_path') = 'public, pg_catalog'
          AND pg_catalog.current_schema()::pg_catalog.text = 'public';
        $1
      " 2>/dev/null
  )" || return 1
  search_path_verified="${output%%$'\n'*}"
  if [[ "$search_path_verified" != t || "$output" == "$search_path_verified" ]]; then
    return 1
  fi
  printf '%s\n' "${output#*$'\n'}"
}
database_failure() {
  echo "Restore drill database verification failed." >&2
  exit 1
}

actual_database="$(psql_value 'SELECT pg_catalog.current_database()')" || database_failure
if [[ "$actual_database" != "$database_name" ]]; then
  database_failure
fi

if ! psql_value "
  SELECT pg_catalog.json_build_object(
    'database', pg_catalog.current_database(),
    'marker', guard.marker,
    'backup_id', guard.backup_id,
    'recovery_point', pg_catalog.to_char(
      guard.recovery_point AT TIME ZONE 'UTC',
      'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'
    ),
    'restore_attestation_sha256', guard.restore_attestation_sha256,
    'expected_ledger_inventory_sha256', guard.expected_ledger_inventory_sha256
  )::text
  FROM public.pakperk_restore_drill_guard AS guard
  WHERE guard.marker = '$marker'
    AND guard.recovery_point = pg_catalog.date_trunc('second', guard.recovery_point)
    AND guard.expires_at > pg_catalog.statement_timestamp()
    AND guard.expires_at <= pg_catalog.statement_timestamp() + interval '24 hours'
" | python3 -I -B "$helper" capture-raw "$staging_dir" "restore-guard.raw"; then
  database_failure
fi
if ! python3 -I -B "$helper" validate-guard "$staging_dir" "restore-guard.raw"; then
  database_failure
fi

check_sessions() {
  local other_sessions
  other_sessions="$(psql_value "
    SELECT pg_catalog.count(*)
    FROM pg_catalog.pg_stat_activity
    WHERE datname = pg_catalog.current_database()
      AND pid <> pg_catalog.pg_backend_pid()
  ")" || return 1
  [[ "$other_sessions" == 0 ]]
}
if ! check_sessions; then
  database_failure
fi

migration="$(psql_value '
  SELECT COALESCE(pg_catalog.max(version), 0)
  FROM public._sqlx_migrations
  WHERE success
')" || database_failure
if [[ "$migration" != "$expected_migration" ]]; then
  database_failure
fi

invalid_required_extensions="$(psql_value "
  SELECT pg_catalog.count(*)
  FROM (VALUES
    ('vector'),
    ('pg_trgm'),
    ('pgcrypto')
  ) AS required(extension_name)
  WHERE (
    SELECT pg_catalog.count(*)
    FROM pg_catalog.pg_extension AS extension
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.oid = extension.extnamespace
    WHERE extension.extname = required.extension_name
      AND namespace.nspname = 'public'
  ) <> 1
")" || database_failure
if [[ "$invalid_required_extensions" != 0 ]]; then
  database_failure
fi

missing_required_tables="$(psql_value "
  SELECT pg_catalog.count(*)
  FROM (VALUES
    ('public.users'),
    ('public.papers'),
    ('public.jobs'),
    ('public.user_paper_library'),
    ('public.library_operations'),
    ('public.paper_comments'),
    ('public.comment_reports'),
    ('public.user_reports'),
    ('public.user_blocks'),
    ('public.account_deletion_ledger'),
    ('public.account_deletion_jobs')
  ) AS required(table_name)
  WHERE pg_catalog.to_regclass(required.table_name) IS NULL
")" || database_failure
if [[ "$missing_required_tables" != 0 ]]; then
  database_failure
fi

database_snapshot() {
  psql_value "
    WITH local_deletion_bindings AS (
      SELECT
        ledger.operation_id,
        ledger.original_user_id,
        ledger.identity_fingerprint_key_id AS ledger_fingerprint_key_id,
        ledger.identity_fingerprint AS ledger_fingerprint,
        jobs.operation_id AS job_operation_id,
        jobs.user_id AS job_user_id,
        jobs.identity_fingerprint_key_id AS job_fingerprint_key_id,
        jobs.identity_fingerprint AS job_fingerprint,
        jobs.oidc_issuer,
        jobs.oidc_subject
      FROM public.account_deletion_ledger AS ledger
      LEFT JOIN public.account_deletion_jobs AS jobs USING (operation_id)
    ),
    deletion_user_matches AS (
      SELECT users.id, users.status
      FROM public.users AS users
      WHERE EXISTS (
        SELECT 1
        FROM public.account_deletion_ledger AS ledger
        LEFT JOIN public.account_deletion_jobs AS jobs USING (operation_id)
        WHERE users.id = ledger.original_user_id
           OR users.id = jobs.user_id
           OR (
                users.identity_fingerprint_key_id = ledger.identity_fingerprint_key_id
                AND users.identity_fingerprint = ledger.identity_fingerprint
           )
           OR (
                jobs.oidc_issuer IS NOT NULL
                AND users.oidc_issuer = jobs.oidc_issuer
                AND users.oidc_subject = jobs.oidc_subject
           )
      )
    )
    SELECT pg_catalog.json_build_object(
      'migration', (SELECT COALESCE(pg_catalog.max(version), 0) FROM public._sqlx_migrations WHERE success),
      'users', (SELECT pg_catalog.count(*) FROM public.users),
      'papers', (SELECT pg_catalog.count(*) FROM public.papers),
      'core_jobs', (SELECT pg_catalog.count(*) FROM public.jobs),
      'library_items', (SELECT pg_catalog.count(*) FROM public.user_paper_library),
      'library_operations', (SELECT pg_catalog.count(*) FROM public.library_operations),
      'paper_comments', (SELECT pg_catalog.count(*) FROM public.paper_comments),
      'comment_reports', (SELECT pg_catalog.count(*) FROM public.comment_reports),
      'user_reports', (SELECT pg_catalog.count(*) FROM public.user_reports),
      'user_blocks', (SELECT pg_catalog.count(*) FROM public.user_blocks),
      'ledger_records', (SELECT pg_catalog.count(*) FROM public.account_deletion_ledger),
      'deletion_jobs', (SELECT pg_catalog.count(*) FROM public.account_deletion_jobs),
      'local_deletion_bindings_sha256', (
        SELECT 'sha256:' || pg_catalog.encode(
          public.digest(
            pg_catalog.convert_to(
              pg_catalog.jsonb_build_array(
                'pakperk-local-account-deletion-bindings-v1',
                COALESCE(
                  pg_catalog.jsonb_agg(
                    pg_catalog.jsonb_build_array(
                      operation_id::pg_catalog.text,
                      original_user_id::pg_catalog.text,
                      ledger_fingerprint_key_id,
                      pg_catalog.encode(ledger_fingerprint, 'hex'),
                      job_operation_id::pg_catalog.text,
                      job_user_id::pg_catalog.text,
                      job_fingerprint_key_id,
                      pg_catalog.encode(job_fingerprint, 'hex'),
                      CASE
                        WHEN oidc_issuer IS NULL THEN NULL
                        ELSE 'sha256:' || pg_catalog.encode(
                          public.digest(
                            pg_catalog.convert_to(
                              pg_catalog.jsonb_build_array(
                                'pakperk-local-account-deletion-provider-binding-v1',
                                oidc_issuer,
                                oidc_subject
                              )::pg_catalog.text,
                              'UTF8'
                            ),
                            'sha256'
                          ),
                          'hex'
                        )
                      END
                    )
                    ORDER BY operation_id
                  ),
                  '[]'::pg_catalog.jsonb
                )
              )::pg_catalog.text,
              'UTF8'
            ),
            'sha256'
          ),
          'hex'
        )
        FROM local_deletion_bindings
      ),
      'unfinished_jobs', (
        SELECT pg_catalog.count(*) FROM public.account_deletion_jobs WHERE state <> 'completed'
      ),
      'terminal_jobs', (
        SELECT pg_catalog.count(*) FROM public.account_deletion_jobs WHERE state = 'failed_terminal'
      ),
      'matching_restored_users', (
        SELECT pg_catalog.count(*) FROM deletion_user_matches
      ),
      'unsafe_restored_users', (
        SELECT pg_catalog.count(*) FROM deletion_user_matches
        WHERE status <> 'deletion_pending'
      ),
      'missing_jobs', (
        SELECT pg_catalog.count(*)
        FROM public.account_deletion_ledger AS ledger
        LEFT JOIN public.account_deletion_jobs AS jobs USING (operation_id)
        WHERE jobs.operation_id IS NULL
      )
    )::text
  "
}

if ! database_snapshot | python3 -I -B "$helper" capture-raw \
  "$staging_dir" "database-before.raw"; then
  database_failure
fi
if ! python3 -I -B "$helper" validate-snapshot \
  "$staging_dir" "database-before.raw" "database-before.json" before; then
  database_failure
fi

if ! python3 -I -B "$helper" run-worker "$staging_dir" "$phase"; then
  echo "Restore drill ledger verification failed." >&2
  exit 1
fi
if ! check_sessions; then
  database_failure
fi

if [[ "$phase" == reapply ]]; then
  final_raw_name="database-after-reapply.raw"
  final_json_name="database-after-reapply.json"
  final_position="after"
else
  final_raw_name="database-final.raw"
  final_json_name="database-final.json"
  final_position="final"
fi
if ! database_snapshot | python3 -I -B "$helper" capture-raw \
  "$staging_dir" "$final_raw_name"; then
  database_failure
fi
if ! python3 -I -B "$helper" validate-snapshot \
  "$staging_dir" "$final_raw_name" "$final_json_name" "$final_position"; then
  database_failure
fi

if ! python3 -I -B "$helper" check-source "$project_dir"; then
  echo "Restore drill source verification failed." >&2
  exit 1
fi
if ! python3 -I -B "$helper" build-context "$staging_dir" "$phase"; then
  echo "Restore drill evidence context verification failed." >&2
  exit 1
fi

content_id="$(python3 -I -B "$helper" publish "$staging_dir" "$evidence_dir" "$phase")" || {
  echo "Restore drill evidence publication failed." >&2
  exit 1
}
package_published=1
verify_package_arguments=("$evidence_dir")
if [[ "$phase" == finalize ]]; then
  verify_package_arguments+=(
    --prior-reapply-evidence-dir "$prior_reapply_evidence_dir"
  )
fi
verified_content_id="$(
  python3 -I -B "$helper" verify-package "${verify_package_arguments[@]}"
)" || {
  echo "Restore drill evidence re-verification failed." >&2
  exit 1
}
if [[ "$verified_content_id" != "$content_id" ]]; then
  echo "Restore drill evidence re-verification failed." >&2
  exit 1
fi
if ! python3 -I -B "$helper" check-source "$project_dir"; then
  echo "Restore drill source verification failed." >&2
  exit 1
fi
drill_succeeded=1

printf '%s\n' "Restore drill $phase phase passed."
printf '%s\n' "Evidence content ID: $content_id"
printf '%s\n' "Anchor this content ID in the protected external release record."
