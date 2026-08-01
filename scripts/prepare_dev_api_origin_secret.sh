#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_dir="${1:-$project_dir/.local/pakperk-secrets}"
origin_target="$secret_dir/API_ORIGIN_HASH_SECRET"
cursor_target="$secret_dir/API_CURSOR_ENCRYPTION_KEYS"

command -v openssl >/dev/null 2>&1 || {
  echo "OpenSSL is required to generate the development API origin key." >&2
  exit 2
}
if [[ -L "$secret_dir" || -L "$origin_target" || -L "$cursor_target" ]]; then
  echo "Refusing a symlinked development API secret path." >&2
  exit 1
fi
install -d -m 0700 "$secret_dir"
umask 077
if [[ ! -e "$origin_target" ]]; then
  openssl rand -base64 48 | tr -d '\r\n' >"$origin_target"
  printf '\n' >>"$origin_target"
fi
if [[ ! -e "$cursor_target" ]]; then
  printf 'cursor_1:' >"$cursor_target"
  openssl rand -base64 32 | tr -d '\r\n' >>"$cursor_target"
  printf '\n' >>"$cursor_target"
fi
if [[ ! -f "$origin_target" || ! -s "$origin_target" ]]; then
  echo "Development API origin key is not a non-empty regular file." >&2
  exit 1
fi
if [[ ! -f "$cursor_target" || ! -s "$cursor_target" ]]; then
  echo "Development API cursor keyring is not a non-empty regular file." >&2
  exit 1
fi
chmod 0600 "$origin_target" "$cursor_target"
printf 'Development API origin key is ready (value was not printed): %s\n' "$origin_target"
printf 'Development API cursor keyring is ready (values were not printed): %s\n' "$cursor_target"
