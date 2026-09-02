# Deploy the Pakperk backend on a server

This guide turns the repository's deployment contracts into an operator-friendly
sequence. It is written for a staging or production server environment, whether
that is a managed Kubernetes cluster or Kubernetes installed on operator-owned
servers.

> **The supported server deployment is Kubernetes 1.29 or newer with the
> Pakperk Helm chart.** Docker Compose is a local development stack. It contains
> development passwords, a development identity provider, plaintext endpoints,
> automatic migrations, prototype full-text policy, and an API port bound on
> all interfaces. Do not expose it as a public production service.

The chart is deliberately not a one-command installer. PostgreSQL, OIDC, DNS,
TLS, registry images, secrets, backups, the deletion ledger, and telemetry are
security and recovery boundaries owned outside the chart. The deployment fails
closed until those inputs are explicit.

## Decide what “a server” means

| Target | Appropriate use | Important limitation |
| --- | --- | --- |
| Managed multi-node Kubernetes | Staging or production | You still own external services, values, evidence, and smoke tests |
| Operator-managed multi-node Kubernetes | Staging or production if the platform is reviewed | You also own control-plane, node, storage, ingress, and upgrade reliability |
| Single-node Kubernetes on one server | Private development or staging evaluation | The database, workloads, ingress, and storage can share one failure domain; this is not a resilient production topology |
| Docker Compose on a remote VM | Short-lived private developer work only | It is not the production topology and must remain behind a firewall or VPN |

This repository does not prescribe a Kubernetes distribution or cloud vendor.
Whichever platform you choose must satisfy the chart's version, storage,
NetworkPolicy, ingress, security-context, and immutable-image requirements.

## Understand what the chart owns

The chart deploys:

- the Axum API;
- the paper preparation worker;
- an independently isolated account-deletion worker;
- a pre-install/pre-upgrade migration Job;
- a scheduled metadata synchronization CronJob;
- the static public policy and association site;
- an isolated GROBID parser;
- the mobile telemetry gateway; and
- an OpenTelemetry Collector.

The chart does **not** create:

- PostgreSQL;
- Keycloak or another OIDC provider;
- public DNS, certificates, or a shared ingress controller;
- application image repositories;
- the external Kubernetes Secret;
- the deletion-ledger or optional visual-asset volumes;
- the external OTLP sink and alert adapter; or
- backups, restore points, protected evidence, or human approvals.

The API, workers, metadata sync, and migration Job use distinct PostgreSQL
roles. PostgreSQL is also Pakperk's durable queue, shared rate-limit store,
synchronization authority, and moderation source of truth. Do not add Redis,
Kafka, or another network service to “complete” this deployment unless an
accepted ADR changes the architecture.

## Prepare the operator workstation

Use a trusted workstation with access to the target cluster and protected
configuration system. Install:

- `kubectl` compatible with the cluster;
- Helm 3.18.x;
- PostgreSQL 16 `psql` or an equivalent secret-manager-backed SQL console;
- Python 3 and `jq` for repository validators; and
- the repository at the exact reviewed source revision.

Confirm the context before every render or apply:

```bash
kubectl config current-context
kubectl version
helm version
```

Use explicit, task-specific variables in the examples:

```bash
export PAKPERK_DEPLOY_ENV='staging'
export PAKPERK_K8S_NAMESPACE='pakperk-staging'
export PAKPERK_HELM_RELEASE='pakperk-staging'
export PAKPERK_VALUES_FILE='/protected/path/pakperk-staging-values.yaml'
```

The values file is environment-owned and should live in a protected system,
not in the repository. Substitute production names only after the same
candidate has passed the required staging and promotion gates. Its top-level
`environment` value must exactly equal `PAKPERK_DEPLOY_ENV`.

### Create and label the namespace first

The Secret, PVCs, and any platform-owned ServiceAccounts are namespaced, so the
namespace must exist before you can provision the chart's external inputs. For
a new environment, create it once and add stable ownership/environment labels:

```bash
kubectl create namespace "$PAKPERK_K8S_NAMESPACE"
kubectl label namespace "$PAKPERK_K8S_NAMESPACE" \
  app.kubernetes.io/part-of=pakperk \
  "pakperk.app/environment=$PAKPERK_DEPLOY_ENV" \
  --overwrite
kubectl get namespace "$PAKPERK_K8S_NAMESPACE" --show-labels
```

If the namespace already exists, do not recreate it: inspect its current
labels, ownership, quotas, default-deny policy, and admission profile before
using it. Do not blindly apply a `restricted` Pod Security label. The chart's
Collector reads `/var/log/pods` through a reviewed read-only `hostPath`, so the
platform must document the compatible admission exception or provide an
equivalent platform-owned node log agent.

## Complete the external prerequisites

Do these in order. A missing item is a deployment blocker, not a value to fill
with a placeholder.

### 1. Kubernetes, ingress, storage, and egress

The cluster must be Kubernetes 1.29 or newer and enforce the chart's non-root,
read-only-root-filesystem, seccomp, capability, token-less ServiceAccount, and
NetworkPolicy settings.

Prepare an ingress controller whose namespace and Pod labels exactly match
`networkPolicy.ingressController`. The reviewed reference configuration is
`deploy/helm/ingress-nginx-production-values.yaml`; it supplies the expected
HSTS and gzip boundary. If the platform uses a different ingress, it must
reproduce the same TLS redirect, exact-host/path, request-size/time, rate-limit,
forwarded-address, gzip, and query-safe logging behavior.

Resolve and review the actual IPv4 CIDRs needed for:

- database access;
- API HTTPS egress to OIDC and optional moderation;
- arXiv HTTPS egress;
- model-provider HTTPS egress;
- identity-admin HTTPS egress; and
- telemetry export.

The chart accepts canonical `/8` through `/32` IPv4 networks and intentionally
rejects overlapping arXiv, model, and identity-admin ranges. Standard
NetworkPolicy cannot safely express a provider hostname, so re-resolve and
review the ranges whenever a provider changes them.

Prepare a `ReadWriteMany` claim for the deletion ledger when the deletion worker
runs. It must be separately backed up from PostgreSQL and writable by
UID/GID 10001. An optional visual-asset claim must also be RWX across all
participating nodes. Do not substitute node-local or ordinary
`ReadWriteOnce` storage in a multi-node production deployment.

### 2. PostgreSQL 16 and database roles

Provision PostgreSQL 16 with these extensions in the `public` schema:

- `vector`;
- `pg_trgm`; and
- `pgcrypto`.

Create separate login roles and connection URLs for migration, API, paper
worker, metadata sync, and deletion worker. The migration role alone owns the
reviewed DDL capability. Runtime roles receive only component-specific DML.
Keycloak uses its own database and role, not the Pakperk application database.

The repository's grant matrix defines the required boundaries, but it is not an
executable role-provisioning script. The database owner must maintain and review
an environment-specific SQL/IaC grant artifact that maps those boundaries to
the tables in migrations 1 through 24. Do not replace that missing artifact with
`GRANT ALL`, schema ownership, a shared login, or the migration role in a
runtime Secret.

Every Pakperk runtime role also needs the narrow readiness grants:

```sql
GRANT USAGE ON SCHEMA public TO <runtime_role>;
GRANT SELECT (version, success, checksum)
  ON TABLE public._sqlx_migrations TO <runtime_role>;
```

That grant lets a process prove that its embedded migration history matches the
database. It must not receive write access to `_sqlx_migrations`, schema
ownership, or DDL. The detailed component privilege matrix is in the
[chart README](../deploy/helm/pakperk/README.md#database-and-provider-grant-matrix).

For a new database, `_sqlx_migrations` and the application tables do not exist
until the first migration. Do not start the API or workers and hope to grant
access while Helm waits. Follow
[Bootstrap a brand-new database in two phases](#bootstrap-a-brand-new-database-in-two-phases):
run only the migration boundary, apply and audit the runtime grants, and only
then install the ordinary workloads. Audit the grants again after every role or
schema replacement.

### 3. Public HTTPS identities

Create distinct lowercase public hosts for:

- the public site;
- the API;
- mobile telemetry; and
- the OIDC provider.

Issue trusted TLS certificates and prepare the ingress TLS Secret. Staging and
production origins must be HTTPS. Keep the browser OIDC client and native
mobile OIDC client distinct, and register their exact callback URIs from the
matching mobile flavor.

For account deletion, create a separate confidential Keycloak service account
with exactly `realm-management/manage-users`. Do not grant `realm-admin`,
`query-users`, or `view-users`. The deletion worker's readiness check performs
a bounded non-destructive Admin REST permission probe; obtaining a token alone
does not prove the integration works.

### 4. Model, arXiv, and telemetry providers

Production-shaped paper workers require an OpenAI-compatible HTTPS model
provider, explicit chat and embedding model IDs, the correct embedding
dimension, and a real monitored arXiv contact address.

Prepare an external HTTPS OTLP sink and its authentication headers. The chart's
Collector exports to it; the mobile telemetry gateway is only the public closed
schema intake. Also prepare the platform adapter that imports the reviewed alert
policy and connects named owners to real receivers. Rendering an alert
ConfigMap does not prove that anyone will be paged.

### 5. Immutable release images

The chart accepts repository plus `sha256:` digest pairs and rejects mutable
tags. The backend image contains the API, worker, deletion worker, migrator,
telemetry gateway, and admin binaries. Chart workloads select the API, worker,
deletion-worker, migrator, and gateway commands. `pakperk-admin` remains an
operator-invoked tool; the chart deliberately creates no always-running admin
Deployment. The static site is a separate image.

For an official staging or production candidate, run the protected
`publish-release-images` workflow from `main` for the exact reviewed full commit
SHA. Require its vulnerability scans, image SBOMs, immutable registry digests,
and `promotion-handoff.json`. Deploy the repositories and digests from that
handoff. Do not rebuild locally during promotion or substitute a local Docker
image ID for the registry digest.

The repository's checked-in CI values contain documentation hosts, private test
ranges, deterministic digests, and fixture credentials. They validate chart
logic only and must never be applied to a cluster.

## Create the external Secret safely

The chart references one existing Kubernetes Secret and never creates it. Use
the platform's secret manager, External Secrets integration, sealed delivery,
or another reviewed mechanism. Do not place secret bytes in the values file,
command history, annotations, logs, or release evidence.

The selected Secret key names must be distinct. The default names are visible
under `secret.*Key` in `deploy/helm/pakperk/values.yaml` and include:

- five role-specific database URLs;
- the model API key;
- the optional HTTP moderation token;
- API origin-hashing material;
- the rotation-ordered API cursor-encryption keyring;
- account identity-fingerprint keys;
- deletion-ledger signing keys;
- deletion provider-coordinate encryption keys;
- the identity-admin client secret; and
- telemetry exporter headers.

Keyring files contain at most eight unique `key_id:base64(raw-random-bytes)`
lines with the active key first. Cursor-encryption and deletion
provider-coordinate keys decode to exactly 32 bytes; identity-fingerprint and
ledger-signing keys decode to 32 through 128 bytes. Key IDs are bounded safe
identifiers, not dates or secret material. `API_ORIGIN_HASH_SECRET` is a
separate non-placeholder secret, not a keyring. Generate all production values
inside the approved secret manager; the `prepare_dev_*` scripts create local
development material and are not a production provisioning workflow. Preserve
older verification or decryption keys for the full record, cursor, and
recoverable-backup windows defined by the corresponding runbook.

Set `secret.existingSecret` to the Secret name and give
`secret.rotationVersion` a non-secret version identifier. After changing the
external Secret, increment `rotationVersion` so every consuming Pod rolls.
Cursor encryption uses a two-phase rotation: first append and roll while the old
key remains first, then promote the new key and roll again. Removing the old
key before all old cursors expire can split a rolling deployment.

## Build the environment values file

Start from the field structure in `deploy/helm/pakperk/values.yaml`, not from a
CI fixture. Fill every environment-owned value from the reviewed release
manifest.

At minimum, review these groups:

| Values group | What it must describe |
| --- | --- |
| `environment` | Exactly `staging` or `production` |
| `image`, `siteImage` | Pullable tag-free repositories and immutable registry digests |
| `public` | Exact HTTPS origins, issuer/audience, distinct clients, support contact, legal document version |
| `mobileAssociations` | Actual Android package/signing and Apple team/bundle identities |
| `secret` | Existing Secret, distinct key names, rotation version |
| `features` | Fail-closed product map for this exact candidate |
| `releaseEvidence` | Production always needs legal-review, reviewer-flow, and strict-content-review SHA-256 content IDs; enabled features add their own evidence IDs |
| `alerting` | Production enables the exact packaged policy digest; staging keeps that production policy disabled and binds a separately imported staging policy outside the chart |
| `policy` | Strict full-text policy, matching legal versions, reviewed retention |
| `api` | Replicas, timeouts, limits, trusted ingress source CIDRs |
| `paperWorker` | arXiv identity, model coordinates, dimension, resource/lease settings |
| `deletionWorker`, `deletionLedger` | Provider coordinates, worker limits, RWX claim, environment and retention |
| `migration` | Real verified backup ID and expected schema version 24 |
| `metadataSync` | Bounded schedule and canonical arXiv manifest |
| `otelCollector` | External sink and capacity |
| `ingress`, `networkPolicy` | Hosts, TLS Secret, controller selectors, and reviewed egress/database CIDRs |

Start all optional product features dark. Enable a feature only after its exact
dependency and evidence gates pass. One subtle default deserves special
attention: `deletionWorker.enabled` is `true` even when
`features.accountDeletion` is `false`. For a truly guest-only staging
deployment, explicitly set `deletionWorker.enabled: false`; otherwise fully
provision its database role, admin provider, Secret keys, ledger, and alerts.

Production accounts require account deletion to be enabled at the same time.
Long-running API and worker processes always receive `RUN_MIGRATIONS=false`
from the chart. Do not attempt to override that division of responsibility.

Even a guest-only production values file must set `alerting.enabled: true`, pin
the exact packaged `alerting.policySha256`, and provide
`releaseEvidence.legalReviewId`, `releaseEvidence.reviewerFlowId`, and
`releaseEvidence.strictContentReviewId` as retrievable
`sha256:<64-lowercase-hex>` content IDs. Staging must set
`alerting.enabled: false` and an empty `policySha256`; its equivalent 19-rule
policy is imported and canary-tested by the platform with staging resource
filters. Feature-specific production evidence remains additive: for example,
comments require moderation readiness, account deletion requires provider E2E
and restore-drill evidence, and any Deep Reader feature requires the complete
Deep Reader release bundle.

## Validate before touching the cluster

From the repository root, validate the **exact** environment-owned values:

```bash
helm lint deploy/helm/pakperk \
  --values "$PAKPERK_VALUES_FILE"

helm template "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE"
```

Treat every warning, missing value, and render failure as a blocker. Inspect the
rendered workload commands, public hosts, image digests, feature map, database
Secret keys, NetworkPolicies, ServiceAccounts, PVCs, retention, and resources
against the change record.

Also run the repository's chart regression suite:

```bash
HELM_BIN=helm ./scripts/validate_helm_release.sh
```

That script exercises accepted and rejected repository fixtures. It proves the
chart's validation logic still behaves as designed; it does **not** validate
your secret values, reach your dependencies, attest your cluster, or make the
CI staging fixture deployable.

Before continuing, confirm:

- the exact candidate's scans, SBOMs, and immutable handoff passed;
- the external Secret exists without printing it;
- every referenced PVC exists and has the required access mode and backup;
- DNS and TLS records are ready;
- all provider and database CIDRs were observed and reviewed;
- each database URL authenticates as the intended distinct role;
- the ingress controller and real-IP boundary are already installed; and
- a restorable PostgreSQL backup has a real immutable identifier.

## Take and verify the pre-migration backup

Follow [Backup and restore](runbooks/backup-restore.md) before every migration.
The protected record must cover PostgreSQL and, when accounts exist, Keycloak,
the current external deletion ledger, and the retained key history needed to
interpret restored records.

Put the verified backup identifier in `migration.confirmBackupId`. The chart
rejects an empty or obvious placeholder. Never restore PostgreSQL without the
current deletion ledger: doing so can resurrect application state that a later
provider deletion already finalized.

## Bootstrap a brand-new database in two phases

Skip this section for an ordinary upgrade or a restored database that already
has `public._sqlx_migrations`; the chart's pre-upgrade hook owns that migration.
Use this section only when the application database is genuinely new.

A new database cannot receive table-specific runtime grants before the tables
exist. Conversely, a single atomic Helm install cannot pause after its
pre-install migration while the database owner grants access. If the API and
workers start without those grants, readiness fails and Helm can remove the
Kubernetes release even though the forward migration has committed. Avoid that
race with two explicit phases.

### Phase A: run only the migration boundary

Confirm that the namespace, image-pull credentials, external runtime Secret,
migration database role, reviewed NetworkPolicy CIDRs, and verified backup ID
already exist. Render only the chart's migration prerequisites and Job into an
owner-readable artifact:

```bash
export PAKPERK_BOOTSTRAP_RENDER='/protected/path/pakperk-bootstrap-migration.yaml'
test ! -e "$PAKPERK_BOOTSTRAP_RENDER"
umask 077
helm template "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE" \
  --show-only templates/migration-prerequisites.yaml \
  --show-only templates/migration-job.yaml \
  > "$PAKPERK_BOOTSTRAP_RENDER"

grep -E '^kind: (ServiceAccount|NetworkPolicy|Job)$' \
  "$PAKPERK_BOOTSTRAP_RENDER"

test "$(grep -c '^kind: ServiceAccount$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
test "$(grep -c '^kind: NetworkPolicy$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
test "$(grep -c '^kind: Job$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
```

The `grep` output must show exactly one `ServiceAccount`, one `NetworkPolicy`,
and one `Job`, and all three silent `test` assertions must exit successfully.
Inspect the rendered image digest, Secret/key reference,
database CIDRs, environment, backup ID, and expected version before applying
it. The file contains topology and evidence identifiers but no Secret bytes;
keep it in the protected release record anyway.

Apply the three resources and wait for the one migration Job selected by both
release and component labels:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  apply --filename "$PAKPERK_BOOTSTRAP_RENDER"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration" \
  --output name

export PAKPERK_BOOTSTRAP_JOB='COPY_THE_ONE_EXACT_JOB_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  wait "job/$PAKPERK_BOOTSTRAP_JOB" \
  --for=condition=complete \
  --timeout=16m

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_BOOTSTRAP_JOB" \
  --container migrate \
  --tail=-1 \
  --prefix=true
```

The first query must be empty for a first attempt; investigate any surviving
resource instead of overwriting it. The second query after apply must print
exactly one `job.batch/...` name. Copy only its name (the text after `/`) into
`PAKPERK_BOOTSTRAP_JOB`. The success log contains `migration verified` for the
exact environment, backup ID, and schema version 24. It can then contain an
OTLP flush warning because the in-chart Collector does not exist yet; that
warning does not erase a successful migration result. A failed or timed-out Job
is a blocker. Preserve `kubectl describe` and sanitized logs, inspect the
database state, and do not repeatedly recreate the Job until the owner
understands the failure.

### Phase B: grant and audit runtime roles before Helm starts them

The database owner now applies the reviewed environment-specific grant artifact
for the API, paper worker, metadata sync, and—when enabled—deletion worker.
Connect through the protected SQL client configuration for each exact runtime
role; never paste a database URL or password into the command line. At minimum,
each role must be able to run these read-only readiness queries:

```sql
SELECT current_user;

SELECT version, success, checksum
FROM public._sqlx_migrations
ORDER BY version;

SELECT extension.extname, namespace.nspname
FROM pg_catalog.pg_extension AS extension
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = extension.extnamespace
WHERE extension.extname IN ('vector', 'pg_trgm', 'pgcrypto')
ORDER BY extension.extname;

SELECT service, blocked_until
FROM public.external_rate_limits
WHERE service = 'arxiv';
```

Require successful migrations 1 through 24, all three extensions exactly once
in `public`, and exactly one `arxiv` gate row. Then run the grant artifact's
component-specific allowed and denied probes: each role must have only its DML
scope, must not write migration history, and must not own the schema. Record
role names and bounded pass/fail results, not connection strings or returned
application data.

The ordinary Helm install can now begin. Its pre-install hook replaces the
bootstrap hook resources and reruns the same embedded migrator as an idempotent
verification. Compare `_sqlx_migrations` versions, success values, and checksums
before and after; they must be unchanged. For later upgrades, do not run this
manual bootstrap phase—the one chart hook is the migration owner.

## Install or upgrade the release

Helm has no repository wrapper that chooses a release name, namespace, timeout,
or rollback policy for the operator. A common operator pattern is:

```bash
helm upgrade --install "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE" \
  --timeout 20m \
  --atomic
```

Use that pattern only if it matches the platform change procedure. `--atomic`
can roll Kubernetes resources back after a failure, but it cannot undo a
database migration that already committed. Schema compatibility and the
pre-migration backup remain mandatory. The namespace is deliberately not
created here: it already owns the reviewed Secret, PVCs, labels, admission
boundary, and any platform-created ServiceAccounts.

During installation, Helm creates a token-less migration ServiceAccount, its
deny-by-default NetworkPolicy, and then a pre-install/pre-upgrade migration Job.
The Job:

- uses the dedicated migration database URL;
- forces and verifies `public, pg_catalog` search order;
- obtains an advisory lock;
- checks the backup identifier and embedded migration version;
- applies forward-only migrations through schema 24; and
- verifies migration checksums and required extensions.

It has no retry and a bounded deadline. A failed migration blocks the ordinary
workloads. On a brand-new database it must be the unchanged, idempotent
verification described above; on an upgrade it is the only process allowed to
change the schema. Save its sanitized status and logs; do not simply rerun until
the root cause and database state are understood.

Inspect the release:

```bash
helm status "$PAKPERK_HELM_RELEASE" \
  --namespace "$PAKPERK_K8S_NAMESPACE"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods,deployments,cronjobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE" \
  -L app.kubernetes.io/component
```

List only this release's migration hook before its 24-hour TTL expires. The
query must return exactly one `job.batch/...` entry; copy the text after `/`
into `PAKPERK_MIGRATION_JOB`:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration" \
  --output name

export PAKPERK_MIGRATION_JOB='COPY_THE_ONE_EXACT_JOB_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_MIGRATION_JOB" \
  --container migrate \
  --tail=-1
```

Never paste unsanitized logs into tickets or release evidence.

## Verify the dark deployment in dependency order

Keep public features and writes dark while you verify infrastructure. Work in
this order because later services depend on earlier boundaries:

1. The authorized migration path completed: an upgrade has one chart hook; a
   fresh environment has one schema-changing bootstrap Job followed by an
   unchanged Helm-hook verification. No concurrent migrator ran.
2. Deletion worker is ready if it is intentionally enabled.
3. Paper worker is running and can lease without crash-looping.
4. Metadata CronJob configuration renders and a controlled run can reach only
   its permitted database and arXiv boundaries.
5. Telemetry gateway and Collector are healthy and a canary reaches the real
   sink and alert adapter.
6. API replicas are ready through their actual restricted database role.
7. Public site replicas and association configuration match the candidate.

The health surfaces prove different things:

| Surface | What a pass proves | What it does not prove |
| --- | --- | --- |
| API `/health/live` | API process is running | Database or dependency readiness |
| API `/health/ready` | PostgreSQL is reachable; every migration embedded through version 24 is present and checksum-valid; `vector`, `pg_trgm`, and `pgcrypto` are each in `public`; and the shared arXiv gate exists | Exact schema equality (a compatible newer schema is accepted), GROBID, model, OIDC, workers, queue progress, telemetry, DNS, or TLS |
| Telemetry gateway health | Gateway process contract is healthy | External OTLP delivery or paging |
| GROBID `/api/isalive` | Parser process responds | End-to-end paper preparation quality |
| Deletion worker readiness probe | Startup, provider permission probe, database, and ledger boundary passed | A real user's full deletion and restore replay |
| Paper worker Pod state | Process has not exited | It has no HTTP readiness endpoint; prove a leased job and result |

From a trusted external machine, check the public API and complete edge
contract:

```bash
export PAKPERK_SITE_ORIGIN='https://staging.pakperk.app'
export PAKPERK_API_ORIGIN='https://api.staging.pakperk.app'
export PAKPERK_TELEMETRY_ORIGIN='https://telemetry.staging.pakperk.app'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/health/live"
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/health/ready"

./scripts/verify_public_edge.sh \
  "$PAKPERK_SITE_ORIGIN" \
  "$PAKPERK_API_ORIGIN" \
  "$PAKPERK_TELEMETRY_ORIGIN"
```

Replace the example staging origins with the exact values from the protected
values file. Do not use production for exploratory testing.

The edge verifier checks redirect, security-header, gzip, bounded feed,
configuration, legal-document, association, and telemetry-origin behavior. Run
the protected public-edge workflow for release evidence; a local invocation is
diagnostic only.

### Prove one paper crosses the durable queue

In protected staging, select an operator-reviewed synthetic paper whose license
allows the strict full-text path. Copy its existing Pakperk UUID—not an arXiv
identifier—into the task-specific variable:

```bash
set -o pipefail
export PAKPERK_SMOKE_PAPER_ID='COPY_REVIEWED_STAGING_PAPER_UUID'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID" \
  | jq '{paper_id, arxiv_id, title}'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"retry":false,"trigger":"explicit_prepare"}' \
  --write-out '%{stderr}HTTP %{http_code}\n' \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/prepare" \
  | jq '{paper_id, generation, stage, overall_state, retryable}'
```

HTTP 202 means a job was accepted; HTTP 200 means the exact generation was
already ready or terminal. Poll the persisted processing record without
resubmitting the write:

```bash
set -o pipefail
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/processing" \
  | jq '{paper_id, generation, stage, overall_state, capabilities, retryable,
         last_error: (.last_error | if . == null then null else {category, code} end)}'
```

Require the reviewed generation to reach `ready`, then require its permitted
Introduction route to return successfully. A terminal or retryable failure is
evidence to diagnose, not a reason to loop `prepare`:

```bash
set -o pipefail
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/introduction" \
  | jq '{paper_id, generation, heading, paragraph_count: (.paragraphs | length)}'
```

Correlate only bounded request IDs, generation, closed stage/error categories,
and aggregate queue timing. Do not retain the paper's full text, prompts, or
model response in release evidence.

### Run the metadata CronJob once under its restricted identity

First obtain only this release's metadata CronJob:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get cronjobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=metadata-sync" \
  --output name
```

Copy the name after `cronjob.batch/`, choose a unique lowercase DNS-safe smoke
Job name, and create one Job from that exact CronJob template:

```bash
export PAKPERK_METADATA_CRONJOB='COPY_EXACT_CRONJOB_NAME'
export PAKPERK_METADATA_SMOKE_JOB='pakperk-metadata-smoke-001'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  create job "$PAKPERK_METADATA_SMOKE_JOB" \
  --from="cronjob/$PAKPERK_METADATA_CRONJOB"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  wait "job/$PAKPERK_METADATA_SMOKE_JOB" \
  --for=condition=complete \
  --timeout=20m

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_METADATA_SMOKE_JOB" \
  --container metadata-sync \
  --tail=-1
```

Require a bounded successful manifest result. Inspect the rendered Pod to prove
that it references only the metadata database Secret key, then use the enforcing
CNI's flow logs or equivalent platform observation to prove that its network
traffic was limited to DNS, the reviewed database CIDRs, arXiv, and the
Collector. NetworkPolicy YAML alone is intended policy, not observed traffic.
The role's audited SQL probes must show metadata-only DML; it must have no model
key, GROBID route, full-text pipeline, or account/deletion privilege. Preserve
sanitized status and logs, then remove this exact one-off Job when the
environment's evidence policy permits:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete "job/$PAKPERK_METADATA_SMOKE_JOB"
```

### Verify deletion and telemetry through their real boundaries

When the deletion worker is enabled, find only this release's Deployment and
run its read-only ledger verifier inside the configured Pod. The query must
return one `deployment.apps/...` entry; copy the text after `/` into
`PAKPERK_DELETION_DEPLOYMENT`:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get deployments \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=deletion-worker" \
  --output name

export PAKPERK_DELETION_DEPLOYMENT='COPY_EXACT_DEPLOYMENT_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  exec "deployment/$PAKPERK_DELETION_DEPLOYMENT" \
  --container deletion-worker \
  -- /usr/local/bin/pakperk-deletion-worker verify-ledger
```

That proves the currently mounted signed inventory is internally valid; it does
not prove provider deletion or restore replay. Complete the command-bearing
[reference-provider E2E gate](runbooks/account-deletion.md#reference-provider-end-to-end-gate)
and the protected
[restore drill](runbooks/account-deletion.md#restore-drill-and-production-restore)
before enabling production accounts.

Run the local chart-pinned Collector/redaction/restart contract, then complete
the live staging and dark-production sink checks in
[Observability verification and alerts](runbooks/observability.md#verification-and-alerts):

```bash
HELM_BIN=helm ./scripts/test_backend_log_export.sh
```

The local harness is not proof of live delivery. Require a privacy-safe canary
at the real sink, staging page and ticket canaries for all 19 imported rules,
externally observed Collector-failure alerts, and the documented 30-day
retention behavior.

### Complete the candidate-bound protected exercises

After the infrastructure checks pass, use approved synthetic identities and
content to complete:

- guest cached feed and reader behavior;
- OIDC discovery, browser/native clients, and exact issuer validation when
  accounts are planned;
- profile, Library, comments, report/block/moderation, and idempotent writes
  only after their dependencies are enabled in staging; and
- deletion request, provider action, application purge, signed ledger,
  backup/restore replay, and retained-key verification before production
  accounts are enabled.

The exact identity rotation, idempotency, cross-replica quota, and switch
procedure is [Protected auth, write, and switch exercise](runbooks/release.md#protected-auth-write-and-switch-exercise).
Run the bounded staging-only [guest load gate](runbooks/backend-load-testing.md#guest-gate)
after the smoke paths are stable; the load tool refuses production by design.

Capture bounded outcomes, hashes, counts, and immutable references. Do not put
tokens, user content, paper full text, prompts, identity attributes, Secret
data, raw Pod objects, or cluster credentials into evidence.

## Enable features one dependency at a time

Change one fail-closed switch at a time in the protected values, render again,
deploy, and prove off/on/off behavior where the release runbook requires it.
Enable dependencies first and enforcement or write switches last. To back out,
disable dependent enforcement and writes first, then their providers.

Examples of important dependency ordering include:

- accounts before Library or comments;
- Library before Library writes;
- paper resolution before title search or import;
- reading feed before To Read First enforcement;
- Lookup before Explore, and Explore before saved queries;
- subscriptions before notifications; and
- Deep Reader before Passport, facets, visuals, annotations, version diff, or
  assistant v2.

A healthy route is not evidence that its background queue, retention, privacy,
moderation, accessibility, or human-domain gates passed. The exact staged
sequence is in [Release](runbooks/release.md) and
[Deep Reader rollout](runbooks/deep-reader-rollout.md).

## Roll back without corrupting state

Prepare rollback before deployment, not after an incident begins.

1. Disable enforcement and write switches in reverse dependency order.
2. If only application code is bad, deploy the previously approved image
   digests only when that code is explicitly compatible with schema 24.
3. Keep schema 24 in place during an ordinary application rollback. The
   repository uses forward-only expand/contract migrations and provides no
   automatic destructive down migration.
4. If database restoration is unavoidable, follow the backup/restore runbook
   and restore the bound PostgreSQL, Keycloak, current deletion ledger, and
   retained keys together. Reapply finalized deletions before reopening
   traffic.
5. Re-run readiness, public-edge, queue, deletion, telemetry, and feature smoke
   checks against the actual rolled-back state.

Do not assume `helm rollback` is a database rollback. A Helm action can change
workload manifests and may execute chart hooks; it cannot reverse committed
application data or safely reconstruct an external ledger.

### Clean up migration hook resources after decommission

The migration Job, its ServiceAccount, and its NetworkPolicy are Helm hooks, not
ordinary release objects. `helm uninstall` and a failed atomic first install can
therefore leave them behind. Do not remove them during a migration or merely
because an application rollout failed.

After the release is intentionally decommissioned—or a failed first install is
explicitly abandoned—preserve the sanitized Job status/logs and prove that no
migration Job or Pod is running:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"
```

Only when every listed migration Job is complete or failed and no migration Pod
is running, delete the release-scoped Job and its two prerequisites, then
confirm the selector is empty:

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods,serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"
```

Never broaden that selector or delete the namespace as a shortcut; PVCs,
Secrets, evidence, or other releases may still be retained there.

## If you only need a temporary remote development server

For a short-lived private developer environment, Compose can run on a remote
VM only when a host firewall or private VPN blocks its database, GROBID,
Keycloak, Mailpit, and API ports from the public Internet. Retain its
**development** classification and `FULLTEXT_POLICY=prototype`, but do not treat
default passwords as a security boundary. Replace configurable Keycloak
defaults, use an isolated disposable host, and remember that the Compose
application-database credential is intentionally development-only; strict
network isolation is mandatory.

One safer access shape is an SSH tunnel from the development computer:

```bash
ssh -L 8080:127.0.0.1:8080 YOUR_USER@YOUR_PRIVATE_SERVER
```

An Android phone attached to that computer can then use the documented
`adb reverse tcp:8080 tcp:8080` path. A physical iPhone still needs a reachable
trusted HTTPS endpoint for live networking. Do not call this remote Compose
shape staging, production, or release evidence.

## Final operator checklist

Before declaring the backend deployed, answer **yes** to every applicable item:

- Is the cluster version and exact context recorded?
- Are backend and site images pulled by immutable registry digest from the
  approved handoff?
- Are PostgreSQL roles distinct, least-privilege, and schema-24 ready?
- Is the backup real, restorable, and bound to the migration attempt?
- Are the current deletion ledger and retained keys backed up separately?
- Are Secret bytes absent from values, logs, commands, and evidence?
- Do DNS, TLS, HSTS, gzip, real-IP trust, trusted-proxy CIDRs, and
  NetworkPolicies match observed traffic?
- Do public origins, OIDC clients, mobile associations, and legal document
  versions match exactly?
- Are GROBID, arXiv, model, deletion, telemetry, and alert dependencies proven
  beyond process liveness?
- Are optional features still dark unless their exact protected and human gates
  passed?
- Is a schema-compatible rollback and full restore procedure ready?
- Has the final feature map been reconciled with the completion audit and
  immutable release record?

If any answer is “unknown,” the honest status is “deployed but not ready for
that capability,” not “probably ready.”
