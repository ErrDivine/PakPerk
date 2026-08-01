# Pakperk production chart

This chart deploys the Pakperk API, paper worker, deletion worker, public policy
site, isolated GROBID service, scheduled metadata sync, migration job, and an
OpenTelemetry Collector. PostgreSQL, OIDC, TLS, the deletion-ledger RWX volume,
and secret material are deliberately external.

The external Secret must expose distinct component database URLs plus the
mapped model/comment credentials. When account deletion is enabled it must
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
clients, and a separately backed-up deletion ledger claim.

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
`0.0.0.0/0` or `::/0`. A non-Nginx or externally managed ingress must preserve
this exact source-boundary contract.

Render the structural fixture with the repository-pinned validation command:

```bash
helm lint deploy/helm/pakperk -f deploy/helm/pakperk/ci/staging-values.yaml
helm template pakperk deploy/helm/pakperk \
  -f deploy/helm/pakperk/ci/staging-values.yaml
```

The fixture uses non-deployable staging hostnames, documentation IP ranges, and
fake application digests. It is only for rendering tests and must never be
applied.
Create an environment-owned values file from a release manifest containing the
actual signed image digests, provider CIDRs, secret/PVC names, domains, models,
and pre-deploy backup identifier. The chart never creates a Secret or database.

Apply migrations only after the backup verification and restore-readiness gate.
Use feature flags for application rollback; never automate destructive SQL
downgrades. See [release](../../../docs/runbooks/release.md) and
[backup/restore](../../../docs/runbooks/backup-restore.md).

## Database and provider grant matrix

The external Secret maps a different database URL key for every component. The
platform database owner creates and audits these roles; never point two keys at
the same login.

| Component | Required scope | Explicitly excluded |
| --- | --- | --- |
| migration Job | connect plus reviewed schema DDL/migration ownership | identity-provider administration, application serving |
| API | serving DML for paper/account/library/comment/deletion request and shared-limit tables | schema ownership/DDL, Keycloak admin credentials |
| paper worker | paper/job/cache/provider-result DML and shared arXiv gate | account-deletion/provider-admin tables and credentials |
| metadata sync | bounded metadata/job ingestion and arXiv gate | account, UGC, deletion, DDL |
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
purge. Model, OIDC admin, telemetry exporter, and request-origin credentials can
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

The Collector DaemonSet reads `/var/log/pods` through a read-only hostPath. The
cluster owner must approve its node coverage, taints/tolerations, restricted Pod
Security exception if needed, rotation bounds, and upstream egress. Offsets are
in-memory, so restart may replay bounded retained files; verify sink behavior
and do not use log events as unique session counts. See
[the observability runbook](../../../docs/runbooks/observability.md) for redaction, replay, alert, and 30-day sink
retention checks.
