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
- The log DaemonSet mounts `/var/log/pods` read-only and therefore needs
  deliberate node scheduling and Pod Security admission review. It has no
  service-account token, a read-only root filesystem, dropped capabilities,
  bounded memory/batch queues, and only DNS/upstream telemetry egress.
- `filelog` starts at the beginning so a newly scheduled agent does not miss
  existing container output. File offsets are in-memory for this release:
  agent/node restart can replay bounded retained log files. The sink must
  deduplicate where needed and alerts must tolerate replay; do not infer unique
  user/session counts from logs. Verify rotation bounds prevent unbounded
  replay before deployment.
- If the cluster's restricted profile forbids the hostPath, deploy an
  equivalent platform-owned node logging agent and disable neither redaction
  nor the backend stdout collection contract. Record the exception/owner.

## Privacy and retention

The Collector deletes authorization/cookie/API-key fields, request/response
bodies, query strings, raw URL/path parameters, user/account/provider IDs,
network addresses, device/session identifiers, comment/paper content, exception
messages/stacks, and source file paths before export. Application diagnostics
use bounded error kinds, operation classes/outcomes, aggregate counters, and
request IDs only. Request IDs are operationally random and must not become a
user/session identity.

Production operational telemetry retention is exactly 30 days unless a newer
published privacy schedule and protected values are approved together. Enforce
expiry at the upstream sink; the Collector cannot prove sink deletion. Access
is least privilege and audited. Never copy raw production events into issue
trackers or long-lived test fixtures.

## Verification and alerts

Before release:

1. Run `scripts/test_backend_log_export.sh` with the chart-pinned Collector. It
   injects a backend container log plus direct OTLP log, trace, and metric
   fixtures. Every configured protected key is exercised as both a signal and
   resource attribute; safe sentinels must export and protected sentinels must
   not. This local E2E is pipeline evidence, not proof of the live sink or
   retention job.
2. Send valid and hostile mobile telemetry payloads through staging. Require
   valid events to export and unknown fields, identifiers, oversized payloads,
   redirects, and wrong content types to fail closed. Confirm no auth/cookie
   header is sent by the app.
3. Inspect the live sink using canary values that are not personal/content data;
   verify redacted fields are absent and expiry is configured/tested at 30 days.
4. Restart one agent in staging and record replay volume/duplicates and recovery
   time. Verify node coverage and that log rotation cannot outgrow storage.

Alert on API readiness/error/latency and database saturation; paper/deletion
queue age and terminal failure; moderation report age; authentication recovery
failure; Collector rejected/dropped/export-failed data; missing node agents;
telemetry gateway rejection spikes; and deletion-ledger verification/capacity.
Alerts contain aggregates only. Each alert links its owner and the applicable
incident/deletion/moderation runbook.

If redaction, exporter credentials, sink access, or retention is wrong, stop
the affected export, preserve bounded evidence, rotate credentials when needed,
and follow [incident-response.md](incident-response.md). Do not make product
availability depend on mobile telemetry or loosen the schema to recover volume.
