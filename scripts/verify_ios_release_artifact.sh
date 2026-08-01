#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: $0 app.ipa expected-bundle-id expected-version expected-build expected-oidc-scheme expected-app-link-host-or-dash"
  exit 0
fi
if [[ $# -ne 6 ]]; then
  echo "usage: $0 app.ipa expected-bundle-id expected-version expected-build expected-oidc-scheme expected-app-link-host-or-dash" >&2
  exit 2
fi

ipa="$1"
expected_bundle_id="$2"
expected_version="$3"
expected_build="$4"
expected_oidc_scheme="$5"
expected_app_link_host="$6"
plist_buddy=/usr/libexec/PlistBuddy
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_privacy_manifest="$project_dir/mobile/ios/Runner/PrivacyInfo.xcprivacy"

for command in assetutil codesign plutil python3 security unzip; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "iOS release verification requires macOS tool: $command" >&2
    exit 2
  fi
done
if [[ ! -x "$plist_buddy" ]]; then
  echo "iOS release verification requires $plist_buddy." >&2
  exit 2
fi
if [[ ! -f "$ipa" || -L "$ipa" || ! -s "$ipa" ]]; then
  echo "IPA must be a non-symlink, non-empty regular file: $ipa" >&2
  exit 1
fi
if [[ ! -f "$source_privacy_manifest" || -L "$source_privacy_manifest" || ! -s "$source_privacy_manifest" ]]; then
  echo "Checked-in app privacy manifest is missing or invalid: $source_privacy_manifest" >&2
  exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-ios-release.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM
verified_ipa="$temporary_dir/candidate.ipa"
apple_ipa_sha256="$(python3 - "$ipa" "$verified_ipa" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
artifact = pathlib.Path(sys.argv[2])
metadata = os.lstat(source)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 1
    or metadata.st_size <= 0
    or metadata.st_size > 8 * 1024**3
):
    raise SystemExit("IPA must be one bounded regular file")
source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
destination_descriptor = os.open(
    artifact,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
    0o400,
)
digest = hashlib.sha256()
try:
    before = os.fstat(source_descriptor)
    while True:
        chunk = os.read(source_descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        remaining = memoryview(chunk)
        while remaining:
            written = os.write(destination_descriptor, remaining)
            if written <= 0:
                raise SystemExit("IPA snapshot write did not make progress")
            remaining = remaining[written:]
    os.fsync(destination_descriptor)
    after = os.fstat(source_descriptor)
    retained = os.fstat(destination_descriptor)
finally:
    os.close(destination_descriptor)
    os.close(source_descriptor)
identity = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
)
if identity(metadata) != identity(before) or identity(before) != identity(after):
    raise SystemExit("IPA changed while its verification snapshot was created")
if not stat.S_ISREG(retained.st_mode) or retained.st_nlink != 1 or retained.st_size != before.st_size:
    raise SystemExit("IPA verification snapshot is incomplete")
try:
    with zipfile.ZipFile(artifact) as archive:
        entries = archive.infolist()
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit(f"IPA is not a readable ZIP archive: {error}") from error
if len(entries) > 200_000 or sum(entry.file_size for entry in entries) > 8 * 1024**3:
    raise SystemExit("IPA archive exceeds the bounded extraction budget")
normalized_names = set()
for entry in entries:
    name = entry.filename
    parts = pathlib.PurePosixPath(name).parts
    if (
        not name
        or name.startswith(("/", "./"))
        or "\\" in name
        or ".." in parts
        or stat.S_ISLNK(entry.external_attr >> 16)
    ):
        raise SystemExit(f"IPA contains an unsafe archive entry: {name!r}")
    normalized = name.rstrip("/").casefold()
    if normalized in normalized_names:
        raise SystemExit(f"IPA contains a duplicate archive entry: {name!r}")
    normalized_names.add(normalized)
manifests = [
    entry
    for entry in entries
    if re.fullmatch(r"Payload/[^/]+\.app/PrivacyInfo\.xcprivacy", entry.filename)
]
if len(manifests) != 1:
    raise SystemExit("IPA must contain exactly one app-level PrivacyInfo.xcprivacy")
mode = manifests[0].external_attr >> 16
if manifests[0].file_size == 0 or stat.S_ISLNK(mode):
    raise SystemExit("IPA app privacy manifest must be non-empty and not a symlink")
print(digest.hexdigest())
PY
)"
if ! [[ "$apple_ipa_sha256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Could not derive the verified IPA SHA-256 digest." >&2
  exit 1
fi
unzip -q "$verified_ipa" -d "$temporary_dir/unpacked"

apps=("$temporary_dir"/unpacked/Payload/*.app)
if [[ ${#apps[@]} -ne 1 || ! -d "${apps[0]}" ]]; then
  echo "IPA must contain exactly one Payload application." >&2
  exit 1
fi
app="${apps[0]}"
info_plist="$app/Info.plist"
profile="$app/embedded.mobileprovision"
asset_catalog="$app/Assets.car"
privacy_manifest="$app/PrivacyInfo.xcprivacy"
if [[ ! -f "$info_plist" || ! -f "$profile" || ! -f "$asset_catalog" \
  || ! -f "$privacy_manifest" || -L "$privacy_manifest" || ! -s "$privacy_manifest" ]]; then
  echo "IPA is missing Info.plist, its embedded provisioning profile, Assets.car, or the app privacy manifest." >&2
  exit 1
fi
plutil -lint "$privacy_manifest" >/dev/null

codesign --verify --deep --strict --verbose=2 "$app"
certificate_prefix="$temporary_dir/signing-certificate-"
codesign -d --extract-certificates "$certificate_prefix" "$app"
leaf_certificate="${certificate_prefix}0"
apple_signer_sha256="$(python3 - "$leaf_certificate" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
metadata = os.lstat(path)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 1
    or metadata.st_size <= 0
    or metadata.st_size > 1024 * 1024
):
    raise SystemExit("codesign did not emit one bounded leaf certificate")
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    data = bytearray()
    while True:
        chunk = os.read(descriptor, 64 * 1024)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 1024 * 1024:
            raise SystemExit("codesign leaf certificate exceeded its read budget")
    after = os.fstat(descriptor)
finally:
    os.close(descriptor)
identity = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
)
if identity(metadata) != identity(before) or identity(before) != identity(after):
    raise SystemExit("codesign leaf certificate changed while it was read")
print(hashlib.sha256(data).hexdigest())
PY
)"
if ! [[ "$apple_signer_sha256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Could not derive the signed IPA leaf-certificate SHA-256 fingerprint." >&2
  exit 1
fi
bundle_id="$($plist_buddy -c 'Print :CFBundleIdentifier' "$info_plist")"
version="$($plist_buddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$($plist_buddy -c 'Print :CFBundleVersion' "$info_plist")"
xcode_version="$($plist_buddy -c 'Print :DTXcode' "$info_plist")"
xcode_build="$($plist_buddy -c 'Print :DTXcodeBuild' "$info_plist")"
sdk_name="$($plist_buddy -c 'Print :DTSDKName' "$info_plist")"
sdk_build="$($plist_buddy -c 'Print :DTSDKBuild' "$info_plist")"
platform_version="$($plist_buddy -c 'Print :DTPlatformVersion' "$info_plist")"
minimum_os="$($plist_buddy -c 'Print :MinimumOSVersion' "$info_plist")"
if [[ "$bundle_id" != "$expected_bundle_id" || "$version" != "$expected_version" || "$build" != "$expected_build" ]]; then
  echo "Signed IPA identity/version mismatch: bundle=$bundle_id version=$version+$build" >&2
  exit 1
fi

security cms -D -i "$profile" >"$temporary_dir/profile.plist"
team_id="$($plist_buddy -c 'Print :TeamIdentifier:0' "$temporary_dir/profile.plist")"
profile_app_id="$($plist_buddy -c 'Print :Entitlements:application-identifier' "$temporary_dir/profile.plist")"
if ! [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || [[ "$profile_app_id" != "$team_id.$bundle_id" ]]; then
  echo "Provisioning profile does not exactly authorize the signed bundle identity." >&2
  exit 1
fi

codesign -d --entitlements :- "$app" >"$temporary_dir/entitlements.plist" 2>"$temporary_dir/codesign.txt"
signed_app_id="$($plist_buddy -c 'Print :application-identifier' "$temporary_dir/entitlements.plist")"
signed_team_id="$($plist_buddy -c 'Print :com.apple.developer.team-identifier' "$temporary_dir/entitlements.plist")"
if [[ "$signed_app_id" != "$team_id.$bundle_id" || "$signed_team_id" != "$team_id" ]]; then
  echo "Code-signing entitlements do not match the provisioning profile and bundle." >&2
  exit 1
fi
python3 - "$info_plist" "$temporary_dir/entitlements.plist" "$temporary_dir/profile.plist" \
  "$privacy_manifest" "$source_privacy_manifest" "$expected_oidc_scheme" \
  "$expected_app_link_host" "$apple_signer_sha256" <<'PY'
import datetime
import fnmatch
import hashlib
import pathlib
import plistlib
import re
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    info = plistlib.load(handle)
with pathlib.Path(sys.argv[2]).open("rb") as handle:
    entitlements = plistlib.load(handle)
with pathlib.Path(sys.argv[3]).open("rb") as handle:
    profile = plistlib.load(handle)
with pathlib.Path(sys.argv[4]).open("rb") as handle:
    privacy = plistlib.load(handle)
with pathlib.Path(sys.argv[5]).open("rb") as handle:
    source_privacy = plistlib.load(handle)


def version_tuple(value):
    match = re.fullmatch(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(value))
    if match is None:
        raise SystemExit(f"invalid Apple version metadata: {value!r}")
    return tuple(int(component or 0) for component in match.groups())


if info.get("DTPlatformName") != "iphoneos":
    raise SystemExit("signed IPA must target the iphoneos platform")
xcode = str(info.get("DTXcode", ""))
if not re.fullmatch(r"\d{4,}", xcode) or int(xcode) < 2600:
    raise SystemExit("signed IPA must be built with Xcode 26 or later")
sdk_match = re.fullmatch(r"iphoneos(\d+)(?:\.\d+)?", str(info.get("DTSDKName", "")))
if sdk_match is None or int(sdk_match.group(1)) < 26:
    raise SystemExit("signed IPA must be built with the iOS 26 SDK or later")
if version_tuple(info.get("MinimumOSVersion", "")) != (15, 0, 0):
    raise SystemExit("signed IPA deployment target must be exactly iOS 15.0")

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime.datetime):
    raise SystemExit("provisioning profile has no valid expiration date")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit("provisioning profile is expired")

profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    raise SystemExit("provisioning profile has no entitlement dictionary")
if profile_entitlements.get("get-task-allow", False) is not False:
    raise SystemExit("provisioning profile enables get-task-allow")
if entitlements.get("get-task-allow", False) is not False:
    raise SystemExit("signed app enables get-task-allow")
if profile.get("ProvisionsAllDevices") is True or profile.get("ProvisionedDevices"):
    raise SystemExit("signed IPA must use an App Store provisioning profile")
developer_certificates = profile.get("DeveloperCertificates")
if (
    not isinstance(developer_certificates, list)
    or not 1 <= len(developer_certificates) <= 32
    or any(
        not isinstance(certificate, bytes)
        or not 1 <= len(certificate) <= 1024 * 1024
        for certificate in developer_certificates
    )
):
    raise SystemExit("provisioning profile has no bounded authorized certificates")
authorized_signer_digests = {
    hashlib.sha256(certificate).hexdigest()
    for certificate in developer_certificates
}
if sys.argv[8] not in authorized_signer_digests:
    raise SystemExit(
        "signed IPA leaf certificate is not authorized by the provisioning profile"
    )
for application_id in (
    profile_entitlements.get("application-identifier", ""),
    entitlements.get("application-identifier", ""),
):
    if not application_id or "*" in application_id:
        raise SystemExit("application-identifier must be exact and non-wildcard")


def value_allowed(allowed, actual):
    if isinstance(actual, dict):
        return isinstance(allowed, dict) and all(
            key in allowed and value_allowed(allowed[key], value)
            for key, value in actual.items()
        )
    if isinstance(actual, list):
        return isinstance(allowed, list) and all(
            any(value_allowed(candidate, value) for candidate in allowed)
            for value in actual
        )
    if isinstance(actual, str) and isinstance(allowed, str) and "*" in allowed:
        return fnmatch.fnmatchcase(actual, allowed)
    return allowed == actual


for key, value in entitlements.items():
    if key not in profile_entitlements or not value_allowed(
        profile_entitlements[key], value
    ):
        raise SystemExit(f"signed entitlement is not authorized by profile: {key}")

if privacy != source_privacy:
    raise SystemExit("packaged app privacy manifest differs from checked-in source")
if privacy.get("NSPrivacyTracking") is not False:
    raise SystemExit("packaged app privacy manifest must declare tracking false")
schemes = sorted(
    scheme
    for entry in info.get("CFBundleURLTypes", [])
    for scheme in entry.get("CFBundleURLSchemes", [])
)
if schemes != sorted(["pakperk", sys.argv[6]]):
    raise SystemExit("signed IPA has unexpected paper or OIDC callback schemes")
domains = entitlements.get("com.apple.developer.associated-domains", [])
expected_domains = [] if sys.argv[7] == "-" else [f"applinks:{sys.argv[7]}"]
if domains != expected_domains:
    raise SystemExit("signed IPA has unexpected associated-domain entitlements")
transport_security = info.get("NSAppTransportSecurity")
if sys.argv[7] == "-":
    expected_transport_security = {
        "NSExceptionDomains": {
            "localhost": {"NSExceptionAllowsInsecureHTTPLoads": True}
        }
    }
    if transport_security != expected_transport_security:
        raise SystemExit("development IPA has an unexpected transport exception")
elif transport_security not in (None, {}):
    raise SystemExit("staging/production IPA must not contain ATS exceptions")
print(f"apple_profile_expiration={expiration.isoformat()}")
PY
assetutil --info "$asset_catalog" >"$temporary_dir/assets.json"
python3 - "$app" "$temporary_dir/assets.json" <<'PY'
import hashlib
import json
import pathlib
import sys

app = pathlib.Path(sys.argv[1])
assets = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
default_flutter_png_hashes = {
    "19be171481dc71a0b2803ebcd01dd8b0c5fd5778dee34c0a3cabc948c225f24e",
    "41c7d42f6e61f8fe7f30b1ffa2256aecbc9682be06d18c4a3062043e1a2e547c",
}
for name in ("AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"):
    launcher = app / name
    if not launcher.is_file() or launcher.is_symlink() or launcher.stat().st_size == 0:
        raise SystemExit(f"signed IPA is missing packaged launcher asset {name}")
    digest = hashlib.sha256(launcher.read_bytes()).hexdigest()
    if digest in default_flutter_png_hashes:
        raise SystemExit(f"signed IPA contains the stock Flutter launcher asset {name}")

icon_renditions = [
    entry
    for entry in assets
    if entry.get("AssetType") == "Icon Image" and entry.get("Name") == "AppIcon"
]
if not icon_renditions:
    raise SystemExit("signed IPA asset catalog has no AppIcon renditions")
marketing = [
    entry
    for entry in icon_renditions
    if entry.get("Idiom") == "marketing"
    and entry.get("PixelWidth") == 1024
    and entry.get("PixelHeight") == 1024
]
if len(marketing) != 1:
    raise SystemExit("signed IPA must contain exactly one 1024x1024 marketing icon")
if marketing[0].get("Opaque") is not True:
    raise SystemExit("signed IPA 1024x1024 marketing icon must be opaque")
if marketing[0].get("SHA1Digest") == (
    "DA81094C0D0E328CC4DA70EBE5B18AD4D6C9C31943C9BC0A0928DFB65D22E1E1"
):
    raise SystemExit("signed IPA 1024x1024 marketing icon is the stock Flutter icon")
PY
if ! codesign -d --verbose=4 "$app" 2>&1 | grep -Eq '^Authority=(Apple Distribution|iPhone Distribution):'; then
  echo "IPA was not signed with an Apple distribution certificate." >&2
  exit 1
fi

printf 'apple_team_id=%s\n' "$team_id"
printf 'apple_signer_sha256=%s\n' "$apple_signer_sha256"
printf 'apple_ipa_sha256=%s\n' "$apple_ipa_sha256"
printf 'apple_profile_kind=app-store\n'
printf 'apple_bundle_id=%s\n' "$bundle_id"
printf 'apple_version=%s\n' "$version"
printf 'apple_build=%s\n' "$build"
printf 'apple_xcode_version=%s\n' "$xcode_version"
printf 'apple_xcode_build=%s\n' "$xcode_build"
printf 'apple_sdk_name=%s\n' "$sdk_name"
printf 'apple_sdk_build=%s\n' "$sdk_build"
printf 'apple_platform_version=%s\n' "$platform_version"
printf 'apple_minimum_os=%s\n' "$minimum_os"
printf 'apple_oidc_scheme=%s\n' "$expected_oidc_scheme"
printf 'apple_app_link_host=%s\n' "$expected_app_link_host"
printf 'apple_launcher_assets=packaged,marketing-1024-opaque\n'
printf 'apple_privacy_manifest=source-equivalent,tracking-false\n'
