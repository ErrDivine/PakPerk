#!/usr/bin/env bash
set -euo pipefail

image="${1:-pakperk-backend:ci}"

command -v docker >/dev/null 2>&1 || {
  echo "docker is required" >&2
  exit 1
}

# Exercise the exact ownership transition used by the Helm init containers.
# The first chown simulates an emptyDir left owned by the application UID after
# an init-container restart. No capability except CHOWN is available.
docker run --rm \
  --user 0:0 \
  --cap-drop ALL \
  --cap-add CHOWN \
  --read-only \
  --tmpfs /source:rw,noexec,nosuid,nodev,size=1m,mode=700 \
  --tmpfs /work:rw,noexec,nosuid,nodev,size=1m,mode=700 \
  "$image" \
  /bin/sh -ceu '
    printf "%s\n" "source-secret-material" > /source/SECRET
    chmod 0400 /source/SECRET
    chown 10001:10001 /work
    chown 0:0 /work
    chmod 0700 /work
    rm -f /work/SECRET
    install -m 0400 /source/SECRET /work/SECRET
    chown 10001:10001 /work/SECRET
    chown 10001:10001 /work
    test "$(stat -c %u:%g /work)" = 10001:10001
    test "$(stat -c %a /work)" = 700
    test "$(stat -c %u:%g /work/SECRET)" = 10001:10001
    test "$(stat -c %a /work/SECRET)" = 400
    test "$(cat /work/SECRET)" = source-secret-material
  '

echo "Secret init succeeded with only CAP_CHOWN."
