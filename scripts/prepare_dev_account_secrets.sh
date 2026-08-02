#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_dir="${1:-$project_dir/.local/pakperk-secrets}"
ledger_dir="${2:-$project_dir/.local/pakperk-deletion-ledger}"

"$project_dir/scripts/prepare_dev_api_origin_secret.sh" "$secret_dir"

for command in openssl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to prepare development account keyrings." >&2
    exit 2
  fi
done
for path in "$secret_dir" "$ledger_dir"; do
  if [[ -L "$path" ]]; then
    echo "Refusing a symlinked development account path: $path" >&2
    exit 1
  fi
  mkdir -p "$path"
  chmod 0700 "$path"
done

umask 077
generate_keyring() {
  local target="$1"
  local random_bytes="$2"
  local minimum_key_bytes="$3"
  local maximum_key_bytes="$4"
  local label="$5"
  if [[ -L "$target" ]]; then
    echo "Refusing a symlinked development keyring: $target" >&2
    exit 1
  fi
  if [[ ! -e "$target" ]]; then
    local key
    key="$(openssl rand -base64 "$random_bytes" | tr -d '\r\n')"
    printf 'dev-v1:%s\n' "$key" >"$target"
  fi
  if [[ ! -f "$target" || ! -s "$target" ]]; then
    echo "Development keyring is not a non-empty regular file: $target" >&2
    exit 1
  fi
  chmod 0600 "$target"
  if ! python3 "$project_dir/scripts/validate_account_keyring.py" \
    "$target" \
    --minimum-key-bytes "$minimum_key_bytes" \
    --maximum-key-bytes "$maximum_key_bytes"; then
    echo "The existing development $label keyring is invalid: $target" >&2
    echo "Keyrings are never overwritten; rotate it or move the invalid development file aside before retrying." >&2
    exit 1
  fi
}

generate_keyring "$secret_dir/ACCOUNT_IDENTITY_FINGERPRINT_KEYS" 48 32 128 \
  "identity-fingerprint"
generate_keyring "$secret_dir/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS" 48 32 128 \
  "ledger-signing"
generate_keyring "$secret_dir/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS" 32 32 32 \
  "provider-coordinate"

printf '%s\n' "Development account keyrings are ready (values were not printed)."
printf 'ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE=%s\n' \
  "$secret_dir/ACCOUNT_IDENTITY_FINGERPRINT_KEYS"
printf 'ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE=%s\n' \
  "$secret_dir/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS"
printf 'ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE=%s\n' \
  "$secret_dir/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS"
printf 'ACCOUNT_DELETION_LEDGER_DIRECTORY=%s\n' "$ledger_dir"
