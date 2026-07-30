#!/usr/bin/env bash
set -euo pipefail

api_base="${PAKPERK_API_BASE_URL:-http://localhost:8080}"
api_base="${api_base%/}"
arxiv_id="${LAZY_TEST_ARXIV_ID:-2106.09685v2}"
timeout_seconds="${LAZY_TEST_TIMEOUT_SECONDS:-600}"
poll_seconds="${LAZY_TEST_POLL_SECONDS:-1}"
report="${LAZY_TEST_REPORT:-}"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "test_live_lazy_preparation.sh requires curl and jq." >&2
  exit 2
fi
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "LAZY_TEST_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi
if ! [[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "LAZY_TEST_POLL_SECONDS must be a nonnegative number." >&2
  exit 2
fi

curl --fail --silent --show-error \
  --retry 3 --retry-connrefused \
  "$api_base/health/ready" >/dev/null

paper="$(
  curl --fail --silent --show-error \
    "$api_base/v1/papers/by-arxiv/$arxiv_id"
)"
paper_id="$(jq --exit-status --raw-output '.paper_id' <<<"$paper")"
initial="$(
  curl --fail --silent --show-error \
    "$api_base/v1/papers/$paper_id/processing"
)"
jq --exit-status \
  '.stage == "not_requested"
   and .capabilities.introduction == false
   and .capabilities.chat == false
   and .capabilities.connections == false' \
  <<<"$initial" >/dev/null || {
  echo "$arxiv_id must be pristine (not_requested with no derived capabilities)." >&2
  exit 1
}

first="$(
  curl --fail --silent --show-error \
    --request POST \
    --header "Content-Type: application/json" \
    --data '{}' \
    "$api_base/v1/papers/$paper_id/prepare"
)"
second="$(
  curl --fail --silent --show-error \
    --request POST \
    --header "Content-Type: application/json" \
    --data '{}' \
    "$api_base/v1/papers/$paper_id/prepare"
)"
jq --exit-status \
  --arg paper_id "$paper_id" \
  'select(.paper_id == $paper_id)
   | select(.generation > 0)
   | select(.overall_state == "processing" or .overall_state == "ready")' \
  <<<"$first" >/dev/null
jq --exit-status \
  --arg paper_id "$paper_id" \
  --argjson generation "$(jq '.generation' <<<"$first")" \
  'select(.paper_id == $paper_id)
   | select(.generation == $generation)
   | select(.overall_state == "processing" or .overall_state == "ready")' \
  <<<"$second" >/dev/null

started_epoch="$(date +%s)"
observed_introduction=false
: >"$work_dir/stages.jsonl"
while true; do
  current="$(
    curl --fail --silent --show-error \
      "$api_base/v1/papers/$paper_id/processing"
  )"
  jq --compact-output \
    '{observed_at: now | todateiso8601,
      stage,
      overall_state,
      capabilities,
      retryable,
      last_error}' \
    <<<"$current" >>"$work_dir/stages.jsonl"

  if jq --exit-status '.capabilities.introduction == true' \
    <<<"$current" >/dev/null; then
    observed_introduction=true
    introduction="$(
      curl --fail --silent --show-error \
        "$api_base/v1/papers/$paper_id/introduction"
    )"
    jq --exit-status \
      '.paragraphs | type == "array" and length > 0' \
      <<<"$introduction" >/dev/null
  fi

  stage="$(jq --exit-status --raw-output '.stage' <<<"$current")"
  if [[ "$stage" == "ready" ]]; then
    break
  fi
  if [[ "$stage" == "failed_terminal" ]]; then
    echo "Lazy preparation failed terminally: $(jq -c '.last_error' <<<"$current")" >&2
    exit 1
  fi
  if (( $(date +%s) - started_epoch >= timeout_seconds )); then
    echo "Timed out waiting for lazy preparation after ${timeout_seconds}s." >&2
    exit 1
  fi
  sleep "$poll_seconds"
done

if [[ "$observed_introduction" != true ]]; then
  echo "Preparation reached ready without exposing a readable Introduction." >&2
  exit 1
fi

connections="$(
  curl --fail --silent --show-error \
    "$api_base/v1/papers/$paper_id/connections"
)"
jq --exit-status \
  '.ready == true
   and (.key_connections | type == "array")
   and (.references | type == "array")' \
  <<<"$connections" >/dev/null

if [[ -n "$report" ]]; then
  mkdir -p "$(dirname "$report")"
  jq --slurp \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg api_base "$api_base" \
    --arg arxiv_id "$arxiv_id" \
    --arg paper_id "$paper_id" \
    --argjson initial "$initial" \
    --argjson first_prepare "$first" \
    --argjson second_prepare "$second" \
    --argjson final "$current" \
    --argjson introduction "$introduction" \
    --argjson connections "$connections" \
    '{
      schema_version: 1,
      generated_at: $generated_at,
      api_base: $api_base,
      arxiv_id: $arxiv_id,
      paper_id: $paper_id,
      initial: $initial,
      first_prepare: $first_prepare,
      second_prepare: $second_prepare,
      observed_stages: .,
      final: $final,
      introduction_paragraph_count: ($introduction.paragraphs | length),
      key_connection_count: ($connections.key_connections | length),
      reference_count: ($connections.references | length),
      success: true
    }' "$work_dir/stages.jsonl" >"$report"
fi

echo "Lazy preparation passed for $arxiv_id: Introduction, Chat, and Connections are ready."
