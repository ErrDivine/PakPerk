#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helm_bin="${HELM_BIN:-helm}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-check.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

for command in cargo jq python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required check dependency is missing: $command" >&2
    exit 2
  fi
done

echo "== Repository contracts =="
bash -n "$project_dir"/scripts/*.sh
"$project_dir/scripts/drill_backup_restore.sh" --self-test
python3 -B - "$project_dir"/scripts/*.py <<'PY'
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    compile(path.read_bytes(), str(path), "exec")
PY
python3 "$project_dir/scripts/validate_workflow_pins.py"
python3 "$project_dir/scripts/test_validate_workflow_pins.py"
python3 "$project_dir/scripts/validate_dockerignore.py"
python3 "$project_dir/scripts/validate_gradle_wrapper.py"
python3 "$project_dir/scripts/test_verify_android_elf_alignment.py"
if jarsigner -help >/dev/null 2>&1 && keytool -help >/dev/null 2>&1; then
  "$project_dir/scripts/test_verify_signed_jar.sh"
else
  echo "Signed JAR regression test skipped: jarsigner/keytool are unavailable." >&2
fi
jq empty \
  "$project_dir/demo/seed_manifest.json" \
  "$project_dir/demo/fallback_feed.json" \
  "$project_dir/demo/expected_connections.json" \
  "$project_dir/demo/content_evaluation.json" \
  "$project_dir/demo/lazy_preparation_validation.json" \
  "$project_dir/mobile/assets/fallback_feed.json" \
  "$project_dir/mobile/assets/prepared_introductions.json" \
  "$project_dir/mobile/assets/prepared_connections.json" \
  "$project_dir/deploy/keycloak/pakperk-realm.json" \
  "$project_dir/deploy/helm/pakperk/values.schema.json"
"$project_dir/scripts/validate_keycloak_realm.sh"
"$project_dir/scripts/verify_mobile_associations.sh" --help >/dev/null
PAKPERK_USE_DOCKER=0 "$project_dir/scripts/validate_demo_content.sh"

echo "== Rust workspace =="
cargo fmt --manifest-path "$project_dir/backend/Cargo.toml" --all -- --check
cargo clippy --manifest-path "$project_dir/backend/Cargo.toml" \
  --locked --workspace --all-targets --all-features -- -D warnings
cargo test --manifest-path "$project_dir/backend/Cargo.toml" \
  --locked --workspace --all-features
"$project_dir/scripts/check_openapi.sh"

echo "== Release metadata regression =="
python3 "$project_dir/scripts/test_generate_release_metadata.py"

if command -v flutter >/dev/null 2>&1; then
  echo "== Flutter =="
  (
    cd "$project_dir/mobile"
    flutter pub get --enforce-lockfile

    echo "== Release metadata =="
    source_revision="$(git -C "$project_dir" rev-parse HEAD)"
    source_epoch="$(git -C "$project_dir" show -s --format=%ct HEAD)"
    SOURCE_REVISION="$source_revision" SOURCE_DATE_EPOCH="$source_epoch" \
      "$project_dir/scripts/generate_release_metadata.py" \
      --output-dir "$temporary_dir/metadata-a"
    SOURCE_REVISION="$source_revision" SOURCE_DATE_EPOCH="$source_epoch" \
      "$project_dir/scripts/generate_release_metadata.py" \
      --output-dir "$temporary_dir/metadata-b"
    cmp "$temporary_dir/metadata-a/open-source-notices.txt" \
      "$temporary_dir/metadata-b/open-source-notices.txt"
    cmp "$temporary_dir/metadata-a/dependencies.cdx.json" \
      "$temporary_dir/metadata-b/dependencies.cdx.json"

    dart format --output=none --set-exit-if-changed .
    flutter analyze
    flutter test

    if [[ "${PAKPERK_BUILD_MOBILE_ARTIFACTS:-1}" == "1" ]]; then
      for flavor in dev staging prod; do
        flutter build apk --debug --flavor "$flavor" \
          --dart-define-from-file="config/$flavor.json"
      done
      dart run tool/verify_strict_artifact_assets.dart \
        build/app/outputs/flutter-apk/app-staging-debug.apk
      dart run tool/verify_strict_artifact_assets.dart \
        build/app/outputs/flutter-apk/app-prod-debug.apk

      if [[ "$(uname -s)" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then
        for flavor in dev staging prod; do
          flutter build ios --simulator --debug --flavor "$flavor" \
            --dart-define-from-file="config/$flavor.json"
        done
      else
        echo "iOS simulator flavor builds skipped: they require macOS and Xcode." >&2
      fi
    else
      echo "Mobile artifact builds skipped by PAKPERK_BUILD_MOBILE_ARTIFACTS=0." >&2
    fi

    if [[ "${PAKPERK_RUN_DEVICE_INTEGRATION_TESTS:-0}" == "1" ]]; then
      flutter test integration_test/demo_flows_test.dart
    else
      echo "Device integration tests skipped; set PAKPERK_RUN_DEVICE_INTEGRATION_TESTS=1 with a target device." >&2
    fi
  )
else
  echo "Flutter checks skipped: install the pinned Flutter SDK to run them." >&2
fi

if command -v npm >/dev/null 2>&1; then
  echo "== Public site =="
  if command -v "$helm_bin" >/dev/null 2>&1; then
    rendered_site_manifest="$temporary_dir/rendered-site.yaml"
    "$helm_bin" template pakperk "$project_dir/deploy/helm/pakperk" \
      --values "$project_dir/deploy/helm/pakperk/ci/staging-values.yaml" \
      >"$rendered_site_manifest"
    (
      cd "$project_dir/site"
      npm ci --ignore-scripts
      PAKPERK_RENDERED_SITE_MANIFEST="$rendered_site_manifest" npm test
    )
  else
    (
      cd "$project_dir/site"
      npm ci --ignore-scripts
      npm test
    )
    echo "Rendered site/CSP assertion skipped: set HELM_BIN to a Helm 3.18.x binary." >&2
  fi
else
  echo "Public-site tests skipped: npm is not installed." >&2
fi

if command -v "$helm_bin" >/dev/null 2>&1; then
  echo "== Helm deployment contract =="
  HELM_BIN="$helm_bin" "$project_dir/scripts/validate_helm_release.sh"
  if [[ "${PAKPERK_RUN_CONTAINER_TESTS:-0}" == "1" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      echo "PAKPERK_RUN_CONTAINER_TESTS=1 requires Docker." >&2
      exit 2
    fi
    HELM_BIN="$helm_bin" "$project_dir/scripts/test_backend_log_export.sh"
  else
    echo "Collector container E2E skipped; set PAKPERK_RUN_CONTAINER_TESTS=1 to run it." >&2
  fi
else
  echo "Helm checks skipped: set HELM_BIN to a Helm 3.18.x binary." >&2
fi

echo "All available Pakperk checks passed. Review every explicit skip above before release."
