#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${DEMO_SEED_MANIFEST:-$project_dir/demo/seed_manifest.json}"
timeout_seconds="${DEMO_PREPROCESS_TIMEOUT_SECONDS:-1800}"

run_worker() {
  if [[ "${PAKPERK_USE_DOCKER:-1}" == "1" ]]; then
    docker compose --project-directory "$project_dir" run --rm \
      --volume "$manifest:/inputs/seed_manifest.json:ro" \
      worker /usr/local/bin/pakperk-worker "$@"
  else
    cargo run --manifest-path "$project_dir/backend/Cargo.toml" \
      --package pakperk-worker -- "$@"
  fi
}

if [[ ! -f "$manifest" ]]; then
  echo "Seed manifest not found: $manifest" >&2
  exit 2
fi

if [[ "${PAKPERK_USE_DOCKER:-1}" == "1" ]]; then
  run_worker prepare-demo \
    --manifest /inputs/seed_manifest.json \
    --wait \
    --timeout-seconds "$timeout_seconds"
else
  run_worker prepare-demo \
    --manifest "$manifest" \
    --wait \
    --timeout-seconds "$timeout_seconds"
fi
