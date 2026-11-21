# PakPerk recommendation design

**The reader’s chosen papers come first.** When To Read empties, For You should favor papers one citation away from work the reader reviewed and rated relevant. Within that group, learn whether the reader prefers a root paper’s references, papers that cite it, or work by followed authors.

## 1. Give the reader’s papers priority

`GET /v1/me/reading-feed` owns the decision. In the enforced signed-in feed, serve active Inbox, Read next, and Reading items in `saved_at ASC, paper_id ASC` order. Only a current `queue_first_v1` decision with a proven count of zero permits discovery. Apply the new ranking only to opted-in For You. With personalization off, a For You request resolves to Recent after the same queue check. [Reading-feed contract][feed]

The reader’s forest is a view of the shared citation graph. Its roots are chosen papers still in their inactive Library, and a neighbor shared by two roots gets one card. **Reviewed** supplies explicit reading evidence. **Relevant** comes from existing recommendation feedback. A reader can rate a suggestion, save it, then mark it Reviewed. A manually imported paper qualifies on Reviewed alone.

| Priority | Evidence for a candidate on the current page |
|---|---|
| 4 | A direct citation connects it to a **Reviewed** paper with retained, opted-in `relevant` feedback. |
| 3 | A direct citation connects it to another eligible **Reviewed** paper. |
| 2 | A direct citation connects it to an **Archived** paper with retained, opted-in `relevant` feedback. Archiving alone makes no claim about reading. |
| 1 | The existing author generator matches an explicit author follow, with no qualifying citation. |
| 0 | Other eligible For You candidates, including the existing Recent fallback. |

Take the **highest** applicable tier. A retained `not_relevant` or `dismissed` on a root’s base arXiv identity disqualifies that root. Other paths to its neighbors remain eligible. Positive feedback on an unsaved suggestion can teach the learner immediately. It becomes a root once it meets the Library criteria above. Keep note text private. A later opt-in “Use this paper for recommendations” switch could admit an otherwise unqualified Archived paper at tier 2. Removing the switch would remove that evidence.

## 2. Collect one-hop neighbors for the buffer

1. **Start with the authorized page.** PakPerk selects a chronological page of metadata-ready papers, applies the category filter and excludes existing Library rows, retained removals and feedback by exact or base identity. The service verifies every returned paper and its continuation against that page. An older reference outside the page can surface only when a later page contains it. [Snapshot query][snapshot] · [Service validation][validation]
2. **Use the local citation graph.** `paper_connections` stores citing → cited IDs. The repository reads both directions at the citing paper’s current processing generation. Today the generator stops at the first matching root. Select the ten strongest distinct roots by tier, latest Library update, then paper ID. Join those roots to the authorized page and return each matching root ID and edge direction. At mobile’s 20-paper page size there are at most 200 distinct candidate–root pairs. [Citation lookup and historical seeds][storage] · [Citation generator][generator]
3. **Keep shared evidence.** Count each distinct base-ID pair once for overlap, discard self-matches, and retain both directions if both exist. Give each candidate three yes/no features. **Reference** means one of its strongest roots cites it. **Citing paper** means it cites one of its strongest roots. **Followed author** comes from the existing author generator. It matches normalized display names, so a match establishes name agreement only. Existing For You generators supply the rest of the page when links are sparse. [Author matcher][author] · [Batch construction][batch]

## 3. Learn three weights per reader

On a served For You card, `relevant` gives one positive vote and `not_relevant` gives one negative vote. Divide it equally among active features. A reference by a followed author gives each half a vote. A card with no active features supplies none. Dismissals suppress the paper, saves change the queue, and qualified impressions keep their capped repeat penalty. Only the two explicit ratings train the weights.

Each feature starts at **0.5** and updates from this reader’s vote totals.

```text
weight = (2 + positive_votes) / (4 + positive_votes + negative_votes)
```

Two prior votes on each side keep one judgment from dominating. A new rating takes effect in the next eligible batch.

**Rank each slot** by first choosing the highest tier with a candidate that passes the existing exclusions and author, topic and category caps. Within that tier use the following score, with the existing diversity adjustment and seeded tie-break. Honor an exploration slot within the selected tier when it has an eligible exploration candidate. Carry cap counts across the whole page. [Current scoring policy][scoring] · [Diversity and slot selection][rerank]

```text
overlap = 1 if at least two distinct eligible roots connect, else 0
within_tier = weighted_v1(candidate) + 0.25 × overlap
            + sum(weight[feature] - 0.5 for each active feature)
```

The centered weights add zero at cold start. Recency, novelty, repeat exposure and the reader’s existing controls still affect close choices.

**Example.** A was reviewed and rated relevant. B was reviewed without a rating. On earlier recommendations, the reader liked two references and marked one citing paper not relevant. Each had just that feature. Assume P and Q otherwise score equally, with no cap or exploration slot in play.

| Candidate | Tier | Learned adjustment |
|---|---:|---:|
| P, referenced by A | 4 | `4/6 − 0.5 = +0.167` |
| Q, which cites A | 4 | `2/5 − 0.5 = −0.100` |
| R, referenced by B and written by the followed author | 3 | `+0.167 + 0 = +0.167` |
| S, by the followed author, with no root edge | 1 | `0` |

The buffer shows **P, Q, R, S**. Learning breaks the P/Q tie. R’s author match cannot overcome its weaker root. P’s explanation can say “Your reviewed paper A references this paper.” Q’s can say “This paper cites your reviewed paper A.”

## 4. Fit the learner into PakPerk

- **Store the evidence that earned the rank.** Add a For You policy version, `citation_online_v1`, to the validator, job and batch paths. Store tier, feature bits, learned adjustment and up to two supporting roots with direction on each candidate. Decode older batches with defaults. Lead the explanation with the winning evidence. Reuse `reviewed_paper_citation`, `archived_paper_citation` and `followed_author`, and mark `behavior_used` when learned feedback affected the rank. [Worker and policy wiring][worker] · [Explanation templates][explanations]
- **Update on accepted feedback.** Use the existing idempotent `POST /v1/discovery/batches/{batch_id}/feedback` transaction. Record a nullable three-bit feature mask on the feedback row from the server’s stored evidence for the owned, unexpired item. Null means consent at rating time was absent or unknown, including legacy rows. Zero marks opted-in feedback without feature votes. A nonzero mask requires a served card from the new policy. The votes survive the 24-hour batch expiry. [Feedback route][feedback] · [Feedback storage][schema]
- **Keep learning bounded and reversible.** Within the 180-day feedback window, take the latest trainable rating per base paper, then the 100 most recently rated distinct papers. Sum their votes at batch build. A retry adds zero votes. Read weights and feedback revision from the same snapshot. Recheck Library, profile and feedback revisions at publication and serve. Advance the feedback revision when retention removes contributing evidence. Serialize feedback writes with the profile opt-out that clears the masks to null. Reset All and account deletion remove the underlying feedback. [Feedback transaction and retention][storage] · [Profile controls][profile]
- **Use the existing mobile buffer.** Request 20 items and call the existing single-flight `loadMore()` at three or fewer remaining. Each continuation re-proves emptiness and retains each item’s batch ID and page-local position. Append only compatible pages. A pending save/import, stale revision or account switch suppresses recommendations until fresh authority arrives. A suggestion enters To Read through the normal save action. [Mobile reading-feed controller][mobile]

## 5. Verify before rollout

Compare current `weighted_v1`, citation tiers with fixed weights, and citation tiers with learned weights on identical authorized pages. Replay each account’s ratings in time order and score each batch using only earlier feedback. Track the share of eligible pages with any root neighbor, nDCG@10 offline, and saves per proven-empty For You session online. Also check dismissals per served card and refill latency. If few pages contain neighbors, widening retrieval requires a separate change to the server’s snapshot query and cursor contract. [Existing evaluation fixtures][evaluation]

Require zero suggestions over an active or uncertain queue, zero out-of-page papers and zero tier inversions among cap-eligible candidates. Test the worked example, duplicate versions, overlapping roots, a missing edge, a feedback retry, opt-out/reset and a save during refill. Shadow the new scorer first. Roll back by selecting `weighted_v1` for new batches and rejecting incompatible continuations.

**Implementation baseline** · [ErrDivine/PakPerk at `04059c5`][baseline]

[feed]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/docs/reading-feed.md
[snapshot]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/reading_feed.rs#L255-L365
[validation]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/reading_feed/src/service.rs#L198-L297
[storage]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/recommendations.rs
[generator]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/candidates/citation.rs
[author]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/candidates/author.rs
[batch]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/batch.rs#L393-L435
[scoring]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/scoring.rs
[rerank]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/rerank.rs
[worker]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/apps/api/src/recommendation_source.rs
[explanations]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/src/explanations.rs
[feedback]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/apps/api/src/routes/recommendations.rs#L78-L195
[schema]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/migrations/0014_recommendation_foundation.sql#L104-L204
[profile]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/db/src/repository/research_profiles.rs
[mobile]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/mobile/lib/features/feed/reading_feed_controller.dart
[evaluation]: https://github.com/ErrDivine/PakPerk/blob/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2/backend/crates/recommendations/tests/offline_fixture.rs
[baseline]: https://github.com/ErrDivine/PakPerk/commit/04059c5e27b6b4bf5ac928bdacd08b60f47abeb2
