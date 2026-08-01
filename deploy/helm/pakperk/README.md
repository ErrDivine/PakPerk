# Pakperk production chart

This chart deploys the Pakperk API, paper worker, deletion worker, public policy
site, isolated GROBID service, scheduled metadata sync, migration job, and an
OpenTelemetry Collector. PostgreSQL, OIDC, TLS, the deletion-ledger RWX volume,
and secret material are deliberately external.

The external Secret must expose a different key for every component database
URL and every purpose-specific credential; reusing one key for two consumers
is rejected even when neither value is a database URL. This keeps database,
model, comment-moderation, request-origin, identity, deletion-ledger, provider-encryption, OIDC
admin, and telemetry credentials independently grantable and rotatable. When
account deletion is enabled the Secret must
also contain rotation-ordered owner-only keyrings for identity fingerprints,
ledger signing, and provider-coordinate encryption
(`ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS`, formatted as up to eight
`key_id:base64(32 random bytes)` lines with the active encryption key first),
as well as the deletion worker's confidential OIDC admin secret. Retain legacy
verification/decryption keys until every corresponding ledger record and
recoverable backup has passed final purge.
The Keycloak service account must have exactly the realm's
`realm-management/manage-users` grant. Deletion-worker readiness remains false
until a bounded reserved-user 404 and a bounded empty exact-ID query prove that
the Admin REST origin and permission are both correct; token issuance alone is
not considered a functioning adapter.

The chart is fail-closed: images require immutable SHA-256 digests, staging and
production require OTLP export and reviewed network CIDRs, automatic migrations
are disabled in long-running processes, and the migration job requires a
verified backup identifier. Production also requires strict full-text policy,
two API/site replicas, exact HTTPS origins, distinct native/browser OIDC
clients, a separately backed-up deletion ledger claim, the exact packaged
alert-policy digest, and content-addressed release-evidence references.

For shared anonymous prepare/chat and comment abuse limits,
`api.trustedProxyCidrs` is mandatory and must list the source ranges the API
actually sees for the ingress-controller chain. The API trusts
`X-Forwarded-For` only from those ranges, resolves it right-to-left, and
immediately replaces the canonical address with a keyed digest; the raw value
is not persisted or logged. The API NetworkPolicy independently limits port
8080 to the configured ingress controller labels. Before rollout, confirm the
ingress controller appends the actual connection address, its external
load-balancer/real-IP trust list is restricted to the platform load balancers,
and Pod-to-API source addresses fall inside `api.trustedProxyCidrs`. Do not use
`0.0.0.0/0` or `::/0`, and keep the list at the API runtime limit of 64
canonical ranges. A non-Nginx or externally managed ingress must preserve this
exact source-boundary contract.

Chart validation mirrors the deployed process invariants. Paper-worker and
deletion-worker polling must remain strictly shorter than their leases;
deletion retry base must remain below its maximum; deletion ledger retention
must cover security retention; and deletion steps are capped at 1,800 seconds.
Paper categories use the runtime arXiv category grammar, the contact must be a
real monitored non-placeholder address, and model IDs are limited to the
provider's 128-character safe identifier grammar. The migration Job is pinned
to embedded migration version `10` and accepts only a bounded, non-placeholder
backup ID. Metadata sync accepts a bounded five-field numeric/wildcard Cron
schedule and a JSON object of 1 to 2,000 canonical arXiv IDs no larger than
1,048,000 bytes; the ConfigMap uses a quoted scalar that preserves those bytes
exactly while leaving room below Kubernetes' one-MiB data ceiling. API shutdown
grace exceeds the larger request/chat timeout plus its five-second preStop, and
paper/deletion shutdown grace exceeds the relevant lease. All four image
repositories use a lowercase, tag-free OCI grammar capped at the 255-character
distribution reference-name limit; public/dependency hosts use distinct
lowercase external FQDNs. Kubernetes names, label/selector keys and values,
resource quantities, request-at-or-below-limit ordering, and PDB availability
values are validated before rendering. These checks happen before Kubernetes
can accept a workload that would then fail process construction, image pull,
rollout, or scheduled execution.

`api.commentModerationProvider=rules` keeps the deterministic built-in
moderator. Setting it to `http` is allowed only with comments enabled and
requires a bounded HTTPS `api.commentModerationUrl`, a timeout no greater than
10 seconds, and the external Secret key selected by
`secret.commentModerationTokenKey`. The API receives the token through the
same owner-only memory-backed materialization boundary as its other file
secrets. Include every moderation-provider address in
`networkPolicy.apiHttpsCidrs`; the adapter has no redirect support and treats
transport, status, response-size, and response-schema failures as unavailable,
which leaves content pending review rather than publishing it.

Render the structural fixture with the repository-pinned validation command:

```bash
helm lint deploy/helm/pakperk -f deploy/helm/pakperk/ci/staging-values.yaml
helm template pakperk deploy/helm/pakperk \
  -f deploy/helm/pakperk/ci/staging-values.yaml
helm template pakperk deploy/helm/pakperk \
  -f deploy/helm/pakperk/ci/staging-values.yaml \
  -f deploy/helm/pakperk/ci/production-render-values.yaml
```

The fixtures use non-deployable hostnames or private/documentation ranges plus
deterministic signing, backup, and application-digest values. They exist only
to exercise staging and production render contracts and must never be applied.
Create an environment-owned values file from a release manifest containing the
actual signed image digests, provider CIDRs, secret/PVC names, domains, models,
and pre-deploy backup identifier. The chart never creates a Secret or database.

Apply migrations only after the backup verification and restore-readiness gate.
Use feature flags for application rollback; never automate destructive SQL
downgrades. See [release](../../../docs/runbooks/release.md) and
[backup/restore](../../../docs/runbooks/backup-restore.md).

The migration Job is a `pre-install,pre-upgrade` hook and never uses the
namespace's default ServiceAccount. Helm first creates a token-less dedicated
ServiceAccount at hook weight `-30`, then its deny-by-default NetworkPolicy at
`-20`, and only then creates the Job at `-10`. The prerequisite hooks use only
`before-hook-creation` deletion so they stay effective for the whole Job; the
next upgrade replaces them before launching another migration. Because Helm
does not manage hook resources as ordinary release objects, an environment
decommission must delete the release-labeled migration ServiceAccount and
NetworkPolicy after confirming no migration Pod remains.

Every long-running or scheduled component likewise uses its own token-less
ServiceAccount and receives no chart-created RBAC grant. With
`serviceAccount.create=true`, the chart derives one `<base>-<component>` name
for API, site, telemetry gateway, paper worker, metadata sync, deletion worker,
GROBID, and the Collector. With `create=false`, `serviceAccount.name` is the
required base prefix and the platform must pre-create every derived identity;
it must not bind one shared account to multiple workloads. The base is one DNS
label (dots are rejected), so suffixing and length bounding cannot truncate at
an invalid label boundary.
Custom Pod metadata cannot replace chart-owned workload identity labels or any
`checksum/*` rollout annotation; such values are rejected before rendering so
selectors, NetworkPolicies, and Secret/config rotation remain authoritative.

## Database and provider grant matrix

The external Secret maps a different database URL key for every component. The
platform database owner creates and audits these roles; never point two keys at
the same login.

| Component | Required scope | Explicitly excluded |
| --- | --- | --- |
| migration Job | connect plus reviewed schema DDL/migration ownership | identity-provider administration, application serving |
| API | serving DML for paper/account/library/comment/deletion request and shared-limit tables | schema ownership/DDL, Keycloak admin credentials |
| paper worker | paper/job/cache/provider-result DML and shared arXiv gate | account-deletion/provider-admin tables and credentials |
| metadata sync | bounded metadata ingestion/cache and shared arXiv gate | model key, GROBID, full-text/embedding pipeline, account, UGC, deletion, DDL |
| deletion worker | deletion/jobs/ledger binding, account-owned purge and retention DML | schema DDL, paper-provider/model credentials |
| Keycloak | its separate Keycloak database only | Pakperk application database |

The Keycloak deletion service account has only
`realm-management/manage-users`; worker readiness proves bounded read access
before deletion traffic. Do not add `realm-admin`, `query-users`, or
`view-users`. NetworkPolicy additionally keeps paper workers away from the
identity-admin egress ranges.

## Secret materialization and rotation

Kubernetes Secret projection modes do not by themselves satisfy the runtime's
owner-only UID checks. Root init containers reclaim the memory-backed target,
copy and chmod each file while root still owns it, transfer each file and then
the directory to UID/GID 10001, and run with a read-only root filesystem and
only `CAP_CHOWN`. `scripts/test_secret_init_capabilities.sh` exercises that
sequence in the release image. Do not replace it with `install -o/-g`, relax
file modes, or run the application as root.

Rotate the external Secret, verify every new/retained keyring and credential,
then increment `secret.rotationVersion` to force a rollout. Keep old identity
fingerprint, ledger signature, and provider-coordinate decryption keys until
every bound record and recoverable backup has expired or completed an evidenced
purge. Model, comment-moderation, OIDC admin, telemetry exporter, and request-origin credentials can
be removed only after old pods stop and their bounded request/rate windows have
elapsed. Never put secret bytes in values, annotations, rollout checksums, logs,
or release evidence.

## Ingress and node-log prerequisites

The chart-owned Nginx annotations enforce TLS redirect, body/time bounds, a
query-safe site logging boundary, and telemetry rate/connection limits. A
replacement ingress must implement the same contract. Its real-IP configuration
must trust only platform load balancers and append the actual connection address;
the API separately accepts `X-Forwarded-For` only when its direct peer falls in
`api.trustedProxyCidrs`. Observe the Pod-to-API source address in staging and
test a spoofed leftmost entry before enabling comment or anonymous
prepare/chat traffic.

The API Ingress also applies the configurable `api.edgeRateLimitRps`,
`api.edgeBurstMultiplier`, and `api.edgeConnectionLimit` per-client controls
for obvious broad abuse. These coarse edge limits complement rather than
replace the shared PostgreSQL-backed prepare/chat/comment quotas. Tune them
only from observed staging traffic, retain a finite value, and verify that the
controller's real-IP boundary prevents an attacker from selecting the limit
key through a spoofed forwarding header.

The cluster-scoped ingress-nginx release must also apply
`deploy/helm/ingress-nginx-production-values.yaml`: HSTS is enabled for two
years with `includeSubDomains` and `preload`. The site, API, and telemetry
origins repeat the exact header as defense in depth, but that does not replace
TLS-edge enforcement. After every controller or public-ingress change, run
`scripts/verify_public_edge.sh SITE_ORIGIN API_ORIGIN TELEMETRY_ORIGIN`; any
redirect, duplicate/missing header, or value mismatch blocks rollout. Pin and
review the ingress-nginx chart/image separately; this application chart does
not take ownership of the shared controller.

`networkPolicy.ingressController.namespaceSelector` and `podSelector` must
each contain at least one non-empty exact-match label. Empty selectors would
select every namespace or Pod and are rejected by both the values schema and
the render-time contract. arXiv, model-provider, and identity-admin egress
lists are restricted to canonical IPv4 CIDRs and may not overlap in either
direction, including an equal range or one range containing another. This is a
security boundary: the paper worker receives arXiv plus model egress, while the
metadata-only CronJob receives arXiv egress only. Do not place a shared proxy
address in multiple lists. Every chart CIDR, including trusted proxy, database,
and telemetry ranges, must be canonical IPv4 with a `/8` through `/32` prefix;
IPv6 is rejected until the chart has an equally strict canonical parser and
minimum-prefix contract. API OIDC discovery/JWKS and optional HTTPS comment
moderation use `networkPolicy.apiHttpsCidrs`; paper-worker model traffic,
and deletion-worker identity administration each use a NetworkPolicy egress
rule fixed to TCP/443. Their configured HTTPS origins may spell `:443`
explicitly, but any other explicit port is rejected instead of rendering a
deployment that cannot reach its dependency.

The metadata-sync CronJob has only its database role, exact arXiv HTTPS egress,
and OTLP egress. It does not mount the model Secret and cannot reach GROBID;
the runtime also refuses to start if an LLM key or GROBID coordinate is
injected accidentally.

The Collector DaemonSet reads `/var/log/pods` through a read-only hostPath. The
cluster owner must approve its node coverage, taints/tolerations, restricted Pod
Security exception if needed, rotation bounds, and upstream egress. Offsets are
in-memory, so restart may replay bounded retained files; verify sink behavior
and do not use log events as unique session counts. See
[the observability runbook](../../../docs/runbooks/observability.md) for redaction, replay, alert, and 30-day sink
retention checks.

Every application `OTEL_SERVICE_NAME` ends in the canonical environment, for
example `pakperk-api-staging` and `pakperk-metadata-sync-production`. Keep that
suffix when defining dashboards and alerts so staging and production cannot be
silently combined by an upstream collector.

## Legal document release invariant

`public.documentVersion`, `policy.termsVersion`, and
`policy.communityGuidelinesVersion` are one reviewed release date and must be
identical. That value configures the public legal-site disclosure and both API
acceptance gates, so the chart rejects a rollout that could record acceptance
for text different from the published document. Update the published files,
their reviewed version, and all three values in the same release.

## Production evidence and alert-policy gates

`releaseEvidence` stores SHA-256 content IDs for evidence held by the protected
release system; it never stores approval prose, credentials, user data, or a
mutable ticket URL. Every production release requires legal review,
app-reviewer-flow, and strict-content-policy evidence. Enabling comments also
requires moderation-readiness evidence. Enabling any production account
surface requires the account-deletion feature, including a comments-disabled
library release; enabling account deletion in turn requires provider-deletion
E2E and restore-drill evidence. The chart records the enabled feature set and these IDs in a
content-addressed immutable ConfigMap so the deployed release can be matched to
the protected evidence bundle. Its address covers the exact backend, site,
GROBID, and Collector repository/digest pairs; chart and app versions; enabled
features; alert-policy digest; and document, terms, community-guidelines, and
full-text policy identities. Changing any one produces a different ConfigMap.
Helm can validate the ID shape and gate binding, not the truth of an external
approval or drill.

The production-only, provider-neutral alert contract is packaged from
`files/alerts/pakperk-production-alert-policy.json`. `alerting.policySha256`
must equal its exact SHA-256 digest, and production cannot disable the rendered
immutable policy ConfigMap. A protected platform adapter still has to import
the contract, provide its declared infrastructure inputs, connect the named
role owners to real receivers, and produce live canary evidence. See
[the observability runbook](../../../docs/runbooks/observability.md).
Staging must use separately imported rules whose resource filters are bound to
staging; the chart rejects attaching the production ConfigMap to a staging
release. Both content-addressed ConfigMap names reserve their digest suffix and
remain valid DNS labels even when the Helm release name reaches its limit.
