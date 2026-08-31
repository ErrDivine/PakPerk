# Pakperk Plan 02: v0.1 Queue-First Discovery and Library

**Document status:** Standalone implementation specification for a vibe-coding agent; aligned revision  
**Milestone:** v0.1 Discovery and Library  
**Depends on:** Production v0.0 completed according to Plan 01; this document incorporates the To-Read-First Feed and Manual Paper Import foundation  
**Handoff to:** Plan 03, Deep Reader and Memory  
**Primary objective:** Make the account-owned To-Read set the authoritative signed-in reading feed, support serious manual paper intake, and activate transparent discovery only after that active set is authoritatively empty.

> Pakperk must honor work the user has already chosen before offering more work. Discovery remains important, but it is a fallback after the active To-Read queue is empty—not a parallel stream competing for attention.

### Alignment authority

The following invariant governs every conflicting sentence elsewhere in this plan:

```text
signed-in active To-Read count > 0
    => Read feed mode = to_read
    => every automatically fed paper is an active item in that user's To-Read set

signed-in active To-Read count = 0, proven by the server
    => Read feed mode = recommendations
    => Recent, Following, For You, or Explore may supply papers

pending manual add, stale synchronization, unknown account scope, or unknown queue state
    => recommendations are forbidden
```

For v0.1, the **active To-Read set** is every nondeleted library row in `Inbox`, `Read next`, or `Reading`. `Reviewed` and `Archived` remain in the library but do not block discovery. A paper intentionally saved from any source—including a recommendation—is manual queue intent and immediately becomes active.

Automatic feed behavior is distinct from explicit navigation. A user may search for a known paper, open an original source, or follow a connection at any time, but those actions must not inject unqueued papers into the vertical Read feed.

---

## 0. Coding-agent execution contract

1. Preserve every cross-plan invariant from the master roadmap.
2. Treat the account-owned active To-Read set as the sole authority for the signed-in Read feed.
3. Compute queue-versus-recommendation mode on the server from one committed database snapshot; do not split the count and page query across unrelated reads.
4. On mobile, treat unknown queue state as nonempty for recommendation purposes. Pending saves, stale revisions, sync resets, authentication transitions, and offline launches suppress recommendations.
5. Preserve the public `GET /v1/feed` contract for guests, bundled/cache fallback, and recommendation sourcing. Do not convert it into an account-private endpoint.
6. Use `GET /v1/me/reading-feed` as the canonical signed-in feed. A signed-in production client must not bypass it by rendering the public discovery feed as its primary Read stream.
7. Manual addition must be reachable at any time by recognized arXiv URL/identifier or title search. Ambiguous title results require explicit user selection.
8. Never fetch an arbitrary user-supplied URL. Parse allowlisted arXiv forms, resolve through the server, and store only canonical paper identity and metadata.
9. Saving, importing, searching, listing, recommendation generation, vertical prefetch, and queue pagination may prepare metadata only. They must never acquire a PDF or enqueue PDF-derived processing.
10. A local pending save immediately suppresses visible recommendation cards, even before the server acknowledges the mutation.
11. Removing or completing the last active item does not unlock recommendations until the write is acknowledged and the server confirms an empty active set at a new library revision.
12. Anonymous users continue to receive deterministic Recent and Explore feeds because they have no account-owned queue.
13. Do not train or deploy an opaque ranking model in the first phase.
14. Build candidate generation, scoring, explanation, and reranking as inspectable modules with offline fixtures.
15. A recommendation explanation must correspond to features actually used and may appear only in recommendation mode.
16. Behavioral personalization is opt-in or clearly disclosed according to applicable policy, and it can be disabled without losing Search, Library, or queue reading.
17. Do not use comment sentiment, public profile popularity, private note bodies, or exact dwell time as primary recommendation signals.
18. Do not treat a save as proof that a paper was read, endorsed, or understood.
19. Do not add a separate recommendation or library service. Implement inside the Rust modular monolith and existing worker until measured scaling evidence justifies separation.
20. Store only content-free interaction events needed for product behavior and evaluation. Critical queue/library state is never reconstructed from telemetry.
21. Discovery alerts about new papers are queue-aware: defer them while the active set is nonempty. User-requested reminders and version updates for active papers may still surface.
22. Every schema change must be backward compatible with the v0.0 mobile release during rollout.
23. Every phase must include queue-policy fixtures and evaluation fixtures, not merely implementation tests.

---

## 1. Product mission

A signed-in user should be able to answer, in this order:

- What have I already chosen to read?
- Which queued paper is next, and why is it still active?
- How do I add a paper by URL or title without waiting for it to appear in Pakperk?
- When my queue is empty, what should I look at today?
- Why is a recommended paper in front of me?
- Is it new, central, adjacent, or exploratory?
- Can I preserve why I saved it and find it again?
- Can I control how adventurous or narrow future discovery is?

### 1.1 Product promise

Pakperk v0.1 provides:

- a production-grade, account-scoped queue-first Read feed;
- manual paper intake by recognized arXiv URL/identifier or title search;
- immediate local suppression of recommendations after save intent;
- an explicit `checking / to_read / recommendations / unavailable` feed state model;
- a durable research inbox with explicit states, lists, tags, and private save notes;
- a bounded reading brief drawn from the active queue while it is nonempty;
- deterministic Recent and Following discovery after the queue is empty;
- a transparent For You fallback after the queue is empty;
- a deliberate Explore fallback after the queue is empty;
- lookup and user-initiated exploratory search at any time;
- topic, author, and query subscriptions whose paper-discovery delivery respects queue state;
- understandable recommendation reasons and direct negative feedback;
- cold-start behavior that works before collaborative data exists;
- cross-device revision fencing so a stale device cannot leak recommendations over a newly added paper.

### 1.2 Non-goals

Do not implement in v0.1:

- a parallel recommendation stream visible while active To-Read items exist;
- automatic recommendations during unknown, stale, offline, or account-transition queue state;
- arbitrary URL crawling or mobile-to-arXiv requests;
- automatic completion merely because a paper was opened, scrolled, or viewed to the end;
- cross-paper annotation or evidence extraction;
- project workspaces;
- full systematic review search;
- autonomous research agents;
- public follower graphs;
- trending-by-engagement leaderboards;
- personalized push notifications based on inferred urgency;
- a general-purpose academic search engine;
- paid ranking or sponsored papers;
- recommendations generated from private note bodies;
- implicit personalization from exact scroll duration.

---

## 2. User experience model

### 2.1 Application shell

Evolve to:

```text
Read | Library | You
```

- **Read:** the queue-first vertical reader, manual add/search entry, and—only after authoritative emptiness—discovery modes and a discovery brief.
- **Library:** Inbox, Read next, Reading, Reviewed, Archived, lists, tags, history, and manual paper intake.
- **You:** account, research profile, future-discovery controls, notification/privacy settings, and queue diagnostics where appropriate.

Keep independent route stacks for all three destinations.

### 2.2 Signed-in Read state model

The Read destination is not permanently a recommendation selector. It has four account-scoped states:

```text
Checking queue | To Read | Recommendations | Unavailable
```

#### Checking queue

Use when local/server authority is incomplete—for example startup, account switch, token refresh, sync reset, or final-item removal awaiting confirmation.

- show cached active queue items when safely account-scoped;
- otherwise show an explicit verification state;
- retain the add-paper action;
- never show a recommendation card, discovery brief, or recommendation-mode prefetch.

#### To Read

Use whenever any active item exists locally, is pending creation, or is confirmed by the server.

- every automatically fed paper must be an active account library item;
- recommendation tabs are hidden or disabled with clear copy such as `Discovery resumes when To Read is empty`;
- queue metadata—not recommendation reasons—explains why the item is present;
- manual add remains available;
- reaching the end of loaded queue pages is not permission to recommend.

#### Recommendations

Use only when the server response says `queue_proven_empty=true`, the bound library revision still matches, no local pending save exists, and account/auth epochs still match.

Top-level controls then become:

```text
Recent | Following | For You | Explore
```

Changing the preferred discovery mode changes only the fallback source. It never overrides a nonempty or unknown queue.

#### Unavailable

Use when account, database, or sync authority cannot be established and no safe cached queue representation exists.

- explain that Pakperk cannot verify the To-Read list;
- allow retry, account repair, and local draft management;
- fail closed rather than substituting public recommendations.

### 2.3 Active To-Read queue behavior

The active set is:

```text
state IN (inbox, read_next, reading)
AND deleted_at/removed_at IS NULL
```

State meanings:

- **Inbox:** intentionally saved and awaiting triage.
- **Read next:** explicitly marked as near-term work.
- **Reading:** explicitly started or marked; never inferred solely from an accidental open.
- **Reviewed:** retained history; excluded from the active feed.
- **Archived:** retained but inactive; excluded from the active feed.

Initial production ordering remains deterministic and cursor-safe. Use the queue-order policy already established by the To-Read-First foundation. Do not add silent behavioral reranking. If manual ranking is introduced later, it requires a versioned rank/sync protocol and must still return only active queue items.

Queue actions:

- open abstract;
- commit to Introduction/deeper preparation;
- edit state, note, lists, or tags;
- mark Reviewed;
- Archive/remove;
- add another paper;
- open original source.

Opening, scrolling, viewing the final section, or exhausting the current page never removes an item automatically.

When the last active item is marked Reviewed, Archived, or removed:

1. update local state optimistically;
2. enter a `finishing/checking queue` state;
3. keep recommendation content hidden;
4. synchronize the mutation;
5. refresh `GET /v1/me/reading-feed`;
6. enter Recommendations only after server-confirmed emptiness.

### 2.4 Discovery fallback modes

These modes are available to guests and to signed-in users only after queue emptiness is proven.

#### Recent

- papers from selected arXiv categories;
- deterministic recency order;
- optional category chips;
- no behavioral ranking;
- available to guests.

#### Following

- topics;
- authors;
- saved searches;
- later, venues/labs when source metadata is reliable;
- chronological with light relevance grouping, not opaque personalization.

#### For You

- candidate mix based on explicit and consented signals;
- each card has a `Why this?` action;
- adjustable `Focused <-> Balanced <-> Exploratory` preference;
- hide/reset personalization controls;
- signed-in only, with a clear guest explanation;
- unavailable while any active or unresolved queue intent exists.

#### Explore

- intentionally broad and diverse;
- adjacent fields, methods, datasets, or concepts;
- reason labels such as `Adjacent method` or `Outside your usual topics`;
- available to guests using selected categories;
- never described as personalized unless it is.

### 2.5 Reading brief

The default signed-in Read landing may be bounded, but its source is conditional:

- **Queue nonempty:** the brief contains only active To-Read items. It is a bounded view over the queue, not a recommendation batch.
- **Queue empty and proven:** the brief may contain 15–25 discovery papers from the selected fallback mode.
- **Queue unknown:** no brief is generated or restored unless it is a safely account-scoped queue brief.

Common behavior:

- generated once per local day or on explicit refresh;
- progress indicator;
- natural stopping state;
- no streak or guilt language;
- stable item identity and reasons within a discovery batch.

Critical distinction: finishing or swiping through a queue brief does not make the underlying active queue empty. Recommendations remain blocked until every active item is explicitly transitioned out of the active states.

### 2.6 Search and manual intake

Search must distinguish intent.

#### Add by URL or title

Always reachable from Read and Library.

- field label: `Paste an arXiv link or search by paper title`;
- recognized arXiv URL/identifier is normalized locally, then resolved server-side;
- other text invokes bounded title search against arXiv through the server;
- ambiguous matches show candidate cards and require a user selection;
- selecting a candidate or confirming an exact identifier calls the idempotent import route;
- local pending intent immediately switches/sustains To Read mode;
- no PDF preparation occurs.

#### Lookup

For a known paper, author, identifier, or exact phrase.

- exact ID/title/author matches first;
- minimal filters;
- fast and deterministic;
- opening a result is explicit navigation, not feed insertion;
- saving the result adds it to Inbox and immediately suppresses discovery.

#### Explore search

For user-initiated learning about a topic or related work.

- query plus topic/category/date/source filters;
- related topic suggestions;
- sort by relevance/recency;
- `map from this paper` entry to Connections;
- save query as alert;
- private query history by default.

Explore search may be used while the queue is nonempty because it is an explicit user action, but its results must not be auto-inserted into the vertical feed. Saving any result adds it to the active queue.

Do not claim systematic completeness. A later project mode handles transparent, reproducible searches.

### 2.7 Reason and provenance UI

In **To Read** mode, show queue provenance such as:

- `Added by title search`;
- `Added from arXiv link`;
- `Saved from Explore`;
- `Saved on August 19`;
- the user's private `Why save this?` note.

Do not label these as recommendation explanations.

In **Recommendations** mode, card-level reasons may include:

- `Because you reviewed “Attention Is All You Need”`;
- `Matches followed topic: parameter-efficient fine-tuning`;
- `Connected to 2 papers in your Reviewed library`;
- `New paper from an author you follow`;
- `Exploration: uses a method adjacent to retrieval`;
- `Popular in cs.CL this week` only when popularity is genuinely used and defined.

The `Why this?` sheet shows:

- candidate source;
- top matching explicit interests;
- exact historical seed paper where applicable;
- whether behavior was used;
- novelty/diversity role;
- controls to mute or adjust;
- a link to personalization privacy settings.

### 2.8 Library model

Replace flat To Read with explicit states:

```text
Inbox
Read next
Reading
Reviewed
Archived
```

Definitions are authoritative for feed gating:

- **Inbox, Read next, Reading:** active To-Read states that block recommendations.
- **Reviewed, Archived:** inactive library states that do not block recommendations.

Provide a separate History view based on explicit paper opens if the user enables history. History is not a library state and must not affect queue emptiness.

### 2.9 Save and import action

On save, offer a lightweight optional sheet:

- state, default Inbox;
- `Why save this?` one-line private note;
- add to list;
- add tags;
- remind later, optional;
- save silently when the user uses quick-save.

A quick-save is still authoritative queue intent. It must:

1. create a local pending mutation;
2. suppress recommendation cards immediately;
3. cancel in-flight recommendation prefetch;
4. synchronize idempotently;
5. reconcile to the canonical paper/library row.

Do not force organization at the moment of discovery.

### 2.10 Lists and tags

- Lists are ordered named collections.
- Tags are reusable labels.
- A paper may belong to many lists and tags.
- Lists are private in v0.1.
- Smart lists are limited to deterministic filters such as state, category, unread, no note, or recently updated.
- Lists/tags never independently determine whether the main feed can recommend; active library state does.
- Public/shared collections wait until Plan 05.

### 2.11 Resurfacing

Useful, non-addictive prompts include:

- `Saved 14 days ago and not opened.`
- `A new version is available.`
- `This active paper is connected to something you just saved.`
- `You marked this Read next.`

Queue-owned reminders and active-paper version updates may surface while the queue is nonempty. Discovery prompts for new unrelated papers are deferred until the queue is empty. Every resurfacing rule is visible and dismissible; the app must not manufacture urgency.

---

## 3. Research profile and onboarding

### 3.1 Progressive onboarding

Do not require a long profile form before queue reading. Use three stages:

1. Guest category selection at first launch, skippable.
2. Signed-in queue setup: explain manual add by URL/title and migrate/render existing To Read before asking for discovery preferences.
3. Discovery profile setup after the active queue is empty, or earlier only when the user explicitly opens future-discovery settings.
4. Ongoing preference refinement through explicit feedback received in recommendation mode.

Profile configuration may occur while the queue is nonempty, but it must not unlock or render recommendations.

### 3.2 Explicit profile fields

- research topics as normalized entities and user-entered labels;
- arXiv categories;
- authors to follow;
- experience/reading preference optional, used only for explanation depth later;
- preferred discovery fallback: Recent, Following, For You, or Explore;
- discovery mode preference: focused/balanced/exploratory;
- desired discovery-brief size;
- recency preference;
- notification and quiet-hours settings;
- personalization enabled/disabled.

Do not collect institution, career stage, or demographic fields unless there is a clear user benefit and privacy justification.

### 3.3 Topic representation

Store:

- canonical topic ID where resolved;
- display label;
- source vocabulary;
- user-entered alias;
- positive/negative strength;
- explicit versus inferred source;
- created/updated timestamps.

Never silently convert an inferred topic into an explicit follow.

### 3.4 Profile transparency

The You destination provides:

- followed topics/authors;
- inferred interests separately labeled;
- recent feedback affecting recommendations;
- selected fallback mode for when To Read becomes empty;
- reset/delete recommendation profile;
- export profile;
- personalization toggle;
- explanation of retained event windows;
- a clear statement that these settings do not bypass the active queue.

---

## 4. Data model

Use a new migration, for example:

```text
backend/migrations/0004_discovery_library.sql
```

Exact sequence must follow repository state and any already-landed To-Read-First migration. Do not reuse a migration number from this document blindly.

The existing account library and per-user library revision remain the sole queue authority. Do not create a second queue-state table or infer emptiness from `paper_interactions`. At query time:

```text
active_to_read = state IN ('inbox', 'read_next', 'reading')
                 AND removed_at/deleted_at IS NULL
```

The first-page feed decision, active count, library revision, and selected page must come from one database snapshot.

### 4.1 `research_profiles`

```text
user_id                 uuid primary key references users(id)
personalization_enabled boolean not null default true
discovery_mode          text not null default 'balanced'
brief_size              integer not null default 20
recency_weight          real not null default 0.5
novelty_weight          real not null default 0.3
diversity_weight        real not null default 0.3
profile_revision        bigint not null
created_at              timestamptz not null
updated_at              timestamptz not null
```

Constraints:

- modes are enumerated;
- weights are bounded;
- revision increments transactionally.

### 4.2 `profile_categories`

```text
user_id
category
weight
source: explicit | feedback | inferred
created_at
updated_at
primary key(user_id, category, source)
```

### 4.3 `topics`

```text
id                      uuid primary key
canonical_key           text unique
label                   text
normalized_label        text
source                   text
metadata                 jsonb
created_at
updated_at
```

### 4.4 `profile_topics`

```text
user_id
topic_id
polarity: positive | negative
strength
source: explicit | feedback | inferred
explanation_source_id null
created_at
updated_at
primary key(user_id, topic_id, source)
```

### 4.5 `profile_authors`

Initially use normalized arXiv author labels with caution; later migrate to source identities.

```text
user_id
author_key
display_name
source
created_at
updated_at
primary key(user_id, author_key)
```

### 4.6 Extend `user_paper_library`

Extend the existing canonical account library through expand-and-contract:

```text
state                   inbox | read_next | reading | reviewed | archived
private_note            text null
reviewed_at             timestamptz null
archived_at             timestamptz null
save_source_kind        discovery | lookup | title_search | arxiv_url | arxiv_id | connection | other, optional
```

Retain and reuse the existing fields/patterns for:

- `(user_id, paper_id)` identity;
- `saved_at`/timestamps;
- active/removal tombstones;
- per-user monotonic library revision;
- last operation/idempotency identity;
- change-feed synchronization.

Feed semantics:

- `Inbox`, `Read next`, and `Reading` are active and block recommendations.
- `Reviewed` and `Archived` are inactive and do not block recommendations.
- v0.0 To Read rows migrate to `Inbox` without losing timestamps or revision history.
- opening a paper does not change state automatically.

Do not add a second active flag. Do not drop the v0.0 state column until all supported clients understand the new model. Any compatibility projection must map old `to_read` to the active set.

Do not add queue ranking merely because lists are ordered. The initial signed-in feed uses the established deterministic queue order. A later manual-order feature requires an explicit ADR, cursor update, revision semantics, and conflict tests.

### 4.7 `library_lists`

```text
id
user_id
name
normalized_name
description null
sort_order
revision
deleted_at null
created_at
updated_at
unique active normalized name per user
```

### 4.8 `library_list_items`

```text
list_id
paper_id
position_rank
note null
revision
deleted_at null
created_at
updated_at
primary key(list_id, paper_id)
```

### 4.9 `library_tags`

```text
id
user_id
name
normalized_name
revision
deleted_at
created_at
updated_at
unique active normalized name per user
```

### 4.10 `library_item_tags`

```text
user_id
paper_id
tag_id
revision
deleted_at
created_at
updated_at
primary key(user_id, paper_id, tag_id)
```

### 4.11 `paper_interactions`

Purpose: consented, content-free events used for product state, deduplication, and recommendation evaluation.

```text
id                      uuid or uuidv7
user_id                 uuid null
anonymous_session_id    uuid null
installation_id_hash    text null
event_type              text
paper_id                 uuid
feed_mode                text null
batch_id                 uuid null
position                 integer null
reason_codes             text[]
metadata                 jsonb bounded
occurred_at              timestamptz
received_at              timestamptz
expires_at               timestamptz
```

Event types:

- `impression_qualified`;
- `abstract_opened`;
- `introduction_committed`;
- `connections_opened`;
- `saved`;
- `unsaved`;
- `marked_relevant`;
- `marked_not_relevant`;
- `dismissed`;
- `opened_original`;
- `opened_connection`;
- `library_state_changed`.

A qualified impression requires a stable, documented threshold such as card visibility and app foreground, not raw scroll time optimization.

### 4.12 `recommendation_batches`

```text
id
user_id null
anonymous_session_id null
mode
query_key
profile_revision null
library_revision null
queue_proven_empty boolean null
algorithm_version
policy_version
seed
created_at
expires_at
status: building | ready | served | superseded | blocked_by_queue | expired | failed
metadata jsonb bounded
```

For an authenticated user, a batch may be marked `ready` or served only when its recorded queue decision was empty at the bound library revision. A later library mutation supersedes every unserved account batch from an older revision. Generic public candidate caches are not user batches and may continue to refresh independently.

### 4.13 `recommendation_candidates`

```text
batch_id
paper_id
candidate_sources text[]
raw_features jsonb
base_score real
reranked_position integer
reason_codes text[]
served_at null
primary key(batch_id, paper_id)
```

Retention of raw features must be bounded and content-safe. Prefer explicit numeric/symbolic features over storing full text.

### 4.14 `recommendation_feedback`

```text
id
user_id
paper_id
batch_id null
feedback_type
reason null
idempotency_key
created_at
unique(user_id, idempotency_key)
```

### 4.15 `subscriptions`

```text
id
user_id
kind: topic | category | author | saved_query
key
label
query_definition jsonb null
frequency: immediate | daily | weekly | off
last_evaluated_at
revision
deleted_at
created_at
updated_at
```

### 4.16 `notifications`

```text
id
user_id
type
entity_type
entity_id
payload jsonb bounded
batch_key null
created_at
read_at null
dismissed_at null
expires_at null
```

### 4.17 `notification_preferences`

- per type frequency;
- quiet hours and timezone;
- push/email/in-app channels;
- global pause;
- revision.

---

## 5. API contract

All authenticated writes use bearer auth and idempotency where retryable. Account-private feed responses use `Cache-Control: private, no-store` and `Vary: Authorization`.

### 5.1 Profile

```text
GET    /v1/discovery/profile
PUT    /v1/discovery/profile
GET    /v1/discovery/profile/interests
PUT    /v1/discovery/profile/topics/{topic_id}
DELETE /v1/discovery/profile/topics/{topic_id}
PUT    /v1/discovery/profile/authors/{author_key}
DELETE /v1/discovery/profile/authors/{author_key}
POST   /v1/discovery/profile/reset
```

These routes configure only the future recommendation fallback. They never change active queue state.

### 5.2 Public discovery and canonical signed-in feed

Preserve the existing public feed:

```text
GET /v1/feed?category=&cursor=&limit=
```

Use it for:

- signed-out Recent/Explore;
- bundled/cache fallback for guests;
- a source adapter inside recommendation infrastructure;
- backward compatibility.

Do not attach account-specific queue decisions to its publicly cacheable representation.

Canonical signed-in route:

```text
GET /v1/me/reading-feed?recommendation_mode=recent|following|for_you|explore&cursor=&limit=&brief_id=
```

The requested `recommendation_mode` is only a preference used after the queue is proven empty. The server—not the query parameter—selects `to_read` versus `recommendations`.

Required response shape:

```json
{
  "mode": "to_read",
  "decision": {
    "library_revision": 128,
    "active_to_read_count": 4,
    "queue_proven_empty": false,
    "policy_version": "queue_first_v1"
  },
  "items": [
    {
      "paper": { "...": "existing PaperSummary" },
      "source": "to_read",
      "queue": {
        "state": "inbox",
        "saved_at": "2026-08-19T12:00:00Z",
        "revision": 126,
        "save_source_kind": "title_search"
      },
      "recommendation": null
    }
  ],
  "next_cursor": "<opaque-or-null>",
  "brief": null,
  "server_time": "..."
}
```

Recommendation mode:

```json
{
  "mode": "recommendations",
  "decision": {
    "library_revision": 129,
    "active_to_read_count": 0,
    "queue_proven_empty": true,
    "policy_version": "queue_first_v1"
  },
  "batch_id": "...",
  "items": [
    {
      "paper": { "...": "existing PaperSummary" },
      "source": "for_you_v1",
      "queue": null,
      "recommendation": {
        "mode": "for_you",
        "reason_codes": ["reviewed_paper_similarity", "diversity_slot"],
        "reason_label": "Related to a paper you reviewed",
        "explanation_available": true
      }
    }
  ],
  "next_cursor": "<opaque-or-null>",
  "brief": {
    "id": "...",
    "position": 5,
    "total": 20,
    "complete": false
  },
  "server_time": "..."
}
```

Consistency requirements:

- first-page decision and page selection use one snapshot;
- cursor binds user, mode, library revision, order coordinates, query, expiry, and cursor-key epoch;
- a library revision mismatch returns `409 READING_FEED_CURSOR_STALE`;
- a recommender never decides whether it is allowed to run;
- active queue mode never calls user-specific recommendation generation;
- recommendation pages exclude retained tombstones and unavailable papers.

### 5.3 Reading briefs and recommendation feedback

```text
POST /v1/me/reading-briefs
GET  /v1/me/reading-briefs/current
POST /v1/discovery/batches/{batch_id}/feedback
GET  /v1/discovery/batches/{batch_id}/papers/{paper_id}/explanation
```

Brief creation uses the same queue gate as `/v1/me/reading-feed`:

- nonempty active set -> queue brief only, with no recommendation batch;
- proven empty -> discovery brief may be created;
- unknown/stale -> fail closed.

Feedback/explanation routes accept only server-created batch/item pairs. Queue items do not carry recommendation feedback controls.

### 5.4 Manual title search and exact import

Canonical authenticated intake routes:

```text
POST /v1/me/paper-searches
POST /v1/me/library/imports
```

Title-search request:

```json
{
  "query": "attention is all you need",
  "limit": 10
}
```

Requirements:

- search through the server's arXiv adapter and shared rate gate/cache;
- bounded normalized query and result count;
- return title, authors, dates, categories, abstract snippet where allowed, and canonical arXiv ID;
- never auto-select an ambiguous result;
- do not persist or log raw search text outside approved short-lived operational handling.

Import request:

```json
{
  "input": "https://arxiv.org/abs/1706.03762",
  "input_kind": "arxiv_url",
  "target_state": "inbox",
  "operation_id": "<uuidv7>"
}
```

Accepted input kinds:

- recognized `arxiv.org/abs/...` URL;
- recognized `arxiv.org/pdf/...` URL;
- bare modern or legacy arXiv identifier;
- canonical arXiv identifier selected from title-search results.

The server parses the allowlisted form, resolves/upserts canonical metadata, and idempotently creates or restores the library row. It does not fetch an arbitrary submitted URL and does not enqueue PDF preparation.

### 5.5 General search

```text
GET  /v1/search/lookup?q=&cursor=&limit=
POST /v1/search/explore
GET  /v1/search/suggestions?q=
POST /v1/search/saved
```

Explore response returns source coverage and an explicit disclaimer that this is not a systematic search. Opening search results is explicit navigation. Saving uses `/v1/me/library/imports` when only external identity is known, or the idempotent library write when a canonical internal `paper_id` already exists.

### 5.6 Library

```text
GET    /v1/library/items?state=&list_id=&tag_id=&cursor=
PUT    /v1/library/papers/{paper_id}
PATCH  /v1/library/papers/{paper_id}
DELETE /v1/library/papers/{paper_id}

GET    /v1/library/lists
POST   /v1/library/lists
PATCH  /v1/library/lists/{list_id}
DELETE /v1/library/lists/{list_id}
PUT    /v1/library/lists/{list_id}/papers/{paper_id}
DELETE /v1/library/lists/{list_id}/papers/{paper_id}

GET    /v1/library/tags
POST   /v1/library/tags
PATCH  /v1/library/tags/{tag_id}
DELETE /v1/library/tags/{tag_id}
PUT    /v1/library/papers/{paper_id}/tags/{tag_id}
DELETE /v1/library/papers/{paper_id}/tags/{tag_id}

GET /v1/library/changes?after_revision=
```

Every mutation that changes active membership increments the per-user library revision transactionally. The reading-feed cursor and mobile queue authority consume that same revision.

### 5.7 Subscriptions and notifications

```text
GET    /v1/subscriptions
POST   /v1/subscriptions
PATCH  /v1/subscriptions/{id}
DELETE /v1/subscriptions/{id}
GET    /v1/notifications
POST   /v1/notifications/{id}/read
POST   /v1/notifications/read-all
GET    /v1/notification-preferences
PUT    /v1/notification-preferences
```

Discovery notifications carry a delivery eligibility state so they can be deferred while the active queue is nonempty. Version updates and explicit reminders for active papers may be delivered according to user settings.

### 5.8 Event ingestion

```text
POST /v1/events/batch
```

Requirements:

- bounded event count and bytes;
- allowlisted schema;
- duplicate event IDs ignored;
- server timestamps and retention assignment;
- no arbitrary content values;
- endpoint may be disabled without breaking product state;
- critical library/queue state is never reconstructed solely from events;
- events cannot forge queue emptiness, library revision, batch reasons, or recommendation eligibility.

---

## 6. Search and source enrichment architecture

### 6.1 Source policy

For v0.1:

- arXiv remains the canonical content source and paper-opening guarantee;
- local PostgreSQL remains the feed source;
- OpenAlex and/or Semantic Scholar may enrich citation/topic/author metadata after legal, attribution, and rate-limit review;
- Crossref may enrich DOI and publication metadata;
- no external source is queried directly from mobile;
- title search and exact import run through the server's shared arXiv gate/cache;
- the import API parses only recognized arXiv URLs/IDs and never performs arbitrary URL fetches;
- metadata resolution/import does not trigger PDF acquisition or derived processing;
- external enrichment failure must not remove an arXiv paper from the product.

### 6.2 Search indexes

Use PostgreSQL first:

- `tsvector` over title/abstract/authors/categories;
- trigram indexes for title and author lookup;
- optional pgvector abstract embeddings;
- identifier indexes;
- date/category indexes.

Do not introduce Elasticsearch/OpenSearch before measuring PostgreSQL limits.

### 6.3 Lookup ranking

Priority:

1. exact arXiv ID;
2. exact DOI if known;
3. exact normalized title;
4. high title trigram match;
5. exact author plus title tokens;
6. text relevance;
7. recency as tie-breaker.

### 6.4 Explore retrieval

Candidate union:

- PostgreSQL text search;
- abstract embedding similarity;
- topic/category filter;
- citation-neighbor expansion where available.

Use reciprocal rank fusion or a similarly auditable method. Return retrieval diagnostics in internal logs/evaluation, not necessarily user UI.


### 6.5 Manual input resolution

Implement one shared paper-resolution service used by exact lookup, title-search selection, and library import:

1. classify input as arXiv URL, arXiv ID, selected search candidate, or unsupported;
2. normalize to a canonical base/version identity;
3. consult local paper metadata and the shared arXiv cache;
4. reserve upstream capacity through the existing rate gate when needed;
5. fetch bounded metadata only;
6. upsert the canonical paper transactionally;
7. idempotently create/restore the account library row;
8. return canonical paper and library revision;
9. enqueue no PDF/document work.

Use operation IDs for retry/crash recovery. A crash after metadata upsert or library save must replay to the same canonical result rather than create duplicates.

---

## 7. Recommendation architecture

### 7.1 Policy boundary and module boundaries

Recommendation quality is subordinate to queue eligibility. Put the queue gate above every candidate generator:

```text
ReadingFeedService
  -> read active queue + library revision in one snapshot
  -> if active/unknown: return queue or fail closed
  -> if proven empty: invoke RecommendationSource
```

A generator, scorer, worker, cache, or mobile mode selector must never override this decision.

```text
backend/crates/recommendations/
  src/lib.rs
  src/candidates/
    recent.rs
    following.rs
    semantic.rs
    citation.rs
    author.rs
    exploration.rs
  src/features.rs
  src/scoring.rs
  src/rerank.rs
  src/explanations.rs
  src/policy.rs
  src/evaluation.rs
```

The authenticated reading-feed orchestration remains a separate domain module above this crate. Worker entry points may refresh generic candidate material, but user-specific batches are generated or made ready only after queue emptiness is proven.

### 7.2 Candidate generators

#### Recent generator

- current configured categories;
- time-decayed recency;
- exclusions for seen/hidden papers;
- used only in guest discovery or proven-empty signed-in fallback.

#### Following generator

- category subscriptions;
- topic matches;
- author matches;
- saved query results;
- version updates are handled separately for already-owned papers;
- used only in guest/proven-empty feed contexts.

#### Semantic generator

- centroid or diversified embeddings from positive historical library items and explicit relevance feedback;
- weight `Reviewed`, user-marked relevant, and deliberately retained historical items more than a generic save;
- exclude private notes from embedding input;
- include decay and per-topic normalization;
- do not build an account batch while active queue rows exist.

#### Citation generator

- references and citations of Reviewed/Archived or otherwise inactive seed papers;
- co-cited and bibliographically coupled neighbors when data exists;
- higher confidence for direct resolved graph edges;
- explanation includes the exact historical seed paper;
- never claim connection to active `To Read` papers in a recommendation shown under an empty-queue decision.

#### Exploration generator

- adjacent topics/methods;
- underrepresented categories within selected boundaries;
- random seed recorded for reproducibility;
- relevance floor enforced.

### 7.3 Feature set v1

Allowlisted features:

- semantic similarity;
- topic overlap;
- explicit follow match;
- citation distance and edge type;
- recency;
- prior qualified recommendation impression count;
- dismissed/hidden state;
- author/topic repetition in current batch;
- source metadata completeness;
- project affinity later, initially absent;
- exploration slot indicator.

Do not include:

- comment popularity;
- user social status;
- exact dwell time;
- email domain/institution prestige;
- demographic proxies;
- provider identity attributes unrelated to product;
- private note, annotation, or evidence-card bodies.

### 7.4 Initial scoring

Implement a versioned weighted policy:

```text
score =
    w_semantic * semantic_similarity
  + w_topic * topic_overlap
  + w_follow * explicit_follow
  + w_graph * citation_affinity
  + w_recency * recency
  + w_novelty * novelty
  - w_seen * repeat_exposure
  - w_negative * negative_feedback
```

Normalize features and test monotonicity. Queue membership is not a score: it is a hard policy gate evaluated before scoring.

### 7.5 Reranking

Apply only after queue eligibility:

- hard exclusions first;
- per-author cap;
- per-topic/category cap;
- duplicate/version collapse;
- maximal marginal relevance;
- reserved exploration positions based on user setting;
- deterministic tie-breaking using batch seed.

### 7.6 Cold start

When a signed-in user's active queue is empty:

1. use selected categories/topics;
2. optionally use 3–10 known Reviewed/Archived papers or authors;
3. generate a Recent/Following blend;
4. reserve a small Explore fraction;
5. ask low-friction explicit relevant/not relevant questions;
6. avoid overfitting to the first few actions.

If onboarding itself adds a known paper to Inbox, stop recommendation generation and enter To Read mode immediately.

New-paper handling:

- use title/abstract/category embeddings;
- use references and second-order graph neighbors when available;
- do not require citation popularity;
- give new papers a controlled coverage opportunity.

### 7.7 Explanation generation

Explanations are template-based in v0.1, not LLM-generated. They map directly to reason codes and seed IDs.

Validation requirements:

- the batch/item pair exists;
- the reason references features actually used;
- historical seed state is described truthfully;
- queue papers show queue provenance, not recommendation reasons;
- explanations remain immutable for an already served batch.

### 7.8 Batch generation

Worker job:

```text
job_type = generate_recommendation_batch
idempotency = (user_id, mode, local_date, profile_revision, library_revision, algorithm_version)
```

Steps:

1. load account/profile and current library revision;
2. check the active To-Read set;
3. if nonempty, write/return `blocked_by_queue` and stop before account candidate generation;
4. generate candidates in parallel with bounded timeouts;
5. compute features;
6. score;
7. rerank;
8. recheck library revision/active emptiness before marking ready;
9. store batch and reasons bound to the empty revision;
10. publish availability;
11. emit privacy-safe metrics.

A profile or library change supersedes old unserved batches. A late batch may never be served after a save. Generic public candidate refresh jobs may continue because they are not an account feed decision.

### 7.9 Fallbacks

After server-proven empty queue only:

- no profile -> Recent;
- enrichment outage -> local metadata candidates;
- embedding unavailable -> topic/text/citation candidates;
- worker delay -> last fresh batch only if its bound library revision still matches and the queue remains empty;
- empty Following -> onboarding suggestions, not an infinite spinner;
- personalization disabled -> deterministic Recent/Following/Explore only.

During nonempty or unknown queue state, the fallback is queue content or an explicit unavailable/checking state—never a recommendation mode.

---

## 8. Alerts and notification policy

### 8.1 Alert classes

Separate alerts by whether they concern work already chosen.

**Queue-owned alerts, eligible while queue is nonempty:**

- user-selected reminder for an active item;
- new arXiv version of an active item;
- correction/retraction status for an active item when available;
- synchronization/action failure requiring user attention.

**Discovery alerts, deferred while queue is nonempty:**

- new paper in followed topic/category;
- new paper by followed author;
- saved-query matches;
- general adjacent-paper suggestions.

### 8.2 Default behavior

- in-app daily digest for discovery only when the active queue is empty;
- push off until explicitly enabled;
- quiet hours required before push is enabled;
- duplicate papers collapsed;
- maximum daily notification budget;
- no engagement-pressure copy;
- discovery matches may be buffered with a bounded retention window, but must not create an infinite backlog;
- when the queue becomes empty, release at most one bounded digest rather than a burst of old notifications.

A notification tap is explicit navigation. It does not change queue state unless the user saves or changes the paper's library state.

### 8.3 Worker jobs

```text
evaluate_subscriptions
build_notification_digest
deliver_push_notifications
expire_notifications
recheck_notification_queue_eligibility
```

Each job is idempotent by subscription/window/item. Before delivering a discovery notification, recheck active queue state and notification preferences. A race with a new save must result in deferral, not delivery.

### 8.4 Version-update behavior

When a saved paper changes version:

- update metadata generation as current architecture requires;
- notify when the user opted in or the paper is active;
- preserve old note/library state;
- derived content invalidates per generation;
- Plan 03 later provides version diff;
- this queue-owned alert does not unlock unrelated discovery.

---

## 9. Mobile implementation structure

```text
mobile/lib/core/reading_feed/
  reading_feed_api.dart
  reading_feed_models.dart
  reading_feed_repository.dart
  reading_feed_policy.dart
  reading_feed_cursor.dart

mobile/lib/core/paper_resolution/
  paper_resolution_api.dart
  paper_resolution_models.dart
  paper_input_classifier.dart

mobile/lib/features/discovery/
  discovery_controller.dart
  discovery_mode.dart
  recommendation_explanation_sheet.dart
  feedback_sheet.dart
  research_profile/
  search/
  alerts/

mobile/lib/features/feed/
  feed_screen.dart
  feed_controller.dart
  feed_prefetch_coordinator.dart

mobile/lib/features/library/
  library_screen.dart
  library_controller.dart
  library_filters.dart
  library_item_editor.dart
  add_paper_sheet.dart
  paper_search_results.dart
  paper_import_controller.dart
  lists/
  tags/

mobile/lib/core/recommendations/
  recommendation_models.dart
  recommendation_policy.dart

mobile/lib/core/storage/tables/
  research_profile_table.dart
  topics_table.dart
  library_lists_table.dart
  library_tags_table.dart
  recommendation_batches_table.dart
  recommendation_feedback_table.dart
  subscriptions_table.dart
  notifications_table.dart
  pending_paper_imports_table.dart   # only if durable offline drafts are approved

mobile/lib/core/sync/
  library_sync_coordinator.dart
  profile_sync_coordinator.dart
  subscription_sync_coordinator.dart
  event_batcher.dart
```

### 9.1 Reading-feed state and authority

Do not represent queue authority with `bool isEmpty`.

```dart
enum ReadingFeedMode {
  checkingQueue,
  toRead,
  recommendations,
  unavailable,
}

enum QueueAuthority {
  unknown,
  localNonEmpty,
  pendingSave,
  serverConfirmedNonEmpty,
  serverConfirmedEmpty,
  stale,
}
```

State binds:

- authenticated local account scope;
- authentication epoch;
- local active rows;
- pending library/import operations;
- library revision/checkpoint;
- server decision and cursor;
- selected future discovery mode;
- request generation/cancellation identity.

A recommendation response is publishable only when all of these still match and local policy remains `serverConfirmedEmpty`.

### 9.2 Startup and account transitions

Signed out:

1. render bundled/cached public feed;
2. revalidate `GET /v1/feed`;
3. allow guest Recent/Explore.

Signed in:

1. open account-scoped Drift rows;
2. if an active row, pending save, or unresolved import intent exists, render/sustain To Read and deactivate discovery prefetch;
3. synchronize the library after verified `/v1/me` mapping;
4. call `GET /v1/me/reading-feed`;
5. before publishing, recheck account, auth epoch, active rows, pending operations, and library revision;
6. merge queue mode with optimistic local operations;
7. publish recommendations only if all checks still prove empty.

On sign-out/account switch:

- cancel requests and increment request generation;
- clear old-account visible queue and recommendation decision;
- close/reopen account-scoped stores;
- do not flash prior account data;
- treat the new scope as unknown until verified.

### 9.3 Optimistic library and import edits

A pending local save wins over every remote recommendation response.

```text
visible queue =
    pending canonical saves/import placeholders
    + server active rows not shadowed by newer local removes/state changes
    + safely cached active rows not yet in the page
```

- generate client operation IDs;
- update locally immediately;
- cancel in-flight recommendation work;
- deduplicate by canonical `paper_id`, temporarily by normalized arXiv identity/operation ID;
- replace placeholder after server response;
- retain explicit retry for transient failure;
- remove only on terminal validation failure or user cancellation;
- an unresolved local import draft suppresses recommendations because it represents queue intent.

A pending removal/state transition of the final item enters `checkingQueue`; it never reveals cached recommendations before server confirmation.

### 9.4 Mode-aware prefetch

```text
guest discovery                 -> active
signed-in server-confirmed empty -> active for recommendation metadata only
to_read                          -> discovery prefetch cancelled
pending save/import              -> discovery prefetch cancelled immediately
unknown/stale/unavailable         -> discovery prefetch cancelled
```

When switching to To Read:

- increment request generation;
- cancel in-flight recommendation requests;
- clear recommendation cursor and visible cards;
- retain ordinary metadata cache rows;
- reject late responses.

Queue mode may prefetch only bounded metadata for active queue pages. Neither mode may prefetch PDFs, document blocks, Passport fields, figures, or assistant context. Deeper preparation remains tied to an explicit Introduction commitment.

### 9.5 Local feed storage

For recommendation batches store:

- query/mode key;
- batch ID;
- ordered paper IDs;
- reason codes/labels;
- profile, policy, and algorithm versions;
- bound library revision and `queue_proven_empty` decision;
- cursor and expiry;
- served/feedback state.

For queue pages store:

- account scope fingerprint;
- library revision;
- active library state and save provenance;
- ordered paper IDs;
- cursor;
- pending operation overlay.

A cached recommendation batch is never authority for current emptiness. A reason shown offline must remain the same reason produced for that batch, but the batch can be rendered only if queue authority is still safely confirmed.

### 9.6 Search and add-paper UX

Reachable from Read and Library.

1. show `Paste an arXiv link or search by paper title`;
2. inspect clipboard only after direct user action;
3. classify obvious arXiv URL/ID forms locally;
4. normalize and preview exact identity;
5. debounce title search after minimum length;
6. show bounded candidates with title, authors, date, category, and arXiv ID;
7. require explicit candidate choice;
8. enqueue/import with an idempotency key;
9. insert optimistic queue intent and switch to To Read immediately;
10. reconcile canonical result;
11. retain honest retry/error states.

Offline unresolved input may be held only as a clearly labeled account-scoped draft. It is not a canonical paper, but it suppresses recommendations until resolved, cancelled, or terminally rejected. Do not persist raw URL/title beyond the minimum justified retention.

### 9.7 Search caching

- recent lookup queries may cache briefly;
- exploratory result sets cache by normalized query/filter hash;
- saved queries are account owned;
- private query history stays on device unless user enables sync;
- clear-history controls exist;
- no cache entry authorizes recommendation mode.

### 9.8 Cross-device convergence

Refresh queue authority:

- on foreground/resume;
- after each mutation acknowledgement;
- after reconnect;
- after auth epoch changes;
- on library sync reset;
- after `READING_FEED_CURSOR_STALE`;
- after applying library changes;
- on a bounded foreground timer while in recommendation mode.

Real-time WebSockets/SSE are not required initially. A configurable 30–60 second foreground recheck in recommendation mode is acceptable.

### 9.9 Accessibility

- queue/checking/recommendation state is announced semantically;
- disabled discovery controls explain why they are unavailable;
- reason/provenance chips are not color-only;
- list ordering has button alternatives;
- search filters support large text;
- candidate result count and import outcome are announced;
- feedback sheets have descriptive actions;
- daily progress uses no pressure language;
- loading is not conveyed only by animation;
- reduced-motion settings are respected.

---

## 10. Privacy and security

### 10.1 Personalization data classes

Document:

- explicit follows/preferences;
- library state;
- qualified impressions;
- explicit relevance feedback;
- recommendation batches/reasons;
- notification preferences;
- search history behavior.

### 10.2 Retention

Suggested initial policy subject to review:

- explicit profile and library: until deletion;
- raw recommendation interactions: short bounded window such as 90–180 days;
- aggregated evaluation metrics: de-identified where defensible;
- recommendation batches/features: short diagnostic window;
- raw URL/title import input: not retained after canonical resolution except bounded idempotency metadata;
- search logs: not server-retained beyond operations unless saved or consented;
- notification delivery logs: bounded operational period.

Implement deletion by user and account deletion. Do not rely on policy text without cleanup jobs.

### 10.3 Sensitive inference

Do not infer or store sensitive characteristics from paper interests. Provide a route for a user to inspect and reset inferred topics.

### 10.4 Abuse and manipulation

Protect feedback/event endpoints from:

- replay;
- batch poisoning;
- automated event floods;
- arbitrary reason or feature injection;
- cross-user access;
- client-forged recommendation explanations.

Recommendation batches are server-signed/identified records; mobile reports feedback referencing existing batch/item pairs.

---

## 11. Evaluation framework

### 11.1 Queue-policy fixtures

Create executable fixtures for:

- active count 0, 1, and many;
- each active/inactive library state;
- pending save before server acknowledgement;
- final-item removal before and after acknowledgement;
- cross-device revision changes between pages;
- account switch and stale response;
- offline launch with empty local cache;
- sync reset;
- unresolved import draft;
- late recommendation batch after a save;
- queue brief exhaustion while active items remain;
- recommendation batch generation skipped while queue is active.

Property invariant:

```text
if visible mode == recommendations:
    server decision says queue_proven_empty
    AND bound library revision is current
    AND local active/pending intent count == 0
```

### 11.2 Recommendation offline datasets

Create versioned fixtures:

- curated empty-queue user profiles with explicit topics and historical seed papers;
- expected candidate pools;
- relevance judgments from team/manual review;
- diversity and repetition expectations;
- cold-start papers;
- sparse categories;
- misleading title/abstract cases;
- author name ambiguity cases;
- version duplicates;
- reason templates referencing only actual inactive/historical seeds.

Store under:

```text
backend/crates/recommendations/tests/fixtures/
backend/crates/reading_feed/tests/fixtures/
demo/recommendation_evaluation/
```

### 11.3 Offline metrics

- Recall@K / nDCG@K on judged sets;
- catalog and topic coverage;
- intra-list diversity;
- novelty;
- author/category concentration;
- cold-start item coverage;
- explanation correctness;
- stability under small profile changes;
- negative-feedback response;
- latency and cost;
- queue decision correctness;
- recommendation-source invocation count when queue is nonempty, target zero;
- stale cursor detection;
- manual import exact-match and ambiguity behavior.

Do not optimize recommendation accuracy at the cost of queue-policy correctness.

### 11.4 Online metrics

Queue-first primary metrics:

- recommendation leakage rate while active/unknown/pending, target zero;
- time from save intent to recommendation suppression;
- time from final acknowledged completion to server-confirmed fallback;
- queue/read-next/reviewed transition success;
- manual import success and retry rate;
- cross-device stale cursor/recovery rate;
- library follow-through within 7/30 days.

Recommendation-mode metrics, collected only after proven emptiness:

- explicit relevant rate;
- save/read-next rate per qualified impression;
- time to first relevant item;
- hide/dismiss rate;
- `Why this?` open and correction/mute behavior;
- discovery brief completion without excess session-time pressure.

Guardrails:

- topic/author concentration;
- notification disable rate;
- feedback regret/undo;
- personalization reset rate;
- user-reported irrelevant or creepy recommendations;
- public-source coverage bias;
- queue abandonment potentially caused by confusing state transitions.

### 11.5 A/B policy

- Never experiment on whether active queue items block recommendations; that is a product invariant, not a variant.
- Randomization unit is documented for eligible recommendation policies.
- No experiment changes privacy collection silently.
- Persist assigned algorithm/policy version and bound library revision in each batch.
- Explanations remain truthful under each variant.
- Stop conditions include trust, diversity, and queue-leakage regressions.

---

## 12. Observability

Metrics:

- reading-feed decisions by `checking|to_read|recommendations|unavailable`;
- active queue count distribution;
- queue query and recommendation query latency;
- recommendation source invocation while active queue exists, target zero;
- client recommendation publication rejected by local policy;
- library revision/cursor stale rate;
- pending save/import age;
- time to suppress discovery after save intent;
- time to unlock discovery after final acknowledged completion;
- title-search/import latency, cache use, ambiguity, replay, and outcome;
- candidate count and latency per generator;
- generator failure/fallback rates;
- batch age/generation latency and `blocked_by_queue` rate;
- recommendation API cache hit;
- no-result rate by eligible discovery mode;
- per-mode relevance/dismiss metrics;
- topic/author concentration;
- cold-start coverage;
- feedback ingestion dedupe/rejection;
- library sync conflict/outbox age;
- search latency/index usage;
- deferred discovery alert count/age and release budget;
- external enrichment quota/rate-limit/error;
- data-retention cleanup success.

Logs contain opaque IDs, revisions, state/reason codes, and safe failure classes—not paper text, raw URL/title/search bodies, account identifiers, or private notes.

Trace spans should make the policy boundary visible:

```text
reading_feed.request
reading_feed.queue_snapshot
reading_feed.queue_page
reading_feed.recommendation_eligibility
reading_feed.recommendation_page
paper_search.request
paper_import.resolve
paper_import.library_save
```

Alert on any confirmed recommendation card rendered while local/server queue authority was not empty.

---

## 13. Implementation phases

### Phase A — Queue-first feed and manual intake foundation

1. Pin the repository baseline and write the queue-first ADR.
2. Extract shared exact arXiv resolution from existing paper lookup code.
3. Add bounded authenticated title search.
4. Add idempotent URL/ID/candidate import.
5. Add `GET /v1/me/reading-feed` with one-snapshot arbitration and revision-bound cursors.
6. Add mobile queue authority state machine.
7. Make add-paper reachable from Read and Library.
8. Cancel recommendation prefetch on local save intent.
9. Add cross-device, offline, account-switch, and no-PDF-preparation tests.

Release behind independent server/mobile flags. If this foundation has already landed from the separate implementation plan, verify its Definition of Done rather than duplicating it.

### Phase B — Library expansion

1. Expand server library state schema through compatibility-safe migration.
2. Map v0.0 To Read to Inbox.
3. Define active states as Inbox/Read next/Reading.
4. Add list/tag/state/note APIs.
5. Add Drift tables and migration.
6. Upgrade Library destination.
7. Add optimistic outbox flows and conflict handling.
8. Verify every active-state transition increments the same library revision used by reading feed.

Release behind `library_v2_enabled` while preserving v0.0 clients.

### Phase C — Research profile and Following

1. Add profile/category/topic/author schema.
2. Add profile APIs.
3. Build progressive onboarding after queue setup.
4. Implement Following candidate generation from explicit signals.
5. Add profile transparency/settings.
6. Gate all signed-in presentation on queue emptiness.

### Phase D — Search

1. Add PostgreSQL indexes and lookup API.
2. Add explore retrieval and source diagnostics.
3. Implement mobile search UI.
4. Add saved queries.
5. Route save through canonical library/import operations.
6. Add exact-match, ambiguity, and queue-suppression fixtures.

### Phase E — Recommendation foundation

1. Build candidate module interfaces.
2. Implement Recent/Following/Semantic/Citation/Explore generators.
3. Add versioned feature/scoring policy.
4. Add diversity reranker.
5. Add batch storage bound to library revision and empty decision.
6. Add explanation templates.
7. Build offline evaluator.
8. Add `blocked_by_queue` and late-batch rejection tests.

Do not expose For You before both evaluation and queue-policy gates pass.

### Phase F — For You, explanations, and feedback

1. Connect recommendation modes behind `/v1/me/reading-feed`.
2. Add explanation sheet.
3. Add feedback controls.
4. Add minimal event batching and retention.
5. Add profile reset/personalization toggle.
6. Roll out only to accounts observed in proven-empty mode.

### Phase G — Briefs, subscriptions, and queue-aware alerts

1. Add queue/discovery brief generation through the same gate.
2. Add subscription schema/API.
3. Add digest worker jobs.
4. Add deferred-discovery eligibility.
5. Add in-app notifications.
6. Add push only after preferences, quiet hours, queue recheck, and delivery operations are ready.

### Phase H — Stabilization

1. Backfill/update migrations.
2. Review source terms/attribution.
3. Run bias/diversity evaluation.
4. Run queue-invariant property tests under concurrency.
5. Test retention/deletion.
6. Tune prefetch by queue mode.
7. Test fail-closed behavior under upstream/database/auth failures.
8. Update OpenAPI, docs, runbooks, privacy disclosures, and rollback procedures.

---

## 14. Detailed acceptance scenarios

### 14.1 New guest

- selects `cs.CL` and `cs.LG` or skips;
- sees public Recent and Explore;
- no claim of personalization;
- can search and read explicitly;
- save prompts sign-in and resumes the exact save intent;
- after sign-in, the saved paper enters Inbox and the signed-in feed becomes To Read.

### 14.2 New signed-in user with an empty queue

- server proves active count zero;
- user may select topics/authors;
- sees chosen eligible fallback mode;
- For You explains that early recommendations use explicit choices;
- can mark items relevant/not relevant;
- saving one paper immediately removes all recommendation cards and enters To Read.

### 14.3 Existing library user

- v0.0 To Read items migrate to Inbox;
- no data loss or timestamp reset;
- signed-in Read shows only those active papers;
- creates a list/tags without changing feed eligibility;
- offline edits sync after reconnect;
- stale second device converges by revision.

### 14.4 Manual URL import

- user pastes a recognized arXiv URL while recommendations are visible;
- local pending intent suppresses recommendations before the request completes;
- server resolves canonical metadata and idempotently saves Inbox;
- late recommendation responses are discarded;
- no PDF/job/preparation row is created.

### 14.5 Ambiguous title search

- user enters a paper title;
- server returns multiple bounded candidates;
- app does not auto-save the first;
- user selects the exact paper;
- import creates one canonical library row;
- retry with the same operation ID returns the same result.

### 14.6 Queue exhaustion is not queue emptiness

- user swipes through every loaded active item but marks none Reviewed/Archived;
- app shows a natural queue stopping state;
- no recommendation appears;
- fetching next page returns remaining active items or end-of-queue metadata;
- only explicit state transition/removal can make the active set empty.

### 14.7 Final-item completion

- user marks the last active paper Reviewed;
- local UI enters checking/finishing state;
- cached recommendations remain hidden;
- mutation is acknowledged and revision advances;
- a fresh reading-feed response proves count zero;
- only then does the selected discovery fallback appear.

### 14.8 Cross-device save race

- device A is in recommendation mode;
- device B imports a paper;
- device A's next cursor becomes stale or periodic refresh sees the new revision;
- recommendation list is removed;
- device A renders the active queue;
- no mixed page survives.

### 14.9 Personalization disabled

- For You disappears as an eligible fallback;
- Recent/Following/Explore, Search, Library, and queue reading remain useful;
- active queue behavior is unchanged;
- event collection reduces to essential operational/product state;
- profile reset deletes inferred signals.

### 14.10 External source outage

- OpenAlex/Semantic Scholar enrichment fails;
- active queue remains fully usable from local arXiv metadata;
- manual import of already cached exact identity can succeed;
- new title/exact resolve shows retryable failure if arXiv is unavailable;
- proven-empty recommendation falls back to local metadata where possible;
- no error loop or queue bypass.

### 14.11 Queue and discovery briefs

- active queue contains 20 items;
- brief contains only those queue items;
- closing after 6 resumes at 7;
- reaching 20 does not unlock discovery while active states remain;
- after all are explicitly completed and emptiness is confirmed, a separate discovery brief may be created with stable reasons.

### 14.12 Alert safety

- user follows a high-volume topic while queue is nonempty;
- discovery matches are deferred and bounded;
- an opted-in version update for an active paper may surface;
- quiet hours and daily budget are honored;
- after queue emptiness, at most one bounded discovery digest is released;
- user can mute from notification/settings.

### 14.13 Offline unknown state

- app launches signed in with no safely scoped local queue snapshot and no network;
- UI says queue verification is unavailable;
- add-paper drafts are clearly labeled;
- no public or cached recommendation cards are substituted;
- reconnect performs account/library sync before recommendation eligibility.

---

## 15. Release gates

v0.1 is not complete until:

- an active or pending To-Read item can never coexist with a visible recommendation card in signed-in automated feed tests;
- unknown/stale/offline/account-transition queue state fails closed;
- the reading-feed decision and first page are computed from one snapshot;
- every active-membership change increments the same per-user library revision;
- cross-device mutations invalidate stale cursors and batches;
- final-item removal waits for server-confirmed emptiness before fallback;
- v0.0 library migration has zero known data-loss cases;
- recognized arXiv URL/ID import is idempotent and SSRF-safe;
- ambiguous title search requires explicit selection;
- search/import/feed/prefetch create no PDF or derived-processing work;
- late recommendation responses are rejected after local save intent;
- search lookup exact-match quality passes fixtures;
- recommendation explanations are 100% reason-code consistent;
- no explanation falsely references an active To-Read list under an empty-queue decision;
- diversity/concentration thresholds pass offline evaluation;
- cold-start user and paper cases meet coverage targets;
- personalization can be disabled/reset/exported without harming queue reading;
- event retention deletion is tested;
- no private notes enter ranking or telemetry;
- discovery alerts defer correctly while queue is active;
- feed remains usable when enrichment sources are unavailable;
- p95 queue-feed, import, and eligible recommendation latency meet budgets;
- bounded briefs do not bypass active state;
- accessibility and reduced-motion behavior pass;
- rollback can disable discovery/import independently without corrupting the queue.

---

## 16. Handoff contract to Plan 03

Plan 03 may assume:

- `GET /v1/me/reading-feed` is the canonical signed-in automatic paper source;
- active queue membership is derived only from canonical Library state;
- `Inbox`, `Read next`, and `Reading` block recommendations;
- `Reviewed` and `Archived` do not block recommendations;
- queue state is revisioned, synchronized, and fail-closed on mobile;
- pending saves/import drafts immediately suppress discovery;
- public `GET /v1/feed` remains separate and is not a signed-in bypass;
- manual arXiv URL/title intake is idempotent and metadata-only;
- deep preparation is triggered by explicit reader commitment, not feed/import/prefetch;
- a stable Library destination and state model;
- private paper-level save notes;
- normalized topics and explicit/inferred interest separation;
- search/source-enrichment adapters;
- recommendation batch/reason infrastructure bound to empty queue revisions;
- consented content-free event system;
- queue-aware version/update notification support;
- Drift entity revision and outbox patterns;
- arXiv remains canonical while source adapters begin to generalize.

Plan 03 will add annotations, semantic document objects, figures/tables/equations, paper passports, evidence cards, and reading memory. It must preserve the queue authority, must not introduce another next-paper source, and must not overload recommendation events with private reading content.

---

## 17. Final implementation principle

A good v0.1 Read feed first respects the user's declared commitments. While active To-Read work exists, Pakperk should reduce choice rather than manufacture more of it. Once that work is explicitly cleared and emptiness is authoritatively confirmed, discovery should become transparent, diverse, controllable, and easy to convert into the next intentional queue item.
