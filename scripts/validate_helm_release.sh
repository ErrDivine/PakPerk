#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$project_dir/deploy/helm/pakperk"
fixture="$chart/ci/staging-values.yaml"
production_fixture="$chart/ci/production-render-values.yaml"
ingress_controller_values="$project_dir/deploy/helm/ingress-nginx-production-values.yaml"
helm_bin="${HELM_BIN:-helm}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-helm-validation.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
rendered="$temporary_dir/rendered.yaml"
http_moderation_rendered="$temporary_dir/http-moderation-rendered.yaml"
production_rendered="$temporary_dir/production-rendered.yaml"
long_name_production_rendered="$temporary_dir/long-name-production-rendered.yaml"
long_name_collision_rendered="$temporary_dir/long-name-collision-rendered.yaml"
long_fullname_production_rendered="$temporary_dir/long-fullname-production-rendered.yaml"
long_fullname_collision_rendered="$temporary_dir/long-fullname-collision-rendered.yaml"
production_guest_rendered="$temporary_dir/production-guest-rendered.yaml"
binding_variants_dir="$temporary_dir/release-binding-variants"
chart_version_rendered="$binding_variants_dir/chart-version.yaml"
app_version_rendered="$binding_variants_dir/app-version.yaml"
legal_policy_rendered="$binding_variants_dir/legal-policy.yaml"
external_accounts_rendered="$temporary_dir/external-accounts-rendered.yaml"
metadata_llm_rotation_rendered="$temporary_dir/metadata-llm-rotation-rendered.yaml"
metadata_db_rotation_rendered="$temporary_dir/metadata-db-rotation-rendered.yaml"
metadata_boundary_values="$temporary_dir/metadata-boundary-values.yaml"
metadata_boundary_rendered="$temporary_dir/metadata-boundary-rendered.yaml"
metadata_overflow_values="$temporary_dir/metadata-overflow-values.yaml"
rejection_index=0

collector_checksum_template="$(grep -F 'checksum/config:' "$chart/templates/otel-collector.yaml")"
for required_checksum_input in '.Chart.Version' '.Values.environment' 'toJson .Values.otelCollector'; do
  if [[ "$collector_checksum_template" != *"$required_checksum_input"* ]]; then
    echo "Collector rollout checksum omits $required_checksum_input." >&2
    exit 1
  fi
done

site_checksum_template="$(grep -F 'checksum/site-config:' "$chart/templates/site.yaml")"
for required_checksum_input in '.Chart.Version' '.Values.environment' 'toJson .Values.mobileAssociations'; do
  if [[ "$site_checksum_template" != *"$required_checksum_input"* ]]; then
    echo "Site rollout checksum omits $required_checksum_input." >&2
    exit 1
  fi
done

expect_template_rejection() {
  local description="$1"
  local expected_message="$2"
  shift 2
  rejection_index=$((rejection_index + 1))
  local rejection_log="$temporary_dir/rejection-$rejection_index.log"

  if "$helm_bin" template pakperk "$chart" "$@" >"$rejection_log" 2>&1; then
    echo "Chart accepted $description." >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$rejection_log"; then
    echo "Chart rejected $description for an unexpected reason; wanted: $expected_message" >&2
    sed -n '1,20p' "$rejection_log" >&2
    exit 1
  fi
}

"$helm_bin" lint "$chart" --values "$fixture"
"$helm_bin" template pakperk "$chart" --values "$fixture" >"$rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set api.commentModerationProvider=http \
  --set-string api.commentModerationUrl=https://moderation.staging.pakperk.app/v1/evaluate \
  >"$http_moderation_rendered"
"$helm_bin" lint "$chart" --values "$fixture" --values "$production_fixture"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" >"$production_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-string public.oidcOrigin=https://identity.staging.pakperk.app:443 \
  --set-string public.oidcIssuer=https://identity.staging.pakperk.app:443/realms/pakperk \
  --set-string deletionWorker.keycloakAdminBaseUrl=https://identity.staging.pakperk.app:443/ \
  --set-string paperWorker.llmBaseUrl=https://model.staging.pakperk.app:443/v1/ \
  >/dev/null
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-string public.oidcIssuer=https://identity.staging.pakperk.app/tenants/reference/realms/pakperk \
  >/dev/null
trusted_proxy_boundary_json="$(python3 -c 'import json; print(json.dumps([f"10.80.0.{index}/32" for index in range(64)]))')"
trusted_proxy_overflow_json="$(python3 -c 'import json; print(json.dumps([f"10.80.0.{index}/32" for index in range(65)]))')"
long_oci_repository="$(python3 -c 'print("ghcr.io/pakperk/" + "a" * 240)')"
overlong_dns_host="$(python3 -c 'print(".".join(["a"] * 126 + ["app"]))')"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set paperWorker.leaseSeconds=30 \
  --set paperWorker.pollIntervalMs=29999 \
  --set-string paperWorker.arxivCategories=cs.AI \
  --set-string paperWorker.arxivContactEmail=research-ops@pakperk.app \
  --set-string paperWorker.llmChatModel=provider/chat-v1 \
  --set-string paperWorker.llmEmbeddingModel=provider/embedding-v1 \
  --set deletionWorker.leaseSeconds=60 \
  --set deletionWorker.pollIntervalMs=59999 \
  --set deletionWorker.retryBaseSeconds=10 \
  --set deletionWorker.retryMaxSeconds=11 \
  --set deletionLedger.retentionDays=400 \
  --set deletionLedger.securityRetentionDays=400 \
  --set-json "api.trustedProxyCidrs=$trusted_proxy_boundary_json" \
  --set-string migration.confirmBackupId=pitr-20260801T020000Z-a7f9 \
  --set migration.expectedVersion=10 \
  --set-json 'metadataSync.manifestJson="{\"papers\":[{\"arxiv_id\":\"2401.12345v2\"}]}"' \
  >/dev/null
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-string image.repository=registry.pakperk.app:5000/pakperk/backend \
  --set-string siteImage.repository=registry.pakperk.app:5000/pakperk/site \
  --set-string grobid.image.repository=docker.io/grobid/grobid \
  --set-string otelCollector.image.repository=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib \
  >/dev/null
python3 - "$metadata_boundary_values" "$metadata_overflow_values" <<'PY'
import pathlib
import sys

boundary_path, overflow_path = map(pathlib.Path, sys.argv[1:])


def manifest(size: int) -> str:
    prefix = '{"papers":[{"arxiv_id":"2401.12345"}],"padding":"'
    suffix = '"}'
    return prefix + ("x" * (size - len(prefix) - len(suffix))) + suffix


def values_document(value: str) -> str:
    return "metadataSync:\n  manifestJson: |-\n    " + value + "\n"


boundary_path.write_text(values_document(manifest(1_048_000)), encoding="utf-8")
overflow_path.write_text(values_document(manifest(1_048_001)), encoding="utf-8")
PY
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$metadata_boundary_values" >"$metadata_boundary_rendered"
python3 - "$metadata_boundary_rendered" <<'PY'
import json
import pathlib
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
prefix = "  manifest.json: "
encoded = next(
    (line[len(prefix):] for line in rendered.splitlines() if line.startswith(prefix)),
    None,
)
if encoded is None:
    raise SystemExit("rendered metadata ConfigMap is missing manifest.json")
manifest = json.loads(encoded)
if len(manifest.encode("utf-8")) != 1_048_000:
    raise SystemExit("rendered metadata manifest did not preserve the validated byte boundary exactly")
if not manifest.startswith('{"papers":[{"arxiv_id":"2401.12345"}],"padding":"'):
    raise SystemExit("rendered metadata manifest content changed")
PY
if "$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$metadata_overflow_values" >/dev/null 2>&1; then
  echo "Chart accepted a metadata manifest above its ConfigMap-safe byte boundary." >&2
  exit 1
fi
mkdir -p "$binding_variants_dir"
binding_mutations=(
  'image.repository=ghcr.io/pakperk/pakperk-contract-variant'
  'image.digest=sha256:1111111111111111111111111111111111111111111111111111111111111111'
  'siteImage.repository=ghcr.io/pakperk/pakperk-site-contract-variant'
  'siteImage.digest=sha256:2222222222222222222222222222222222222222222222222222222222222222'
  'grobid.image.repository=grobid/grobid-contract-variant'
  'grobid.image.digest=sha256:3333333333333333333333333333333333333333333333333333333333333333'
  'otelCollector.image.repository=ghcr.io/open-telemetry/pakperk-contract-variant'
  'otelCollector.image.digest=sha256:4444444444444444444444444444444444444444444444444444444444444444'
)
binding_variant_paths=()
for index in "${!binding_mutations[@]}"; do
  variant_path="$binding_variants_dir/image-$index.yaml"
  "$helm_bin" template pakperk "$chart" \
    --values "$fixture" \
    --values "$production_fixture" \
    --set-string "${binding_mutations[$index]}" >"$variant_path"
  binding_variant_paths+=("$variant_path")
done
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string public.documentVersion=2026-08-02 \
  --set-string policy.termsVersion=2026-08-02 \
  --set-string policy.communityGuidelinesVersion=2026-08-02 >"$legal_policy_rendered"
chart_version_mutation="$temporary_dir/chart-version-mutation"
app_version_mutation="$temporary_dir/app-version-mutation"
cp -R "$chart" "$chart_version_mutation"
cp -R "$chart" "$app_version_mutation"
python3 - "$chart_version_mutation/Chart.yaml" "$app_version_mutation/Chart.yaml" <<'PY'
import pathlib
import sys

chart_path, app_path = map(pathlib.Path, sys.argv[1:])
chart_source = chart_path.read_text(encoding="utf-8")
app_source = app_path.read_text(encoding="utf-8")
chart_path.write_text(
    chart_source.replace("version: 0.2.1\n", "version: 0.2.2\n", 1),
    encoding="utf-8",
)
app_path.write_text(
    app_source.replace('appVersion: "0.2.0"\n', 'appVersion: "0.2.1"\n', 1),
    encoding="utf-8",
)
PY
"$helm_bin" template pakperk "$chart_version_mutation" \
  --values "$fixture" \
  --values "$production_fixture" >"$chart_version_rendered"
"$helm_bin" template pakperk "$app_version_mutation" \
  --values "$fixture" \
  --values "$production_fixture" >"$app_version_rendered"
binding_variant_paths+=(
  "$legal_policy_rendered"
  "$chart_version_rendered"
  "$app_version_rendered"
)
"$helm_bin" template pakperk-production-release-common-prefix-aaaaaaaaaa1 "$chart" \
  --values "$fixture" \
  --values "$production_fixture" >"$long_name_production_rendered"
"$helm_bin" template pakperk-production-release-common-prefix-aaaaaaaaaa2 "$chart" \
  --values "$fixture" \
  --values "$production_fixture" >"$long_name_collision_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string fullnameOverride=pakperk-production-fullname-common-prefix-aaaaaaaaaaaaaaaaaaaa1 >"$long_fullname_production_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string fullnameOverride=pakperk-production-fullname-common-prefix-aaaaaaaaaaaaaaaaaaaa2 >"$long_fullname_collision_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set features.accounts=false \
  --set features.library=false \
  --set features.libraryWrites=false \
  --set features.comments=false \
  --set features.commentCreation=false \
  --set features.accountDeletion=false \
  --set deletionWorker.enabled=false \
  --set-string releaseEvidence.moderationReadinessId= \
  --set-string releaseEvidence.accountDeletionE2eId= \
  --set-string releaseEvidence.restoreDrillId= >"$production_guest_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set serviceAccount.create=false \
  --set-string serviceAccount.name=platform-pakperk >"$external_accounts_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-string secret.llmApiKeyKey=ROTATED_LLM_API_KEY >"$metadata_llm_rotation_rendered"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-string secret.metadataSyncDatabaseUrlKey=ROTATED_METADATA_SYNC_DATABASE_URL \
  >"$metadata_db_rotation_rendered"

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
grep -Fq -- '-migration-*_*/migrate/*.log' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/limit-rps: "5"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/enable-access-log: "false"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-read-timeout: "75"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-send-timeout: "75"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/proxy-body-size: "65536"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/limit-rps: "20"' "$rendered"
grep -Fq 'nginx.ingress.kubernetes.io/limit-connections: "40"' "$rendered"
for exact_edge_setting in \
  'hsts: "true"' \
  'hsts-include-subdomains: "true"' \
  'hsts-max-age: "63072000"' \
  'hsts-preload: "true"'; do
  if [[ "$(grep -Fxc "    $exact_edge_setting" "$ingress_controller_values")" -ne 1 ]]; then
    echo "Ingress controller HSTS overlay is missing exact setting: $exact_edge_setting" >&2
    exit 1
  fi
done
grep -Fq 'name: API_ORIGIN_HASH_SECRET_FILE' "$rendered"
grep -Fq 'name: API_TRUSTED_PROXY_CIDRS' "$rendered"
grep -Fq 'documentVersion: "2026-07-31"' "$rendered"
grep -Fq 'name: CURRENT_TERMS_VERSION, value: "2026-07-31"' "$rendered"
grep -Fq 'name: CURRENT_COMMUNITY_GUIDELINES_VERSION, value: "2026-07-31"' "$rendered"
if grep -Fq 'app.kubernetes.io/component: alert-policy' "$rendered" || \
   grep -Fq 'pakperk-production-alert-policy.json' "$rendered"; then
  echo "Staging render attached the production-only alert policy." >&2
  exit 1
fi
grep -Fq 'environment: "production"' "$production_rendered"
grep -Fq 'documentVersion: "2026-08-01"' "$production_rendered"
grep -Fq 'name: CURRENT_TERMS_VERSION, value: "2026-08-01"' "$production_rendered"
grep -Fq 'name: CURRENT_COMMUNITY_GUIDELINES_VERSION, value: "2026-08-01"' "$production_rendered"
grep -Fq 'app.kubernetes.io/component: alert-policy' "$production_rendered"
grep -Fq 'pakperk.app/alert-policy-sha256: "sha256:17d4e5087723d78da7a61486af6170eff238a69d2254c201eaa7860393172702"' "$production_rendered"
grep -Fq 'app.kubernetes.io/component: release-evidence' "$production_rendered"
grep -Fq 'legalReviewId: "sha256:f89d44fee80d431539b2b3c4df101f00d5ad0aa0af150e9963d2d9f20b0565c2"' "$production_rendered"
grep -Fq 'alertPolicySha256: "sha256:17d4e5087723d78da7a61486af6170eff238a69d2254c201eaa7860393172702"' "$production_rendered"
grep -Fq 'pakperk.app/release-binding-schema: "1"' "$production_rendered"
grep -Fq 'imageIdentities.json:' "$production_rendered"
grep -Fq 'chartIdentity.json:' "$production_rendered"
grep -Fq 'legalPolicy.json:' "$production_rendered"
grep -Fq 'releaseContract.json:' "$production_rendered"
grep -Fq 'immutable: true' "$production_rendered"
grep -Fq 'strictContentReviewId: "sha256:0946ee59d150a1e065ba7d02eb1c3e2fa8323feca8b9c21de388eb76f2ab3cc8"' "$production_guest_rendered"
grep -Fq 'moderationReadinessId: ""' "$production_guest_rendered"
grep -Fq 'accountDeletionE2eId: ""' "$production_guest_rendered"
grep -Fq 'restoreDrillId: ""' "$production_guest_rendered"
python3 - "$production_rendered" "$chart/files/alerts/pakperk-production-alert-policy.json" <<'PY'
import pathlib
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(keepends=True)
source = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
marker = "  pakperk-production-alert-policy.json: |\n"
try:
    start = rendered.index(marker) + 1
except ValueError as error:
    raise SystemExit("rendered alert-policy ConfigMap data key is missing") from error
embedded = []
for line in rendered[start:]:
    if not line.startswith("    "):
        break
    embedded.append(line[4:])
if "".join(embedded) != source:
    raise SystemExit("rendered alert-policy ConfigMap bytes differ from the checksummed source policy")
PY
production_evidence_name="$(awk '/^  name: .*release-evidence-/ { print $2; exit }' "$production_rendered")"
production_guest_evidence_name="$(awk '/^  name: .*release-evidence-/ { print $2; exit }' "$production_guest_rendered")"
if [[ -z "$production_evidence_name" || -z "$production_guest_evidence_name" || "$production_evidence_name" == "$production_guest_evidence_name" ]]; then
  echo "Immutable release-evidence ConfigMap name does not bind the environment feature set." >&2
  exit 1
fi
python3 - "$production_rendered" "${binding_variant_paths[@]}" <<'PY'
import hashlib
import json
import pathlib
import re
import sys


def release_binding(path: str) -> tuple[str, str, dict]:
    source = pathlib.Path(path).read_text(encoding="utf-8")
    names = re.findall(
        r"(?m)^  name: (\S+-release-evidence-[0-9a-f]{12})\s*$",
        source,
    )
    annotations = re.findall(
        r'(?m)^    pakperk[.]app/release-binding-sha256: "sha256:([0-9a-f]{64})"$',
        source,
    )
    encoded_contracts = re.findall(
        r"(?m)^  releaseContract[.]json: (.+)$",
        source,
    )
    if len(names) != 1 or len(annotations) != 1 or len(encoded_contracts) != 1:
        raise SystemExit(f"{path} has an ambiguous release-evidence binding")
    try:
        contract = json.loads(json.loads(encoded_contracts[0]))
    except (json.JSONDecodeError, TypeError) as error:
        raise SystemExit(f"{path} releaseContract.json is not canonical JSON") from error
    canonical = json.dumps(contract, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if annotations[0] != digest or not names[0].endswith(digest[:12]):
        raise SystemExit(f"{path} release binding digest does not address its contract")
    return names[0], digest, contract


baseline_name, baseline_digest, contract = release_binding(sys.argv[1])
if set(contract) != {
    "schemaVersion",
    "environment",
    "features",
    "releaseEvidence",
    "alertPolicySha256",
    "images",
    "chart",
    "legalPolicy",
} or contract["schemaVersion"] != 1:
    raise SystemExit("release contract has an incomplete or unknown top-level shape")
if set(contract["images"]) != {"backend", "site", "grobid", "otelCollector"}:
    raise SystemExit("release contract does not bind every deployed image identity")
for component, identity in contract["images"].items():
    if set(identity) != {"repository", "digest"} or not identity["repository"]:
        raise SystemExit(f"release contract image identity is malformed: {component}")
    if re.fullmatch(r"sha256:[0-9a-f]{64}", identity["digest"]) is None:
        raise SystemExit(f"release contract image digest is malformed: {component}")
if contract["chart"] != {
    "name": "pakperk",
    "version": "0.2.1",
    "appVersion": "0.2.0",
}:
    raise SystemExit("release contract does not bind the exact chart/app identity")
if contract["legalPolicy"] != {
    "documentVersion": "2026-08-01",
    "termsVersion": "2026-08-01",
    "communityGuidelinesVersion": "2026-08-01",
    "fulltext": "strict",
}:
    raise SystemExit("release contract does not bind the exact legal/full-text policy")

variant_bindings = [release_binding(path) for path in sys.argv[2:]]
if any(name == baseline_name or digest == baseline_digest for name, digest, _ in variant_bindings):
    raise SystemExit("a release-contract input changed without changing its content address")
if len({digest for _, digest, _ in variant_bindings}) != len(variant_bindings):
    raise SystemExit("distinct release-contract mutations produced the same binding")
PY
python3 - \
  "$long_name_production_rendered" \
  "$long_name_collision_rendered" \
  "$long_fullname_production_rendered" \
  "$long_fullname_collision_rendered" <<'PY'
import pathlib
import re
import sys

name_sets = []
for path in sys.argv[1:]:
    source = pathlib.Path(path).read_text(encoding="utf-8")
    metadata_names = re.findall(r"(?m)^  name: (\S+)\s*$", source)
    if (
        not metadata_names
        or any(len(name) > 63 for name in metadata_names)
        or any(
            re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", name) is None
            for name in metadata_names
        )
    ):
        raise SystemExit("a long Helm name produced invalid or duplicate metadata.name values")
    for component in ("alert-policy", "release-evidence"):
        matching = [
            name
            for name in metadata_names
            if re.search(rf"-{component}-[0-9a-f]{{12}}$", name)
        ]
        if len(matching) != 1 or len(matching[0]) > 63:
            raise SystemExit(f"the {component} ConfigMap did not preserve its digest suffix")
    name_sets.append(set(metadata_names))
for first, second, label in (
    (name_sets[0], name_sets[1], "release names"),
    (name_sets[2], name_sets[3], "fullname overrides"),
):
    overlap = first & second
    if overlap:
        raise SystemExit(
            f"long {label} with a common prefix collide on metadata names: {sorted(overlap)[:3]}"
        )
PY
if [[ "$(grep -Fc 'name: ARXIV_USER_AGENT, value: "Pakperk/0.2.0"' "$rendered")" -ne 3 ]]; then
  echo "Every arXiv client must use the release-version agent exactly once; contact is appended by the client." >&2
  exit 1
fi
grep -Fq 'value: "10.244.0.0/16"' "$rendered"
grep -Fq 'path: /v1/logs' "$rendered"
grep -Fq 'path: /health/ready' "$rendered"
grep -Fq 'chown 0:0 /work' "$rendered"
grep -Fq 'rm -f /work/LLM_API_KEY' "$rendered"
grep -Fq 'install -m 0400 /source/LLM_API_KEY /work/LLM_API_KEY' "$rendered"
grep -Fq 'chown 10001:10001 /work/LLM_API_KEY' "$rendered"
if grep -Fq '/source/COMMENT_MODERATION_TOKEN' "$rendered" || grep -Fq 'name: COMMENT_MODERATION_TOKEN_FILE' "$rendered"; then
  echo "Rules moderation unexpectedly mounted or configured the HTTP provider credential." >&2
  exit 1
fi
grep -Fq 'install -m 0400 /source/COMMENT_MODERATION_TOKEN /work/COMMENT_MODERATION_TOKEN' "$http_moderation_rendered"
grep -Fq 'chown 10001:10001 /work/COMMENT_MODERATION_TOKEN' "$http_moderation_rendered"
grep -Fq 'key: COMMENT_MODERATION_TOKEN, path: COMMENT_MODERATION_TOKEN' "$http_moderation_rendered"
grep -Fq 'name: COMMENT_MODERATION_PROVIDER, value: "http"' "$http_moderation_rendered"
grep -Fq 'name: COMMENT_MODERATION_URL, value: "https://moderation.staging.pakperk.app/v1/evaluate"' "$http_moderation_rendered"
grep -Fq 'name: COMMENT_MODERATION_TOKEN_FILE, value: "/var/run/pakperk-secrets/COMMENT_MODERATION_TOKEN"' "$http_moderation_rendered"
grep -Fq 'name: COMMENT_MODERATION_TIMEOUT_MS, value: "2000"' "$http_moderation_rendered"
grep -Fq 'chown 10001:10001 /work' "$rendered"
grep -Fq 'mkdir -p /ledger/data; chown 0:0 /ledger/data; chmod 0700 /ledger/data; chown 10001:10001 /ledger/data' "$rendered"
python3 - \
  "$rendered" \
  "$production_rendered" \
  "$external_accounts_rendered" \
  "$metadata_llm_rotation_rendered" \
  "$metadata_db_rotation_rendered" <<'PY'
import pathlib
import re
import sys

rendered = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
production_rendered = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
external_accounts_rendered = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
metadata_llm_rotation_rendered = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
metadata_db_rotation_rendered = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")
documents = re.split(r"(?m)^---\s*$", rendered)
if re.search(r"chown 10001:10001 /work\n\s+chmod 0700 /work", rendered):
    raise SystemExit("secret init relinquishes its directory before materialization")
if re.search(r"install\s+[^\n]*\s-(?:o|g)(?:\s|$)", rendered):
    raise SystemExit("secret init uses install ownership flags that need CAP_FOWNER")

migration_hooks = {}
for document in documents:
    if "app.kubernetes.io/component: migration" not in document:
        continue
    kind_match = re.search(r"(?m)^kind:\s+(\S+)\s*$", document)
    if kind_match is None or "helm.sh/hook: pre-install,pre-upgrade" not in document:
        continue
    kind = kind_match.group(1)
    if kind in migration_hooks:
        raise SystemExit(f"duplicate migration hook kind {kind}")
    migration_hooks[kind] = document

expected_weights = {"ServiceAccount": "-30", "NetworkPolicy": "-20", "Job": "-10"}
if set(migration_hooks) != set(expected_weights):
    raise SystemExit(
        f"migration hooks must contain exactly {sorted(expected_weights)}; got {sorted(migration_hooks)}"
    )
for kind, expected_weight in expected_weights.items():
    document = migration_hooks[kind]
    weight_match = re.search(r'(?m)^\s+helm\.sh/hook-weight:\s+"?(-?\d+)"?\s*$', document)
    if weight_match is None or weight_match.group(1) != expected_weight:
        raise SystemExit(f"migration {kind} must use hook weight {expected_weight}")
    if "helm.sh/hook-delete-policy: before-hook-creation" not in document:
        raise SystemExit(f"migration {kind} must be replaced only before the next hook run")
    if "hook-succeeded" in document:
        raise SystemExit(f"migration {kind} is deleted before later-weighted migration hooks finish")

service_account = migration_hooks["ServiceAccount"]
job = migration_hooks["Job"]
service_account_name = re.search(r"(?m)^\s+name:\s+(\S+)\s*$", service_account)
job_service_account = re.search(r"(?m)^\s+serviceAccountName:\s+(\S+)\s*$", job)
if service_account_name is None or job_service_account is None:
    raise SystemExit("migration Job or dedicated ServiceAccount name is missing")
if service_account_name.group(1) != job_service_account.group(1):
    raise SystemExit("migration Job does not use its dedicated ServiceAccount")
if job_service_account.group(1) == "default":
    raise SystemExit("migration Job uses the namespace default ServiceAccount")
if "automountServiceAccountToken: false" not in service_account or "automountServiceAccountToken: false" not in job:
    raise SystemExit("migration ServiceAccount token automount must be disabled on the account and Pod")

migration_policy = migration_hooks["NetworkPolicy"]
if "app.kubernetes.io/component: migration" not in migration_policy or "ingress: []" not in migration_policy:
    raise SystemExit("migration NetworkPolicy does not select and deny ingress to migration Pods")
if 'cidr: "198.51.100.10/32"' not in migration_policy or "port: 5432" not in migration_policy:
    raise SystemExit("migration NetworkPolicy is missing its reviewed database egress")

expected_otel_names = {
    "staging": {
        "pakperk-api-staging",
        "pakperk-telemetry-gateway-staging",
        "pakperk-paper-worker-staging",
        "pakperk-metadata-sync-staging",
        "pakperk-deletion-worker-staging",
        "pakperk-migrate-staging",
    },
    "production": {
        "pakperk-api-production",
        "pakperk-telemetry-gateway-production",
        "pakperk-paper-worker-production",
        "pakperk-metadata-sync-production",
        "pakperk-deletion-worker-production",
        "pakperk-migrate-production",
    },
}
for environment, manifest in (("staging", rendered), ("production", production_rendered)):
    names = re.findall(r'name: OTEL_SERVICE_NAME, value: "([^"]+)"', manifest)
    if len(names) != len(set(names)) or set(names) != expected_otel_names[environment]:
        raise SystemExit(
            f"{environment} OTEL_SERVICE_NAME values do not exactly identify component and environment: {names}"
        )

def kind_of(document: str) -> str | None:
    match = re.search(r"(?m)^kind:\s+(\S+)\s*$", document)
    return match.group(1) if match else None

def component_of(document: str) -> str | None:
    match = re.search(r"(?m)^\s+app\.kubernetes\.io/component:\s+(\S+)\s*$", document)
    return match.group(1) if match else None

def metadata_name_of(document: str) -> str | None:
    match = re.search(r"(?m)^metadata:\s*\n\s+name:\s+(\S+)\s*$", document)
    return match.group(1) if match else None

workload_kinds = {"Deployment", "CronJob", "DaemonSet"}
expected_workloads = {
    "api",
    "site",
    "telemetry-gateway",
    "paper-worker",
    "metadata-sync",
    "deletion-worker",
    "grobid",
    "otel-collector",
}
workloads = {}
service_accounts = {}
network_policies = {}
for document in documents:
    kind = kind_of(document)
    component = component_of(document)
    if kind in workload_kinds and component in expected_workloads:
        if component in workloads:
            raise SystemExit(f"duplicate rendered workload for {component}")
        workloads[component] = document
    elif kind == "ServiceAccount" and component in expected_workloads:
        if component in service_accounts:
            raise SystemExit(f"duplicate rendered ServiceAccount for {component}")
        service_accounts[component] = document
    elif kind == "NetworkPolicy" and component is not None:
        network_policies[component] = document

if set(workloads) != expected_workloads:
    raise SystemExit(f"rendered workload components are incomplete: {sorted(workloads)}")
if set(service_accounts) != expected_workloads:
    raise SystemExit(f"dedicated workload ServiceAccounts are incomplete: {sorted(service_accounts)}")

used_service_accounts = set()
for component in sorted(expected_workloads):
    account_document = service_accounts[component]
    workload_document = workloads[component]
    account_name = metadata_name_of(account_document)
    workload_account_match = re.search(
        r"(?m)^\s+serviceAccountName:\s+(\S+)\s*$", workload_document
    )
    if account_name is None or workload_account_match is None:
        raise SystemExit(f"{component} workload or ServiceAccount name is missing")
    workload_account = workload_account_match.group(1)
    if account_name != workload_account or workload_account == "default":
        raise SystemExit(f"{component} workload does not use its matching non-default ServiceAccount")
    if "automountServiceAccountToken: false" not in account_document:
        raise SystemExit(f"{component} ServiceAccount permits token automount")
    if "automountServiceAccountToken: false" not in workload_document:
        raise SystemExit(f"{component} workload permits token automount")
    used_service_accounts.add(workload_account)
if len(used_service_accounts) != len(expected_workloads):
    raise SystemExit("multiple workloads share one ServiceAccount")

external_workloads = {}
external_component_accounts = set()
for document in re.split(r"(?m)^---\s*$", external_accounts_rendered):
    kind = kind_of(document)
    component = component_of(document)
    if kind in workload_kinds and component in expected_workloads:
        external_workloads[component] = document
    elif kind == "ServiceAccount" and component in expected_workloads:
        external_component_accounts.add(component)
if external_component_accounts:
    raise SystemExit(
        f"serviceAccount.create=false still rendered component accounts: {sorted(external_component_accounts)}"
    )
if set(external_workloads) != expected_workloads:
    raise SystemExit("externally managed ServiceAccount render omitted a workload")
for component, document in external_workloads.items():
    match = re.search(r"(?m)^\s+serviceAccountName:\s+(\S+)\s*$", document)
    expected_name = f"platform-pakperk-{component}"
    if match is None or match.group(1) != expected_name:
        raise SystemExit(f"{component} did not derive external ServiceAccount {expected_name}")

for document in documents:
    if kind_of(document) in {"Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"}:
        raise SystemExit("chart unexpectedly grants Kubernetes RBAC to application workloads")

metadata_sync = workloads["metadata-sync"]
for required in (
    "name: DATABASE_URL",
    "name: ARXIV_CONTACT_EMAIL",
    "name: ARXIV_USER_AGENT",
    'name: OTEL_SERVICE_NAME, value: "pakperk-metadata-sync-staging"',
    "name: OTEL_EXPORTER_OTLP_ENDPOINT",
    "imagePullSecrets:",
):
    if required not in metadata_sync:
        raise SystemExit(f"metadata-sync is missing its metadata-only runtime input: {required}")
for forbidden in (
    "LLM_",
    "GROBID_URL",
    "FULLTEXT_POLICY",
    "EMBEDDING_DIMENSION",
    "WORKER_ID",
    "RUN_MIGRATIONS",
    "DEMO_MODE",
    "owner-secrets",
    "secret-source",
    "materialize-owner-only-secrets",
    "initContainers:",
):
    if forbidden in metadata_sync:
        raise SystemExit(f"metadata-sync retained a worker-only capability: {forbidden}")

def metadata_checksum(manifest: str) -> str:
    for document in re.split(r"(?m)^---\s*$", manifest):
        if kind_of(document) == "CronJob" and component_of(document) == "metadata-sync":
            match = re.search(r"(?m)^\s+checksum/runtime-secrets:\s+([a-f0-9]{64})\s*$", document)
            if match:
                return match.group(1)
    raise SystemExit("metadata-sync runtime Secret checksum is missing")

base_metadata_checksum = metadata_checksum(rendered)
if metadata_checksum(metadata_llm_rotation_rendered) != base_metadata_checksum:
    raise SystemExit("metadata-sync checksum still depends on the unrelated LLM Secret key")
if metadata_checksum(metadata_db_rotation_rendered) == base_metadata_checksum:
    raise SystemExit("metadata-sync checksum does not depend on its database Secret key")

metadata_policy = network_policies.get("metadata-sync")
grobid_policy = network_policies.get("grobid")
paper_policy = network_policies.get("paper-worker")
if metadata_policy is None or grobid_policy is None or paper_policy is None:
    raise SystemExit("metadata-sync, paper-worker, or GROBID NetworkPolicy is missing")
if "app.kubernetes.io/component: grobid" in metadata_policy or "port: 8070" in metadata_policy:
    raise SystemExit("metadata-sync NetworkPolicy still permits GROBID egress")
for required in ('cidr: "198.51.100.10/32"', 'cidr: "203.0.113.20/32"', "app.kubernetes.io/component: otel-collector"):
    if required not in metadata_policy:
        raise SystemExit(f"metadata-sync NetworkPolicy is missing required bounded egress: {required}")
if 'cidr: "203.0.113.21/32"' in metadata_policy:
    raise SystemExit("metadata-sync NetworkPolicy can reach the model-provider range")
for required in ('cidr: "203.0.113.20/32"', 'cidr: "203.0.113.21/32"'):
    if required not in paper_policy:
        raise SystemExit(f"paper worker is missing required provider egress: {required}")
if "app.kubernetes.io/component: grobid" not in paper_policy or "port: 8070" not in paper_policy:
    raise SystemExit("paper worker lost its required GROBID egress")
if "metadata-sync" in grobid_policy or "values: [paper-worker]" not in grobid_policy:
    raise SystemExit("GROBID ingress is not restricted to the paper worker")
PY

expect_template_rejection \
  "a missing ingress-controller namespace selector" \
  "namespaceSelector is required" \
  --values "$fixture" \
  --set-json 'networkPolicy.ingressController.namespaceSelector=null'
expect_template_rejection \
  "an empty ingress-controller namespace selector when schema validation is bypassed" \
  "networkPolicy.ingressController.namespaceSelector must contain at least one exact label" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.ingressController.namespaceSelector=null'
expect_template_rejection \
  "a missing ingress-controller pod selector" \
  "podSelector is required" \
  --values "$fixture" \
  --set-json 'networkPolicy.ingressController.podSelector=null'
expect_template_rejection \
  "an empty ingress-controller pod selector when schema validation is bypassed" \
  "networkPolicy.ingressController.podSelector must contain at least one exact label" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.ingressController.podSelector=null'

expect_template_rejection \
  "an arXiv CIDR containing a model-provider CIDR" \
  "networkPolicy.arxivHttpsCidrs entry 10.20.0.0/16 overlaps modelHttpsCidrs entry 10.20.1.0/24" \
  --values "$fixture" \
  --set-json 'networkPolicy.arxivHttpsCidrs=["10.20.0.0/16"]' \
  --set-json 'networkPolicy.modelHttpsCidrs=["10.20.1.0/24"]'
expect_template_rejection \
  "an identity-admin CIDR containing a model-provider CIDR" \
  "overlaps identityAdminHttpsCidrs" \
  --values "$fixture" \
  --set-json 'networkPolicy.modelHttpsCidrs=["10.30.1.0/24"]' \
  --set-json 'networkPolicy.identityAdminHttpsCidrs=["10.30.0.0/16"]'
expect_template_rejection \
  "equal arXiv and identity-admin CIDRs" \
  "overlaps identityAdminHttpsCidrs" \
  --values "$fixture" \
  --set-json 'networkPolicy.arxivHttpsCidrs=["10.20.0.0/24"]' \
  --set-json 'networkPolicy.identityAdminHttpsCidrs=["10.20.0.0/24"]'
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --set-json 'networkPolicy.arxivHttpsCidrs=["10.20.0.0/24"]' \
  --set-json 'networkPolicy.modelHttpsCidrs=["10.20.1.0/24"]' \
  --set-json 'networkPolicy.identityAdminHttpsCidrs=["10.20.2.0/24"]' \
  >"$temporary_dir/adjacent-egress-cidrs.yaml"

expect_template_rejection \
  "a malformed trusted-proxy CIDR" \
  "abc must be a canonical IPv4 CIDR" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'api.trustedProxyCidrs=["abc"]'
expect_template_rejection \
  "more trusted-proxy CIDRs than the API runtime accepts" \
  "api.trustedProxyCidrs: Array must have at most 64 items" \
  --values "$fixture" \
  --set-json "api.trustedProxyCidrs=$trusted_proxy_overflow_json"
expect_template_rejection \
  "more trusted-proxy CIDRs than the API runtime accepts with schema validation bypassed" \
  "api.trustedProxyCidrs must contain at most 64 CIDR ranges" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json "api.trustedProxyCidrs=$trusted_proxy_overflow_json"
expect_template_rejection \
  "a noncanonical database CIDR with host bits" \
  "10.40.0.1/24 must start at its canonical network address" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.databaseCidrs=["10.40.0.1/24"]'
expect_template_rejection \
  "a near-internet-wide telemetry CIDR" \
  "0.0.0.0/1 must use an IPv4 prefix between /8 and /32" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.telemetryCidrs=["0.0.0.0/1"]'
expect_template_rejection \
  "an IPv6 API dependency CIDR without a strict parser" \
  "2001:db8::/32 must be a canonical IPv4 CIDR" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.apiHttpsCidrs=["2001:db8::/32"]'
expect_template_rejection \
  "an OIDC origin on a port blocked by the API NetworkPolicy" \
  "public.oidcOrigin must be an exact HTTPS origin on TCP/443 without path, query, fragment, credentials, or wildcard" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string public.oidcOrigin=https://identity.staging.pakperk.app:8443 \
  --set-string public.oidcIssuer=https://identity.staging.pakperk.app:8443/realms/pakperk
expect_template_rejection \
  "a query-bearing OIDC issuer rejected by the runtime" \
  "public.oidcIssuer must be a bounded HTTPS URL on TCP/443 below public.oidcOrigin with a nonempty safe path and no credentials, query, or fragment" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'public.oidcIssuer=https://identity.staging.pakperk.app/tenant?target=/realms/pakperk'
expect_template_rejection \
  "a fragment-bearing OIDC issuer rejected by the runtime" \
  "public.oidcIssuer must be a bounded HTTPS URL on TCP/443 below public.oidcOrigin with a nonempty safe path and no credentials, query, or fragment" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'public.oidcIssuer=https://identity.staging.pakperk.app/tenant#target=/realms/pakperk'
expect_template_rejection \
  "a Keycloak admin origin on a port blocked by the deletion-worker NetworkPolicy" \
  "deletionWorker.keycloakAdminBaseUrl must be an exact HTTPS origin on TCP/443" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string deletionWorker.keycloakAdminBaseUrl=https://identity.staging.pakperk.app:8443/
expect_template_rejection \
  "a model-provider URL on a port blocked by the paper-worker NetworkPolicy" \
  "paperWorker.llmBaseUrl must be a credential-free HTTPS URL on TCP/443 without query or fragment" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string paperWorker.llmBaseUrl=https://model.staging.pakperk.app:8443/v1/
expect_template_rejection \
  "an invalid OCI backend repository" \
  "image.repository: Does not match pattern" \
  --values "$fixture" \
  --set-string 'image.repository=bad repo'
for repository_path in image.repository siteImage.repository grobid.image.repository otelCollector.image.repository; do
  expect_template_rejection \
    "an invalid $repository_path with schema validation bypassed" \
    "$repository_path must be a lowercase tag-free OCI repository with an optional valid registry port" \
    --values "$fixture" \
    --skip-schema-validation \
    --set-string "$repository_path=bad repo"
done
expect_template_rejection \
  "an OCI repository above the distribution reference-name limit" \
  "image.repository: String length must be less than or equal to 255" \
  --values "$fixture" \
  --set-string "image.repository=$long_oci_repository"
expect_template_rejection \
  "an OCI repository above the distribution reference-name limit with schema validation bypassed" \
  "image.repository must be a lowercase tag-free OCI repository with an optional valid registry port and at most 255 characters" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string "image.repository=$long_oci_repository"
expect_template_rejection \
  "an ingress host with a leading hyphen" \
  "public.siteOrigin must be an exact HTTPS origin without path, query, fragment, credentials, or wildcard" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string ingress.siteHost=-bad.staging.pakperk.app \
  --set-string public.siteOrigin=https://-bad.staging.pakperk.app
expect_template_rejection \
  "an invalid Kubernetes IngressClass name" \
  "ingress.className must be a valid Kubernetes DNS-subdomain name" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'ingress.className=bad class'
expect_template_rejection \
  "an invalid Kubernetes TLS Secret name" \
  "ingress.tlsSecretName must be a valid Kubernetes DNS-subdomain name" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string ingress.tlsSecretName=BAD_SECRET
expect_template_rejection \
  "an invalid Kubernetes deletion-ledger PVC name" \
  "deletionLedger.existingClaim must be a valid Kubernetes DNS-subdomain name" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string deletionLedger.existingClaim=BAD_CLAIM
expect_template_rejection \
  "an enabled deletion worker without its ledger claim" \
  "account deletion or an enabled deletion worker requires a separately backed-up deletionLedger.existingClaim" \
  --values "$fixture" \
  --skip-schema-validation \
  --set features.accountDeletion=false \
  --set-string deletionLedger.existingClaim=
expect_template_rejection \
  "an enabled deletion worker bound to another ledger environment" \
  "deletionLedger.environmentId must exactly equal the canonical environment" \
  --values "$fixture" \
  --set features.accountDeletion=false \
  --set-string deletionLedger.environmentId=production
expect_template_rejection \
  "an invalid Kubernetes CPU quantity" \
  "api.resources.requests.cpu must be a nonnegative integer core count or positive millicore quantity" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string api.resources.requests.cpu=wat
expect_template_rejection \
  "an invalid Kubernetes memory quantity" \
  "api.resources.requests.memory must be a positive binary Kubernetes memory quantity" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string api.resources.requests.memory=no
expect_template_rejection \
  "a Kubernetes CPU request above its limit" \
  "api.resources.requests.cpu must not exceed its CPU limit" \
  --values "$fixture" \
  --set api.resources.requests.cpu=2 \
  --set api.resources.limits.cpu=1
expect_template_rejection \
  "a Kubernetes memory request above its limit" \
  "api.resources.requests.memory must not exceed its memory limit" \
  --values "$fixture" \
  --set-string api.resources.requests.memory=2Gi \
  --set-string api.resources.limits.memory=1024Mi
expect_template_rejection \
  "an invalid custom Pod label value" \
  "podLabels[bad] must use Kubernetes label-value grammar" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'podLabels.bad=value with spaces'
expect_template_rejection \
  "an invalid ingress-controller selector label value" \
  "networkPolicy.ingressController.podSelector[bad] must use Kubernetes label-value grammar" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'networkPolicy.ingressController.podSelector.bad=value with spaces'
expect_template_rejection \
  "an invalid Kubernetes PDB availability value" \
  "api.pdb.minAvailable must be a nonnegative integer or a percentage from 0% to 100%" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string api.pdb.minAvailable=bogus
expect_template_rejection \
  "an API termination budget equal to an ordinary request plus preStop" \
  "api.terminationGracePeriodSeconds must exceed the maximum request/chat timeout plus the five-second preStop budget" \
  --values "$fixture" \
  --set api.requestTimeoutSeconds=300 \
  --set api.chatTimeoutSeconds=1 \
  --set api.terminationGracePeriodSeconds=305
expect_template_rejection \
  "a paper-worker termination budget equal to its lease" \
  "paperWorker.terminationGracePeriodSeconds must exceed leaseSeconds" \
  --values "$fixture" \
  --set paperWorker.leaseSeconds=300 \
  --set paperWorker.terminationGracePeriodSeconds=300
expect_template_rejection \
  "a control character in the arXiv contact" \
  "paperWorker.arxivContactEmail must be a monitored, non-placeholder email address" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'paperWorker.arxivContactEmail="ops\u0007@pakperk.app"'
expect_template_rejection \
  "a numeric OIDC host normalized to loopback by the runtime" \
  "public.oidcOrigin must be an exact HTTPS origin on TCP/443 without path, query, fragment, credentials, or wildcard" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string public.oidcOrigin=https://2130706433 \
  --set-string public.oidcIssuer=https://2130706433/realms/pakperk
expect_template_rejection \
  "a numeric model-provider host normalized to loopback by the runtime" \
  "paperWorker.llmBaseUrl must be a credential-free HTTPS URL on TCP/443 without query or fragment" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string paperWorker.llmBaseUrl=https://2130706433/v1
expect_template_rejection \
  "a model-provider host above the DNS length limit" \
  "paperWorker.llmBaseUrl host must not exceed the DNS maximum of 253 characters" \
  --values "$fixture" \
  --set-string "paperWorker.llmBaseUrl=https://$overlong_dns_host/v1"
expect_template_rejection \
  "an out-of-range public origin port rejected by the runtime" \
  "public.siteOrigin must be an exact HTTPS origin without path, query, fragment, credentials, or wildcard" \
  --values "$fixture" \
  --skip-schema-validation \
  --set ingress.enabled=false \
  --set-string public.siteOrigin=https://staging.pakperk.app:99999
expect_template_rejection \
  "a reserved model-provider host" \
  "paperWorker.llmBaseUrl must not use a loopback, local, reserved, or placeholder host" \
  --values "$fixture" \
  --set-string paperWorker.llmBaseUrl=https://model.invalid/v1
expect_template_rejection \
  "a reserved Keycloak admin host" \
  "deletionWorker.keycloakAdminBaseUrl must not use a loopback, local, reserved, or placeholder host" \
  --values "$fixture" \
  --set-string deletionWorker.keycloakAdminBaseUrl=https://admin.invalid/
expect_template_rejection \
  "a reserved telemetry exporter host" \
  "otelCollector.exporterEndpoint must not use a loopback, local, reserved, or placeholder host" \
  --values "$fixture" \
  --set-string otelCollector.exporterEndpoint=https://sink.invalid:4317
expect_template_rejection \
  "two public services sharing one host" \
  "site, API, telemetry, and OIDC public origins must use distinct hosts" \
  --values "$fixture" \
  --set-string public.apiOrigin=https://staging.pakperk.app \
  --set-string ingress.apiHost=staging.pakperk.app
expect_template_rejection \
  "a paper-worker poll interval equal to its lease" \
  "paperWorker.pollIntervalMs must be shorter than leaseSeconds" \
  --values "$fixture" \
  --set paperWorker.leaseSeconds=30 \
  --set paperWorker.pollIntervalMs=30000
expect_template_rejection \
  "paper-worker categories that become empty after runtime splitting" \
  "paperWorker.arxivCategories must contain at least one nonempty category" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'paperWorker.arxivCategories=" , "'
expect_template_rejection \
  "a paper-worker category rejected by the runtime query grammar" \
  "every paperWorker.arxivCategories entry must use the runtime arXiv category grammar" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'paperWorker.arxivCategories=not valid'
expect_template_rejection \
  "a placeholder arXiv contact rejected during runtime client construction" \
  "paperWorker.arxivContactEmail must be a monitored, non-placeholder email address" \
  --values "$fixture" \
  --set-string paperWorker.arxivContactEmail=research@example.com
expect_template_rejection \
  "an unsafe model ID rejected during runtime provider construction" \
  "paperWorker model IDs must contain 1 to 128 safe provider identifier characters" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string 'paperWorker.llmChatModel=bad model'
expect_template_rejection \
  "a deletion-worker poll interval equal to its lease" \
  "deletionWorker.pollIntervalMs must be shorter than leaseSeconds" \
  --values "$fixture" \
  --set deletionWorker.leaseSeconds=60 \
  --set deletionWorker.pollIntervalMs=60000
expect_template_rejection \
  "a deletion-worker retry base equal to its retry maximum" \
  "deletionWorker.retryBaseSeconds must be shorter than retryMaxSeconds" \
  --values "$fixture" \
  --set deletionWorker.retryBaseSeconds=10 \
  --set deletionWorker.retryMaxSeconds=10
expect_template_rejection \
  "a deletion-worker step timeout above the runtime maximum" \
  "deletionWorker.stepTimeoutSeconds: Must be less than or equal to 1800" \
  --values "$fixture" \
  --set deletionWorker.stepTimeoutSeconds=1801 \
  --set deletionWorker.leaseSeconds=1803 \
  --set deletionWorker.terminationGracePeriodSeconds=1804
expect_template_rejection \
  "a deletion-worker step timeout above the runtime maximum with schema validation bypassed" \
  "deletionWorker.stepTimeoutSeconds must not exceed the runtime maximum of 1800" \
  --values "$fixture" \
  --skip-schema-validation \
  --set deletionWorker.stepTimeoutSeconds=1801 \
  --set deletionWorker.leaseSeconds=1803 \
  --set deletionWorker.terminationGracePeriodSeconds=1804
expect_template_rejection \
  "deletion-ledger retention shorter than security retention" \
  "deletionLedger.retentionDays must be at least deletionLedger.securityRetentionDays" \
  --values "$fixture" \
  --set deletionLedger.retentionDays=365 \
  --set deletionLedger.securityRetentionDays=400
expect_template_rejection \
  "a migration version different from the release binary" \
  "migration.expectedVersion: Must be less than or equal to 10" \
  --values "$fixture" \
  --set migration.expectedVersion=11
expect_template_rejection \
  "a migration version different from the release binary with schema validation bypassed" \
  "migration.expectedVersion must match embedded migration version 10" \
  --values "$fixture" \
  --skip-schema-validation \
  --set migration.expectedVersion=11
expect_template_rejection \
  "a placeholder migration backup ID accepted by the old chart" \
  "migration.confirmBackupId must identify a verified real backup" \
  --values "$fixture" \
  --set-string migration.confirmBackupId=todo-backup-20260801
expect_template_rejection \
  "an invalid metadata-sync Cron schedule" \
  "metadataSync.schedule: Does not match pattern" \
  --values "$fixture" \
  --set-string metadataSync.schedule=not-a-cron
expect_template_rejection \
  "an invalid metadata-sync Cron schedule with schema validation bypassed" \
  "metadataSync.schedule must be a bounded five-field numeric or wildcard Cron schedule" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-string metadataSync.schedule=not-a-cron
expect_template_rejection \
  "an invalid scheduled metadata manifest" \
  "metadataSync.manifestJson must be a valid JSON object" \
  --values "$fixture" \
  --set-json 'metadataSync.manifestJson="not-json"'
expect_template_rejection \
  "a scheduled metadata manifest with an array root" \
  "metadataSync.manifestJson must be a valid JSON object" \
  --values "$fixture" \
  --set-json 'metadataSync.manifestJson="[]"'
expect_template_rejection \
  "a scheduled metadata manifest with a null root" \
  "metadataSync.manifestJson must be a valid JSON object" \
  --values "$fixture" \
  --set-json 'metadataSync.manifestJson="null"'
expect_template_rejection \
  "an empty scheduled metadata manifest" \
  "metadataSync.manifestJson must contain 1 to 2000 papers" \
  --values "$fixture" \
  --set-json 'metadataSync.manifestJson="{\"papers\":[]}"'
expect_template_rejection \
  "a scheduled metadata manifest with a runtime-invalid arXiv ID" \
  "every metadataSync manifest paper must be an object with a canonical arxiv_id" \
  --values "$fixture" \
  --set-json 'metadataSync.manifestJson="{\"papers\":[{\"arxiv_id\":\"not-an-id\"}]}"'
expect_template_rejection \
  "a provider CIDR with an invalid octet" \
  "10.0.0.999/24 must be a canonical IPv4 CIDR" \
  --values "$fixture" \
  --skip-schema-validation \
  --set-json 'networkPolicy.modelHttpsCidrs=["10.0.0.999/24"]'

expect_template_rejection \
  "a legal document version different from the accepted terms version" \
  "public.documentVersion, policy.termsVersion, and policy.communityGuidelinesVersion must match exactly" \
  --values "$fixture" \
  --set-string policy.termsVersion=2026-08-01
expect_template_rejection \
  "a legal document version different from the accepted Community Guidelines version" \
  "public.documentVersion, policy.termsVersion, and policy.communityGuidelinesVersion must match exactly" \
  --values "$fixture" \
  --set-string policy.communityGuidelinesVersion=2026-08-01
expect_template_rejection \
  "a mutable non-content-addressed release-evidence reference" \
  "releaseEvidence.legalReviewId: Does not match pattern" \
  --values "$fixture" \
  --set-string releaseEvidence.legalReviewId=change-123
expect_template_rejection \
  "one external Secret key shared by unrelated credentials" \
  "database URLs and every purpose-specific credential must use distinct external Secret keys" \
  --values "$fixture" \
  --set-string secret.telemetryExporterHeadersKey=LLM_API_KEY
expect_template_rejection \
  "a moderation credential reusing the model credential key" \
  "database URLs and every purpose-specific credential must use distinct external Secret keys" \
  --values "$fixture" \
  --set-string secret.commentModerationTokenKey=LLM_API_KEY
expect_template_rejection \
  "an HTTP moderation provider without an endpoint" \
  "api.commentModerationUrl must be a bounded HTTPS provider URL on TCP/443" \
  --values "$fixture" \
  --set api.commentModerationProvider=http
expect_template_rejection \
  "an HTTP moderation provider over plaintext" \
  "api.commentModerationUrl: Does not match pattern" \
  --values "$fixture" \
  --set api.commentModerationProvider=http \
  --set-string api.commentModerationUrl=http://moderation.staging.pakperk.app/v1/evaluate
expect_template_rejection \
  "HTTP moderation while comments are disabled" \
  "api.commentModerationProvider=http requires features.comments=true" \
  --values "$fixture" \
  --set api.commentModerationProvider=http \
  --set-string api.commentModerationUrl=https://moderation.staging.pakperk.app/v1/evaluate \
  --set features.comments=false \
  --set features.commentCreation=false
expect_template_rejection \
  "a latent moderation endpoint with the rules provider" \
  "api.commentModerationUrl must be empty when api.commentModerationProvider=rules" \
  --values "$fixture" \
  --set-string api.commentModerationUrl=https://moderation.staging.pakperk.app/v1/evaluate
expect_template_rejection \
  "comments with no connection reserved for coordinated writes" \
  "features.comments requires api.databasePoolSize>=2 for coordinated writes" \
  --values "$fixture" \
  --set api.databasePoolSize=1
expect_template_rejection \
  "externally managed workload identities without a ServiceAccount base name" \
  "serviceAccount.name base is required when serviceAccount.create=false" \
  --values "$fixture" \
  --set serviceAccount.create=false
expect_template_rejection \
  "a dotted ServiceAccount base that can truncate at a label boundary" \
  "the derived ServiceAccount base must be one DNS label" \
  --values "$fixture" \
  --skip-schema-validation \
  --set serviceAccount.create=false \
  --set-string serviceAccount.name=platform.pakperk
expect_template_rejection \
  "a user Pod label overriding workload identity" \
  "podLabels[app.kubernetes.io/component] is chart-owned and cannot be overridden" \
  --values "$fixture" \
  --set-string podLabels.app\\.kubernetes\\.io/component=attacker
expect_template_rejection \
  "a user Pod annotation overriding Secret rotation" \
  "cannot override a chart-owned rollout checksum" \
  --values "$fixture" \
  --set-string podAnnotations.checksum/runtime-secrets=attacker

expect_template_rejection \
  "a production render with a fixture image digest" \
  "production image digests must be signed release artifacts, not render fixtures" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_template_rejection \
  "a production render with a fixture Apple Team ID" \
  "production mobileAssociations.appleTeamId must be the protected release Team ID, not a fixture" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string mobileAssociations.appleTeamId=AAAAAAAAAA
expect_template_rejection \
  "a production render with a TEST-NET provider range" \
  "production networkPolicy.arxivHttpsCidrs cannot contain TEST-NET documentation ranges" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-json 'networkPolicy.arxivHttpsCidrs=["203.0.113.0/24"]'
expect_template_rejection \
  "a production render with a fixture backup identifier" \
  "production migration.confirmBackupId must identify verified environment backup evidence" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string migration.confirmBackupId=staging-backup-contract-fixture
expect_template_rejection \
  "a production render with a reserved support address" \
  "production public.supportEmail cannot use a reserved or placeholder domain" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string public.supportEmail=support@example.com
expect_template_rejection \
  "a production render with prototype full-text policy" \
  "production requires policy.fulltext=strict" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string policy.fulltext=prototype
expect_template_rejection \
  "a production render without legal-review evidence" \
  "production requires an immutable sha256 release-evidence ID for legal review" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.legalReviewId=
expect_template_rejection \
  "a production render without app-reviewer-flow evidence" \
  "production requires an immutable sha256 release-evidence ID for app-reviewer flow" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.reviewerFlowId=
expect_template_rejection \
  "a production render without strict-content-review evidence" \
  "production requires an immutable sha256 release-evidence ID for strict content review" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.strictContentReviewId=
expect_template_rejection \
  "production comments without moderation-readiness evidence" \
  "production comments require an immutable moderation-readiness evidence ID" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.moderationReadinessId=
expect_template_rejection \
  "production comments with account deletion disabled" \
  "production comments require the account-deletion feature and its policy controls" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set features.commentCreation=false \
  --set features.accountDeletion=false \
  --set deletionWorker.enabled=false
expect_template_rejection \
  "production accounts and library with account deletion disabled" \
  "production accounts require the account-deletion feature and its policy controls" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set features.comments=false \
  --set features.commentCreation=false \
  --set features.accountDeletion=false \
  --set deletionWorker.enabled=false
expect_template_rejection \
  "production account deletion without provider E2E evidence" \
  "production account deletion requires an immutable provider deletion E2E evidence ID" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.accountDeletionE2eId=
expect_template_rejection \
  "production account deletion without restore-drill evidence" \
  "production account deletion requires an immutable restore-drill evidence ID" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.restoreDrillId=
expect_template_rejection \
  "a production release-evidence placeholder" \
  "production releaseEvidence.reviewerFlowId cannot use an obvious placeholder digest" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set-string releaseEvidence.reviewerFlowId=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_template_rejection \
  "a production release with alert-policy packaging disabled" \
  "production requires the packaged alert policy" \
  --values "$fixture" \
  --values "$production_fixture" \
  --set alerting.enabled=false \
  --set-string alerting.policySha256=
expect_template_rejection \
  "a staging release that attaches the production-only alert policy" \
  "the packaged alert policy is production-only and cannot be enabled for staging" \
  --values "$fixture" \
  --set alerting.enabled=true \
  --set-string alerting.policySha256=sha256:17d4e5087723d78da7a61486af6170eff238a69d2254c201eaa7860393172702
expect_template_rejection \
  "a disabled alert policy with a stale digest" \
  "alerting.policySha256 must be empty when alerting.enabled=false" \
  --values "$fixture" \
  --set-string alerting.policySha256=sha256:17d4e5087723d78da7a61486af6170eff238a69d2254c201eaa7860393172702
expect_template_rejection \
  "an alert-policy digest that does not match the packaged contract" \
  "alerting.policySha256 must pin the exact packaged provider-neutral alert policy" \
  --values "$fixture" \
  --set alerting.enabled=true \
  --set-string alerting.policySha256=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

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
