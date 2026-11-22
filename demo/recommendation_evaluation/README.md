# Recommendation evaluation fixtures

These versioned, content-free fixtures exercise recommendation quality only
after the reading-feed authority has proven an empty active queue at a current
library revision. The executable source fixture lives at
`backend/crates/recommendations/tests/fixtures/empty_queue_mixed_v1.json`,
`empty_queue_edge_cases_v2.json`, and `empty_queue_cold_start_v3.json`; the
queue-policy matrix lives at
`backend/crates/reading_feed/tests/fixtures/queue_policy_v2.json`.

Run the offline gate with:

```sh
cd backend
cargo test -p recommendations --test offline_fixture --locked
```

The executable suite covers curated explicit profiles, expected candidate
pools, sparse categories, misleading title-only overlap, author-name
ambiguity, arXiv version deduplication, inactive historical-seed reasons,
negative feedback, and small-profile-change stability. Checked-in thresholds
cover Recall@K, nDCG@K, catalog/topic coverage, intra-list diversity, novelty,
author/category concentration, cold-start coverage, explanation correctness,
negative-feedback response, ranking stability, latency, estimated cost, and
bounded resource use.

The v3 cold-start fixture is a separate release gate for both sides of the
bootstrap problem. Its empty/new-user profile has no categories, topics,
authors, saved-query matches, feedback or inferred categories, or historical
seeds, while its active queue is proven empty. Every eligible candidate must
retain Recent provenance, no personalized provenance may appear, and the exact
ranked paper order is checked so the recency fallback stays deterministic. Its
six-paper curated cohort is entirely marked cold-start and carries explicit
catalog/topic coverage, intra-list-diversity, author/category-concentration,
cold-start-coverage, and resource-budget thresholds.

Latency and cost are deliberately injected fixture measurements rather than
wall-clock observations from the CI machine. `latency_micros` is microseconds;
`estimated_cost_microusd` is micro-US-dollars (1 USD = 1,000,000 micro-USD);
`generator_invocations` counts generator executions;
`generator_document_work_units` counts one generator examining one candidate
document; and `external_requests` counts metered or remote service calls. The
local metadata fixtures use seven generators, zero external requests, and zero
estimated spend. Their explicit maximum budgets are checked in the returned
evaluation report.

The machine-readable
[`offline_resource_report_v1.json`](offline_resource_report_v1.json) mirrors
the executable fixture inputs, units, thresholds, and expected pass status. A
benchmark harness may instead supply `measurement_source: measured`, but live
wall-clock measurements remain staging evidence and must not become a flaky
deterministic quality gate. These fixtures are not claims about production
relevance or online outcomes.

The citation worked fixture ranks P, Q, R, S with feature masks 1, 2, 5, 4.
It runs the production builder on the same replay pages with weighted
ranking, fixed citation weights, and learned citation weights. It prints
paired nDCG@10 differences and judgment coverage.

```sh
cd backend
cargo test -p recommendations --test offline_fixture --locked citation_online_worked_example -- --nocapture
```

For a live rollout comparison, run [rollout_outcomes.sql](rollout_outcomes.sql)
on the retained database with the same completed UTC window for both policies.
Run it after the 30-minute attribution window closes and before the cohort's
24-hour batches expire. The report returns aggregate counts only.
Use the same client build in both arms. Save attribution requires
`RECOMMENDATION_EVENTS_ENABLED=true`, behavioral interaction collection, and
a build that uses the Library operation ID as the recommendation save event ID.
Older builds' save events cannot be matched exactly.

```sh
psql -v ON_ERROR_STOP=1 -v window_start="$window_start" -v window_end="$window_end" \
  -f demo/recommendation_evaluation/rollout_outcomes.sql
```

A session starts at an account's first observed For You page and continues
through subsequent page batches under the same scoring policy and Library
revision while consecutive batches are at most 30 minutes apart. Each batch
contributes its first serve. Empty served batches use their creation time as
an approximation. Session counts include accounts that never save. The report
uses accepted Library writes with discovery provenance and a matching
consented save interaction on the served card. The event and write must
share the account, paper, and operation ID. Saves are deduplicated by base
arXiv ID per session. An accepted dismissal counts once per served card within
the same attribution window. Both measures use the 30 minutes after each
card's first serve. Shadow predictions have no served batches of their own.

The report counts observed first serves. Reusing a cached batch can collapse
repeat visits and continuation cards served after the window ends are outside
the sample. Record comparable event collection and client coverage in both
arms. Use observed cursor walks for an exact session-level release decision.

For refill latency, group `recommendation_refill_completed` mobile events in
the same UTC window by `recommendation_policy`. Compute p50 and p95 from
`elapsed_ms` for `outcome=success`. Report that sample size and the counts
for `stale`, `failed`, and `canceled` alongside the percentiles. Timing starts
at the three-card trigger, includes waiting for a foreground refresh, and ends
when the controller accepts the continuation or records its outcome.
