#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${DEMO_SEED_MANIFEST:-$project_dir/demo/seed_manifest.json}"
api_base="${PAKPERK_API_BASE_URL:-http://localhost:8080}"
api_base="${api_base%/}"
output_dir="${DEMO_MOBILE_CACHE_DIR:-$project_dir/mobile/assets}"
demo_fallback="${DEMO_FALLBACK_FEED:-$project_dir/demo/fallback_feed.json}"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -f "$manifest" ]]; then
  echo "Seed manifest not found: $manifest" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "export_mobile_cache.sh requires curl and jq." >&2
  exit 2
fi

curl --fail --silent --show-error \
  --retry 3 --retry-connrefused \
  "$api_base/health/ready" >/dev/null

total_count=0
while IFS= read -r arxiv_id; do
  total_count=$((total_count + 1))
  printf -v prefix '%04d' "$total_count"

  paper_file="$work_dir/paper-$prefix.json"

  curl --fail --silent --show-error \
    "$api_base/v1/papers/by-arxiv/$arxiv_id" >"$paper_file"
done < <(jq --exit-status --raw-output '.papers[].arxiv_id' "$manifest")

if [[ "$total_count" -eq 0 ]]; then
  echo "Seed manifest contains no papers." >&2
  exit 2
fi

prepared_count=0
while IFS= read -r arxiv_id; do
  prepared_count=$((prepared_count + 1))
  printf -v prefix '%04d' "$prepared_count"

  paper_file="$work_dir/prepared-paper-$prefix.json"
  introduction_file="$work_dir/introduction-$prefix.json"
  connections_file="$work_dir/connections-$prefix.json"

  curl --fail --silent --show-error \
    "$api_base/v1/papers/by-arxiv/$arxiv_id" >"$paper_file"
  paper_id="$(jq --exit-status --raw-output '.paper_id' "$paper_file")"

  curl --fail --silent --show-error \
    "$api_base/v1/papers/$paper_id/introduction" >"$introduction_file"
  curl --fail --silent --show-error \
    "$api_base/v1/papers/$paper_id/connections" >"$connections_file"

  jq --exit-status \
    '.paper_id != null and (.paragraphs | length > 0)' \
    "$introduction_file" >/dev/null
  jq --exit-status \
    '.paper_id != null and .ready == true' \
    "$connections_file" >/dev/null
done < <(
  jq --exit-status --raw-output \
    '.papers[] | select(.prepared == true) | .arxiv_id' \
    "$manifest"
)

if [[ "$prepared_count" -eq 0 ]]; then
  echo "Seed manifest contains no prepared papers." >&2
  exit 2
fi

exported_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

jq --slurp --arg exported_at "$exported_at" \
  '{
    items: .,
    next_cursor: null,
    source: {
      name: "arXiv",
      retrieved_at: $exported_at,
      notice: "Pakperk uses arXiv metadata but is not affiliated with or endorsed by arXiv."
    }
  }' "$work_dir"/paper-*.json >"$work_dir/fallback_feed.json"

jq --slurp --arg exported_at "$exported_at" \
  '{
    schema_version: 1,
    provenance: {
      kind: "bundled_api_cache",
      content_form: "persisted_grobid_introductions",
      exported_at: $exported_at,
      source: "GET /v1/papers/{paper_id}/introduction",
      notice: "Exported from the ordinary prepared-paper API; not a separately coded demo result."
    },
    papers: (reduce .[] as $paper ({}; .[$paper.paper_id] = $paper))
  }' "$work_dir"/introduction-*.json \
  >"$work_dir/prepared_introductions.json"

jq --slurp --arg exported_at "$exported_at" \
  '{
    schema_version: 1,
    provenance: {
      kind: "bundled_api_cache",
      content_form: "persisted_reference_relationships",
      exported_at: $exported_at,
      source: "GET /v1/papers/{paper_id}/connections",
      notice: "Exported from the ordinary prepared-paper API; not a separately coded demo result."
    },
    papers: (reduce .[] as $paper ({}; .[$paper.paper_id] = $paper))
  }' "$work_dir"/connections-*.json \
  >"$work_dir/prepared_connections.json"

mkdir -p "$output_dir"
cp "$work_dir/fallback_feed.json" "$output_dir/fallback_feed.json"
mkdir -p "$(dirname "$demo_fallback")"
cp "$work_dir/fallback_feed.json" "$demo_fallback"
cp "$work_dir/prepared_introductions.json" \
  "$output_dir/prepared_introductions.json"
cp "$work_dir/prepared_connections.json" \
  "$output_dir/prepared_connections.json"

echo "Exported $total_count feed papers and $prepared_count prepared content records to $output_dir"
echo "Mirrored the ordinary-API fallback feed to $demo_fallback"
