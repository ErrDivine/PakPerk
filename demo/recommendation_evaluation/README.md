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
