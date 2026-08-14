# Observability, redaction, retention, and alert runbook

Pakperk processes emit structured traces/metrics through OTLP and JSON stdout
logs. A chart-managed node Collector tails only Pakperk container logs, applies
container parsing and protected-field redaction, and exports to the configured
HTTPS OTLP sink. Mobile clients send only the closed, identifier-free schema to
the validating `/v1/logs` gateway; the gateway, not the app, forwards accepted
events to the in-cluster Collector.

## Deployment boundary

- Process OTLP uses the exact in-cluster `*-otel-collector:4317` endpoint over
  plaintext only inside the NetworkPolicy boundary. External export is exact
  credential-free HTTPS host/port with headers from the external Secret.
- Telemetry-gateway `/health/live` and `/health/ready` are non-cacheable
  gateway-process signals: configuration, client construction, and listener
  setup succeeded before the server became reachable. They deliberately do
  not probe the Collector receiver, exporter queue, or external sink. Use the
  protected canary and externally observed Collector alerts below for delivery
  evidence; do not make product availability depend on that best-effort path.
- The log DaemonSet mounts `/var/log/pods` read-only and therefore needs
  deliberate node scheduling and Pod Security admission review. It has no
  service-account token, a read-only root filesystem, dropped capabilities,
  bounded memory/batch queues, and only DNS/upstream telemetry egress.
- `filelog` starts at the beginning so a newly scheduled agent does not miss
  existing container output. Its offsets use the `file_storage` extension on a
  128 MiB Pod-scoped `emptyDir`. The OTLP exporter's retry queue uses a separate
  `file_storage` instance and 128 MiB `emptyDir`, so an accepted, checkpointed
  record remains queued across a Collector container restart in the same Pod.
  Retry has no elapsed-time expiry; bounded queue or volume saturation instead
  fails visibly through the Collector failure/drop alerts. Pod replacement,
  rescheduling, or node loss discards both stores and can replay bounded
  retained log files. The sink must deduplicate where needed and
  alerts must tolerate replay; do not infer unique user/session counts from
  logs. Verify rotation and exporter-queue bounds before deployment. These
  `emptyDir` volumes provide continuity for an in-place container restart, not
  durable state or evidence of delivery to the external sink.
- If the cluster's restricted profile forbids the hostPath, deploy an
  equivalent platform-owned node logging agent and disable neither redaction
  nor the backend stdout collection contract. Record the exception/owner.

## Privacy and retention

The Collector deletes authorization/cookie/API-key fields, request/response
bodies, query strings, raw URL/path parameters, user/account/provider IDs,
network addresses, device/session identifiers, comment/paper content, exception
messages/stacks, and source file paths before export. OTLP log bodies use a
separate fail-closed transform: only an exact mobile-gateway event name with the
expected `pakperk-mobile` service, deployment environment, and
`app.pakperk.mobile` scope remains; every other scalar or structured OTLP body
is replaced by the static `otlp_log_body_redacted` marker. Node stdout is a
separate pipeline: every parsed message becomes the constant
`pakperk_backend_log` marker except the exact content-free
`external deletion ledger failed verification` alert message, which remains
only for `ERROR` records from the exact `account_deletion::worker` Rust target.
The pipeline upserts its fixed service/environment identity and retains only
body, severity, and Rust namespace. Application diagnostics use bounded error
kinds, operation classes/outcomes, aggregate counters, and request IDs only.
Request IDs are operationally random and must not become a user/session
identity.

Production operational telemetry retention is exactly 30 days unless a newer
published privacy schedule and protected values are approved together. Enforce
expiry at the upstream sink; the Collector cannot prove sink deletion. Access
is least privilege and audited. Never copy raw production events into issue
trackers or long-lived test fixtures.

The bounded exporter-queue `emptyDir` contains only batches after the redaction
processors above and is deleted with the Collector Pod. It is transient
delivery state, not an additional retention tier; inspect its node-storage and
access controls during the platform review and never mount it into another
workload.

## Verification and alerts

The reviewed, provider-neutral rule contract is
`deploy/helm/pakperk/files/alerts/pakperk-production-alert-policy.json`.
`scripts/validate_alert_policy.py` fixes the required signal, threshold,
missing-data behavior, role owner, notification class, and runbook for every
rule below. The Helm chart verifies `alerting.policySha256` against the exact
packaged bytes and deploys those bytes in a content-addressed, immutable
ConfigMap. This makes the released policy auditable; a ConfigMap is not an
alert engine and is not evidence that paging works.

The platform adapter must import every rule without weakening it, supply the
declared external synthetic/database/Kubernetes/Collector inputs, and retain
immutable evidence of the imported policy digest, enabled rule IDs, receiver
ownership, all 17 rules routed across owned `page` and `ticket` receiver
classes in both environments, and successful staging page/ticket canaries.
Collector failure signals must be observed outside the Collector's own failing
export path. Do not enable production feature gates merely because repository
validation or a Helm render passed.

The packaged policy is deliberately production-only: its exact filters select
production resource and service identities. Staging canaries must use a
separately imported copy whose resource filters select staging, and that
staging policy needs its own immutable adapter evidence. Bind a reviewed
production-versus-staging parity diff: the canary copy may change the exact
environment filters and staging receivers, but it may not weaken the six
inputs, 17 rules, redaction, ownership, or 30-day retention policy. The chart
rejects mounting the packaged production policy in a staging release.

Before release:

1. Run `scripts/test_backend_log_export.sh` with the chart-pinned Collector. It
   injects a backend container log plus direct OTLP log, trace, and metric
   fixtures. Every configured protected key is exercised as both a signal and
   resource attribute; hostile scalar and structured OTLP log bodies must be
   replaced, the exact mobile event identity, constant backend marker, and
   exact ledger-alert body/severity/namespace must remain, hostile interpolated
   and structured stdout messages plus spoofed resource identities must not,
   safe sentinels must export, and protected sentinels must not. The harness
   also requires the Collector body allowlist to match the gateway event
   vocabulary exactly. It then holds the sink unavailable, checkpoints and
   queues the exact ledger-alert record, restarts the Collector with the same
   Pod-scoped stores, brings the sink up, and requires that queued record to
   arrive without being reread from the source log. This local E2E is pipeline
   and same-Pod restart evidence, not proof of the live sink or retention job.
2. Send valid and hostile mobile telemetry payloads through staging. Require
   valid events to export and unknown fields, identifiers, oversized payloads,
   redirects, and wrong content types to fail closed. Confirm no auth/cookie
   header is sent by the app.
3. Inspect the staging sink using canary values that are not personal/content
   data and verify the redacted fields are absent. Separately send a privacy-safe
   canary through the exact dark production Collector/gateway/adapter images and
   require the same bound commitment in the production sink. Process readiness
   and a staging delivery do not replace this production-path observation.
4. Bind the production and staging receiver/retention-policy identities
   separately and verify both are configured at exactly 30 days. For the
   production retention behavior test, seed a bounded commitment inventory,
   observe every canary initially, observe the same set once between day 29 and
   day 30, and observe none of them between day 30 and day 31. Record canonical
   UTC seed/query timestamps and exact ages/counts so a canary that was never
   ingested cannot pass as expired.
5. Restart one agent in staging and record replay volume/duplicates and recovery
   time. Verify node coverage and that log rotation cannot outgrow storage.

The immutable policy alerts on API readiness/error/latency and database
saturation; paper/deletion queue age and terminal failure; moderation report
age; authentication recovery failure; Collector rejected/dropped/export-failed
data; missing node agents; telemetry gateway rejection spikes; and
deletion-ledger verification/capacity. Alerts contain aggregates only. Each
alert links its role owner and the applicable incident/deletion/moderation
runbook.

If redaction, exporter credentials, sink access, or retention is wrong, stop
the affected export, preserve bounded evidence, rotate credentials when needed,
and follow [incident-response.md](incident-response.md). Do not make product
availability depend on mobile telemetry or loosen the schema to recover volume.
