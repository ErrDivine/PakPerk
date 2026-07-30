#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${DEMO_SEED_MANIFEST:-$project_dir/demo/seed_manifest.json}"
expected="${DEMO_EXPECTED_CONNECTIONS:-$project_dir/demo/expected_connections.json}"
evaluation="${DEMO_CONTENT_EVALUATION:-$project_dir/demo/content_evaluation.json}"
report="${DEMO_CONTENT_STRUCTURE_REPORT:-$project_dir/demo/content_evaluation_structure_report.json}"

if [[ ! -f "$manifest" || ! -f "$expected" || ! -f "$evaluation" ]]; then
  echo "Demo manifest, expected-connections, or content-evaluation file is missing." >&2
  exit 2
fi

if [[ "${PAKPERK_USE_DOCKER:-1}" == "1" ]]; then
  report_dir="$(dirname "$report")"
  mkdir -p "$report_dir"
  docker compose --project-directory "$project_dir" run --rm --no-deps \
    --volume "$report_dir:/reports" \
    --volume "$manifest:/inputs/seed_manifest.json:ro" \
    --volume "$expected:/inputs/expected_connections.json:ro" \
    --volume "$evaluation:/inputs/content_evaluation.json:ro" \
    worker /usr/local/bin/pakperk-worker validate-demo-content \
    --manifest /inputs/seed_manifest.json \
    --expected-connections /inputs/expected_connections.json \
    --content-evaluation /inputs/content_evaluation.json \
    --output "/reports/$(basename "$report")"
else
  cargo run --manifest-path "$project_dir/backend/Cargo.toml" \
    --package pakperk-worker -- validate-demo-content \
    --manifest "$manifest" \
    --expected-connections "$expected" \
    --content-evaluation "$evaluation" \
    --output "$report"
fi

echo "Content-evaluation structure report: $report"
