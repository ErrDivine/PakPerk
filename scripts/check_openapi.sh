#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_contract="$(mktemp "${TMPDIR:-/tmp}/pakperk-openapi-generated.XXXXXX")"
base_contract="$(mktemp "${TMPDIR:-/tmp}/pakperk-openapi-base.XXXXXX")"
trap 'rm -f "$generated_contract" "$base_contract"' EXIT

python3 -B "$project_dir/scripts/test_openapi_compatibility.py"
"$project_dir/scripts/generate_openapi.sh" >"$generated_contract"

if ! cmp -s "$project_dir/docs/openapi-v1.json" "$generated_contract"; then
  echo "docs/openapi-v1.json does not match the generated API contract." >&2
  diff -u "$project_dir/docs/openapi-v1.json" "$generated_contract" || true
  echo "Regenerate it with: ./scripts/generate_openapi.sh > docs/openapi-v1.json" >&2
  exit 1
fi

# CI supplies the pull-request base (or previous pushed commit). The first
# checked-in contract has no historical artifact, so absence is intentionally
# non-fatal; every later change is checked when the ref contains the artifact.
if [[ -n "${OPENAPI_BASE_REF:-}" ]] && \
  git -C "$project_dir" cat-file -e \
    "${OPENAPI_BASE_REF}:docs/openapi-v1.json" 2>/dev/null; then
  git -C "$project_dir" show \
    "${OPENAPI_BASE_REF}:docs/openapi-v1.json" >"$base_contract"
  python3 "$project_dir/scripts/check_openapi_compatibility.py" \
    "$base_contract" "$project_dir/docs/openapi-v1.json"
fi
