#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--self-test" ]]; then
  if [[ "$#" != 1 ]]; then
    echo "Usage: test_live_account_deletion.sh --self-test" >&2
    exit 2
  fi
  exec python3 "$project_dir/scripts/test_live_account_deletion.py" self-test
fi
if [[ "$#" != 0 ]]; then
  echo "Usage: LIVE_ACCOUNT_DELETION_CONFIRM=RUN_DISPOSABLE_KEYCLOAK_DELETION test_live_account_deletion.sh" >&2
  exit 2
fi
if [[ "${LIVE_ACCOUNT_DELETION_CONFIRM:-}" != "RUN_DISPOSABLE_KEYCLOAK_DELETION" ]]; then
  echo "Refusing the destructive disposable suite without LIVE_ACCOUNT_DELETION_CONFIRM=RUN_DISPOSABLE_KEYCLOAK_DELETION." >&2
  exit 2
fi

manage_compose="${LIVE_ACCOUNT_DELETION_MANAGE_COMPOSE:-1}"
skip_build="${LIVE_ACCOUNT_DELETION_SKIP_BUILD:-0}"
api_port="${LIVE_ACCOUNT_DELETION_API_PORT:-18084}"
keycloak_base="${LIVE_ACCOUNT_DELETION_KEYCLOAK_BASE_URL:-http://localhost:8081}"
realm=pakperk
database_url="${LIVE_ACCOUNT_DELETION_DATABASE_URL:-postgres://pakperk:pakperk@127.0.0.1:5432/pakperk}"
recent_auth_seconds="${LIVE_ACCOUNT_DELETION_RECENT_AUTH_SECONDS:-30}"
api_binary="$project_dir/backend/target/debug/pakperk-api"
worker_binary="$project_dir/backend/target/debug/pakperk-deletion-worker"
readiness_marker="/tmp/pakperk-deletion-worker-ready"

for command in cargo curl docker openssl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "test_live_account_deletion.sh requires $command." >&2
    exit 2
  fi
done
if ! python3 -c 'import requests, bs4' >/dev/null 2>&1; then
  echo "test_live_account_deletion.sh requires the Python requests and beautifulsoup4 packages." >&2
  exit 2
fi
docker_endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
if [[ "$docker_endpoint" != unix:///* ]]; then
  echo "test_live_account_deletion.sh requires a local Docker engine context." >&2
  exit 2
fi
for value in "$api_port" "$recent_auth_seconds"; do
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Live account-deletion numeric settings must be positive integers." >&2
    exit 2
  fi
done
if ((api_port > 65535)); then
  echo "LIVE_ACCOUNT_DELETION_API_PORT must be at most 65535." >&2
  exit 2
fi
if ((recent_auth_seconds < 30 || recent_auth_seconds > 300)); then
  echo "LIVE_ACCOUNT_DELETION_RECENT_AUTH_SECONDS must be between 30 and 300." >&2
  exit 2
fi
if [[ "$manage_compose" != 0 && "$manage_compose" != 1 ]]; then
  echo "LIVE_ACCOUNT_DELETION_MANAGE_COMPOSE must be 0 or 1." >&2
  exit 2
fi
if [[ "$skip_build" != 0 && "$skip_build" != 1 ]]; then
  echo "LIVE_ACCOUNT_DELETION_SKIP_BUILD must be 0 or 1." >&2
  exit 2
fi
if [[ -e "$readiness_marker" || -L "$readiness_marker" ]]; then
  echo "A deletion-worker readiness marker already exists; use an exclusive local host for this suite." >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-live-account-deletion.XXXXXX")"
umask 077
state_file="$work_dir/state.json"
origin_secret="$work_dir/api-origin-secret"
cursor_keys="$work_dir/api-cursor-encryption-keys"
identity_keys="$work_dir/account-identity-fingerprint-keys"
signing_keys="$work_dir/account-deletion-signing-keys"
provider_keys="$work_dir/account-deletion-provider-keys"
worker_secret="$work_dir/keycloak-worker-client-secret"
ledger_directory="$work_dir/external-ledger"
api_log="$work_dir/api.log"
worker_log="$work_dir/worker.log"
mkdir -m 0700 "$ledger_directory"
openssl rand -hex 48 >"$origin_secret"
printf 'live-account-deletion-cursor:%s\n' "$(openssl rand -base64 32 | tr -d '\n')" >"$cursor_keys"
printf 'live-account-deletion-current:%s\n' "$(openssl rand -base64 48 | tr -d '\n')" >"$identity_keys"
printf 'live-account-deletion-signing:%s\n' "$(openssl rand -base64 48 | tr -d '\n')" >"$signing_keys"
printf 'live-account-deletion-provider:%s\n' "$(openssl rand -base64 48 | tr -d '\n')" >"$provider_keys"
chmod 0600 "$origin_secret" "$cursor_keys" "$identity_keys" "$signing_keys" "$provider_keys"

run_id="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
token_sentinel="PAKPERK_DELETION_TOKEN_SENTINEL_${run_id}"
api_base="http://127.0.0.1:$api_port"
issuer="$keycloak_base/realms/$realm"
admin_username="${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME:-admin}"
admin_password="${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD:-pakperk-admin-dev}"

export LIVE_ACCOUNT_DELETION_PROJECT_DIR="$project_dir"
export LIVE_ACCOUNT_DELETION_STATE_FILE="$state_file"
export LIVE_ACCOUNT_DELETION_API_BASE="$api_base"
export LIVE_ACCOUNT_DELETION_KEYCLOAK_BASE_URL="$keycloak_base"
export LIVE_ACCOUNT_DELETION_KEYCLOAK_REALM=pakperk
export LIVE_ACCOUNT_DELETION_OIDC_CLIENT_ID=pakperk-mobile-dev
export LIVE_ACCOUNT_DELETION_OIDC_REDIRECT_URI=pakperk-auth-dev://oauth/callback
export LIVE_ACCOUNT_DELETION_DATABASE_URL="$database_url"
export LIVE_ACCOUNT_DELETION_POSTGRES_USER="${LIVE_ACCOUNT_DELETION_POSTGRES_USER:-pakperk}"
export LIVE_ACCOUNT_DELETION_POSTGRES_DB="${LIVE_ACCOUNT_DELETION_POSTGRES_DB:-pakperk}"
export LIVE_ACCOUNT_DELETION_RUN_ID="$run_id"
export LIVE_ACCOUNT_DELETION_TOKEN_SENTINEL="$token_sentinel"
export LIVE_ACCOUNT_DELETION_WORKER_CLIENT_ID=pakperk-deletion-worker-dev
export LIVE_ACCOUNT_DELETION_WORKER_SECRET_FILE="$worker_secret"
export LIVE_ACCOUNT_DELETION_WORKER_BINARY="$worker_binary"
export LIVE_ACCOUNT_DELETION_RECENT_AUTH_SECONDS="$recent_auth_seconds"
export LIVE_ACCOUNT_DELETION_LOGS="$api_log:$worker_log"
export PYTHONDONTWRITEBYTECODE=1

export APP_ENV=development
export DATABASE_URL="$database_url"
export DATABASE_POOL_SIZE=5
export RUN_MIGRATIONS=false
export ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$identity_keys"
export ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE="$signing_keys"
export ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE="$provider_keys"
export ACCOUNT_DELETION_LEDGER_DIRECTORY="$ledger_directory"
export ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=development
export ACCOUNT_DELETION_RECENT_AUTH_SECONDS="$recent_auth_seconds"
export ACCOUNT_DELETE_LIMIT=2
export ACCOUNT_DELETE_WINDOW_SECONDS=3600
export ACCOUNT_DELETION_MAX_ATTEMPTS=3
export ACCOUNT_SECURITY_RETENTION_DAYS=90
export ACCOUNT_DELETION_LEDGER_RETENTION_DAYS=400
export ACCOUNT_RECOVERABLE_BACKUP_DAYS=35
export ACCOUNT_DELETION_WORKER_ID="live-account-deletion-$run_id"
export ACCOUNT_DELETION_JOB_LEASE_SECONDS=10
export ACCOUNT_DELETION_STEP_TIMEOUT_SECONDS=5
export ACCOUNT_DELETION_POLL_INTERVAL_MS=100
export ACCOUNT_DELETION_RETRY_BASE_SECONDS=1
export ACCOUNT_DELETION_RETRY_MAX_SECONDS=5
export ACCOUNT_DELETION_CLEANUP_INTERVAL_SECONDS=60
export ACCOUNT_DELETION_CLEANUP_BATCH_SIZE=100
export ACCOUNT_DELETION_PENDING_FILE_MAX_AGE_SECONDS=300
export IDENTITY_ADMIN_PROVIDER=keycloak
export KEYCLOAK_ADMIN_BASE_URL="$keycloak_base"
export KEYCLOAK_REALM="$realm"
export KEYCLOAK_ADMIN_CLIENT_ID="$LIVE_ACCOUNT_DELETION_WORKER_CLIENT_ID"
export KEYCLOAK_ADMIN_CLIENT_SECRET_FILE="$worker_secret"
export OIDC_ISSUER_URL="$issuer"
export OIDC_AUDIENCE=pakperk-api
export OIDC_ALLOWED_ALGORITHMS=RS256
export PAKPERK_ADMIN_ACTOR="live-account-deletion:$run_id"
export RUST_LOG="pakperk=info,tower_http=info"
export LOG_FORMAT=compact

run_driver() {
  env \
    LIVE_ACCOUNT_DELETION_KEYCLOAK_ADMIN_USERNAME="$admin_username" \
    LIVE_ACCOUNT_DELETION_KEYCLOAK_ADMIN_PASSWORD="$admin_password" \
    python3 "$project_dir/scripts/test_live_account_deletion.py" "$@"
}

run_driver validate

api_pid=""
worker_pid=""
stop_postgres=0
stop_keycloak_postgres=0
stop_mailpit=0
stop_keycloak=0
acceptance_succeeded=0
scoped_cleanup_succeeded=1

service_running() {
  local service="$1"
  local container_id
  container_id="$(docker compose --project-directory "$project_dir" --profile accounts ps -q "$service")"
  [[ -n "$container_id" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == true ]]
}

stop_process() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    wait "$pid" >/dev/null 2>&1 || true
    return 0
  fi
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  stop_process "$worker_pid"
  stop_process "$api_pid"
  if [[ -f "$state_file" ]]; then
    if ! run_driver audit; then
      status=1
    fi
    if ! run_driver cleanup; then
      echo "Disposable account-deletion cleanup could not remove all scoped state." >&2
      scoped_cleanup_succeeded=0
      status=1
    fi
  fi
  if [[ "$manage_compose" == 1 ]]; then
    if [[ "$stop_keycloak" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop keycloak >/dev/null || status=1
    fi
    if [[ "$stop_mailpit" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop mailpit >/dev/null || status=1
    fi
    if [[ "$stop_keycloak_postgres" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop keycloak-postgres >/dev/null || status=1
    fi
    if [[ "$stop_postgres" == 1 ]]; then
      docker compose --project-directory "$project_dir" stop postgres >/dev/null || status=1
    fi
  fi
  if [[ "$scoped_cleanup_succeeded" == 1 ]]; then
    rm -rf "$work_dir"
  else
    echo "Owner-only recovery state was retained at $work_dir for a cleanup retry." >&2
  fi
  if [[ "$acceptance_succeeded" == 1 && "$status" == 0 ]]; then
    echo "Live Keycloak account-deletion acceptance passed and disposable state was cleaned."
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$manage_compose" == 1 ]]; then
  postgres_was_running=0
  keycloak_postgres_was_running=0
  mailpit_was_running=0
  keycloak_was_running=0
  service_running postgres && postgres_was_running=1
  service_running keycloak-postgres && keycloak_postgres_was_running=1
  service_running mailpit && mailpit_was_running=1
  service_running keycloak && keycloak_was_running=1

  if ! docker compose --project-directory "$project_dir" --profile accounts up -d postgres keycloak; then
    [[ "$postgres_was_running" == 0 ]] && service_running postgres && stop_postgres=1
    [[ "$keycloak_postgres_was_running" == 0 ]] && service_running keycloak-postgres && stop_keycloak_postgres=1
    [[ "$mailpit_was_running" == 0 ]] && service_running mailpit && stop_mailpit=1
    [[ "$keycloak_was_running" == 0 ]] && service_running keycloak && stop_keycloak=1
    echo "Compose could not start the disposable account-deletion dependencies." >&2
    exit 1
  fi

  [[ "$postgres_was_running" == 0 ]] && service_running postgres && stop_postgres=1
  [[ "$keycloak_postgres_was_running" == 0 ]] && service_running keycloak-postgres && stop_keycloak_postgres=1
  [[ "$mailpit_was_running" == 0 ]] && service_running mailpit && stop_mailpit=1
  [[ "$keycloak_was_running" == 0 ]] && service_running keycloak && stop_keycloak=1
fi

keycloak_ready=0
for _ in $(seq 1 120); do
  if curl --silent --show-error --fail \
    "$issuer/.well-known/openid-configuration" >/dev/null 2>&1; then
    keycloak_ready=1
    break
  fi
  sleep 1
done
if [[ "$keycloak_ready" != 1 ]]; then
  echo "Keycloak is unavailable; the opt-in deletion suite cannot run." >&2
  exit 1
fi

if [[ "$skip_build" == 0 ]]; then
  env -u KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME -u KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD \
    cargo build --locked --manifest-path "$project_dir/backend/Cargo.toml" \
    --package pakperk-api --package pakperk-deletion-worker
fi
if [[ ! -x "$api_binary" || ! -x "$worker_binary" ]]; then
  echo "Required Rust binaries are absent; rerun without LIVE_ACCOUNT_DELETION_SKIP_BUILD=1." >&2
  exit 1
fi

env -i \
  PATH="$PATH" \
  TMPDIR="${TMPDIR:-/tmp}" \
  APP_ENV=development \
  ACCOUNTS_ENABLED=true \
  LIBRARY_ENABLED=false \
  LIBRARY_WRITES_ENABLED=false \
  COMMENTS_ENABLED=false \
  COMMENT_CREATION_ENABLED=false \
  ACCOUNT_DELETION_ENABLED=true \
  ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$identity_keys" \
  ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE="$signing_keys" \
  ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE="$provider_keys" \
  ACCOUNT_DELETION_LEDGER_DIRECTORY="$ledger_directory" \
  ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=development \
  ACCOUNT_DELETION_RECENT_AUTH_SECONDS="$recent_auth_seconds" \
  ACCOUNT_DELETE_LIMIT=2 \
  ACCOUNT_DELETE_WINDOW_SECONDS=3600 \
  ACCOUNT_DELETION_MAX_ATTEMPTS=3 \
  ACCOUNT_SECURITY_RETENTION_DAYS=90 \
  ACCOUNT_DELETION_LEDGER_RETENTION_DAYS=400 \
  ACCOUNT_RECOVERABLE_BACKUP_DAYS=35 \
  API_ORIGIN_HASH_SECRET_FILE="$origin_secret" \
  API_CURSOR_ENCRYPTION_KEYS_FILE="$cursor_keys" \
  OIDC_ISSUER_URL="$issuer" \
  OIDC_AUDIENCE=pakperk-api \
  OIDC_ALLOWED_ALGORITHMS=RS256 \
  OIDC_DISCOVERY_TIMEOUT_SECONDS=5 \
  OIDC_JWKS_CACHE_TTL_SECONDS=900 \
  OIDC_JWKS_MIN_REFRESH_SECONDS=1 \
  OIDC_CLOCK_SKEW_SECONDS=30 \
  OIDC_RETRY_INITIAL_SECONDS=1 \
  OIDC_RETRY_MAX_SECONDS=5 \
  CURRENT_TERMS_VERSION=2026-07-31 \
  CURRENT_COMMUNITY_GUIDELINES_VERSION=2026-07-31 \
  PROFILE_UPDATE_LIMIT=20 \
  PROFILE_UPDATE_WINDOW_SECONDS=3600 \
  API_BIND="127.0.0.1:$api_port" \
  DATABASE_URL="$database_url" \
  DATABASE_POOL_SIZE=5 \
  RUN_MIGRATIONS=true \
  RUST_LOG="pakperk=info,tower_http=info" \
  LOG_FORMAT=compact \
  REQUEST_TIMEOUT_SECONDS=30 \
  CHAT_REQUEST_TIMEOUT_SECONDS=65 \
  API_MAX_REQUEST_BYTES=65536 \
  CORS_ALLOWED_ORIGINS=http://localhost:3000 \
  ARXIV_USER_AGENT=PakperkLiveAccountDeletion/0.1 \
  ARXIV_CONTACT_EMAIL=testing@pakperk.org \
  ARXIV_MIN_INTERVAL_MS=3000 \
  ARXIV_REQUEST_TIMEOUT_SECONDS=30 \
  ARXIV_CACHE_TTL_SECONDS=86400 \
  FULLTEXT_POLICY=prototype \
  DEMO_MODE=true \
  LLM_PROVIDER=deterministic \
  EMBEDDING_DIMENSION=64 \
  PREPARE_REQUESTS_PER_MINUTE=30 \
  CHAT_REQUESTS_PER_MINUTE=30 \
  "$api_binary" >"$api_log" 2>&1 &
api_pid="$!"

api_ready=0
for _ in $(seq 1 90); do
  if ! kill -0 "$api_pid" >/dev/null 2>&1; then
    echo "Account-deletion API exited before readiness; inspect its redacted local log." >&2
    exit 1
  fi
  if curl --silent --show-error --fail "$api_base/health/ready" >/dev/null 2>&1; then
    api_ready=1
    break
  fi
  sleep 1
done
if [[ "$api_ready" != 1 ]]; then
  echo "Account-deletion API did not become ready." >&2
  exit 1
fi

run_driver prepare

env -i \
  PATH="$PATH" \
  TMPDIR="${TMPDIR:-/tmp}" \
  APP_ENV=development \
  DATABASE_URL="$database_url" \
  DATABASE_POOL_SIZE=5 \
  RUN_MIGRATIONS=false \
  ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$identity_keys" \
  ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE="$signing_keys" \
  ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE="$provider_keys" \
  ACCOUNT_DELETION_LEDGER_DIRECTORY="$ledger_directory" \
  ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=development \
  ACCOUNT_DELETION_RECENT_AUTH_SECONDS="$recent_auth_seconds" \
  ACCOUNT_DELETE_LIMIT=2 \
  ACCOUNT_DELETE_WINDOW_SECONDS=3600 \
  ACCOUNT_DELETION_MAX_ATTEMPTS=3 \
  ACCOUNT_SECURITY_RETENTION_DAYS=90 \
  ACCOUNT_DELETION_LEDGER_RETENTION_DAYS=400 \
  ACCOUNT_RECOVERABLE_BACKUP_DAYS=35 \
  ACCOUNT_DELETION_WORKER_ID="live-account-deletion-$run_id" \
  ACCOUNT_DELETION_JOB_LEASE_SECONDS=10 \
  ACCOUNT_DELETION_STEP_TIMEOUT_SECONDS=5 \
  ACCOUNT_DELETION_POLL_INTERVAL_MS=100 \
  ACCOUNT_DELETION_RETRY_BASE_SECONDS=1 \
  ACCOUNT_DELETION_RETRY_MAX_SECONDS=5 \
  ACCOUNT_DELETION_CLEANUP_INTERVAL_SECONDS=60 \
  ACCOUNT_DELETION_CLEANUP_BATCH_SIZE=100 \
  ACCOUNT_DELETION_PENDING_FILE_MAX_AGE_SECONDS=300 \
  IDENTITY_ADMIN_PROVIDER=keycloak \
  KEYCLOAK_ADMIN_BASE_URL="$keycloak_base" \
  KEYCLOAK_REALM="$realm" \
  KEYCLOAK_ADMIN_CLIENT_ID="$LIVE_ACCOUNT_DELETION_WORKER_CLIENT_ID" \
  KEYCLOAK_ADMIN_CLIENT_SECRET_FILE="$worker_secret" \
  OIDC_ISSUER_URL="$issuer" \
  RUST_LOG="pakperk=info,tower_http=info" \
  LOG_FORMAT=compact \
  "$worker_binary" run >"$worker_log" 2>&1 &
worker_pid="$!"
worker_ready=0
for _ in $(seq 1 90); do
  if ! kill -0 "$worker_pid" >/dev/null 2>&1; then
    echo "Account-deletion worker exited before readiness; inspect its redacted local log." >&2
    exit 1
  fi
  if [[ -f "$readiness_marker" && ! -L "$readiness_marker" ]]; then
    worker_ready=1
    break
  fi
  sleep 1
done
if [[ "$worker_ready" != 1 ]]; then
  echo "Account-deletion worker did not publish readiness." >&2
  exit 1
fi

run_driver verify
acceptance_succeeded=1
