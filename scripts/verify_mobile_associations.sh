#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: PAKPERK_RELEASE_ENV=staging|production PAKPERK_ANDROID_PACKAGE=... PAKPERK_ANDROID_SHA256=... PAKPERK_APPLE_TEAM_ID=... PAKPERK_APPLE_BUNDLE_ID=... $0 assetlinks.json apple-app-site-association"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

assetlinks_file="$1"
apple_file="$2"
release_environment="${PAKPERK_RELEASE_ENV:?PAKPERK_RELEASE_ENV is required}"
android_package="${PAKPERK_ANDROID_PACKAGE:?PAKPERK_ANDROID_PACKAGE is required}"
android_fingerprint="${PAKPERK_ANDROID_SHA256:?PAKPERK_ANDROID_SHA256 is required}"
apple_team_id="${PAKPERK_APPLE_TEAM_ID:?PAKPERK_APPLE_TEAM_ID is required}"
apple_bundle_id="${PAKPERK_APPLE_BUNDLE_ID:?PAKPERK_APPLE_BUNDLE_ID is required}"

case "$release_environment" in
  production) expected_id="app.pakperk.pakperk" ;;
  staging) expected_id="app.pakperk.pakperk.staging" ;;
  *) echo "PAKPERK_RELEASE_ENV must be staging or production" >&2; exit 2 ;;
esac

if [[ "$android_package" != "$expected_id" || "$apple_bundle_id" != "$expected_id" ]]; then
  echo "signed application identifiers do not match the release environment" >&2
  exit 1
fi
if ! [[ "$android_fingerprint" =~ ^([A-F0-9]{2}:){31}[A-F0-9]{2}$ ]]; then
  echo "PAKPERK_ANDROID_SHA256 must be an uppercase colon-delimited SHA-256 fingerprint" >&2
  exit 1
fi
if ! [[ "$apple_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "PAKPERK_APPLE_TEAM_ID must be a ten-character Apple team identifier" >&2
  exit 1
fi

for document in "$assetlinks_file" "$apple_file"; do
  if [[ ! -f "$document" || -L "$document" ]]; then
    echo "association input must be a non-symlink regular file: $document" >&2
    exit 1
  fi
  if (( $(wc -c <"$document") > 65536 )); then
    echo "association input exceeds 64 KiB: $document" >&2
    exit 1
  fi
  jq empty "$document"
done

jq -e \
  --arg package "$android_package" \
  --arg fingerprint "$android_fingerprint" '
    length == 1 and
    .[0].relation == ["delegate_permission/common.handle_all_urls"] and
    (.[0].target | keys | sort) == ["namespace", "package_name", "sha256_cert_fingerprints"] and
    .[0].target.namespace == "android_app" and
    .[0].target.package_name == $package and
    (.[0].target.sha256_cert_fingerprints | index($fingerprint)) != null and
    all(.[0].target.sha256_cert_fingerprints[]; test("^([A-F0-9]{2}:){31}[A-F0-9]{2}$"))
  ' "$assetlinks_file" >/dev/null

jq -e \
  --arg app_id "$apple_team_id.$apple_bundle_id" '
    (keys == ["applinks"]) and
    (.applinks | keys == ["details"]) and
    (.applinks.details | length == 1) and
    (.applinks.details[0] | keys | sort) == ["appIDs", "components"] and
    .applinks.details[0].appIDs == [$app_id] and
    .applinks.details[0].components == [{"/":"/p/*"},{"/":"/arxiv/*"}]
  ' "$apple_file" >/dev/null

printf '%s\n' "mobile association documents match the signed release identity"
