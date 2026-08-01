#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$project_dir/deploy/helm/pakperk"
fixture="$chart/ci/staging-values.yaml"
helm_bin="${HELM_BIN:-helm}"

for command in "$helm_bin" curl docker python3; do
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
direct_logs="$temporary_dir/direct-logs.json"
direct_traces="$temporary_dir/direct-traces.json"
direct_metrics="$temporary_dir/direct-metrics.json"
"$helm_bin" template pakperk "$chart" --values "$fixture" >"$rendered"
python3 - "$rendered" "$config" "$direct_logs" "$direct_traces" "$direct_metrics" <<'PY'
import json
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


def redaction_keys(processor_name: str, action_field: str) -> list[str]:
    marker = f"  {processor_name}:\n"
    start = config.find(marker)
    if start < 0:
        raise SystemExit(f"{processor_name} was not rendered")
    remainder = config[start + len(marker):]
    next_processor = re.search(r"(?m)^  [a-zA-Z0-9_./-]+:\n", remainder)
    block = remainder if next_processor is None else remainder[:next_processor.start()]
    if f"    {action_field}:\n" not in block:
        raise SystemExit(f"{processor_name}.{action_field} was not rendered")
    return re.findall(
        r"(?m)^      - \{ key: ([a-zA-Z0-9_.-]+), action: delete \}$",
        block,
    )


attribute_keys = redaction_keys("attributes/redact", "actions")
resource_keys = redaction_keys("resource/redact", "attributes")
if not attribute_keys or attribute_keys != resource_keys:
    raise SystemExit("signal and resource redaction keys must be identical and non-empty")

required_keys = {
    "http.request.header.authorization",
    "http.request.header.cookie",
    "http.response.header.set-cookie",
    "access_token",
    "refresh_token",
    "id_token",
    "user.email",
    "oidc.subject",
    "oidc.sub",
    "comment.body",
    "chat.message",
    "paper.full_text",
    "model.prompt",
    "model.response",
}
missing_keys = sorted(required_keys.difference(attribute_keys))
if missing_keys:
    raise SystemExit(f"required protected OTLP attributes are missing: {missing_keys}")


def attributes(prefix: str) -> list[dict[str, object]]:
    return [
        {
            "key": key,
            "value": {"stringValue": f"sensitive-{prefix}-{index:02d}-sentinel"},
        }
        for index, key in enumerate(attribute_keys)
    ]


def resource(signal: str) -> dict[str, object]:
    return {
        "attributes": [
            {
                "key": "service.name",
                "value": {"stringValue": f"direct-otlp-{signal}-redaction-test"},
            },
            *attributes(f"{signal}-resource"),
        ]
    }


timestamp = "1785456000000000000"
scope = {"name": "pakperk.collector-redaction-test", "version": "1"}
safe_attribute = {
    "key": "safe.attribute",
    "value": {"stringValue": "direct-otlp-safe-attribute-sentinel"},
}

logs = {
    "resourceLogs": [
        {
            "resource": resource("log"),
            "scopeLogs": [
                {
                    "scope": scope,
                    "logRecords": [
                        {
                            "timeUnixNano": timestamp,
                            "severityNumber": 9,
                            "severityText": "INFO",
                            "body": {"stringValue": "direct OTLP log sentinel"},
                            "attributes": [safe_attribute, *attributes("log-signal")],
                        }
                    ],
                }
            ],
        }
    ]
}
traces = {
    "resourceSpans": [
        {
            "resource": resource("trace"),
            "scopeSpans": [
                {
                    "scope": scope,
                    "spans": [
                        {
                            "traceId": "0123456789abcdef0123456789abcdef",
                            "spanId": "0123456789abcdef",
                            "name": "direct OTLP trace sentinel",
                            "kind": 1,
                            "startTimeUnixNano": timestamp,
                            "endTimeUnixNano": "1785456000001000000",
                            "attributes": [safe_attribute, *attributes("trace-signal")],
                        }
                    ],
                }
            ],
        }
    ]
}
metrics = {
    "resourceMetrics": [
        {
            "resource": resource("metric"),
            "scopeMetrics": [
                {
                    "scope": scope,
                    "metrics": [
                        {
                            "name": "direct_otlp_metric_sentinel",
                            "unit": "1",
                            "gauge": {
                                "dataPoints": [
                                    {
                                        "timeUnixNano": timestamp,
                                        "asInt": "1",
                                        "attributes": [
                                            safe_attribute,
                                            *attributes("metric-signal"),
                                        ],
                                    }
                                ]
                            },
                        }
                    ],
                }
            ],
        }
    ]
}

for path, payload in zip(sys.argv[3:], (logs, traces, metrics), strict=True):
    pathlib.Path(path).write_text(
        json.dumps(payload, separators=(",", ":")),
        encoding="utf-8",
    )
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
  --publish 127.0.0.1::4318 \
  --volume "$config:/conf/collector.yaml:ro" \
  --volume "$temporary_dir/pods:/var/log/pods:ro" \
  --volume "$state_dir:/var/lib/otelcol/file-storage" \
  "$collector_image" --config=/conf/collector.yaml)"

otlp_http_address="$(docker port "$container_id" 4318/tcp | sed -n '1p')"
otlp_http_port="${otlp_http_address##*:}"
if [[ ! "$otlp_http_port" =~ ^[0-9]+$ ]]; then
  echo "Collector OTLP/HTTP port was not published on loopback." >&2
  docker logs "$container_id" >&2 || true
  exit 1
fi
otlp_http_origin="http://127.0.0.1:$otlp_http_port"

post_otlp_fixture() {
  local endpoint="$1"
  local fixture_path="$2"
  for _ in $(seq 1 20); do
    if curl --fail --silent --show-error \
      --header 'Content-Type: application/json' \
      --data-binary "@$fixture_path" \
      "$otlp_http_origin/$endpoint" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Collector did not accept the direct OTLP/$endpoint redaction fixture." >&2
  docker logs "$container_id" >&2 || true
  return 1
}

post_otlp_fixture v1/logs "$direct_logs"
post_otlp_fixture v1/traces "$direct_traces"
post_otlp_fixture v1/metrics "$direct_metrics"

timestamp="2026-07-31T00:00:00.000000000Z"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"INFO","message":"backend operational sentinel","target":"pakperk_api","comment.body":"protected-content-sentinel","authorization":"Bearer protected-token-sentinel"}' \
  >"$log_file"

exported=0
for _ in $(seq 1 30); do
  docker logs "$container_id" >"$temporary_dir/collector.log" 2>&1
  if grep -Fq 'backend operational sentinel' "$temporary_dir/collector.log" \
    && grep -Fq 'direct OTLP log sentinel' "$temporary_dir/collector.log" \
    && grep -Fq 'direct OTLP trace sentinel' "$temporary_dir/collector.log" \
    && grep -Fq 'direct_otlp_metric_sentinel' "$temporary_dir/collector.log" \
    && grep -Fq 'direct-otlp-log-redaction-test' "$temporary_dir/collector.log" \
    && grep -Fq 'direct-otlp-trace-redaction-test' "$temporary_dir/collector.log" \
    && grep -Fq 'direct-otlp-metric-redaction-test' "$temporary_dir/collector.log" \
    && grep -Fq 'direct-otlp-safe-attribute-sentinel' "$temporary_dir/collector.log"; then
    exported=1
    break
  fi
  sleep 1
done
if [[ "$exported" != 1 ]]; then
  echo "Collector did not export every stdout/direct-OTLP redaction fixture." >&2
  sed -n '1,160p' "$temporary_dir/collector.log" >&2
  exit 1
fi
grep -Fq 'pakperk-backend-stdout' "$temporary_dir/collector.log"
forbidden_pattern='protected-content-sentinel|protected-token-sentinel|sensitive-(log|trace|metric)-(signal|resource)-[0-9]+-sentinel|comment\.body|authorization|log\.file\.path'
if grep -Eq "$forbidden_pattern" "$temporary_dir/collector.log"; then
  echo "Collector exported a protected stdout or direct-OTLP field." >&2
  grep -En "$forbidden_pattern" "$temporary_dir/collector.log" >&2
  exit 1
fi

echo "Backend stdout and direct OTLP logs/traces/metrics reached export with signal and resource attributes redacted."
