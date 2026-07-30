#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evaluation="${DEMO_CONTENT_EVALUATION:-$project_dir/demo/content_evaluation.json}"
api_base="${PAKPERK_API_BASE_URL:-http://localhost:8080}"
api_base="${api_base%/}"
report="${DEMO_CHAT_REVIEW_REPORT:-$project_dir/demo/chat_review_run.json}"
session_id="${DEMO_CHAT_REVIEW_SESSION_ID:-00000000-0000-4000-8000-000000000015}"
request_delay="${DEMO_CHAT_REVIEW_DELAY_SECONDS:-6.1}"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -f "$evaluation" ]]; then
  echo "Content evaluation not found: $evaluation" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "review_demo_chat.sh requires curl and jq." >&2
  exit 2
fi
if ! [[ "$session_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "DEMO_CHAT_REVIEW_SESSION_ID must be a UUID." >&2
  exit 2
fi
if ! [[ "$request_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "DEMO_CHAT_REVIEW_DELAY_SECONDS must be a nonnegative number." >&2
  exit 2
fi

curl --fail --silent --show-error \
  --retry 3 --retry-connrefused \
  "$api_base/health/ready" >/dev/null

case_index=0
while IFS= read -r paper; do
  arxiv_id="$(jq --exit-status --raw-output '.arxiv_id' <<<"$paper")"
  paper_response="$(
    curl --fail --silent --show-error \
      "$api_base/v1/papers/by-arxiv/$arxiv_id"
  )"
  paper_id="$(jq --exit-status --raw-output '.paper_id' <<<"$paper_response")"
  jq --exit-status \
    '.capabilities.chat == true' \
    <<<"$paper_response" >/dev/null || {
    echo "$arxiv_id is not chat-ready; preprocess the prepared corpus first." >&2
    exit 1
  }

  while IFS= read -r chat_case; do
    case_index=$((case_index + 1))
    printf -v prefix '%04d' "$case_index"
    question="$(jq --exit-status --raw-output '.question' <<<"$chat_case")"
    request_body="$(jq --null-input --arg message "$question" \
      '{thread_id: null, message: $message}')"
    response="$(
      curl --fail --silent --show-error \
        --header "Content-Type: application/json" \
        --header "X-Session-Id: $session_id" \
        --data "$request_body" \
        "$api_base/v1/papers/$paper_id/chat"
    )"
    jq --exit-status \
      '.answer_markdown != null
       and (.insufficient_evidence | type == "boolean")
       and (.evidence | type == "array")' \
      <<<"$response" >/dev/null

    jq --null-input \
      --arg arxiv_id "$arxiv_id" \
      --arg paper_id "$paper_id" \
      --argjson specification "$chat_case" \
      --argjson response "$response" \
      '{
        arxiv_id: $arxiv_id,
        paper_id: $paper_id,
        specification: $specification,
        response: $response,
        diagnostics: {
          provider_abstained: $response.insufficient_evidence,
          evidence_count: ($response.evidence | length),
          returned_chunk_ids: [$response.evidence[].chunk_id]
        }
      }' >"$work_dir/case-$prefix.json"
    sleep "$request_delay"
  done < <(jq --compact-output '.chat_cases[]' <<<"$paper")
done < <(jq --compact-output '.papers[]' "$evaluation")

if [[ "$case_index" -eq 0 ]]; then
  echo "Content evaluation contains no chat cases." >&2
  exit 2
fi

generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
mkdir -p "$(dirname "$report")"
jq --slurp \
  --arg generated_at "$generated_at" \
  --arg api_base "$api_base" \
  --arg session_id "$session_id" \
  '{
    schema_version: 1,
    generated_at: $generated_at,
    api_base: $api_base,
    anonymous_session_id: $session_id,
    notice: "Raw API responses for manual review. This report does not populate or claim observed evaluation labels.",
    cases: .
  }' "$work_dir"/case-*.json >"$report"

echo "Captured $case_index raw chat responses for manual review: $report"
