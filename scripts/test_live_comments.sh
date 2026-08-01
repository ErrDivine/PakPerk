#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manage_compose="${LIVE_COMMENTS_MANAGE_COMPOSE:-1}"
skip_build="${LIVE_COMMENTS_SKIP_BUILD:-0}"
write_port="${LIVE_COMMENTS_WRITE_PORT:-18080}"
read_only_port="${LIVE_COMMENTS_READ_ONLY_PORT:-18082}"
unavailable_port="${LIVE_COMMENTS_UNAVAILABLE_PORT:-18083}"
unavailable_issuer_port="${LIVE_COMMENTS_UNAVAILABLE_ISSUER_PORT:-65530}"
keycloak_base="${LIVE_COMMENTS_KEYCLOAK_BASE_URL:-http://localhost:8081}"
keycloak_admin_username="${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME:-admin}"
keycloak_admin_password="${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD:-pakperk-admin-dev}"
current_terms_version="${CURRENT_TERMS_VERSION:-2026-07-31}"
current_guidelines_version="${CURRENT_COMMUNITY_GUIDELINES_VERSION:-2026-07-31}"
evidence_file="${LIVE_COMMENTS_EVIDENCE_FILE:-}"
evidence_source_revision="${LIVE_COMMENTS_SOURCE_REVISION:-}"
evidence_environment="${LIVE_COMMENTS_EVIDENCE_ENVIRONMENT:-}"
api_binary="$project_dir/backend/target/debug/pakperk-api"
admin_binary="$project_dir/backend/target/debug/pakperk-admin"
api_pids=()
stop_postgres=0
stop_keycloak_postgres=0
stop_mailpit=0
stop_keycloak=0
acceptance_succeeded=0

verify_evidence_source() {
  local current_revision
  local source_status
  if ! current_revision="$(git -C "$project_dir" rev-parse HEAD)"; then
    echo "Live-comments evidence could not resolve the checked-out revision." >&2
    return 1
  fi
  if [[ "$current_revision" != "$evidence_source_revision" ]]; then
    echo "Live-comments evidence must bind the exact checked-out revision." >&2
    return 1
  fi
  if ! source_status="$(git -C "$project_dir" status --porcelain --untracked-files=normal)"; then
    echo "Live-comments evidence could not inspect the source tree." >&2
    return 1
  fi
  if [[ -n "$source_status" ]]; then
    echo "Live-comments evidence requires a clean source tree." >&2
    return 1
  fi
}

for command in cargo curl docker git openssl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "test_live_comments.sh requires $command." >&2
    exit 2
  fi
done
if ! python3 -c 'import requests, bs4' >/dev/null 2>&1; then
  echo "test_live_comments.sh requires the Python requests and beautifulsoup4 packages." >&2
  exit 2
fi
for value in "$write_port" "$read_only_port" "$unavailable_port" "$unavailable_issuer_port"; do
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]] || (( value > 65535 )); then
    echo "Live-comments ports must be integers between 1 and 65535." >&2
    exit 2
  fi
done
if [[ "$manage_compose" != 0 && "$manage_compose" != 1 ]]; then
  echo "LIVE_COMMENTS_MANAGE_COMPOSE must be 0 or 1." >&2
  exit 2
fi
if [[ "$skip_build" != 0 && "$skip_build" != 1 ]]; then
  echo "LIVE_COMMENTS_SKIP_BUILD must be 0 or 1." >&2
  exit 2
fi
if [[ -n "$evidence_file" ]]; then
  if [[ "$evidence_file" != /* || -e "$evidence_file" || -L "$evidence_file" ]]; then
    echo "LIVE_COMMENTS_EVIDENCE_FILE must be a new absolute path." >&2
    exit 2
  fi
  if [[ ! "$evidence_source_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "LIVE_COMMENTS_SOURCE_REVISION must be a full lowercase Git commit SHA." >&2
    exit 2
  fi
  if [[ "$evidence_environment" != manual_ci_disposable_reference && "$evidence_environment" != local_disposable_reference ]]; then
    echo "LIVE_COMMENTS_EVIDENCE_ENVIRONMENT is not a supported classification." >&2
    exit 2
  fi
  if ! verify_evidence_source; then
    exit 2
  fi
elif [[ -n "$evidence_source_revision" || -n "$evidence_environment" ]]; then
  echo "LIVE_COMMENTS_EVIDENCE_FILE is required when evidence metadata is set." >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-live-comments.XXXXXX")"
state_file="$work_dir/state.json"
comment_secret="$work_dir/comment-origin-secret"
identity_fingerprint_keys="$work_dir/account-identity-fingerprint-keys"
admin_access_token="$work_dir/admin-access-token"
unauthorized_admin_access_token="$work_dir/unauthorized-admin-access-token"
write_log="$work_dir/api-write.log"
read_only_log="$work_dir/api-read-only.log"
unavailable_log="$work_dir/api-unavailable.log"
umask 077
openssl rand -hex 48 >"$comment_secret"
printf 'live-comments-current:%s\n' "$(openssl rand -base64 32)" >"$identity_fingerprint_keys"
run_id="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
ugc_sentinel="PAKPERK_UGC_SENTINEL_${run_id}"
token_sentinel="PAKPERK_TOKEN_SENTINEL_${run_id}"

export LIVE_COMMENTS_PROJECT_DIR="$project_dir"
export LIVE_COMMENTS_STATE_FILE="$state_file"
export LIVE_COMMENTS_WRITE_API="http://127.0.0.1:$write_port"
export LIVE_COMMENTS_READ_ONLY_API="http://127.0.0.1:$read_only_port"
export LIVE_COMMENTS_UNAVAILABLE_API="http://127.0.0.1:$unavailable_port"
export LIVE_COMMENTS_KEYCLOAK_BASE_URL="$keycloak_base"
export LIVE_COMMENTS_KEYCLOAK_REALM="${LIVE_COMMENTS_KEYCLOAK_REALM:-pakperk}"
export LIVE_COMMENTS_OIDC_CLIENT_ID="${LIVE_COMMENTS_OIDC_CLIENT_ID:-pakperk-mobile-dev}"
export LIVE_COMMENTS_OIDC_REDIRECT_URI="${LIVE_COMMENTS_OIDC_REDIRECT_URI:-pakperk-auth-dev://oauth/callback}"
export LIVE_COMMENTS_ADMIN_OIDC_CLIENT_ID="${LIVE_COMMENTS_ADMIN_OIDC_CLIENT_ID:-pakperk-admin-dev}"
export LIVE_COMMENTS_ADMIN_OIDC_REDIRECT_URI="${LIVE_COMMENTS_ADMIN_OIDC_REDIRECT_URI:-pakperk-admin-dev://oauth/callback}"
export LIVE_COMMENTS_ADMIN_OIDC_AUDIENCE="${LIVE_COMMENTS_ADMIN_OIDC_AUDIENCE:-pakperk-admin-dev}"
export LIVE_COMMENTS_KEYCLOAK_ADMIN_USERNAME="$keycloak_admin_username"
export LIVE_COMMENTS_KEYCLOAK_ADMIN_PASSWORD="$keycloak_admin_password"
export LIVE_COMMENTS_POSTGRES_USER="${LIVE_COMMENTS_POSTGRES_USER:-pakperk}"
export LIVE_COMMENTS_POSTGRES_DB="${LIVE_COMMENTS_POSTGRES_DB:-pakperk}"
export LIVE_COMMENTS_RUN_ID="$run_id"
export LIVE_COMMENTS_UGC_SENTINEL="$ugc_sentinel"
export LIVE_COMMENTS_TOKEN_SENTINEL="$token_sentinel"
export LIVE_COMMENTS_COMMENT_SECRET_FILE="$comment_secret"
export LIVE_COMMENTS_CURRENT_TERMS_VERSION="$current_terms_version"
export LIVE_COMMENTS_CURRENT_GUIDELINES_VERSION="$current_guidelines_version"
export LIVE_COMMENTS_API_LOGS="$write_log:$read_only_log:$unavailable_log"
export LIVE_COMMENTS_ADMIN_BINARY="$admin_binary"
export LIVE_COMMENTS_DATABASE_URL="${LIVE_COMMENTS_DATABASE_URL:-postgres://pakperk:pakperk@127.0.0.1:5432/pakperk}"
export LIVE_COMMENTS_ADMIN_ACCESS_TOKEN_FILE="$admin_access_token"
export LIVE_COMMENTS_ADMIN_UNAUTHORIZED_ACCESS_TOKEN_FILE="$unauthorized_admin_access_token"
export PYTHONDONTWRITEBYTECODE=1

service_running() {
  local service="$1"
  local container_id
  container_id="$(docker compose --project-directory "$project_dir" --profile accounts ps -q "$service")"
  [[ -n "$container_id" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == true ]]
}

stop_api_processes() {
  local pid
  for pid in "${api_pids[@]-}"; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  for pid in "${api_pids[@]-}"; do
    [[ -z "$pid" ]] && continue
    wait "$pid" >/dev/null 2>&1 || true
  done
}

scan_static_sentinels() {
  local log
  for log in "$write_log" "$read_only_log" "$unavailable_log"; do
    if [[ -f "$log" ]] && {
      grep -Fq "$ugc_sentinel" "$log" || grep -Fq "$token_sentinel" "$log"
    }; then
      echo "Captured API log $(basename "$log") contains a protected sentinel." >&2
      return 1
    fi
  done
}

cleanup() {
  local status="$?"
  local harness_outcome=passed
  local cleanup_succeeded=1
  [[ "$status" != 0 ]] && harness_outcome=failed
  trap - EXIT INT TERM
  stop_api_processes
  if ! scan_static_sentinels; then
    status=1
    cleanup_succeeded=0
  fi
  if [[ -f "$state_file" ]]; then
    if ! python3 "$project_dir/scripts/test_live_comments.py" cleanup; then
      echo "Live-comments cleanup helper could not fully clean disposable data." >&2
      status=1
      cleanup_succeeded=0
    fi
  fi
  if [[ "$manage_compose" == 1 ]]; then
    if [[ "$stop_keycloak" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop keycloak >/dev/null || {
        status=1
        cleanup_succeeded=0
      }
    fi
    if [[ "$stop_mailpit" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop mailpit >/dev/null || {
        status=1
        cleanup_succeeded=0
      }
    fi
    if [[ "$stop_keycloak_postgres" == 1 ]]; then
      docker compose --project-directory "$project_dir" --profile accounts stop keycloak-postgres >/dev/null || {
        status=1
        cleanup_succeeded=0
      }
    fi
    if [[ "$stop_postgres" == 1 ]]; then
      docker compose --project-directory "$project_dir" stop postgres >/dev/null || {
        status=1
        cleanup_succeeded=0
      }
    fi
  fi
  if ! rm -f \
    "$comment_secret" \
    "$identity_fingerprint_keys" \
    "$admin_access_token" \
    "$unauthorized_admin_access_token"; then
    echo "Live-comments private fixtures could not be removed." >&2
    status=1
    cleanup_succeeded=0
  fi
  if [[ -n "$evidence_file" && "$cleanup_succeeded" == 1 && -f "$state_file" ]]; then
    if ! verify_evidence_source; then
      echo "Sanitized evidence was withheld because the source changed during acceptance." >&2
      status=1
      cleanup_succeeded=0
    elif ! LIVE_COMMENTS_EVIDENCE_EXPECTED_OUTCOME="$harness_outcome" \
      python3 "$project_dir/scripts/test_live_comments.py" evidence; then
      echo "Sanitized live-comments evidence could not be emitted." >&2
      status=1
    fi
  fi
  rm -rf "$work_dir"
  if [[ "$acceptance_succeeded" == 1 && "$status" == 0 ]]; then
    echo "Live comments acceptance passed and all disposable state was cleaned."
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

if [[ "$manage_compose" == 1 ]]; then
  postgres_was_running=0
  keycloak_postgres_was_running=0
  mailpit_was_running=0
  keycloak_was_running=0
  service_running postgres && postgres_was_running=1
  service_running keycloak-postgres && keycloak_postgres_was_running=1
  service_running mailpit && mailpit_was_running=1
  service_running keycloak && keycloak_was_running=1

  docker compose --project-directory "$project_dir" --profile accounts up -d postgres keycloak

  [[ "$postgres_was_running" == 0 ]] && service_running postgres && stop_postgres=1
  [[ "$keycloak_postgres_was_running" == 0 ]] && service_running keycloak-postgres && stop_keycloak_postgres=1
  [[ "$mailpit_was_running" == 0 ]] && service_running mailpit && stop_mailpit=1
  [[ "$keycloak_was_running" == 0 ]] && service_running keycloak && stop_keycloak=1
fi

keycloak_ready=0
for _ in $(seq 1 120); do
  if curl --silent --show-error --fail \
    "$keycloak_base/realms/${LIVE_COMMENTS_KEYCLOAK_REALM}/.well-known/openid-configuration" \
    >/dev/null 2>&1; then
    keycloak_ready=1
    break
  fi
  sleep 1
done
if [[ "$keycloak_ready" != 1 ]]; then
  echo "Keycloak is unavailable; the required two-user Authorization Code + PKCE acceptance cannot run." >&2
  exit 1
fi

if [[ "$skip_build" == 0 ]]; then
  cargo build --locked --manifest-path "$project_dir/backend/Cargo.toml" \
    --package pakperk-api --package pakperk-admin
fi
if [[ ! -x "$api_binary" ]]; then
  echo "API binary not found at $api_binary; rerun without LIVE_COMMENTS_SKIP_BUILD=1." >&2
  exit 1
fi
if [[ ! -x "$admin_binary" ]]; then
  echo "Admin binary not found at $admin_binary; rerun without LIVE_COMMENTS_SKIP_BUILD=1." >&2
  exit 1
fi

start_api() {
  local name="$1"
  local port="$2"
  local creation_enabled="$3"
  local issuer="$4"
  local discovery_timeout="$5"
  local retry_initial="$6"
  local retry_maximum="$7"
  local log="$8"
  env \
    APP_ENV=development \
    ACCOUNTS_ENABLED=true \
    LIBRARY_ENABLED=false \
    LIBRARY_WRITES_ENABLED=false \
    COMMENTS_ENABLED=true \
    COMMENT_CREATION_ENABLED="$creation_enabled" \
    ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$identity_fingerprint_keys" \
    API_ORIGIN_HASH_SECRET_FILE="$comment_secret" \
    COMMENT_MAX_SCALARS=2000 \
    COMMENT_MAX_BYTES=8000 \
    COMMENT_MAX_URLS=3 \
    COMMENT_MODERATION_PROVIDER=rules \
    COMMENT_SUPPORT_CONTACT_URL="http://127.0.0.1:$port/support/comments" \
    COMMENT_MAXIMUM_PAGE_SIZE=50 \
    COMMENT_CREATE_LIMIT=20 \
    COMMENT_CREATE_WINDOW_SECONDS=3600 \
    COMMENT_MUTATION_LIMIT=100 \
    COMMENT_MUTATION_WINDOW_SECONDS=3600 \
    COMMENT_REPORT_LIMIT=50 \
    COMMENT_REPORT_WINDOW_SECONDS=3600 \
    COMMENT_ORIGIN_LIMIT=200 \
    COMMENT_ORIGIN_WINDOW_SECONDS=3600 \
    OIDC_ISSUER_URL="$issuer" \
    OIDC_AUDIENCE=pakperk-api \
    OIDC_ALLOWED_ALGORITHMS=RS256 \
    OIDC_DISCOVERY_TIMEOUT_SECONDS="$discovery_timeout" \
    OIDC_JWKS_CACHE_TTL_SECONDS=900 \
    OIDC_JWKS_MIN_REFRESH_SECONDS=1 \
    OIDC_CLOCK_SKEW_SECONDS=30 \
    OIDC_RETRY_INITIAL_SECONDS="$retry_initial" \
    OIDC_RETRY_MAX_SECONDS="$retry_maximum" \
    CURRENT_TERMS_VERSION="$current_terms_version" \
    CURRENT_COMMUNITY_GUIDELINES_VERSION="$current_guidelines_version" \
    PROFILE_UPDATE_LIMIT=20 \
    PROFILE_UPDATE_WINDOW_SECONDS=3600 \
    API_BIND="127.0.0.1:$port" \
    DATABASE_URL="$LIVE_COMMENTS_DATABASE_URL" \
    DATABASE_POOL_SIZE=10 \
    RUN_MIGRATIONS=true \
    RUST_LOG="pakperk=info,tower_http=info" \
    REQUEST_TIMEOUT_SECONDS=30 \
    CHAT_REQUEST_TIMEOUT_SECONDS=65 \
    API_MAX_REQUEST_BYTES=65536 \
    CORS_ALLOWED_ORIGINS=http://localhost:3000 \
    ARXIV_USER_AGENT=PakperkLiveComments/0.1 \
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
    "$api_binary" >"$log" 2>&1 &
  last_api_pid="$!"
  api_pids+=("$last_api_pid")

  local ready=0
  for _ in $(seq 1 90); do
    if ! kill -0 "$last_api_pid" >/dev/null 2>&1; then
      echo "$name API exited before readiness; inspect startup configuration and dependencies." >&2
      return 1
    fi
    if curl --silent --show-error --fail "http://127.0.0.1:$port/health/ready" \
      >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    echo "$name API did not become ready on port $port." >&2
    return 1
  fi
}

issuer="$keycloak_base/realms/${LIVE_COMMENTS_KEYCLOAK_REALM}"
start_api writable "$write_port" true "$issuer" 5 5 300 "$write_log"
start_api creation-disabled "$read_only_port" false "$issuer" 5 5 300 "$read_only_log"
start_api unavailable-issuer "$unavailable_port" false \
  "http://127.0.0.1:$unavailable_issuer_port/realms/pakperk" 1 1 2 "$unavailable_log"

python3 "$project_dir/scripts/test_live_comments.py" run
stop_api_processes
scan_static_sentinels
acceptance_succeeded=1
