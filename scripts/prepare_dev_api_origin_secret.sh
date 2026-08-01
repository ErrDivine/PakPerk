#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_dir="${1:-$project_dir/.local/pakperk-secrets}"
target="$secret_dir/API_ORIGIN_HASH_SECRET"

command -v openssl >/dev/null 2>&1 || {
  echo "OpenSSL is required to generate the development API origin key." >&2
  exit 2
}
if [[ -L "$secret_dir" || -L "$target" ]]; then
  echo "Refusing a symlinked development API secret path." >&2
  exit 1
fi
install -d -m 0700 "$secret_dir"
umask 077
if [[ ! -e "$target" ]]; then
  openssl rand -base64 48 | tr -d '\r\n' >"$target"
  printf '\n' >>"$target"
fi
if [[ ! -f "$target" || ! -s "$target" ]]; then
  echo "Development API origin key is not a non-empty regular file." >&2
  exit 1
fi
chmod 0600 "$target"
printf 'Development API origin key is ready (value was not printed): %s\n' "$target"
