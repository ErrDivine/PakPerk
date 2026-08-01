#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_contract="$(mktemp "${TMPDIR:-/tmp}/pakperk-openapi-generated.XXXXXX")"
trap 'rm -f "$generated_contract"' EXIT

if [[ "${CI:-}" == "true" && -z "${OPENAPI_BASE_REF:-}" ]]; then
  echo "CI must supply OPENAPI_BASE_REF; compatibility was not checked." >&2
  exit 2
fi

python3 -B "$project_dir/scripts/test_openapi_compatibility.py"
"$project_dir/scripts/generate_openapi.sh" >"$generated_contract"

if ! cmp -s "$project_dir/docs/openapi-v1.json" "$generated_contract"; then
  echo "docs/openapi-v1.json does not match the generated API contract." >&2
  diff -u "$project_dir/docs/openapi-v1.json" "$generated_contract" || true
  echo "Regenerate it with: ./scripts/generate_openapi.sh > docs/openapi-v1.json" >&2
  exit 1
fi

# CI supplies the pull-request base (or previous pushed commit). Once supplied,
# the base revision and its contract are mandatory: a missing/shallow/zero base
# must fail instead of silently skipping compatibility verification.
if [[ -n "${OPENAPI_BASE_REF:-}" ]]; then
  python3 "$project_dir/scripts/check_openapi_compatibility.py" \
    --git-base "$project_dir" "$OPENAPI_BASE_REF" docs/openapi-v1.json \
    "$project_dir/docs/openapi-v1.json"
fi
