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
production_rendered="$temporary_dir/production-rendered.yaml"
external_accounts_rendered="$temporary_dir/external-accounts-rendered.yaml"
metadata_llm_rotation_rendered="$temporary_dir/metadata-llm-rotation-rendered.yaml"
metadata_db_rotation_rendered="$temporary_dir/metadata-db-rotation-rendered.yaml"
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
"$helm_bin" lint "$chart" --values "$fixture" --values "$production_fixture"
"$helm_bin" template pakperk "$chart" \
  --values "$fixture" \
  --values "$production_fixture" >"$production_rendered"
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
grep -Fq 'environment: "production"' "$production_rendered"
grep -Fq 'documentVersion: "2026-08-01"' "$production_rendered"
grep -Fq 'name: CURRENT_TERMS_VERSION, value: "2026-08-01"' "$production_rendered"
grep -Fq 'name: CURRENT_COMMUNITY_GUIDELINES_VERSION, value: "2026-08-01"' "$production_rendered"
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
  "one external Secret key shared by unrelated credentials" \
  "database URLs and every purpose-specific credential must use distinct external Secret keys" \
  --values "$fixture" \
  --set-string secret.telemetryExporterHeadersKey=LLM_API_KEY
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
