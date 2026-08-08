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
python3 "$project_dir/scripts/test_validate_shell_syntax.py"
python3 "$project_dir/scripts/validate_shell_syntax.py"
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
python3 "$project_dir/scripts/test_validate_dependency_automation.py"
python3 "$project_dir/scripts/validate_dependency_automation.py"
python3 "$project_dir/scripts/test_validate_release_image_workflow.py"
python3 "$project_dir/scripts/validate_release_image_workflow.py"
python3 "$project_dir/scripts/validate_external_image_scan_pins.py"
python3 "$project_dir/scripts/test_validate_external_image_scan_pins.py"
python3 "$project_dir/scripts/validate_metadata_sync_boundary.py"
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
python3 "$project_dir/scripts/test_validate_keycloak_realm.py"
"$project_dir/scripts/validate_keycloak_realm.sh"
"$project_dir/scripts/test_live_account_deletion.sh" --self-test
python3 "$project_dir/scripts/test_backend_load.py"
"$project_dir/scripts/verify_mobile_associations.sh" --help >/dev/null
"$project_dir/scripts/verify_public_edge.sh" --help >/dev/null
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
python3 "$project_dir/scripts/test_validate_android_native_sbom.py"
python3 "$project_dir/scripts/test_validate_gradle_verification.py"
python3 "$project_dir/scripts/validate_gradle_verification.py"
python3 "$project_dir/scripts/test_validate_fastlane_lock.py"
python3 "$project_dir/scripts/validate_fastlane_lock.py"
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$project_dir/scripts/manage_app_store_phased_release.rb"
  ruby "$project_dir/scripts/test_manage_app_store_phased_release.rb"
  ruby -c "$project_dir/scripts/manage_google_play_rollout.rb"
  ruby "$project_dir/scripts/test_manage_google_play_rollout.rb"
else
  echo "Store rollout API-client Ruby tests skipped: ruby is unavailable." >&2
fi
python3 "$project_dir/scripts/test_validate_flutter_toolchain.py"
python3 "$project_dir/scripts/test_validate_mobile_release_workflow.py"
python3 "$project_dir/scripts/validate_mobile_release_workflow.py"
python3 "$project_dir/scripts/test_materialize_mobile_release_secret.py"
python3 "$project_dir/scripts/materialize_mobile_release_secret.py" --help >/dev/null
python3 "$project_dir/scripts/test_validate_mobile_store_client.py"
python3 "$project_dir/scripts/validate_mobile_store_client.py" --help >/dev/null
python3 "$project_dir/scripts/test_capture_mobile_credentialed_runtime.py"
python3 "$project_dir/scripts/capture_mobile_credentialed_runtime.py" --help >/dev/null
python3 "$project_dir/scripts/test_extract_mobile_store_client.py"
python3 "$project_dir/scripts/extract_mobile_store_client.py" --help >/dev/null
python3 "$project_dir/scripts/test_prepare_mobile_credentialed_upload.py"
python3 -I "$project_dir/scripts/prepare_mobile_credentialed_upload.py" --help >/dev/null
bash -n "$project_dir/scripts/prepare_mobile_store_client.sh"
python3 "$project_dir/scripts/test_assemble_mobile_signed_candidate.py"
python3 -I "$project_dir/scripts/assemble_mobile_signed_candidate.py" --help >/dev/null
python3 "$project_dir/scripts/test_validate_mobile_signed_release_run.py"
python3 "$project_dir/scripts/validate_mobile_signed_release_run.py" --help >/dev/null
python3 "$project_dir/scripts/test_validate_mobile_store_candidate.py"
python3 "$project_dir/scripts/validate_mobile_store_candidate.py" --help >/dev/null
python3 "$project_dir/scripts/test_generate_mobile_store_upload_attempt.py"
python3 "$project_dir/scripts/generate_mobile_store_upload_attempt.py" --help >/dev/null
python3 "$project_dir/scripts/test_generate_mobile_store_upload_outcome.py"
python3 "$project_dir/scripts/generate_mobile_store_upload_outcome.py" --help >/dev/null
python3 "$project_dir/scripts/test_generate_mobile_store_upload_handoff.py"
python3 "$project_dir/scripts/generate_mobile_store_upload_handoff.py" --help >/dev/null
python3 "$project_dir/scripts/test_finalize_mobile_signed_release.py"
python3 -I "$project_dir/scripts/finalize_mobile_signed_release.py" --help >/dev/null
python3 "$project_dir/scripts/test_generate_mobile_store_rollout_receipt.py"
python3 "$project_dir/scripts/test_validate_mobile_store_rollout_workflow.py"
python3 "$project_dir/scripts/validate_mobile_store_rollout_workflow.py"
python3 "$project_dir/scripts/test_validate_mobile_device_workflow.py"
python3 "$project_dir/scripts/validate_mobile_device_workflow.py"
python3 "$project_dir/scripts/test_validate_mobile_acceptance_evidence.py"
python3 "$project_dir/scripts/test_validate_mobile_acceptance_workflow.py"
python3 "$project_dir/scripts/validate_mobile_acceptance_workflow.py"
python3 "$project_dir/scripts/test_validate_live_account_deletion_workflow.py"
python3 "$project_dir/scripts/validate_live_account_deletion_workflow.py"
python3 "$project_dir/scripts/test_live_comments_evidence.py"
python3 "$project_dir/scripts/test_validate_live_comments_workflow.py"
python3 "$project_dir/scripts/validate_live_comments_workflow.py"
python3 "$project_dir/scripts/test_validate_staging_backend_load_workflow.py"
python3 "$project_dir/scripts/validate_staging_backend_load_workflow.py"
python3 "$project_dir/scripts/test_public_edge_evidence.py"
python3 "$project_dir/scripts/test_verify_public_edge.py"
python3 "$project_dir/scripts/test_validate_public_edge_workflow.py"
python3 "$project_dir/scripts/validate_public_edge_workflow.py"
python3 "$project_dir/scripts/test_validate_alert_policy.py"
python3 "$project_dir/scripts/validate_alert_policy.py"

if command -v flutter >/dev/null 2>&1; then
  echo "== Flutter =="
  (
    cd "$project_dir/mobile"
    flutter --no-version-check --version --machine >"$temporary_dir/flutter-toolchain.json"
    python3 "$project_dir/scripts/validate_flutter_toolchain.py" \
      "$temporary_dir/flutter-toolchain.json"
    flutter --no-version-check pub get --enforce-lockfile

    echo "== Release metadata =="
    source_revision="$(git -C "$project_dir" rev-parse HEAD)"
    source_epoch="$(git -C "$project_dir" show -s --format=%ct HEAD)"
    SOURCE_REVISION="$source_revision" SOURCE_DATE_EPOCH="$source_epoch" \
      "$project_dir/scripts/generate_release_metadata.py" \
      --flutter-sdk-version 3.44.8 \
      --output-dir "$temporary_dir/metadata-a"
    SOURCE_REVISION="$source_revision" SOURCE_DATE_EPOCH="$source_epoch" \
      "$project_dir/scripts/generate_release_metadata.py" \
      --flutter-sdk-version 3.44.8 \
      --output-dir "$temporary_dir/metadata-b"
    cmp "$temporary_dir/metadata-a/open-source-notices.txt" \
      "$temporary_dir/metadata-b/open-source-notices.txt"
    cmp "$temporary_dir/metadata-a/dependencies.cdx.json" \
      "$temporary_dir/metadata-b/dependencies.cdx.json"

    dart format --output=none --set-exit-if-changed .
    flutter --no-version-check analyze
    flutter --no-version-check test

    if [[ "${PAKPERK_BUILD_MOBILE_ARTIFACTS:-1}" == "1" ]]; then
      for flavor in dev staging prod; do
        flutter --no-version-check build apk --debug --flavor "$flavor" \
          --dart-define-from-file="config/$flavor.json"
      done
      dart run tool/verify_strict_artifact_assets.dart \
        build/app/outputs/flutter-apk/app-staging-debug.apk
      dart run tool/verify_strict_artifact_assets.dart \
        build/app/outputs/flutter-apk/app-prod-debug.apk

      if [[ "$(uname -s)" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then
        for flavor in dev staging prod; do
          flutter --no-version-check build ios --simulator --debug --flavor "$flavor" \
            --dart-define-from-file="config/$flavor.json"
        done
        dart run tool/verify_strict_artifact_assets.dart \
          build/ios/iphonesimulator/Runner.app
      else
        echo "iOS simulator flavor builds skipped: they require macOS and Xcode." >&2
      fi
    else
      echo "Mobile artifact builds skipped by PAKPERK_BUILD_MOBILE_ARTIFACTS=0." >&2
    fi

    if [[ -n "${PAKPERK_MOBILE_DEVICE_ID:-}" ]]; then
      if ! [[ "$PAKPERK_MOBILE_DEVICE_ID" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
        echo "PAKPERK_MOBILE_DEVICE_ID contains unsupported characters." >&2
        exit 2
      fi
      flutter --no-version-check test integration_test/production_verification_test.dart \
        --profile -d "$PAKPERK_MOBILE_DEVICE_ID"
    else
      echo "Physical-device verification NOT RUN. The deterministic production harness ran headlessly in flutter test; set PAKPERK_MOBILE_DEVICE_ID or dispatch mobile-device-integration for the device probe." >&2
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
