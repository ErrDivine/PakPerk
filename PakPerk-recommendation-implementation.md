# PakPerk · Citation-aware For You recommendations

**Implementation specification for coding agents**  
**Target policy** `citation_online_v1` · **Repository** `ErrDivine/PakPerk` · **Verified baseline** [`04059c5e27b6b4bf5ac928bdacd08b60f47abeb2`][baseline]

Implement a page-local ranker for signed-in, opted-in readers. When the reader has an active paper, show To Read. When the server proves the queue empty, prefer direct citations to chosen papers in the reader’s inactive Library. Learn how to order equally strong evidence from explicit ratings on cards actually served. The attached *PakPerk recommendation design* defines the product behavior. This specification maps it to the code on `main` at the verified commit.

## 1. Keep queue authority and retrieval intact

| When the signed-in feed is enforced | Required result |
|---|---|
| At least one active Library row | Serve Inbox, Read next and Reading in `saved_at ASC, paper_id ASC`. The SQL also recognizes legacy `to_read`. Category and requested discovery mode cannot hide these rows. Invoke no recommendation generator. |
| Authority unavailable, stale, or inconsistent | Follow the existing closed error or restart path. An empty local list, cached batch or generation-job result cannot prove emptiness. |
| Current `queue_first_v1`, active count zero, `queue_proven_empty=true`, effective For You, personalization on | Run the selected For You policy on that one authorized page. |
| Same empty-queue proof, requested For You, personalization off or unknown | Resolve through the existing Recent fallback. Keep Following, Explore, enhanced-recommendations-off Recent, and guest/public feed behavior as implemented. |

The input is the chronological page already produced by `recommendation_snapshot`. It requires metadata readiness, applies the category filter, and excludes existing Library rows, retained removal rows, and retained feedback of **every** type by paper ID or base arXiv identity. Keep its descending `(published_at, paper.id)` keyset, lookahead and page size. Return only original, unmodified `PaperSummary` values. Copy the snapshot’s exact `next_position` even if caps shorten the result or the last displayed card has a different timestamp. A cited paper outside the page can first compete when its own page is authorized. The reading-feed service validates both the summaries and the continuation. [Snapshot SQL][snapshot] · [Service validation][service] · [Feed contract][feed]

## 2. Change map

| Area | Baseline behavior | Work |
|---|---|---|
| [Recommendation source][source] and [job repository][jobs] | Configured discovery enqueues work. Minimal Recent builds inline. Job fingerprints and batch lookup already include policy version. | Select the policy after resolving effective mode. Carry it through prepare, enqueue, claim, build, persistence, lookup and serve. |
| [Recommendation repository][repo] | `historical_seeds(user_id, 50)` returns recent Reviewed/Archived rows. `citation_neighbors` returns undirected ID sets with a global `LIMIT 5000`. `feedback_context` uses separate pool reads. | Add a bounded, directed page-to-root lookup and a consistent read of learning inputs. Preserve the historical inputs used by the existing semantic generator and baseline policy. |
| [Candidate model][model], [citation][citation], [author][author] and [batch builder][batch] | Citation stops at the first matching seed. Author matches trimmed, lowercased display names. Fanout merges sources, features and reasons by paper ID. | Keep all qualifying root pairs through evidence aggregation. Compute the three bits from directional evidence and the actual author match. |
| [Scoring][scoring], [reranking][rerank] and [explanations][explain] | The validator accepts only `weighted_v1`. Reranking searches the entire pool for exploration. Explanation order follows merged reasons. | Preserve baseline behavior behind its version. Add tier-first slot selection, a centered learner adjustment and a winning reason that survives replay. |
| [Feedback route][feedback], [schema][schema], [profile writes][profiles] and [retention worker][maintenance] | Feedback already has idempotency and revision fencing. Expiring a batch sets `feedback.batch_id` to null. Opt-out clears derived interests. | Capture consent and credited features on each accepted row. Invalidate ranking after erasure or retention and retain the existing feedback API. |
| [Flutter feed controller][mobile], [feed screen][screen] and [interaction controller][interactions] | Page size 20, three-card trigger, single-flight refill, page-local provenance and operation UUIDs already exist. | Exercise the existing paths with the new policy, explanations, feedback and rollback. |

## 3. Implement in dependency order

### A. Version the policy and define the stored evidence

1. Add `citation_online_v1` to the recommendation scorer’s supported versions. Keep `algorithm_version = recommendations_v1`, queue policy `queue_first_v1`, item source `for_you_v1`, and the current feedback request/response shapes. Only a configured, opted-in **effective** For You may produce a batch with the new version. Unknown policy versions cannot run. Give API and worker one selection rule, with `weighted_v1` as the rollout default. A shadow run must have a separate output from a servable batch.
2. Add a **forward migration** after the latest migration on the implementation branch. Add nullable `recommendation_feedback.feature_mask SMALLINT CHECK (feature_mask BETWEEN 0 AND 7)`, with no backfill or default. Add nullable, bounded, typed-at-the-Rust-boundary candidate evidence on `recommendation_candidates` (a dedicated JSONB column is one compatible implementation). Leave `raw_features` decodable as the existing closed, unit-interval `RecommendationFeatures`. A signed learned adjustment does not belong in that vector.
3. Store the following for **every new-policy candidate**, including a tier-0 Recent card. Keep the existing candidate sources, raw features, scores, ordered reason codes, reason evidence, position and `served_at`. A missing new evidence record on an old policy decodes to tier 0, mask 0, overlap false, adjustment 0 and no supporting roots for internal consumers. Old explanations still replay with their original ordering. Require valid evidence on the new policy before publishing or training.

| Candidate evidence | Representation and invariant |
|---|---|
| Tier | Integer 0–4. Tiers 2–4 require qualifying citation evidence. Tier 1 requires an explicit author match and no qualifying edge. |
| Active feature mask | `1` = reference, `2` = citing paper, `4` = followed author. Bitwise OR, range 0–7. A bidirectional strongest root can set both directional bits. |
| Overlap | Boolean, computed from **all** matching eligible root bases before truncating display evidence. |
| Learned adjustment | Finite signed sum of centered weights for active bits, separate from the overlap bonus and diversity penalty. Persist the value used for this card. |
| Supporting roots | Zero to two distinct root bases. Store a stable root paper ID, bounded public title for replay, Library state, root tier and direction(s) relative to the candidate. Choose a winning root first. When equally strong roots supply different directional bits, include witnesses for both where needed. Otherwise choose the next root in deterministic root order. |

Validate the new encoding at write and read boundaries. Keep source/reason list limits and bounded JSON sizes from the migrations. Describe the citation direction using only what its endpoints establish. Use only public paper metadata and the account evidence specified here. Private notes and annotations have no role in this lookup or in explanations. [Candidate schema][schema] · [Feature vector][features] · [Batch writer and decoder][repo]

### B. Select ten roots and resolve page-local edges

For each current, unremoved Reviewed/Archived Library row owned by this user, use `papers.arxiv_base_id` to check retained feedback. A positive for promotion is `relevant AND feature_mask IS NOT NULL`, including zero. Any retained `not_relevant` or `dismissed` for the same base vetoes the root, irrespective of consent, order, or version. A veto removes only that root’s path. A later positive cannot erase a retained veto. Look across retained feedback for these checks, independently of the learner’s 100-paper limit.

| Root state and evidence after veto | Root tier |
|---|---:|
| Reviewed with a retained opted-in relevant rating | 4 |
| Any other Reviewed row, including a manually imported paper | 3 |
| Archived with a retained opted-in relevant rating | 2 |
| Archived alone, removed, active, or absent from Library | Ineligible |

Compute tier **before** limiting rows. Group by root base identity, use its best eligible representative, and select ten by `tier DESC, library.updated_at DESC, paper_id ASC`. Query the Library directly. Taking ten from the old 50 seeds can lose an older tier-4 root. A positive on an unsaved card can already train a feature. Saving that paper places it in the active queue. It contributes a citation root only after it qualifies under the table. The design’s optional future per-paper opt-in for Archived is outside this version.

Implement two bounded joins over `paper_connections` using **both** the selected root set and the authorized page IDs. In both branches join `paper_processing` on the **citing endpoint** and require `processing.generation = connection.generation`.

| Stored edge | Feature relative to candidate C |
|---|---|
| Selected root R cites page candidate C | Reference |
| Page candidate C cites selected root R | Citing paper |

Discard self-pairs by base. Group by `(candidate_base, root_base)`, OR the two direction flags and keep the actual authorized candidate ID for output. A reciprocal edge counts as one pair. At server limit 50 there are at most 500 distinct pairs, and at mobile limit 20 there are at most 200. A global unordered edge limit before the page/root join can silently drop a qualifying match. Use one set query with bound IDs or equivalent bounded SQL. Inspect its query plan on skewed in-degree data before adding an index. PakPerk’s initial schema makes `papers.arxiv_base_id` unique and edges generation-specific. Also test duplicate-version inputs at the Rust boundary without weakening that database constraint. [Graph schema][graph] · [Existing seed and edge reads][repo]

For each candidate, find its highest matching root tier. **Strongest roots** are all matching roots at that tier. Compute reference/citing bits only from those roots. Compute overlap from all distinct qualifying root bases, including weaker ones. Set the author bit only from the existing explicit `AuthorFollow` match. A generic `explicit_follow` feature can also mean topic, category or saved query. Preserve that distinction and the normalized display-name semantics. With no qualifying root, assign tier 1 for an author match, otherwise tier 0. For example, if A (tier 4) cites C and C cites B (tier 3), C has tier 4, reference, and overlap. The weaker B edge does not set the citing bit.

Use the new classified pairs in the citation generator for this policy. Preserve the eligible citation-affinity input to the weighted score and the seven existing For You generator classes, including Recent. Semantic similarity alone cannot set a direction, overlap, or citation tier. Compute candidate tier and learnable bits from complete bounded evidence across the merged page. A partial generator failure must not silently relabel a known high-tier card as tier 0. Reuse the same author matcher if it is needed outside fanout. For a genuine missing edge, classify the card from the evidence that exists. [Fanout and baseline scoring path][batch] · [Candidate merge][merge]

### C. Capture feedback, reversibly

In `RecommendationBatchRepository::record_feedback`, use the authenticated principal, batch and paper ID to load the owned, unexpired candidate. Read the batch mode and policy, **the candidate’s own `served_at`**, its stored evidence, and current account consent. The current route accepts certain `ready` as well as `served` batches. Preserve its existing acceptance and suppression semantics while gating vote credit on the served **item**. Return the existing 404 for inaccessible/expired items. Client-supplied masks, tier, timestamps and consent claims have no place in the feedback DTO.

| At acceptance | Value written to feedback |
|---|---|
| No known affirmative consent, including no profile | `NULL`. Existing pre-migration rows also stay null. |
| Opted in, `relevant` or `not_relevant`, actually served new-policy For You item | Copy the persisted mask, including `0`. A corrupt/missing required new-policy record is an error. |
| Opted in, valid accepted feedback without feature votes | `0`. Includes a dismissal, other policies/modes, a valid ready-but-unserved item, or a card with no active feature. |

A new insert, its revision advance, existing relevant-category affinity write when enabled, and superseding stale building/ready batches must commit once. Preserve `UNIQUE (user_id, idempotency_key)`, content matching, 201 for a new write, 200 for a matching replay and 409 for a conflicting reuse on an eligible item. Replays must never recalculate or restore a stored mask. Applicable retries after expiry still follow the existing route eligibility check. Reading the learner must work solely from feedback and paper identity after the 24-hour batch expires and its FK becomes null. [Route and request rules][feedback] · [Transaction][repo] · [Feedback FK][schema]

Serialize feedback acceptance with opt-out and reset. A concrete lock order is to take the user row at transaction entry, before reading consent or locking feedback/profile/batch rows. Profile mutations already take `users ... FOR UPDATE`. Use a compatible shared/exclusive locking protocol across these paths, including first-profile creation. Use the existing subordinate lock order used in publication. If the rating commits first, the subsequent opt-out clears its mask while preserving the raw feedback used for suppression. A rating granted the lock after opt-out sees disabled consent. Both schedules must leave a null mask. On opt-out, clear **all** non-null masks for the account, including zeros, in the transaction that clears derived interests. Advance the feedback fence when evidence changes. Re-enabling consent starts from the remaining eligible evidence and cannot revive erased masks. Reset All deletes feedback, its fence, interactions and batches in the existing reset transaction. Account deletion uses the existing user FK cascades. [Profile mutation and reset][profiles]

Extend `cleanup_retention` to identify affected accounts and advance their feedback revisions atomically with bounded feedback deletion. Bumping once per account per cleanup transaction that removes any retained feedback is a conservative implementation that covers votes, root eligibility and exclusions. Use deterministic account lock order and preserve bounded concurrent cleanup. Selecting rows `FOR UPDATE` before taking the account lock can invert opt-out’s order. Exercise both writers concurrently. Batch-only cleanup must leave votes and the feedback revision intact. The existing maintenance worker supplies the 180-day cutoff. [Retention worker][maintenance] · [Cleanup transaction][repo]

### D. Compute three weights from one snapshot

At batch build, use a single read-only repeatable-read transaction or one SQL statement to obtain the feedback revision and matching vote evidence for the account. Tie root feedback eligibility and candidate history to the same view when reading them. Compare the read Library/profile/feedback fences with the authorized request or claimed job. `feedback_context` currently reads the revision and history separately through the pool. Simply adding another pool query can attach old weights to a new revision.

For a fixed batch observation time `T`, take these steps in order.

1. Select the account’s accepted `relevant` and `not_relevant` ratings with nonzero masks and `T - 180 days < created_at <= T`. A zero mask marks consent for root qualification but supplies no feature vote. Null masks, dismissals, impressions, and saves do not enter this set.
2. Join to `papers.arxiv_base_id`. Take the latest **trainable** rating per base by `created_at DESC, feedback.id DESC`. Sort those winners by the same recency order and take 100 distinct papers. Applying the 100-row limit before version/identity deduplication yields different weights.
3. For each retained rating with `k = popcount(mask)`, add `1/k` to the positive or negative total for **each** active bit. One rating therefore supplies one vote in total. Use deterministic accumulation. Integer sixths are convenient for the possible shares 1, ½, and ⅓.
4. For each of the three features independently, compute `w = (2 + positive_votes) / (4 + positive_votes + negative_votes)`. No votes yields 0.5. Recompute from the bounded evidence on the next eligible build. There is no persistent counter to undo on opt-out, retention, or a replacement rating.

Read the page’s exclusion fence as well. In this baseline, the empty-page snapshot precedes the separate feedback-context read. For the new policy, carry the feedback revision observed in the chronological snapshot through the **internal** request and compare it during prepare/enqueue, or equivalently revalidate the page exclusions against the same fence. If a positive rating is accepted between those reads, an obsolete page must not be stamped with the newer revision. Keep the existing wire cursor and immutable job candidate IDs. [Snapshot and exclusions][snapshot] · [Feedback context and revision checks][repo]

### E. Rank one slot at a time and make the result explainable

Reuse the configured `weighted_v1` numeric score, including the reader’s recency/novelty controls and `min(qualified_impressions, 5) / 5` repeat-exposure feature. Add the following amounts **once per candidate**.

```text
overlap_bonus = 0.25 if at least two distinct eligible root bases match, else 0
learned       = sum(w[f] - 0.5 for each active feature f)
within_tier   = weighted_v1(candidate) + overlap_bonus + learned
```

Use `within_tier` as the score before slot diversity. Keep tier as a separate integer comparison. Preserve the existing hidden/negative exclusions, exact-ID checks and base-version deduplication. When competing versions of one base appear in a fixture, prefer the best eligible tier before applying the within-tier and deterministic version tie-breaks. Keep the returned document and evidence bound to the chosen version.

```text
selected = []
while selected has room:
    eligible = remaining candidates passing exclusions and all current caps
    if eligible is empty: stop
    tier_pool = candidates in eligible with the highest tier in eligible
    if this is an exploration slot and tier_pool contains an exploration candidate:
        tier_pool = its exploration candidates
    pick the best in tier_pool by within_tier minus existing diversity penalty
    apply existing score / updated_at / seeded tie ordering on equal adjusted scores
    record the pick and update author, primary-category and topic counts once
```

Caps and diversity see the entire selected prefix. A capped tier-4 paper can allow a tier-3 paper into this slot. A tier-1 explorer cannot jump an eligible tier-4 paper. Do not reset the counts by tier or concatenate independently reranked tier lists. Keep `weighted_v1`’s original slot order for its own version. [Scoring implementation][scoring] · [Slot selector and tie-break][rerank]

Order immutable reasons **after** merge and selection. For tiers 2–4 lead with the winning citation using `reviewed_paper_citation` or `archived_paper_citation`. For tier 1 lead with `followed_author`. Tier 0 uses existing evidence. A reference can say “Your reviewed paper A references this paper.” A citing paper can say “This paper cites your reviewed paper A.” For reciprocal edges describe both if helpful. Keep Archived wording literal. The brief feed label currently comes from the first code’s title. The explanation endpoint can use the stored direction, title and seed ID for its detail.

Both Flutter decoders require **unique reason codes**. Two Reviewed roots are valid evidence but cannot yield two `reviewed_paper_citation` entries. Store both roots internally. Render one deterministic explanation per code, with the leading seed as its single `seed_paper_id`. Preserve existing `behavior_used` signals and set it when the learned adjustment affects the rank, including on an author-only card. Decode the new-policy explanation from the same stored evidence and require its ordered codes to match the persisted codes. When the existing endpoint authorizes replay, render the evidence recorded at serve time, even if the graph or weights have since changed. Keep the feed label within 96 characters and explanation title/detail within mobile’s 256/1024 limits. [Explanation builder][explain] · [Stored replay][repo] · [Feed model][mobilemodel] · [Explanation model][interactionmodel]

### F. Wire the worker, batch replay and mobile buffer

1. In `BatchRecommendationSource::prepare`, resolve effective mode and policy, bind them to the page and revisions, and pass the exact selected version to `existing_or_prove_empty` and `enqueue_generation`. The generation fingerprint already includes the ordered candidate IDs, seed, versions, revision tuple and continuation. The batch uniqueness key includes the scoring policy. Reuse both mechanisms. Keep the Following saved-search digest, the Recent-only inline path and existing reading-brief batch provenance working.
2. In `process_generation`, hydrate exactly the claimed IDs and verify their count, context revisions, allowed effective mode and claimed policy. Read roots, pairs and weights only for the relevant policy (or its explicit shadow comparison). Use the common production builder. A rollout switch changing between enqueue and claim must never cause a new ranking to be published under an old version. Supersede an incompatible claim and let a fresh request select the current policy. Keep lease ownership, retry and completion behavior. Treat unavailable input as unavailable and revision drift as stale.
3. Retain `persist_ready` and `serve_ready` as separate transactional checks of current active count, Library revision, profile revision and feedback revision. Verify expected policy when resolving/serving an existing batch, including after a rollout switch. An accepted rating invalidates an old ranking even when the queue remains empty. Return the **stored** `batch_metadata.recommendation_policy_version`. The service’s original-page validation remains the final response check. A concurrent save, import, opt-out or reset must win against an obsolete worker or cache read. [Source orchestration][source] · [Job lifecycle][jobs] · [Publication and serve][repo]
4. On mobile, use `onCommittedPage(index)` → `loadMore()`. It already requests 20 and fires when `items.length - index - 1 <= 3`. At index 15 of 20, no refill is due. At index 16 it is due. Rapid commits share the guarded in-flight operation. Each continuation is a fresh authenticated reading-feed request. Append only when account/auth epoch, request generation, enforcement, queue proof and revision, effective mode, profile/feedback revisions, algorithm and recommendation policy are compatible. Different page batch IDs are expected. A compatibility mismatch discards the continuation and re-arbitrates from page one.
5. Preserve item-level origin. After two pages, displayed index 20 refers to **page two’s batch and position 0**. Use that provenance for the explanation, feedback, save attribution and interaction events. Cache only what the existing single-page batch representation can describe. A pending save/import, local active paper, stale authority, account switch or late response suppresses discovery until current authority arrives. Saving a suggestion uses the ordinary Library save action and immediately enters the pending To Read flow. Keep the existing feedback sheet and idempotent retry. Compute tiers and weights on the server. [Controller and continuation checks][mobile] · [Mobile provenance tests][mobiletests] · [Feedback interaction][interactions]

## 4. Acceptance tests

Make the worked example the first ranking fixture. A is Reviewed and rated relevant with consent. B is Reviewed without a qualifying positive. Two prior reference-only positives give `w_reference = 4/6`. One citing-only negative gives `w_citing = 2/5`. The author weight is `1/2`. Hold other scores equal and disable binding caps and exploration for this fixture.

| Card | Evidence | Tier | Learned adjustment | Expected slot |
|---|---|---:|---:|---:|
| P | A → P | 4 | +1/6 | 1 |
| Q | Q → A | 4 | −1/10 | 2 |
| R | B → R and explicit author match | 3 | +1/6 | 3 |
| S | Explicit author match only | 1 | 0 | 4 |

Assert **P, Q, R, S**, the four masks **1, 2, 5, 4**, and the first reason on every card. Verify the direction in both P’s and Q’s explanation. Compare fractional values with a numeric tolerance.

| Test owner | Cases and observable results |
|---|---|
| Rust recommendation crate | Mixed root tiers and equal-strength roots in opposite directions. A reciprocal single root sets mask 3 but gives zero overlap bonus. Two distinct eligible roots give +0.25 exactly once. Duplicate versions and repeated edges yield one card/base and one vote/base. A missing edge falls through to author or tier 0. Topic/category matches alone never set bit 4. |
| Rust learner and slot selection | Cold start gives 0.5 for every weight. A positive mask 5 splits into ½ reference and ½ author. A three-bit negative splits into thirds. Later trainable ratings replace earlier ratings for the same base. Test the 100th/101st base, the exact 180-day boundary, same-timestamp ordering and a zero-mask positive. Exercise both high-tier cap exhaustion and a reserved exploration slot with candidates only in a lower tier. Assert zero cap-eligible tier inversions at each selected prefix. |
| PostgreSQL graph and Library | Select an old tier-4 root ahead of more than 50 newer weak rows. Break a ten-root boundary tie by paper ID. Cover Reviewed/manual, Archived with/without consented positive, removed, vetoed, skipped generation, reciprocal edges, shared candidate, self-base in a pure fixture, wrong category and off-page reference. Assert bounds at 20 and 50. Include a neighbor supported by both a vetoed and a valid root. |
| PostgreSQL feedback and privacy | Exercise masks NULL/0/1–7, owned/unowned or expired item, ready vs actually served item, baseline policy with consent, client-forged fields, matching retries, conflicting reuse, dismissal and existing category affinity. A rating on an unsaved suggestion trains immediately. After saving and setting Reviewed, the retained positive qualifies it as tier 4. Record a rating, expire and delete only its batch, then prove the vote still counts with a null batch FK. |
| Transaction races and lifecycle | Pause feedback versus opt-out in both lock orders. Re-opt-in must yield no old votes or positive promotions. A retained negative still suppresses its root. Test Reset All versus feedback and account deletion. Prune evidence for multiple accounts, assert only affected fences advance, stale batches cannot replay and repeated cleanup has no additional effect. Change feedback between page selection and enqueue, between weight read and publication, and after ready but before serve. Each stale result is rejected. |
| API, worker and compatibility | Active and uncertain queue → zero suggestions. Queue-first with legacy active state, stale cursor, personalization off, public feed, Following, Explore, and minimal Recent retain existing contracts. Assert original summaries and exact continuation after reranking/underfill. Exercise job replay, policy flip during claim, zero features on legacy rows, explanation replay after graph changes, duplicate-code rejection and existing generated reason bounds. |
| Flutter controller and interactions | Exercise the four-to-three refill boundary, repeated triggers, distinct page batch IDs and both page-local positions. Pause a refill, then save/import, opt out, switch account or change revisions. Release the late response and assert no stale cards appear. Check policy-only drift on rollback restarts without appending. Decode both old and new-policy responses. Exercise feedback retry and ordinary save from page two. |

Extend the existing [offline fixture][offline], [PostgreSQL recommendation suite][pgtests], [reading-feed database tests][pgfeed], [profile tests][pgprofile], and [Flutter controller tests][mobiletests]. Keep old fixtures and run both policy versions. Use the production builder in the new ranking fixture so a standalone evaluator cannot silently diverge from worker behavior.

Run from `backend/` with the project toolchain. Set `TEST_DATABASE_URL` to a disposable PostgreSQL test database before invoking the integration suites. These suites can return successfully after skipping database coverage when it is missing.

```sh
cargo test -p recommendations -p reading_feed
cargo test -p db --test postgres_recommendations --test postgres_reading_feed --test postgres_research_profiles
cargo test -p pakperk-api
```

Run from `mobile/` with Flutter dependencies installed.

```sh
flutter test test/features/reading_feed_controller_test.dart test/core/reading_feed_policy_test.dart
flutter test test/features/recommendation_interaction_controller_test.dart test/core/recommendation_interaction_api_test.dart test/widgets/recommendation_explanation_sheet_test.dart
```

## 5. Evaluation, rollout and rollback

Evaluate three variants on **the same authorized pages** with the same observation time, profile controls, exclusions, caps, exploration slots and tie seed. Use the current `weighted_v1` path for the baseline. For the second variant, enable citation tiers and overlap with all three weights fixed at 0.5. For the third, enable the bounded learner. Keep the fixed-weight variant internal to evaluation.

Replay each account in time order. Construct the page, eligible roots, Library states, follows and weights as of the scoring instant. Apply that batch’s ratings only after scoring it. Deduplicate judgments by base. Use known judgments for nDCG, record the judgment coverage and keep unjudged cards distinguishable from explicit dislikes. The baseline’s historical feedback lacks consent/feature masks. Never reconstruct production votes from current graph edges or bulk-mark old feedback as consented. A weighted-policy card shown during shadow can record an opted-in zero on new feedback, but cannot earn directional votes from the shadow prediction. Use time-stamped fixtures with known evidence for a non-cold learned comparison, then evaluate real consented new-policy ratings as they accrue. [Existing evaluation harness][offline] · [Ranking metrics][eval]

| Measure | Definition for the comparison |
|---|---|
| Root-neighbor coverage | Eligible proven-empty For You pages with ≥1 authorized candidate connected to a selected eligible root, divided by all such pages. Measure before caps and keep sparse and no-root pages in the denominator. |
| Offline nDCG@10 | Evaluate each variant on the same held-out page judgments at cutoff 10. Report paired differences and number of evaluable pages. |
| Saves per proven-empty For You session | Count accepted, deduplicated Library saves attributable to served For You cards, divided by eligible sessions, including zero-save sessions. Keep one session across its continuation pages and document the session definition and attribution window used. |
| Dismissals per served card | Distinct accepted dismissals attributable to the cohort divided by served cards in that cohort. Exclude retries and shadow-only predictions. |
| Refill latency | Measure from the three-card trigger to an accepted continuation. Report p50/p95, sample size, and counts of stale, failed or canceled refills alongside successful latency. |

1. Deploy the additive migration and dual-version readers/writers before enabling new-policy production. Release with the baseline selected. Shadow the new scorer on the same eligible page while serving `weighted_v1`. Record aggregate coverage, timing and invariant counts. Shadow results do not mark items served, emit feedback, create votes or populate a reusable serving batch. This ranking shadow is independent of reading-feed enforcement’s existing `shadow/strict` switch.
2. Require **zero** suggestions over active/uncertain queues, **zero** out-of-page papers and **zero** tier inversions among cap-eligible candidates for the new scorer. Include the worked fixture, race tests and rollback rehearsal in the release evidence. Compare nDCG, saves, dismissals and latency against the baseline with sample sizes. The design sets no numeric quality-lift threshold. Report sparse neighbor coverage explicitly. A wider catalog query would require a separately designed snapshot and cursor change.
3. Enable `citation_online_v1` for a measured opted-in For You cohort. Treat an account consistently across its cursor walk. Roll back by selecting `weighted_v1` for new batches, superseding incompatible queued work and rejecting incompatible continuations. Preserve erasure, feedback retention, queue enforcement and decoding for already-created records. Verify the first eligible For You batch after rollback carries `weighted_v1` and a mobile client holding a citation-policy page restarts from fresh authority.

**Agent handoff.** Report the migrated schema and policy selector, tests actually run with PostgreSQL/Flutter, the P/Q/R/S result, replay and rollout measurements available, and any invariant failure. Distinguish fixture results from observed user outcomes.

[baseline]: https://github.com/ErrDivine/PakPerk/commit/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2
[feed]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/docs/reading-feed.md
[snapshot]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/reading_feed.rs
[service]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/reading_feed/src/service.rs
[source]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/apps/api/src/recommendation_source.rs
[jobs]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/recommendation_jobs.rs
[repo]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/recommendations.rs
[model]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/model.rs
[citation]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/candidates/citation.rs
[author]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/candidates/author.rs
[batch]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/batch.rs
[scoring]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/scoring.rs
[rerank]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/rerank.rs
[explain]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/explanations.rs
[feedback]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/apps/api/src/routes/recommendations.rs
[schema]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/migrations/0014_recommendation_foundation.sql
[profiles]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/research_profiles.rs
[maintenance]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/apps/api/src/maintenance.rs
[mobile]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/features/feed/reading_feed_controller.dart
[screen]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/features/feed/feed_screen.dart
[interactions]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/features/recommendations/recommendation_interaction_controller.dart
[features]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/features.rs
[graph]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/migrations/0001_initial.sql
[merge]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/candidates/mod.rs
[mobilemodel]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/core/reading_feed/reading_feed_models.dart
[interactionmodel]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/core/recommendations/recommendation_interaction_models.dart
[offline]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/tests/offline_fixture.rs
[pgtests]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/tests/postgres_recommendations.rs
[pgfeed]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/tests/postgres_reading_feed.rs
[pgprofile]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/tests/postgres_research_profiles.rs
[mobiletests]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/test/features/reading_feed_controller_test.dart
[eval]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/evaluation.rs
