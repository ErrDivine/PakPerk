#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$project_dir/deploy/helm/pakperk"
fixture="$chart/ci/staging-values.yaml"
gateway_source="$project_dir/backend/apps/telemetry-gateway/src/main.rs"
helm_bin="${HELM_BIN:-helm}"

for command in "$helm_bin" curl docker python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Backend log export test requires $command." >&2
    exit 2
  fi
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-log-export.XXXXXX")"
container_id=""
queue_source_id=""
queue_sink_id=""
network_name=""
cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm --force "$container_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$queue_source_id" ]]; then
    docker rm --force "$queue_source_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$queue_sink_id" ]]; then
    docker rm --force "$queue_sink_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$network_name" ]]; then
    docker network rm "$network_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

rendered="$temporary_dir/rendered.yaml"
config="$temporary_dir/collector-test.yaml"
direct_logs="$temporary_dir/direct-logs.json"
direct_traces="$temporary_dir/direct-traces.json"
direct_metrics="$temporary_dir/direct-metrics.json"
queue_config="$temporary_dir/collector-queue-test.yaml"
sink_config="$temporary_dir/collector-sink-test.yaml"
sink_name="pakperk-log-sink-$$-$RANDOM"
"$helm_bin" template pakperk "$chart" --values "$fixture" >"$rendered"
python3 - "$rendered" "$config" "$direct_logs" "$direct_traces" "$direct_metrics" "$gateway_source" <<'PY'
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

otlp_pipeline = (
    "    logs/otlp:\n"
    "      receivers: [otlp]\n"
    "      processors: [memory_limiter, resource/redact, attributes/redact, "
    "transform/redact-otlp-log-body, batch]\n"
)
stdout_pipeline = (
    "    logs/backend-stdout:\n"
    "      receivers: [filelog/pakperk_backend]\n"
    "      processors: [memory_limiter, resource/redact, attributes/redact, "
    "resource/backend-defaults, transform/redact-backend-log-body, batch]\n"
)
if otlp_pipeline not in config or stdout_pipeline not in config:
    raise SystemExit("OTLP and backend stdout logs must use distinct redaction pipelines")

backend_identity = (
    "  resource/backend-defaults:\n"
    "    attributes:\n"
    "      - { key: service.name, value: pakperk-backend-stdout, action: upsert }\n"
    "      - { key: deployment.environment.name, value: \"staging\", action: upsert }\n"
)
if backend_identity not in config:
    raise SystemExit("backend stdout resource identity must be fixed with upsert")

gateway = pathlib.Path(sys.argv[6]).read_text(encoding="utf-8")
valid_event_block = re.search(
    r"(?ms)^fn valid_event\(event: &str\) -> bool \{.*?^\}", gateway
)
if valid_event_block is None:
    raise SystemExit("mobile gateway event allowlist changed shape")
gateway_events = re.findall(r'"([a-z][a-z0-9_]*)"', valid_event_block.group(0))
body_allowlist = re.search(
    r'IsMatch\(log\.body, "\^\(([^"()]+)\)\$"\)', config
)
if body_allowlist is None:
    raise SystemExit("OTLP log-body allowlist was not rendered")
collector_events = body_allowlist.group(1).split("|")
if (
    not gateway_events
    or len(gateway_events) != len(set(gateway_events))
    or len(collector_events) != len(set(collector_events))
    or set(gateway_events) != set(collector_events)
):
    raise SystemExit("Collector and mobile gateway event allowlists must match exactly")


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
                            "body": {
                                "stringValue": "direct-otlp-body-secret-sentinel"
                            },
                            "attributes": [safe_attribute, *attributes("log-signal")],
                        },
                        {
                            "timeUnixNano": timestamp,
                            "severityNumber": 9,
                            "severityText": "INFO",
                            "body": {
                                "kvlistValue": {
                                    "values": [
                                        {
                                            "key": "nested",
                                            "value": {
                                                "stringValue": (
                                                    "structured-body-secret-sentinel"
                                                )
                                            },
                                        }
                                    ]
                                }
                            },
                            "attributes": [],
                        }
                    ],
                }
            ],
        },
        {
            "resource": {
                "attributes": [
                    {
                        "key": "service.name",
                        "value": {"stringValue": "pakperk-mobile"},
                    },
                    {
                        "key": "deployment.environment.name",
                        "value": {"stringValue": "staging"},
                    },
                ]
            },
            "scopeLogs": [
                {
                    "scope": {"name": "app.pakperk.mobile"},
                    "logRecords": [
                        {
                            "timeUnixNano": timestamp,
                            "severityNumber": 9,
                            "severityText": "INFO",
                            "body": {"stringValue": "startup_ready"},
                            "attributes": [],
                        },
                        {
                            "timeUnixNano": timestamp,
                            "severityNumber": 9,
                            "severityText": "INFO",
                            "body": {
                                "stringValue": "spoofed-mobile-body-secret-sentinel"
                            },
                            "attributes": [],
                        }
                    ],
                }
            ],
        },
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

for path, payload in zip(sys.argv[3:6], (logs, traces, metrics), strict=True):
    pathlib.Path(path).write_text(
        json.dumps(payload, separators=(",", ":")),
        encoding="utf-8",
    )
PY
chmod 0644 "$config"

python3 - "$rendered" "$queue_config" "$sink_config" "$sink_name" <<'PY'
import pathlib
import re
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "  collector.yaml: |\n"
start = rendered.find(marker)
if start < 0:
    raise SystemExit("collector ConfigMap was not rendered for queue recovery")
lines = []
for line in rendered[start + len(marker):].splitlines():
    if line == "---":
        break
    if not line.startswith("    "):
        raise SystemExit("collector ConfigMap indentation changed")
    lines.append(line[4:])
config = "\n".join(lines) + "\n"
required = (
    "  file_storage/filelog:\n",
    "  file_storage/exporter_queue:\n",
    "      storage: file_storage/exporter_queue\n",
    "  extensions: [health_check, file_storage/filelog, file_storage/exporter_queue]\n",
)
if any(fragment not in config for fragment in required):
    raise SystemExit("collector exporter queue is not bound to persistent storage")

sink_name = sys.argv[4]
if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", sink_name) is None:
    raise SystemExit("queue test sink name is invalid")
production_destination = (
    "    endpoint: ${env:PAKPERK_TELEMETRY_EXPORTER_ENDPOINT}\n"
    "    headers: ${env:PAKPERK_TELEMETRY_EXPORTER_HEADERS}\n"
    "    tls:\n"
    "      insecure: false\n"
)
test_destination = (
    f"    endpoint: {sink_name}:4317\n"
    "    tls:\n"
    "      insecure: true\n"
)
if config.count(production_destination) != 1:
    raise SystemExit("collector production exporter destination changed")
config = config.replace(production_destination, test_destination, 1)
config = config.replace("level: warn", "level: info", 1)
pathlib.Path(sys.argv[2]).write_text(config, encoding="utf-8")

sink = """receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
exporters:
  debug:
    verbosity: detailed
service:
  telemetry:
    logs:
      level: info
    metrics:
      level: none
  pipelines:
    logs:
      receivers: [otlp]
      exporters: [debug]
"""
pathlib.Path(sys.argv[3]).write_text(sink, encoding="utf-8")
PY
chmod 0644 "$queue_config" "$sink_config"

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
exporter_state_dir="$temporary_dir/exporter-state"
mkdir -p "$log_dir" "$state_dir" "$exporter_state_dir"
chmod 0755 "$temporary_dir/pods" \
  "$temporary_dir/pods/default_pakperk-pakperk-api-fixture_${fixture_uid}" "$log_dir"
chmod 0777 "$state_dir" "$exporter_state_dir"
log_file="$log_dir/0.log"
: >"$log_file"
chmod 0644 "$log_file"

container_id="$(docker run --detach --user 10001:10001 \
  --publish 127.0.0.1::4318 \
  --volume "$config:/conf/collector.yaml:ro" \
  --volume "$temporary_dir/pods:/var/log/pods:ro" \
  --volume "$state_dir:/var/lib/otelcol/file-storage" \
  --volume "$exporter_state_dir:/var/lib/otelcol/exporter-queue" \
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
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"INFO","message":"hostile-interpolated-message-secret-sentinel","target":"pakperk_api","comment.body":"protected-content-sentinel","authorization":"Bearer protected-token-sentinel","service.name":"spoofed-service-secret-sentinel","deployment.environment.name":"spoofed-environment-secret-sentinel"}' \
  >"$log_file"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"WARN","message":{"secret":"structured-stdout-message-secret-sentinel"},"target":"pakperk_structured_fixture"}' \
  >>"$log_file"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"ERROR","message":"external deletion ledger failed verification","target":"account_deletion::worker"}' \
  >>"$log_file"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"ERROR","message":"authenticated reading feed could not prove queue authority","target":"pakperk_api::routes::reading_feed"}' \
  >>"$log_file"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"ERROR","message":"authenticated reading feed could not prove queue authority","target":"account_deletion::worker"}' \
  >>"$log_file"
printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"ERROR","message":"external deletion ledger failed verification","target":"pakperk_api::routes::reading_feed"}' \
  >>"$log_file"

exported=0
for _ in $(seq 1 30); do
  docker logs "$container_id" >"$temporary_dir/collector.log" 2>&1
  if grep -Fq 'Body: Str(pakperk_backend_log)' "$temporary_dir/collector.log" \
    && grep -Fq 'Body: Str(external deletion ledger failed verification)' "$temporary_dir/collector.log" \
    && grep -Fq 'Body: Str(authenticated reading feed could not prove queue authority)' "$temporary_dir/collector.log" \
    && grep -Fq 'Body: Str(otlp_log_body_redacted)' "$temporary_dir/collector.log" \
    && grep -Fq 'Body: Str(startup_ready)' "$temporary_dir/collector.log" \
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
grep -Fq 'deployment.environment.name: Str(staging)' "$temporary_dir/collector.log"
grep -Fq 'code.namespace: Str(pakperk_structured_fixture)' "$temporary_dir/collector.log"
grep -Fq 'code.namespace: Str(account_deletion::worker)' "$temporary_dir/collector.log"
grep -Fq 'code.namespace: Str(pakperk_api::routes::reading_feed)' "$temporary_dir/collector.log"
if [[ "$(grep -Fc 'Body: Str(external deletion ledger failed verification)' "$temporary_dir/collector.log")" -ne 1 ]] || \
   [[ "$(grep -Fc 'Body: Str(authenticated reading feed could not prove queue authority)' "$temporary_dir/collector.log")" -ne 1 ]]; then
  echo "Collector did not preserve exactly one copy of each reviewed backend alert body." >&2
  exit 1
fi
forbidden_pattern='protected-content-sentinel|protected-token-sentinel|hostile-interpolated-message-secret-sentinel|structured-stdout-message-secret-sentinel|spoofed-service-secret-sentinel|spoofed-environment-secret-sentinel|direct-otlp-body-secret-sentinel|structured-body-secret-sentinel|spoofed-mobile-body-secret-sentinel|sensitive-(log|trace|metric)-(signal|resource)-[0-9]+-sentinel|comment\.body|authorization|log\.file\.path'
if grep -Eq "$forbidden_pattern" "$temporary_dir/collector.log"; then
  echo "Collector exported a protected stdout or direct-OTLP field." >&2
  grep -En "$forbidden_pattern" "$temporary_dir/collector.log" >&2
  exit 1
fi

docker rm --force "$container_id" >/dev/null
container_id=""

queue_fixture_uid="11234567-89ab-cdef-0123-456789abcdef"
queue_pods="$temporary_dir/queue-pods"
queue_log_dir="$queue_pods/default_pakperk-pakperk-api-queue_${queue_fixture_uid}/api"
queue_offset_state="$temporary_dir/queue-offset-state"
queue_export_state="$temporary_dir/queue-export-state"
mkdir -p "$queue_log_dir" "$queue_offset_state" "$queue_export_state"
chmod 0755 "$queue_pods" \
  "$queue_pods/default_pakperk-pakperk-api-queue_${queue_fixture_uid}" \
  "$queue_log_dir"
chmod 0777 "$queue_offset_state" "$queue_export_state"
queue_log_file="$queue_log_dir/0.log"
: >"$queue_log_file"
chmod 0644 "$queue_log_file"

network_name="pakperk-log-export-$$-$RANDOM"
docker network create "$network_name" >/dev/null
queue_source_id="$(docker run --detach --user 10001:10001 \
  --network "$network_name" \
  --volume "$queue_config:/conf/collector.yaml:ro" \
  --volume "$queue_pods:/var/log/pods:ro" \
  --volume "$queue_offset_state:/var/lib/otelcol/file-storage" \
  --volume "$queue_export_state:/var/lib/otelcol/exporter-queue" \
  "$collector_image" --config=/conf/collector.yaml)"

printf '%s stdout F %s\n' "$timestamp" \
  '{"timestamp":"2026-07-31T00:00:00.000000Z","level":"ERROR","message":"external deletion ledger failed verification","target":"account_deletion::worker"}' \
  >"$queue_log_file"

queued=0
for _ in $(seq 1 30); do
  docker logs "$queue_source_id" >"$temporary_dir/queue-source-before-restart.log" 2>&1
  if grep -Eiq 'export.*(fail|retry)|retry.*export' \
      "$temporary_dir/queue-source-before-restart.log" \
    && find "$queue_offset_state" -type f -size +0c -print -quit | grep -q . \
    && find "$queue_export_state" -type f -size +0c -print -quit | grep -q .; then
    queued=1
    break
  fi
  sleep 1
done
if [[ "$queued" != 1 ]]; then
  echo "Collector did not checkpoint and queue the ledger alert while the sink was unavailable." >&2
  sed -n '1,180p' "$temporary_dir/queue-source-before-restart.log" >&2
  exit 1
fi

docker stop "$queue_source_id" >/dev/null
# Remove the source record while the Collector is stopped. Recovery can now
# succeed only from the persisted exporter queue, never from a filelog replay.
: >"$queue_log_file"
queue_sink_id="$(docker run --detach --user 10001:10001 \
  --name "$sink_name" \
  --network "$network_name" \
  --volume "$sink_config:/conf/collector.yaml:ro" \
  "$collector_image" --config=/conf/collector.yaml)"
docker start "$queue_source_id" >/dev/null

recovered=0
for _ in $(seq 1 40); do
  docker logs "$queue_sink_id" >"$temporary_dir/queue-sink.log" 2>&1
  if grep -Fq 'Body: Str(external deletion ledger failed verification)' \
      "$temporary_dir/queue-sink.log" \
    && grep -Fq 'code.namespace: Str(account_deletion::worker)' \
      "$temporary_dir/queue-sink.log"; then
    recovered=1
    break
  fi
  sleep 1
done
if [[ "$recovered" != 1 ]]; then
  echo "Collector did not recover the checkpointed ledger alert from its persistent exporter queue." >&2
  docker logs "$queue_source_id" >&2 || true
  sed -n '1,180p' "$temporary_dir/queue-sink.log" >&2
  exit 1
fi

echo "Backend stdout and direct OTLP signals were redacted, and the checkpointed ledger alert survived a sink outage plus same-Pod Collector restart."
