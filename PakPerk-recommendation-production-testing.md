# PakPerk recommendation production testing

Remaining deployment and rollout checks for citation-aware For You with OpenAlex.
The local P/Q/R/S fixture, PostgreSQL worker tests, and live OpenAlex client test
with the development key have passed. The checks below use the actual release
candidate and protected staging or rollout environments.

Local verification on Windows: [2026-11-22 results](docs/recommendation-testing-2026-11-22.md).
These results do not satisfy the protected deployment and rollout gates below.

## 1. Verify the deployed staging candidate

- [ ] Deploy the reviewed API image with schema 26 and `weighted_v1` selected.
  Verify the deployed migration state and that all API replicas use the intended
  configuration. Mount the OpenAlex key in the API and verify HTTPS egress to
  `api.openalex.org`. [Deployment settings](docs/reading-feed.md#citation-policy-rollout)
- [ ] Prove OpenAlex contributes an edge through the deployed worker. Use opted-in
  fixtures with a proven-empty queue and a known public citation such as BERT
  citing *Attention Is All You Need*. Ensure the candidate is on the authorized
  page and the pair has no current local edge. Generate a fresh batch for each
  direction by swapping the root and candidate between fixtures. Check the stored
  root, tier, and direction and the visible explanation.
- [ ] Exercise an OpenAlex outage in staging on a fresh batch with a known local
  edge. Verify the worker completes using local evidence and the original page
  and continuation. Restore the staging configuration and confirm recovery.
- [ ] Run the protected [staging backend load gate](docs/runbooks/backend-load-testing.md#plan-02-queue-search-and-import-fixtures)
  with separate active-queue and opted-in, proven-empty fixture accounts. Verify
  `weighted_v1` at baseline and `citation_online_v1` during the canary. Use the
  `expected_recommendation_policy` input. At 20 items per page the default
  p50/p95/p99 HTTP limits are 350/700/1,400 ms with at most 1% errors.

## 2. Observe shadow, then an opted-in cohort

- [ ] Serve `weighted_v1` while ranking shadow evaluates the same eligible pages.
  Confirm shadow creates zero served batches or training votes. Check aggregate
  coverage, timing, and telemetry delivery before enabling a small, stable
  opted-in `citation_online_v1` cohort. Require measured samples in each phase and
  account for unavailable comparisons. [Observability checks](docs/runbooks/observability.md#verification-and-alerts)
- [ ] Require zero suggestions over active or uncertain queues, zero out-of-page
  papers, and zero tier inversions among cap-eligible candidates. Verify opt-out
  resolves For You to Recent after the queue check. On the signed client, check
  the three-card refill trigger, page-local explanation and feedback provenance,
  and stale refill rejection when the reader saves a paper or opts out.
- [ ] Compare cohort and baseline over the same completed UTC window with the same
  client build. Report sample counts, root-neighbor coverage including pages with
  no roots, paired offline nDCG@10 with judgment coverage, saves per proven-empty
  For You session, dismissals per served card, and refill p50/p95 with stale,
  failed, and canceled counts. Replay weighted, fixed-weight citation, and learned
  citation ranking on identical historical pages for the offline comparison.
  The design leaves the quality-lift decision to the release review. [Measurement procedure](demo/recommendation_evaluation/README.md)

## 3. Rehearse rollback before expanding the cohort

- [ ] Use the staged policy switch to quiesce recommendation workers, select
  `weighted_v1`, and wait for all replicas to converge. Verify the first fresh
  eligible batch reports `weighted_v1`, incompatible jobs are superseded, an old
  citation cursor receives `READING_FEED_CURSOR_STALE`, and the client restarts
  from page one. Keep schema 26 and verify queue enforcement, feedback retention,
  and opt-out erasure. [Staged rollback procedure](docs/reading-feed.md#citation-policy-rollout)
- [ ] Retain the source revision, image and signed-client identities, rollout
  configuration, UTC windows, sample counts, invariant results, and rollback
  result in the release record. Retain redacted evidence and the rollout decision
  together.

## Signed mobile and app-wide release gates

- [ ] Run protected physical acceptance with the exact signed Android and iOS
  candidates. Cover the four device roles and all 42 scenarios in the mobile
  acceptance contract. Verify cached first-readable-frame p95 at or below 1.5 s
  and healthy opening at or below 700 ms, with at least 20 samples each. Verify
  at least 95% cache hits and zero blanks across at least 20 warm next-paper
  requests. Capture the frame-timing window and at least 99.5% crash-free sessions
  across at least 200 exact-candidate sessions over at least 24 hours. [Mobile release runbook](docs/mobile-release.md)
- [ ] For an app-wide release, reconcile the remaining protected evidence in the
  production audit, including migration and restore, account deletion, production
  identity and app links, and the store rollout. [Production completion audit](docs/production-v0.0-completion-audit.md)
