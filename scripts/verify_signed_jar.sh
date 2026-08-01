#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: $0 signed-archive.aab"
  exit 0
fi
if [[ $# -ne 1 ]]; then
  echo "usage: $0 signed-archive.aab" >&2
  exit 2
fi

archive="$1"
for command in jarsigner keytool python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Signed JAR verification requires $command." >&2
    exit 2
  fi
done
if [[ ! -f "$archive" || -L "$archive" || ! -s "$archive" ]]; then
  echo "Signed archive must be a non-symlink, non-empty regular file: $archive" >&2
  exit 1
fi

# One upload identity keeps the AAB/APK fingerprint comparison unambiguous.
# Every JAR signer contributes one top-level META-INF/*.SF signature file.
python3 - "$archive" <<'PY'
import pathlib
import re
import sys
import zipfile

artifact = pathlib.Path(sys.argv[1])
try:
    with zipfile.ZipFile(artifact) as archive:
        signature_files = [
            name
            for name in archive.namelist()
            if re.fullmatch(r"META-INF/[^/]+[.]SF", name, flags=re.IGNORECASE)
        ]
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit(f"Signed archive is not a readable ZIP/JAR: {error}") from error
if len(signature_files) != 1:
    raise SystemExit("Signed archive must contain exactly one JAR signer.")
PY

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-jar-signature.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

certificate_output="$temporary_dir/certificates.pem"
signer_certificate="$temporary_dir/signer.pem"
truststore="$temporary_dir/truststore.p12"
verification_output="$temporary_dir/jarsigner.txt"
truststore_password=pakperk-ephemeral-trust

if ! LC_ALL=C keytool -printcert -rfc -jarfile "$archive" >"$certificate_output" 2>/dev/null; then
  echo "Archive has no readable JAR signing certificate." >&2
  exit 1
fi
python3 - "$certificate_output" "$signer_certificate" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
certificates = re.findall(
    r"-----BEGIN CERTIFICATE-----\n.*?\n-----END CERTIFICATE-----",
    source,
    flags=re.DOTALL,
)
if not certificates:
    raise SystemExit("Archive has no JAR signer certificate.")
pathlib.Path(sys.argv[2]).write_text(certificates[0] + "\n", encoding="utf-8")
PY

# Android upload and app-signing certificates are commonly self-signed. Trust
# the extracted leaf only for this integrity pass; identity is proved separately
# by exact SHA-256 fingerprint parity between the AAB and APK.
keytool -importcert -noprompt -alias pakperk-artifact-signer \
  -file "$signer_certificate" -keystore "$truststore" -storetype PKCS12 \
  -storepass "$truststore_password" >/dev/null 2>&1
if ! LC_ALL=C jarsigner -verify -strict -verbose -certs \
  -keystore "$truststore" -storetype PKCS12 -storepass "$truststore_password" \
  "$archive" >"$verification_output" 2>&1; then
  cat "$verification_output" >&2
  echo "Archive failed strict JAR integrity/signature verification." >&2
  exit 1
fi
if ! grep -Fq 'jar verified.' "$verification_output" \
  || grep -Eiq 'jar is unsigned|unsigned entries|treated as unsigned|disabled algorithm' "$verification_output"; then
  cat "$verification_output" >&2
  echo "Archive is unsigned, partially signed, or uses a disabled signature." >&2
  exit 1
fi
if ! grep -Eq 'Digest algorithm: SHA-(256|384|512)' "$verification_output"; then
  echo "Archive does not use a modern SHA-2 content digest." >&2
  exit 1
fi
if ! grep -Eq 'Signature algorithm: (SHA(256|384|512)with(RSA|ECDSA|DSA)|Ed25519|Ed448)' "$verification_output"; then
  echo "Archive does not use an accepted modern signature algorithm." >&2
  exit 1
fi

printf 'android_aab_jar_signature=verified\n'
