#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: verify_public_edge.sh SITE_ORIGIN API_ORIGIN TELEMETRY_ORIGIN

Verifies exact HTTP-to-HTTPS redirects and the closed Pakperk HSTS header on
the public site, API readiness endpoint, and telemetry readiness endpoint.
Origins must be credential-free HTTPS origins without paths, queries, or
fragments. Run this against the exact staging/production release hosts.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "$#" -ne 3 ]]; then
  usage >&2
  exit 2
fi
for command in curl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "verify_public_edge.sh requires $command." >&2
    exit 2
  fi
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-public-edge.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

python3 - "$@" <<'PY'
import sys
import urllib.parse

for origin in sys.argv[1:]:
    parsed = urllib.parse.urlsplit(origin)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
        or parsed.port not in (None, 443)
        or origin != f"https://{parsed.hostname}"
    ):
        raise SystemExit(f"not an exact credential-free HTTPS origin: {origin!r}")
PY

origins=("$1" "$2" "$3")
paths=("/" "/health/ready" "/health/ready")
expected_hsts='max-age=63072000; includeSubDomains; preload'

for index in 0 1 2; do
  origin="${origins[$index]}"
  path="${paths[$index]}"
  host="${origin#https://}"
  secure_headers="$temporary_dir/secure-$index.headers"
  redirect_headers="$temporary_dir/redirect-$index.headers"

  curl --fail --silent --show-error --max-time 15 --proto '=https' \
    --tlsv1.2 --dump-header "$secure_headers" --output /dev/null "$origin$path"
  curl --silent --show-error --max-time 15 --proto '=http' \
    --dump-header "$redirect_headers" --output /dev/null "http://$host$path"

  python3 - "$secure_headers" "$redirect_headers" "$origin$path" "$expected_hsts" <<'PY'
import pathlib
import re
import sys

secure_path, redirect_path = map(pathlib.Path, sys.argv[1:3])
expected_location, expected_hsts = sys.argv[3:]

def parse(path):
    lines = path.read_text(encoding="iso-8859-1").splitlines()
    if not lines:
        raise SystemExit(f"empty response headers: {path}")
    status = re.fullmatch(r"HTTP/\S+ ([0-9]{3})(?: .*)?", lines[0])
    if status is None:
        raise SystemExit(f"invalid HTTP status line: {lines[0]!r}")
    headers = {}
    for line in lines[1:]:
        if not line:
            continue
        if ":" not in line:
            raise SystemExit(f"invalid response header: {line!r}")
        name, value = line.split(":", 1)
        headers.setdefault(name.lower(), []).append(value.strip())
    return int(status.group(1)), headers

secure_status, secure = parse(secure_path)
if secure_status < 200 or secure_status >= 300:
    raise SystemExit(f"HTTPS endpoint did not return 2xx: {secure_status}")
hsts = secure.get("strict-transport-security", [])
if hsts != [expected_hsts]:
    raise SystemExit(f"unexpected HSTS policy: {hsts!r}")

redirect_status, redirect = parse(redirect_path)
if redirect_status not in (301, 302, 307, 308):
    raise SystemExit(f"HTTP endpoint did not redirect: {redirect_status}")
locations = redirect.get("location", [])
if locations != [expected_location]:
    raise SystemExit(f"unexpected HTTPS redirect: {locations!r}")
PY
done

echo "Verified exact redirects and HSTS on all three Pakperk public origins."
