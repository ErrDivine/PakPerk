#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata_dir="${1:-$project_dir/release/metadata}"
output_dir="$project_dir/release/site"
notices="$metadata_dir/open-source-notices.txt"

if [[ ! -f "$notices" ]]; then
  echo "Missing generated notices: $notices" >&2
  exit 1
fi
if grep -Eiq 'placeholder|must replace|not the release inventory' "$notices"; then
  echo "Refusing to package placeholder open-source notices." >&2
  exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-release-site.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
install -d "$temporary_dir/assets" "$temporary_dir/account-deletion" \
  "$temporary_dir/community-guidelines" "$temporary_dir/open-source-licenses" \
  "$temporary_dir/privacy" "$temporary_dir/support" "$temporary_dir/terms"
install -m 0644 "$project_dir/site/index.html" "$project_dir/site/404.html" "$temporary_dir/"
install -m 0644 "$project_dir/site/assets/site.css" "$project_dir/site/assets/site.js" \
  "$project_dir/site/assets/account-deletion.js" "$temporary_dir/assets/"
install -m 0644 "$project_dir/site/account-deletion/index.html" "$temporary_dir/account-deletion/"
install -m 0644 "$project_dir/site/community-guidelines/index.html" "$temporary_dir/community-guidelines/"
install -m 0644 "$project_dir/site/open-source-licenses/index.html" "$temporary_dir/open-source-licenses/"
install -m 0644 "$notices" "$temporary_dir/open-source-licenses/notices.txt"
install -m 0644 "$project_dir/site/privacy/index.html" "$temporary_dir/privacy/"
install -m 0644 "$project_dir/site/support/index.html" "$temporary_dir/support/"
install -m 0644 "$project_dir/site/terms/index.html" "$temporary_dir/terms/"

install -d "$project_dir/release"
rm -rf "$output_dir"
mv "$temporary_dir" "$output_dir"
trap - EXIT
echo "Prepared curated release site at $output_dir"
