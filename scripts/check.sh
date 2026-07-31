#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cargo fmt --manifest-path "$project_dir/backend/Cargo.toml" --all -- --check
cargo clippy --manifest-path "$project_dir/backend/Cargo.toml" \
  --workspace --all-targets --all-features -- -D warnings
cargo test --manifest-path "$project_dir/backend/Cargo.toml" \
  --workspace --all-features
"$project_dir/scripts/check_openapi.sh"

if command -v flutter >/dev/null 2>&1; then
  (
    cd "$project_dir/mobile"
    flutter pub get
    dart format --output=none --set-exit-if-changed .
    flutter analyze
    flutter test
    if [[ "${PAKPERK_RUN_DEVICE_INTEGRATION_TESTS:-0}" == "1" ]]; then
      flutter test integration_test/demo_flows_test.dart
    fi
  )
else
  echo "Flutter is not installed; skipped Dart format, analyze, and widget tests." >&2
fi

jq empty \
  "$project_dir/demo/seed_manifest.json" \
  "$project_dir/demo/fallback_feed.json" \
  "$project_dir/demo/expected_connections.json" \
  "$project_dir/demo/content_evaluation.json" \
  "$project_dir/demo/lazy_preparation_validation.json" \
  "$project_dir/mobile/assets/fallback_feed.json" \
  "$project_dir/mobile/assets/prepared_introductions.json" \
  "$project_dir/mobile/assets/prepared_connections.json"

bash -n "$project_dir"/scripts/*.sh
