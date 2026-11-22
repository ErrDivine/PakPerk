# Recommendation verification — 2026-11-22

Source: `main` at `f5d94ca7f9a1a1814a50b4d03908a3a742d2b43c`, plus the
existing, uncommitted compact comments/reader toolbar changes and the small
verification fixes described below. This is local verification, not a production
release approval. No deployment, signed app installation, or Git commit was made.

## Results

| Check | Result |
| --- | --- |
| API recommendation/OpenAlex/configuration contracts | 27 passed; the separately executed live test is excluded |
| Reading-feed and ranking crates, including offline replay | 61 passed |
| PostgreSQL recommendation persistence and generation jobs | 8 passed against a fresh, dedicated database |
| Mobile recommendation, refill, explanation, API/cache, and reader tests | 84 passed across eight existing test files, after the toolbar expectation fix |
| Backend load-harness contracts, Linux container with external networking disabled | 17 passed |
| Protected load-workflow validator contracts | 65 passed |
| Full Helm production contract validation | Passed |
| Targeted Dart analysis, Rust formatting, Git whitespace checks | Passed |

Total: 262 passing automated tests, plus the deployment/static checks above.
Logs are retained locally under `.local/recommendation-testing-20261122/`.
An initial database run without `TEST_DATABASE_URL` skipped coverage and is not
counted. The reported database result uses a separate fresh database from the API
tests, since worker claims are global and failed fixtures can leave pending jobs.

The database-backed API test exercises opted-in citation generation, exact
authorized-page membership, persisted evidence, weighted rollback, stale cursor
rejection before enqueueing, shadow without an additional served batch, and local
edge retention during a simulated provider failure. Mobile tests cover the
three-card refill trigger and stale/canceled results after saves, opt-out, account
changes, and revision changes. These are local fixtures, not deployed evidence.

## Small compatibility fixes

- Preserve the existing icon-only comments toolbar. Update its existing test to
  check the icon while retaining accessible labels, 48-pixel targets, keyboard
  order, and complete arXiv text.
- Generate PostgreSQL fixture publication dates at microsecond precision.
  Windows clocks can have finer precision, causing continuation equality and
  replay assertions to fail after a database round trip. No runtime ranking or
  persistence checks were relaxed.
- Pin the packaged alert-policy JSON to LF in `.gitattributes`. Windows automatic
  CRLF conversion changed its bytes and broke the pinned Helm SHA-256 check.
  The verified LF hash is
  `1332fab6e5ab0ef0a98a0b74e3d4285ae10764885be9b80e4a6697fb4d42dc46`.

No Git merge conflicts were present.

## Live OpenAlex: unresolved latency gate

An authenticated HTTPS request to `api.openalex.org` returned HTTP 200 and three
known works in 1,875 ms. The existing production-client live test was attempted
twice; both attempts returned `Timeout` at approximately 1.25 seconds, before
reference assertions could run. The client currently allows 1,250 ms per request
and 1,500 ms for the complete lookup.

The key was used only in process memory for requests to the official API;
captured output was redacted. It is absent from this report and source changes.
The production timeout was left unchanged. Local provider-failure fallback tests
passed, but this machine has not demonstrated successful live enrichment within
the production budget. Recheck the exact deployed candidate from staging before
enabling a citation cohort; do not treat the HTTP 200 diagnostic as a passing
production-client test.

## Remaining protected gates

The production checklist remains unchecked. No Kubernetes context or staging
access configuration was found on this machine. The following need the actual
protected environment and release artifacts:

- Reviewed image deployment, schema 26 and replica/configuration convergence;
  live worker citation edges in both directions, outage/recovery and rollback.
- Separate authorized queue and proven-empty accounts for measured staging load
  under both policies, including the stated HTTP percentile and error limits.
- Measured shadow/cohort invariants, telemetry, completed UTC comparison windows,
  judgment coverage, save/dismissal outcomes, and a rollout decision.
- Exact signed Android/iOS candidates, four physical device roles, all 42
  scenarios, timing/cache samples, and at least 200 sessions over 24 hours.
- Remaining protected app-wide production-audit evidence.

Do not mark these gates complete or expand the citation cohort using local test
counts or deterministic fixture quality scores as substitutes.

## Cleanup

Removed 5,527 build/cache files newly generated during this verification
(4,011,025,435 bytes, approximately 4.01 GB), using a file inventory captured
before testing. Pre-existing artifacts were preserved. Both dedicated test
databases were dropped; the development database and phone installation were
unchanged. Test logs and cleanup evidence remain in the local evidence directory.
