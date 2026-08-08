#!/bin/bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "usage: prepare_mobile_store_client.sh WORKSPACE RUNNER_TEMP GITHUB_OUTPUT RUBY_BIN RUBY_SHA256 GEM_BIN GEM_SHA256" >&2
  exit 2
fi

reviewed_workspace="$1"
runner_temp="$2"
github_output="$3"
reviewed_ruby_bin="$4"
reviewed_ruby_sha256="$5"
reviewed_gem_bin="$6"
reviewed_gem_sha256="$7"

if ! [[ "$reviewed_ruby_sha256" =~ ^[0-9a-f]{64}$ ]] || \
   ! [[ "$reviewed_gem_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Reviewed store-client runtime arguments are malformed." >&2
  exit 2
fi

verify_reviewed_file() {
  local expected="$1"
  local relative="$2"
  local observed
  observed="$(/usr/bin/shasum -a 256 "$reviewed_workspace/$relative")"
  if [[ "${observed%% *}" != "$expected" ]]; then
    echo "Reviewed store-client source changed: $relative" >&2
    exit 1
  fi
}

/usr/bin/git -C "$reviewed_workspace" --no-pager diff \
  --no-ext-diff --exit-code HEAD -- \
  mobile/Gemfile \
  mobile/Gemfile.lock \
  scripts/prepare_mobile_store_client.sh \
  scripts/validate_fastlane_lock.py \
  scripts/validate_mobile_store_client.py
verify_reviewed_file \
  bc9e215e96e04a8ab7f5eb75cd205aa5d99b623ba5cfbbd218c4c857c4627826 \
  mobile/Gemfile
verify_reviewed_file \
  df7c9313182c54ae68a3312f720334dc9f524d17973f6a3b1339e8892d778175 \
  mobile/Gemfile.lock
verify_reviewed_file \
  c0496278791a2c712fc1d72320219690f1501ed71010e67e60ba43d8235c3d85 \
  scripts/validate_fastlane_lock.py
verify_reviewed_file \
  6172367be00718dce1beff7523bfa0988502b0860e6752912864817a92d2e4bf \
  scripts/validate_mobile_store_client.py

observed_ruby_sha256="$(/usr/bin/shasum -a 256 "$reviewed_ruby_bin")"
observed_gem_sha256="$(/usr/bin/shasum -a 256 "$reviewed_gem_bin")"
if [[ "${observed_ruby_sha256%% *}" != "$reviewed_ruby_sha256" || \
      "${observed_gem_sha256%% *}" != "$reviewed_gem_sha256" ]]; then
  echo "Reviewed Ruby/RubyGems executable changed after toolchain capture." >&2
  exit 1
fi

/usr/bin/python3 -I "$reviewed_workspace/scripts/validate_fastlane_lock.py" \
  --gemfile "$reviewed_workspace/mobile/Gemfile" \
  --lockfile "$reviewed_workspace/mobile/Gemfile.lock"
runner_temp_real="$(/usr/bin/python3 -I -c \
  'import os, sys; print(os.path.realpath(sys.argv[1]))' "$runner_temp")"
store_client_root="$(umask 077; /usr/bin/mktemp -d \
  "$runner_temp_real/pakperk-store-client.XXXXXXXXXX")"
/usr/bin/python3 -I - "$runner_temp_real" "$store_client_root" <<'PY'
import os
import stat
import sys

parent, candidate = map(os.path.realpath, sys.argv[1:])
if candidate != sys.argv[2] or os.path.commonpath((parent, candidate)) != parent:
    raise SystemExit("store-client root escaped the real runner temp directory")
metadata = os.lstat(candidate)
descriptor = os.open(
    candidate,
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0),
)
try:
    opened = os.fstat(descriptor)
finally:
    os.close(descriptor)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.getuid()
    or metadata.st_mode & 0o077
    or (metadata.st_dev, metadata.st_ino) != (opened.st_dev, opened.st_ino)
):
    raise SystemExit("store-client root is not one fresh owner-only real directory")
PY

/bin/mkdir -m 0700 \
  "$store_client_root/download" \
  "$store_client_root/gem-home" \
  "$store_client_root/bundle" \
  "$store_client_root/config" \
  "$store_client_root/home" \
  "$store_client_root/manifest"
/bin/cp "$reviewed_workspace/mobile/Gemfile" \
  "$store_client_root/manifest/Gemfile"
/bin/cp "$reviewed_workspace/mobile/Gemfile.lock" \
  "$store_client_root/manifest/Gemfile.lock"
/bin/chmod 0400 \
  "$store_client_root/manifest/Gemfile" \
  "$store_client_root/manifest/Gemfile.lock"

store_client_home="$store_client_root/home"
bundler_gem="$store_client_root/download/bundler-2.6.9.gem"
/usr/bin/env -i PATH="$PATH" HOME="$store_client_home" TMPDIR="$runner_temp_real" \
  /usr/bin/curl --disable --proto '=https' --tlsv1.2 \
  --fail --silent --show-error --location --max-redirs 3 \
  --connect-timeout 10 --max-time 120 \
  --output "$bundler_gem" \
  "https://rubygems.org/downloads/bundler-2.6.9.gem"
bundler_gem_sha256="$(/usr/bin/shasum -a 256 "$bundler_gem")"
if [[ "${bundler_gem_sha256%% *}" != \
      "a25675ffbd055ae1186766cc1e120b4cf62588e88abb59b99c57e22b1c55c9eb" ]]; then
  echo "Downloaded Bundler gem does not match the reviewed digest." >&2
  exit 1
fi

gem_home="$store_client_root/gem-home"
bundle_gemfile="$store_client_root/manifest/Gemfile"
bundle_lockfile="$store_client_root/manifest/Gemfile.lock"
bundle_path="$store_client_root/bundle"
bundle_app_config="$store_client_root/config"
/usr/bin/env -i PATH="$PATH" HOME="$store_client_home" TMPDIR="$runner_temp_real" \
  GEMRC=/dev/null GEM_HOME="$gem_home" GEM_PATH="$gem_home" \
  RUBYGEMS_GEMDEPS= RUBYLIB= RUBYOPT= \
  "$reviewed_ruby_bin" "$reviewed_gem_bin" \
  install --local "$bundler_gem" --no-document \
  --install-dir "$gem_home" --bindir "$gem_home/bin" \
  --config-file /dev/null
bundle_bin="$gem_home/bin/bundle"
/bin/chmod 0700 "$bundle_bin"

run_bundle() {
  /usr/bin/env -i PATH="$PATH" HOME="$store_client_home" TMPDIR="$runner_temp_real" \
    LANG=en_US.UTF-8 GEMRC=/dev/null \
    GEM_HOME="$gem_home" GEM_PATH="$gem_home" RUBYGEMS_GEMDEPS= \
    RUBYLIB= RUBYOPT= BUNDLE_APP_CONFIG="$bundle_app_config" \
    BUNDLE_FROZEN=true BUNDLE_GEMFILE="$bundle_gemfile" \
    BUNDLE_IGNORE_CONFIG=true BUNDLE_LOCKFILE_CHECKSUMS=true \
    BUNDLE_PATH="$bundle_path" \
    "$reviewed_ruby_bin" "$bundle_bin" "_2.6.9_" "$@"
}
run_bundle install --jobs 4 --retry 3
run_bundle exec fastlane --version >/dev/null
run_bundle list >/dev/null

{
  printf 'root=%s\n' "$store_client_root"
  printf 'bundle_bin=%s\n' "$bundle_bin"
  printf 'gem_home=%s\n' "$gem_home"
  printf 'bundle_gemfile=%s\n' "$bundle_gemfile"
  printf 'bundle_lockfile=%s\n' "$bundle_lockfile"
  printf 'bundle_path=%s\n' "$bundle_path"
  printf 'bundle_app_config=%s\n' "$bundle_app_config"
  printf 'home=%s\n' "$store_client_home"
  printf 'bundler_version=2.6.9\n'
} >>"$github_output"
/usr/bin/python3 -I \
  "$reviewed_workspace/scripts/validate_mobile_store_client.py" capture \
  --root "$store_client_root" \
  --bundle-bin "$bundle_bin" \
  --gem-home "$gem_home" \
  --bundle-gemfile "$bundle_gemfile" \
  --bundle-lockfile "$bundle_lockfile" \
  --bundle-path "$bundle_path" \
  --bundle-app-config "$bundle_app_config" \
  --client-home "$store_client_home" \
  --github-output "$github_output"
