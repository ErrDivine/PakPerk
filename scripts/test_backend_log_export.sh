#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$project_dir/deploy/helm/pakperk"
fixture="$chart/ci/staging-values.yaml"
helm_bin="${HELM_BIN:-helm}"

for command in "$helm_bin" docker python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Backend log export test requires $command." >&2
    exit 2
  fi
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-log-export.XXXXXX")"
container_id=""
cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm --force "$container_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

rendered="$temporary_dir/rendered.yaml"
config="$temporary_dir/collector-test.yaml"
"$helm_bin" template pakperk "$chart" --values "$fixture" >"$rendered"
python3 - "$rendered" "$config" <<'PY'
import pathlib
import re
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "  collector.yaml: |\n"
start = rendered.find(marker)
if start < 0:
    raise SystemExit("collector ConfigMap was not rendered")
lines = []
for line in rendered[start + len(marker):].splitlines():
    if line == "---":
        break
    if not line.startswith("    "):
        raise SystemExit("collector ConfigMap indentation changed")
    lines.append(line[4:])
config = "\n".join(lines) + "\n"
config, count = re.subn(
    r"(?ms)^exporters:\n.*?^service:\n",
    "exporters:\n  debug:\n    verbosity: detailed\nservice:\n",
    config,
    count=1,
)
if count != 1:
    raise SystemExit("collector exporter block changed")
config = config.replace("exporters: [otlp]", "exporters: [debug]")
config = config.replace("level: warn", "level: info", 1)
pathlib.Path(sys.argv[2]).write_text(config, encoding="utf-8")
PY
chmod 0644 "$config"

collector_image="$(awk '
  /^        - name: collector$/ { found=1; next }
  found && /^          image: / { print $2; exit }
' "$rendered")"
if [[ "$collector_image" != *@sha256:* ]]; then
  echo "Collector image was not resolved to an immutable digest." >&2
  exit 1
fi

fixture_uid="01234567-89ab-cdef-0123-456789abcdef"
log_dir="$temporary_dir/pods/default_pakperk-pakperk-api-fixture_${fixture_uid}/api"
state_dir="$temporary_dir/state"
mkdir -p "$log_dir" "$state_dir"
chmod 0755 "$temporary_dir/pods" \
  "$temporary_dir/pods/default_pakperk-pakperk-api-fixture_${fixture_uid}" "$log_dir"
chmod 0777 "$state_dir"
log_file="$log_dir/0.log"
: >"$log_file"
chmod 0644 "$log_file"

container_id="$(docker run --detach --user 10001:10001 \
  --volume "$config:/conf/collector.yaml:ro" \
  --volume "$temporary_dir/pods:/var/log/pods:ro" \
  --volume "$state_dir:/var/lib/otelcol/file-storage" \
  "$collector_image" --config=/conf/collector.yaml)"

timestamp="2026-07-31T00:00:00.000000000Z"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"INFO","message":"backend operational sentinel","target":"pakperk_api","comment.body":"protected-content-sentinel","authorization":"Bearer protected-token-sentinel"}' \
  >"$log_file"

exported=0
for _ in $(seq 1 20); do
  docker logs "$container_id" >"$temporary_dir/collector.log" 2>&1
  if grep -Fq 'backend operational sentinel' "$temporary_dir/collector.log"; then
    exported=1
    break
  fi
  sleep 1
done
if [[ "$exported" != 1 ]]; then
  echo "Collector did not export the backend stdout fixture." >&2
  sed -n '1,160p' "$temporary_dir/collector.log" >&2
  exit 1
fi
grep -Fq 'pakperk-backend-stdout' "$temporary_dir/collector.log"
forbidden_pattern='protected-content-sentinel|protected-token-sentinel|comment\.body|authorization|log\.file\.path'
if grep -Eq "$forbidden_pattern" "$temporary_dir/collector.log"; then
  echo "Collector exported a field outside the backend-log allowlist." >&2
  grep -En "$forbidden_pattern" "$temporary_dir/collector.log" >&2
  exit 1
fi

echo "Backend stdout reached the OTLP logs pipeline through the redacting node agent."
