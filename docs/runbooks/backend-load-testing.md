# Backend staging load and latency gate

**Owner:** service owner. **Approvers:** release manager and database owner;
privacy/safety owner as an additional approver when authenticated comments or
library data are exercised.

`scripts/run_backend_load.py` is an opt-in, bounded HTTP load gate for a
reviewed staging deployment. It always exercises guest feed pagination and
guest paper metadata, and it can add authenticated library reads, the first
published-comments page, and explicitly authorized library mutations. Normal
CI runs only its deterministic loopback contract tests; CI never calls a live
environment.

This tool is not authorized for production. Obtain deployment-owner approval,
confirm staging capacity and rate-limit headroom, and use only synthetic papers
and a disposable staging account. Record the exact source revision, deployment
revision/topology, database state and saturation, fault profile, observation
window, and telemetry links next to the emitted evidence. The JSON intentionally
does not contain those potentially sensitive external coordinates.

The preferred shared execution path is the manual-only **staging backend load
gate** Actions workflow. It runs only from `main`, checks out an exact reviewed
full SHA reachable from `main`, enters the protected `staging` environment,
uses bounded choice inputs, and uploads aggregate evidence even when an SLO
gate fails. Configure that environment with
`PAKPERK_STAGING_API_ORIGIN`, and only for selected authenticated scenarios,
the `PAKPERK_STAGING_LOAD_TOKEN` secret. Authenticated comments use the
synthetic `PAKPERK_STAGING_LOAD_COMMENTS_PAPER_ID` variable. Mutations also
require the dedicated absent `PAKPERK_STAGING_LOAD_MUTATION_PAPER_ID` variable
and the dispatch confirmation phrase. Environment reviewers must verify those
fixtures and the requested load profile before approving a run.
The workflow wraps the `0400` evidence and checksum in a tar archive so the
inner owner-only modes survive artifact transport; repository and environment
access controls still determine who can download the Actions artifact.

## Guest gate

The output parent directory must already exist and the output path must not.
Staging accepts only a credential-free HTTPS origin, does not follow redirects
or use proxy environment variables, verifies the platform TLS trust chain, and
caps response bodies. A typical guest run is:

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-load.json \
  --evidence-id release-0.2.0/staging-backend-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 60 \
  --concurrency 8 \
  --max-requests 10000 \
  --request-timeout-seconds 5 \
  --preflight-timeout-seconds 60 \
  --minimum-paper-records 200 \
  --minimum-samples-per-scenario 20
```

Replace the example origin and 40-character revision. The preflight follows
bounded feed cursors until it has at least 200 unique UUID paper records. The
measured feed requests reuse those discovered pages, while metadata requests
sample the discovered paper IDs. Guest requests never receive a bearer token,
even when authenticated scenarios are enabled in the same run.

The workload stops scheduling at the first of its duration or request cap.
Concurrency is limited to 64, duration to one hour, measured requests to
100,000, each request timeout to 30 seconds, preflight to five minutes plus at
most one in-flight request timeout, and each response to 8 MiB. Warm-up,
preflight page, mutation, and library-snapshot counts are separately bounded.

## Authenticated reads

Put a current synthetic-account access token in a regular file outside the
repository. It must contain only the token plus at most one line ending, be
16–65,536 bytes, have owner-only permissions such as `0600`, and not be a
symlink. Never put the token in an argument, environment variable, evidence
path, terminal transcript, issue, or artifact.

Add library reads and a comments first-page read with:

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-auth-load.json \
  --evidence-id release-0.2.0/staging-backend-auth-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 60 \
  --concurrency 8 \
  --max-requests 10000 \
  --bearer-token-file /secure/runtime/pakperk-load-token \
  --include-library \
  --comments-paper-id 00000000-0000-4000-8000-000000000001
```

The library scenario requests one bounded `to_read` page. The comments scenario
requests only `limit=50` and never follows `next_cursor`, so it cannot load the
entire discussion. Response bodies are validated in memory and discarded;
tokens, URLs, category values, paper IDs, titles, comments, and other response
content are never printed or serialized into evidence.

## Explicit mutation gate

Library mutation load is off by default and requires all of
`--allow-library-mutations`, `--library-mutation-paper-id`, and a token file.
Use a dedicated disposable staging account and an existing synthetic paper
that is absent from that account's complete bounded `to_read` snapshot. Run
mutation checks separately with concurrency `1` for stable latency evidence:

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-mutation-load.json \
  --evidence-id release-0.2.0/staging-backend-mutation-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 30 \
  --concurrency 1 \
  --max-requests 1000 \
  --minimum-samples-per-scenario 10 \
  --bearer-token-file /secure/runtime/pakperk-load-token \
  --allow-library-mutations \
  --library-mutation-paper-id 00000000-0000-4000-8000-000000000002 \
  --max-library-mutation-requests 20
```

The runner alternates idempotent save/remove operations, permits only one
in-flight mutation, caps measured mutation requests at 100, and always sends a
final idempotent removal after the measured window. That cleanup request is in
addition to the configured cap. A cleanup failure fails the gate. A force-kill,
machine failure, or lost response can still interrupt cleanup: inspect the
synthetic account and remove the fixture manually before any rerun. Successful
removals leave synchronization tombstones and every attempt consumes staging
rate-limit budget, so this mode is unsuitable for a real user account.

## Thresholds and fault profiles

Every enabled scenario enforces a minimum sample count, maximum error rate, and
nearest-rank successful-request p50, p95, and p99 latency. Defaults are:

| Scenario | p50 | p95 | p99 | Error rate |
| --- | ---: | ---: | ---: | ---: |
| Warm feed page | 250 ms | 500 ms | 1,000 ms | 1% |
| Cached metadata | 125 ms | 250 ms | 500 ms | 1% |
| Library page | 250 ms | 500 ms | 1,000 ms | 1% |
| First comments page | 350 ms | 700 ms | 1,400 ms | 1% |
| Library mutation | 250 ms | 500 ms | 1,000 ms | 1% |

Override an explicit scenario with a repeated
`--threshold NAME=P50_MS,P95_MS,P99_MS,ERROR_RATE`; for example,
`--threshold metadata=100,200,400,0.005`. Use
`--scenario-weight NAME=WEIGHT` to change the default mix of one feed request
to four metadata requests and one request for each optional scenario.

For a repeatable client-side degraded-network exercise, set a fixed added delay
with `--simulated-network-delay-ms` (0–5,000) and deterministic synthetic loss
with `--simulated-packet-loss-rate` (0–1). Loss selection hashes the evidence
ID, source revision, scenario, and sequence; the same inputs reproduce the same
selection. These controls do not emulate bandwidth, jitter, TCP retransmission,
or server-side dependency faults. Record any infrastructure-level fault
injection separately, and do not claim a client-side profile as real packet-loss
measurement.

## Evidence and interpretation

The tool exits nonzero on configuration, preflight, cleanup, sample-floor,
latency, error-rate, warm-up, or runner failures. It writes canonical,
sorted-key JSON before returning a threshold failure. The harness refuses an
existing path, atomically creates the file as owner-readable `0400`, and emits
only aggregate counts, bounded error classes, latency percentiles, configured
bounds, scenario names, an origin SHA-256, the supplied evidence ID/revision,
and explicit limitations. Hash and store that file in the approved immutable
release-evidence system; local filesystem permissions alone are not durable
immutability or approval.

This backend gate covers only the HTTP portion of production-plan section
19.6. It does not measure Flutter frame build/raster time, on-device SQLite
query latency or size, the 500-paper cache/100-saved-paper state, PaperReader
retention, memory-warning/lifecycle recovery, physical-device behavior, or
mobile feed single-flight behavior. Those remain separate physical-device and
mobile profiling gates. The comments request demonstrates bounded first-page
use by this harness; it does not replace the mobile pagination-retention test.

Run the local, no-live-call contract suite with:

```bash
python3 scripts/test_backend_load.py
```
