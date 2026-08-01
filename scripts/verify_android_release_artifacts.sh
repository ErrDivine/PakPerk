#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: $0 app.aab app.apk expected-package expected-version-name expected-version-code expected-oidc-scheme expected-app-link-host"
  exit 0
fi
if [[ $# -ne 7 ]]; then
  echo "usage: $0 app.aab app.apk expected-package expected-version-name expected-version-code expected-oidc-scheme expected-app-link-host" >&2
  exit 2
fi

aab="$1"
apk="$2"
expected_package="$3"
expected_version_name="$4"
expected_version_code="$5"
expected_oidc_scheme="$6"
expected_app_link_host="$7"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for command in jarsigner keytool python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Android release verification requires $command." >&2
    exit 2
  fi
done
for artifact in "$aab" "$apk"; do
  if [[ ! -f "$artifact" || -L "$artifact" || ! -s "$artifact" ]]; then
    echo "Release artifact must be a non-symlink, non-empty regular file: $artifact" >&2
    exit 1
  fi
done

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$android_sdk" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT is required." >&2
  exit 2
fi
build_tools_dir="$(python3 - "$android_sdk/build-tools" <<'PY'
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
candidates = []
if root.is_dir():
    for child in root.iterdir():
        if not child.is_dir() or not re.fullmatch(r"\d+(?:\.\d+){0,2}", child.name):
            continue
        if not all(
            (child / tool).is_file() and os.access(child / tool, os.X_OK)
            for tool in ("aapt", "apksigner", "zipalign")
        ):
            continue
        version = tuple(int(component) for component in child.name.split("."))
        candidates.append((version + (0,) * (3 - len(version)), child))
if not candidates:
    raise SystemExit("No complete numeric Android build-tools installation was found.")
version, directory = max(candidates)
if version < (35, 0, 0):
    raise SystemExit("Android build-tools 35.0.0 or newer is required for 16 KiB checks.")
print(directory)
PY
)"
build_tools_version="$(basename "$build_tools_dir")"
aapt="$build_tools_dir/aapt"
apksigner="$build_tools_dir/apksigner"
zipalign="$build_tools_dir/zipalign"
if [[ ! -x "$aapt" || ! -x "$apksigner" || ! -x "$zipalign" ]]; then
  echo "Android build-tools aapt, apksigner, and zipalign must be executable in $build_tools_dir." >&2
  exit 2
fi

temporary_file="$(mktemp "${TMPDIR:-/tmp}/pakperk-apksigner.XXXXXX")"
manifest_file="$temporary_file.manifest"
trap 'rm -f "$temporary_file" "$manifest_file"' EXIT INT TERM
"$script_dir/verify_signed_jar.sh" "$aab"
"$apksigner" verify --verbose --print-certs "$apk" >"$temporary_file"
if ! grep -Fxq 'Number of signers: 1' "$temporary_file"; then
  echo "Signed APK must have exactly one signer." >&2
  exit 1
fi
if ! grep -Fxq 'Verified using v2 scheme (APK Signature Scheme v2): true' "$temporary_file" \
  || ! grep -Eq '^Verified using v3(\.1)? scheme \(APK Signature Scheme v3(\.1)?\): true$' "$temporary_file"; then
  echo "Signed APK must use APK Signature Scheme v2 and v3/v3.1." >&2
  exit 1
fi
if grep -Fq 'CN=Android Debug' "$temporary_file"; then
  echo "Signed APK uses the stock Android debug certificate." >&2
  exit 1
fi
"$aapt" dump xmltree "$apk" AndroidManifest.xml >"$manifest_file"
"$zipalign" -c -P 16 -v 4 "$apk" >/dev/null
python3 "$script_dir/verify_android_elf_alignment.py" "$apk" "$aab"

badging_output="$("$aapt" dump badging "$apk")"
badging="$(printf '%s\n' "$badging_output" | sed -n '1p')"
package="$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
version_code="$(printf '%s\n' "$badging" | sed -n "s/.* versionCode='\([^']*\)'.*/\1/p")"
version_name="$(printf '%s\n' "$badging" | sed -n "s/.* versionName='\([^']*\)'.*/\1/p")"
if [[ "$package" != "$expected_package" || "$version_name" != "$expected_version_name" || "$version_code" != "$expected_version_code" ]]; then
  echo "Signed APK identity/version mismatch: package=$package version=$version_name+$version_code" >&2
  exit 1
fi
minimum_sdk="$(printf '%s\n' "$badging_output" | sed -n "s/^sdkVersion:'\([^']*\)'.*/\1/p")"
target_sdk="$(printf '%s\n' "$badging_output" | sed -n "s/^targetSdkVersion:'\([^']*\)'.*/\1/p")"
compile_sdk="$(printf '%s\n' "$badging" | sed -n "s/.* compileSdkVersion='\([^']*\)'.*/\1/p")"
if [[ "$minimum_sdk" != "24" || "$target_sdk" != "36" || "$compile_sdk" != "36" ]]; then
  echo "Android SDK contract mismatch: min=$minimum_sdk target=$target_sdk compile=$compile_sdk; expected 24/36/36." >&2
  exit 1
fi
apk_digest="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$temporary_file" | head -1)"
if ! [[ "$apk_digest" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Could not extract one SHA-256 signer digest from the APK." >&2
  exit 1
fi
apk_fingerprint="$(printf '%s' "$apk_digest" | sed 's/../&:/g; s/:$//' | tr '[:lower:]' '[:upper:]')"

aab_fingerprint="$(LC_ALL=C keytool -printcert -jarfile "$aab" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256: //p' | head -1)"
if ! [[ "$aab_fingerprint" =~ ^([A-F0-9]{2}:){31}[A-F0-9]{2}$ ]]; then
  echo "Could not extract one SHA-256 signer fingerprint from the AAB." >&2
  exit 1
fi
if [[ "$aab_fingerprint" != "$apk_fingerprint" ]]; then
  echo "AAB and APK were not signed by the same protected certificate." >&2
  exit 1
fi

python3 - "$manifest_file" "$expected_oidc_scheme" "$expected_app_link_host" "$apk" "$aab" "$expected_package" <<'PY'
import hashlib
import pathlib
import re
import sys
import zipfile

manifest = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected_oidc_scheme = sys.argv[2]
expected_app_link_host = sys.argv[3]
expected_package = sys.argv[6]
development = expected_app_link_host == "localhost"
expected_link_scheme = "http" if development else "https"
expected_auto_verify = "0x0" if development else "0xffffffff"


def element_blocks(source, element):
    lines = source.splitlines()
    starts = []
    marker = f"E: {element}"
    for index, line in enumerate(lines):
        stripped = line.lstrip(" ")
        if stripped == marker or stripped.startswith(marker + " "):
            starts.append((index, len(line) - len(stripped)))
    blocks = []
    for start, indentation in starts:
        end = len(lines)
        for index in range(start + 1, len(lines)):
            stripped = lines[index].lstrip(" ")
            if stripped.startswith("E: ") and len(lines[index]) - len(stripped) <= indentation:
                end = index
                break
        blocks.append("\n".join(lines[start:end]))
    return blocks


def raw_values(source, attribute):
    return re.findall(
        rf"{re.escape(attribute)}[^\n]*\(Raw: \"([^\"]+)\"\)", source
    )


def bool_values(source, attribute):
    return re.findall(
        rf"{re.escape(attribute)}[^\n]*\(type 0x12\)(0x[0-9a-f]+)", source
    )


def data_attribute_sets(source):
    return [
        set(re.findall(r"A: (android:[A-Za-z0-9_]+)", block))
        for block in element_blocks(source, "data")
    ]


activity_blocks = element_blocks(manifest, "activity")
main_activities = [
    block
    for block in activity_blocks
    if raw_values(block, "android:name")[:1] == [f"{expected_package}.MainActivity"]
]
if len(main_activities) != 1:
    raise SystemExit("signed APK must contain exactly one expected MainActivity")
main_activity = main_activities[0]
if bool_values(main_activity.split("E: intent-filter", 1)[0], "android:exported") != [
    "0xffffffff"
]:
    raise SystemExit("signed APK MainActivity must be exported")

filters = element_blocks(main_activity, "intent-filter")
launcher_filters = []
paper_filters = []
app_link_filters = []
for block in filters:
    intent_names = raw_values(block, "android:name")
    schemes = raw_values(block, "android:scheme")
    hosts = raw_values(block, "android:host")
    prefixes = raw_values(block, "android:pathPrefix")
    data_attributes = data_attribute_sets(block)
    auto_verify = bool_values(block.split("E: action", 1)[0], "android:autoVerify")
    if "android.intent.action.MAIN" in intent_names:
        if (
            sorted(intent_names)
            != sorted(
                [
                    "android.intent.action.MAIN",
                    "android.intent.category.LAUNCHER",
                ]
            )
            or schemes
            or hosts
            or prefixes
            or data_attributes
            or auto_verify
        ):
            raise SystemExit("signed APK has a malformed launcher intent filter")
        launcher_filters.append(block)
    elif schemes == ["pakperk"] and hosts == ["paper"]:
        if (
            sorted(intent_names)
            != sorted(
                [
                    "android.intent.action.VIEW",
                    "android.intent.category.DEFAULT",
                    "android.intent.category.BROWSABLE",
                ]
            )
            or prefixes
            or data_attributes != [{"android:scheme", "android:host"}]
            or auto_verify
        ):
            raise SystemExit("signed APK has a malformed paper callback filter")
        paper_filters.append(block)
    elif hosts == [expected_app_link_host]:
        if (
            sorted(intent_names)
            != sorted(
                [
                    "android.intent.action.VIEW",
                    "android.intent.category.DEFAULT",
                    "android.intent.category.BROWSABLE",
                ]
            )
            or schemes != [expected_link_scheme]
            or prefixes not in (["/p/"], ["/arxiv/"])
            or data_attributes
            != [{"android:scheme", "android:host", "android:pathPrefix"}]
        ):
            raise SystemExit("signed APK has an unexpected app-link filter")
        if auto_verify != [expected_auto_verify]:
            raise SystemExit("signed APK has an incorrect app-link autoVerify policy")
        app_link_filters.append(block)
    else:
        raise SystemExit("signed APK MainActivity has an unexpected intent filter")
if len(launcher_filters) != 1 or len(paper_filters) != 1 or len(app_link_filters) != 2:
    raise SystemExit("signed APK has an incomplete launcher/deep-link filter set")
if sorted(raw_values("\n".join(app_link_filters), "android:pathPrefix")) != [
    "/arxiv/",
    "/p/",
]:
    raise SystemExit("signed APK has unexpected app-link path prefixes")

oidc_activities = [
    block
    for block in activity_blocks
    if raw_values(block, "android:name")[:1]
    == ["net.openid.appauth.RedirectUriReceiverActivity"]
]
if len(oidc_activities) != 1:
    raise SystemExit("signed APK must contain exactly one AppAuth callback receiver")
oidc_activity = oidc_activities[0]
if bool_values(oidc_activity.split("E: intent-filter", 1)[0], "android:exported") != [
    "0xffffffff"
]:
    raise SystemExit("signed APK AppAuth callback receiver must be exported")
oidc_filters = element_blocks(oidc_activity, "intent-filter")
if (
    len(oidc_filters) != 1
    or sorted(raw_values(oidc_filters[0], "android:name"))
    != sorted(
        [
            "android.intent.action.VIEW",
            "android.intent.category.DEFAULT",
            "android.intent.category.BROWSABLE",
        ]
    )
    or raw_values(oidc_filters[0], "android:scheme") != [expected_oidc_scheme]
    or data_attribute_sets(oidc_filters[0]) != [{"android:scheme"}]
):
    raise SystemExit("signed APK has an unexpected OIDC callback scheme")
if raw_values(oidc_filters[0], "android:host") or raw_values(
    oidc_filters[0], "android:pathPrefix"
):
    raise SystemExit("signed APK OIDC callback receiver is broader than expected")

if bool_values(manifest, "android:allowBackup") != ["0x0"]:
    raise SystemExit("signed APK must disable Android backup")
if bool_values(manifest, "android:extractNativeLibs") != ["0x0"]:
    raise SystemExit("signed APK must package native libraries for direct loading")
expected_cleartext = "0xffffffff" if development else "0x0"
if bool_values(manifest, "android:usesCleartextTraffic") != [expected_cleartext]:
    raise SystemExit("signed APK has an incorrect cleartext transport policy")
network_security_configs = re.findall(r"android:networkSecurityConfig[^\n]*", manifest)
if development != (len(network_security_configs) == 1):
    raise SystemExit("signed APK has an incorrect network-security configuration")
if manifest.count("android:icon") != 1 or manifest.count("android:roundIcon") != 1:
    raise SystemExit("signed APK must declare exactly one legacy and round launcher icon")

default_flutter_hashes = {
    "c7c0c0189145e4e32a401c61c9bdc615754b0264e7afae24e834bb81049eaf81",
    "6a7c8f0d703e3682108f9662f813302236240d3f8f638bb391e32bfb96055fef",
    "e14aa40904929bf313fded22cf7e7ffcbf1d1aac4263b5ef1be8bfce650397aa",
    "4d470bf22d5c17d84edc5f82516d1ba8a1c09559cd761cefb792f86d9f52b540",
    "3c34e1f298d0c9ea3455d46db6b7759c8211a49e9ec6e44b635fc5c87dfb4180",
}


def has_resource(names, folder, basename):
    expected = f"res/{folder}/{basename}"
    expected_v4 = f"res/{folder}-v4/{basename}"
    return any(
        name == expected
        or name.endswith(f"/{expected}")
        or name == expected_v4
        or name.endswith(f"/{expected_v4}")
        for name in names
    )


def verify_launcher_archive(raw_path):
    artifact = pathlib.Path(raw_path)
    with zipfile.ZipFile(artifact) as archive:
        names = set(archive.namelist())
        for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
            folder = f"mipmap-{density}"
            for basename in ("ic_launcher.png", "ic_launcher_round.png"):
                if not has_resource(names, folder, basename):
                    raise SystemExit(
                        f"{artifact.name} is missing {folder}/{basename}"
                    )
        for folder, basename in (
            ("mipmap-anydpi-v26", "ic_launcher.xml"),
            ("mipmap-anydpi-v26", "ic_launcher_round.xml"),
            ("mipmap-anydpi-v33", "ic_launcher.xml"),
            ("mipmap-anydpi-v33", "ic_launcher_round.xml"),
            ("drawable", "ic_launcher_foreground.xml"),
            ("drawable", "ic_launcher_monochrome.xml"),
        ):
            if not has_resource(names, folder, basename):
                raise SystemExit(
                    f"{artifact.name} is missing {folder}/{basename}"
                )
        for name in names:
            basename = pathlib.PurePosixPath(name).name
            if not basename.startswith("ic_launcher"):
                continue
            if not basename.endswith((".png", ".webp")):
                continue
            digest = hashlib.sha256(archive.read(name)).hexdigest()
            if digest in default_flutter_hashes:
                raise SystemExit(
                    f"{artifact.name} contains a stock Flutter launcher: {name}"
                )


verify_launcher_archive(sys.argv[4])
verify_launcher_archive(sys.argv[5])
PY

if printf '%s\n' "$badging_output" | grep -Eq '^application-(debuggable|testOnly)$'; then
  echo "Android release artifact is debuggable or test-only." >&2
  exit 1
fi

printf 'android_package=%s\n' "$package"
printf 'android_version_name=%s\n' "$version_name"
printf 'android_version_code=%s\n' "$version_code"
printf 'android_min_sdk=%s\n' "$minimum_sdk"
printf 'android_target_sdk=%s\n' "$target_sdk"
printf 'android_compile_sdk=%s\n' "$compile_sdk"
printf 'android_build_tools=%s\n' "$build_tools_version"
printf 'android_upload_sha256=%s\n' "$aab_fingerprint"
printf 'android_oidc_scheme=%s\n' "$expected_oidc_scheme"
printf 'android_app_link_host=%s\n' "$expected_app_link_host"
printf 'android_launcher_assets=legacy,round,adaptive,monochrome\n'
printf 'android_apk_zip_alignment=16384\n'
