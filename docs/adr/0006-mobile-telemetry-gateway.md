# ADR 0006: schema-validating mobile telemetry gateway

- Status: accepted
- Date: 2026-07-31

## Context

Mobile release evidence needs aggregate operational signals, but a native app
cannot safely hold an OTLP backend credential and must not emit account,
device/session, paper, content, token, raw exception, or stack data. Allowing
arbitrary OTLP attributes would make privacy behavior depend on every callsite
and could bypass backend redaction expectations.

## Decision

Mobile sends best-effort, unauthenticated HTTPS POSTs only to the exact
environment `/v1/logs` endpoint. A dedicated Rust gateway accepts one bounded
JSON/OTLP payload shape, rejects unknown event names/attributes and sensitive
keys, enforces 16 KiB/request and media-type/method/path limits, and exports
accepted records to the in-cluster Collector. The app has a two-second
deadline, at most two in-flight sends, and no persistent queue, retry, cookie,
authorization header, or identifier. Failure drops telemetry without changing
product behavior.

Ingress supplies coarse per-client connection/rate limits. The gateway's
closed schema is the privacy boundary; downstream Collector redaction is a
second layer. Crash-free release evidence uses an externally reviewed aggregate
distribution/store denominator rather than inventing a stable identifier.

## Consequences

- The mobile bundle contains no observability credential and direct upstream
  OTLP coordinates remain private.
- New event/attribute vocabulary requires code, tests, privacy disclosure, and
  gateway review before rollout.
- Offline and saturated periods intentionally lose telemetry, so metrics are
  operational samples rather than complete behavioral analytics.
- Source tests can prove validation/redaction mechanics, but live retention,
  ingress behavior, representative crash windows, and store disclosures remain
  external release evidence.
