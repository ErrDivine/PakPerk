#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$project_dir/scripts/verify_signed_jar.sh"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-signed-jar-test.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

for command in jarsigner keytool python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Signed JAR regression test requires $command." >&2
    exit 2
  fi
done

unsigned="$temporary_dir/unsigned.aab"
signed="$temporary_dir/signed.aab"
tampered="$temporary_dir/tampered.aab"
multiply_signed="$temporary_dir/multiply-signed.aab"
keystore="$temporary_dir/release.p12"
password=pakperk-test-password

python3 - "$unsigned" <<'PY'
import pathlib
import sys
import zipfile

with zipfile.ZipFile(pathlib.Path(sys.argv[1]), "w") as archive:
    archive.writestr("base/manifest/AndroidManifest.xml", b"fixture-manifest")
    archive.writestr("base/assets/fixture.txt", b"original")
PY
cp "$unsigned" "$signed"
keytool -genkeypair -noprompt -alias release -keyalg RSA -keysize 2048 \
  -sigalg SHA256withRSA -validity 365 -dname 'CN=PakPerk fixture' \
  -keystore "$keystore" -storetype PKCS12 -storepass "$password" \
  -keypass "$password" >/dev/null 2>&1
jarsigner -keystore "$keystore" -storetype PKCS12 -storepass "$password" \
  -keypass "$password" -sigalg SHA256withRSA -digestalg SHA-256 \
  "$signed" release >/dev/null
"$verifier" "$signed" >/dev/null

if "$verifier" "$unsigned" >/dev/null 2>&1; then
  echo "Unsigned AAB fixture unexpectedly passed signature verification." >&2
  exit 1
fi

python3 - "$signed" "$tampered" <<'PY'
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(source) as incoming, zipfile.ZipFile(destination, "w") as outgoing:
    for entry in incoming.infolist():
        payload = incoming.read(entry)
        if entry.filename == "base/assets/fixture.txt":
            payload = b"tampered"
        outgoing.writestr(entry, payload)
PY
if "$verifier" "$tampered" >/dev/null 2>&1; then
  echo "Tampered AAB fixture unexpectedly passed signature verification." >&2
  exit 1
fi

cp "$signed" "$multiply_signed"
keytool -genkeypair -noprompt -alias secondary -keyalg RSA -keysize 2048 \
  -sigalg SHA256withRSA -validity 365 -dname 'CN=PakPerk secondary fixture' \
  -keystore "$keystore" -storetype PKCS12 -storepass "$password" \
  -keypass "$password" >/dev/null 2>&1
jarsigner -keystore "$keystore" -storetype PKCS12 -storepass "$password" \
  -keypass "$password" -sigalg SHA256withRSA -digestalg SHA-256 \
  "$multiply_signed" secondary >/dev/null
if "$verifier" "$multiply_signed" >/dev/null 2>&1; then
  echo "Multiply signed AAB fixture unexpectedly passed signature verification." >&2
  exit 1
fi

echo "Signed JAR verifier accepted one valid self-signed artifact and rejected unsigned, tampered, and multiply signed fixtures."
