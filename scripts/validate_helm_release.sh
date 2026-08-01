#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$project_dir/deploy/helm/pakperk"
fixture="$chart/ci/staging-values.yaml"
helm_bin="${HELM_BIN:-helm}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-helm-validation.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
rendered="$temporary_dir/rendered.yaml"

"$helm_bin" lint "$chart" --values "$fixture"
"$helm_bin" template pakperk "$chart" --values "$fixture" >"$rendered"

for required in \
  'kind: Deployment' \
  'kind: NetworkPolicy' \
  'kind: Ingress' \
  'kind: Job' \
  'app.kubernetes.io/component: telemetry-gateway' \
  'MOBILE_TELEMETRY_UPSTREAM_URL' \
  'ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE' \
  'ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE' \
  'PAKPERK_MIGRATION_BACKUP_ID'; do
  grep -Fq "$required" "$rendered"
done
grep -Fq 'test -f /tmp/pakperk-deletion-worker-ready' "$rendered"
grep -Fq 'kind: DaemonSet' "$rendered"
grep -Fq 'path: /var/log/pods' "$rendered"
grep -Fq 'filelog/pakperk_backend' "$rendered"
grep -Fq 'start_at: beginning' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/limit-rps: "5"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/enable-access-log: "false"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-read-timeout: "75"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-send-timeout: "75"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-body-size: "65536"' "$rendered"
grep -Fq 'name: API_ORIGIN_HASH_SECRET_FILE' "$rendered"
grep -Fq 'name: API_TRUSTED_PROXY_CIDRS' "$rendered"
if [[ "$(grep -Fc 'name: ARXIV_USER_AGENT, value: "Pakperk/0.2.0"' "$rendered")" -ne 3 ]]; then
  echo "Every arXiv client must use the release-version agent exactly once; contact is appended by the client." >&2
  exit 1
fi
grep -Fq 'value: "10.244.0.0/16"' "$rendered"
grep -Fq 'path: /v1/logs' "$rendered"
grep -Fq 'chown 0:0 /work' "$rendered"
grep -Fq 'rm -f /work/LLM_API_KEY' "$rendered"
grep -Fq 'install -m 0400 /source/LLM_API_KEY /work/LLM_API_KEY' "$rendered"
grep -Fq 'chown 10001:10001 /work/LLM_API_KEY' "$rendered"
grep -Fq 'chown 10001:10001 /work' "$rendered"
grep -Fq 'mkdir -p /ledger/data; chown 0:0 /ledger/data; chmod 0700 /ledger/data; chown 10001:10001 /ledger/data' "$rendered"
python3 - "$rendered" <<'PY'
import pathlib
import re
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if re.search(r"chown 10001:10001 /work\n\s+chmod 0700 /work", rendered):
    raise SystemExit("secret init relinquishes its directory before materialization")
if re.search(r"install\s+[^\n]*\s-(?:o|g)(?:\s|$)", rendered):
    raise SystemExit("secret init uses install ownership flags that need CAP_FOWNER")
PY

if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set public.siteOrigin=https://reserved.example.test >/dev/null 2>&1; then
  echo "Chart accepted a reserved public origin." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set paperWorker.llmBaseUrl=http://model.staging.pakperk.app/v1 >/dev/null 2>&1; then
  echo "Chart accepted a plaintext model endpoint." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set otelCollector.exporterEndpoint=telemetry.example.org:4317 >/dev/null 2>&1; then
  echo "Chart accepted an unqualified telemetry exporter endpoint." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set otelCollector.exporterEndpoint=https://telemetry-upstream.staging.pakperk.app:4318 >/dev/null 2>&1; then
  echo "Chart accepted a telemetry exporter port outside its egress policy." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set secret.paperWorkerDatabaseUrlKey=API_DATABASE_URL >/dev/null 2>&1; then
  echo "Chart accepted a shared database role Secret key." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set networkPolicy.enabled=false >/dev/null 2>&1; then
  echo "Chart accepted a deployed release without network isolation." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set-json 'api.trustedProxyCidrs=[]' >/dev/null 2>&1; then
  echo "Chart accepted anonymous API traffic without a trusted ingress proxy boundary." >&2
  exit 1
fi
if "$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set-json 'api.trustedProxyCidrs=["0.0.0.0/0"]' >/dev/null 2>&1; then
  echo "Chart accepted an internet-wide trusted proxy range." >&2
  exit 1
fi
for required_component in site paperWorker metadataSync grobid migration; do
  if "$helm_bin" template pakperk "$chart" --values "$fixture" \
    --set "$required_component.enabled=false" >/dev/null 2>&1; then
    echo "Chart accepted a release without required component $required_component." >&2
    exit 1
  fi
done

"$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set features.accountDeletion=false \
  --set deletionWorker.enabled=false >"$temporary_dir/no-deletion.yaml"
if grep -Fq 'app.kubernetes.io/component: deletion-worker' "$temporary_dir/no-deletion.yaml"; then
  echo "Deletion worker rendered while disabled." >&2
  exit 1
fi
"$helm_bin" template pakperk "$chart" --values "$fixture" \
  --set features.accounts=false \
  --set features.library=false \
  --set features.libraryWrites=false \
  --set features.comments=false \
  --set features.commentCreation=false \
  --set features.accountDeletion=false \
  --set deletionWorker.enabled=false >"$temporary_dir/guest-only.yaml"
grep -Fq 'app.kubernetes.io/component: api' "$temporary_dir/guest-only.yaml"
grep -Fq 'app.kubernetes.io/component: site' "$temporary_dir/guest-only.yaml"

echo "Helm production contract validation passed."
