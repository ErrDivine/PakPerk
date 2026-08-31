# Pakperk Plan 03: v0.2 Deep Reader and Research Memory

**Document status:** Standalone implementation specification for a vibe-coding agent; queue-first aligned revision  
**Milestone:** v0.2 Deep Reader and Memory  
**Depends on:** Plans 01 and aligned Plan 02 completed, including canonical queue-first reading-feed and manual paper intake  
**Handoff to:** Plan 04, Projects, Evidence, and Auditable Agent  
**Primary objective:** Make Pakperk an excellent active-reading environment on a phone, with exact source grounding, durable private annotations, paper-level memory, and honest transitions between skimming and inspection—without weakening the account-owned To-Read queue as the sole automatic next-paper authority.

> The design must help users read faster when speed is appropriate and slower when rigor is required. Generated explanations are navigation aids into evidence, never replacements for the paper. Reader depth may expand, but automatic paper selection remains queue-first.

### Inherited feed invariant

```text
active To-Read exists, is pending, or is not authoritatively known
    => automatic next paper comes only from active To Read, or no paper is auto-fed

server proves active To-Read count = 0 at the current library revision
    => recommendation fallback may begin
```

Explicit search, opening an original source, or following a citation/connection is allowed at any time because it is direct user navigation. Such navigation must not append an unqueued paper to the vertical Read feed. Saving any such paper adds it to the active queue and immediately suppresses recommendation mode.

---

## 0. Coding-agent execution contract

1. Preserve the reader's three horizontal stages: Abstract, Introduction + Assistant, Connections.
2. Add `Skim / Read / Inspect` as a mode within the paper, not extra horizontal pages.
3. Inherit the aligned Plan 02 queue contract without creating another next-paper API, cache authority, or state table.
4. Automatic vertical navigation may advance only to another active To-Read item while the active set is nonempty.
5. A final active-item transition to Reviewed/Archived/removed enters a checking state; recommendation fallback begins only after server-confirmed emptiness at a current library revision.
6. Unknown queue authority, a pending save/import, stale sync, offline account uncertainty, or account transition forbids recommendation auto-advance.
7. Saving a recommendation, search result, or connected paper immediately suppresses remaining recommendations and makes that paper an active queue item.
8. Reader checkpoints record position and mode only. Canonical Library state is the sole authority for `Inbox / Read next / Reading / Reviewed / Archived` and recommendation eligibility.
9. Searching, importing, queue/feed prefetch, and abstract-card display must not acquire PDFs or enqueue document processing. Preparation begins only after an explicit commitment to Introduction/deeper reading or another clearly labeled prepare action.
10. Passport fields, facets, figures, and other derived objects shown on the Abstract stage may be displayed only if already prepared; their absence must not trigger hidden background preparation.
11. Every generated paper-passport field, explanation, comparison, or answer must link to validated source blocks.
12. Store parser, paper version/generation, model, prompt/schema version, and source IDs for every derived artifact.
13. Do not expose a field when the source does not support it. Use `not_found`, `not_applicable`, or `uncertain`.
14. Do not present abstract-derived inference as full-paper evidence.
15. Paper text, captions, references, and user uploads are untrusted prompt data.
16. The model may cite only evidence IDs supplied by the server; validate all returned IDs.
17. Do not store hidden chain-of-thought.
18. Annotations and notes are private by default and must support export/deletion.
19. Do not use private annotation/note/evidence-card bodies for global recommendations or training without separate explicit consent.
20. Preserve full-text policy checks at extraction and serving.
21. Keep GROBID as the production baseline until a parser benchmark demonstrates a safe change.
22. Add a parser adapter; do not bind the domain model to one parser's XML.
23. Every parser/model upgrade requires a versioned evaluation and reprocessing plan.
24. Accessibility, selection behavior, gesture arbitration, and queue-safe auto-advance are release blockers.
25. No feature may make the original PDF or exact source passage harder to open.

---

## 1. Product mission

A user should be able to:

- skim a paper's contribution without pretending to have evaluated it;
- read coherent reconstructed text comfortably on a phone;
- inspect methods, evidence, figures, tables, equations, citations, and limitations;
- ask a question and see exact supporting passages;
- highlight and annotate without losing anchors after ordinary reflow;
- record why the paper matters;
- return later at the same conceptual place;
- see what changed between paper versions;
- create reusable evidence cards for future projects;
- review only trustworthy, user-selected memory artifacts;
- move through the papers they already chose without unrelated recommendations interrupting the queue;
- explicitly finish or archive a paper before it stops contributing to active queue state.

### 1.1 Product promise

v0.2 adds:

- Skim/Read/Inspect reading modes;
- a structured Paper Passport;
- semantic facets and in-context definitions;
- section navigation beyond Introduction without turning the app into a raw PDF clone;
- figures, tables, and equations as mobile objects;
- robust private highlights and annotations;
- evidence cards and unresolved questions;
- evidence-first assistant responses;
- reading checkpoints and intentional resurfacing;
- version comparison;
- parser quality benchmark and adapter architecture;
- queue-safe reader navigation and explicit Library-state transitions.

### 1.2 Non-goals

Do not implement yet:

- multi-paper project extraction or systematic review workflow;
- public annotations;
- collaborative annotation;
- automatic public summaries written in the user's voice;
- universal full-text hosting;
- autonomous citation verification beyond available sources;
- automatic grading of paper quality;
- automatic plot data extraction presented as exact without a separate validated pipeline;
- generative audio/video “paper stories”;
- on-device LLM inference unless separately approved and evaluated;
- full desktop PDF-authoring functionality.

---

## 2. Reading interaction model

### 2.1 Reader entry and next-paper contract

The reader can be entered from:

- the canonical signed-in To-Read feed;
- proven-empty recommendation fallback;
- Library;
- explicit Lookup/Explore search;
- an explicit Connections/citation action;
- memory review or version-update notification.

Entry source affects controls but not evidence behavior.

Automatic vertical next-paper behavior:

```text
active queue nonempty
    -> next automatic paper must be another active queue item

current paper saved while in recommendation fallback
    -> cancel remaining recommendation navigation
    -> transition to queue mode immediately

last active item marked Reviewed/Archived/removed
    -> show checking/finishing state
    -> refresh canonical reading feed
    -> recommendations only after confirmed empty

queue authority unknown/stale/offline
    -> no recommendation auto-advance
```

Explicitly opening a connected or searched paper does not add it to the feed. The UI must label whether it is `In To Read` and offer `Add to To Read`. Returning closes that explicit branch and restores the prior queue/reader position.

### 2.2 Horizontal stages remain fixed

```text
Abstract <-> Introduction + Assistant <-> Connections
```

Why preserve this:

- it is the product's existing mental model;
- it distinguishes immediate metadata from expensive derived content;
- it maps paper understanding to increasingly connected context;
- it avoids an unbounded horizontal pager.

The committed transition from Abstract toward Introduction is the normal trigger for deep preparation when the requested generation is not already ready. Vertical prefetch and abstract display remain metadata-only.

### 2.3 Depth mode

A compact control appears within the active paper:

```text
Skim | Read | Inspect
```

The control is paper-scoped and restorable. It changes presentation density and available tools, not the paper stage or queue membership.

#### Skim

Purpose: triage.

Shows:

- title/authors/date/source/version;
- abstract;
- Paper Passport compact fields only when already prepared and valid for the current generation;
- contribution/method/evidence/limitations facets only when already prepared;
- queue-state actions for an active paper: change state, mark Reviewed, Archive, edit save note;
- save/add action for an unqueued recommendation/search/connection paper;
- relevant/not-relevant/dismiss controls only for an eligible recommendation batch item;
- prominent `Inspect evidence` and original-source actions.

Guardrails:

- label generated fields and source coverage;
- never start PDF/document preparation merely to decorate an abstract card;
- a save from recommendation mode immediately terminates recommendation presentation.

#### Read

Purpose: coherent comprehension.

Shows:

- reconstructed document text by sections;
- comfortable typography and reading width;
- restrained headings and citations;
- optional definitions;
- persistent assistant composer;
- highlight/annotation actions;
- reading progress by section, not gamified percentage alone;
- explicit Library-state control separate from reading progress.

#### Inspect

Purpose: critical examination.

Adds:

- full section outline;
- method/result/limitation facets;
- figures/tables/equations navigator;
- source block identifiers/page anchors in an unobtrusive details view;
- paper version and parser/provenance information;
- claim/evidence links;
- code/data/resource metadata;
- compare-version action;
- citation context inspection.

### 2.4 Stage behavior by mode

| Stage | Skim | Read | Inspect |
|---|---|---|---|
| Abstract | Abstract + already-ready compact Passport | Abstract + related ready context | Metadata, version, source, identifiers |
| Introduction | Passport narrative + starter questions | Introduction/selected sections + assistant | Outline, blocks, figures, evidence, provenance |
| Connections | Top relationships; explicit open/add actions | Citation-context explanations | Full reference context, edge evidence, graph diagnostics |

### 2.5 Natural stopping points and completion

At section boundaries, offer actions such as:

- save a checkpoint;
- add a note;
- inspect a figure;
- ask about the method;
- continue to next section;
- mark Reading or Reviewed;
- Archive/remove from active queue;
- return to queue brief/Library.

Do not auto-advance into another paper when text selection, note editing, assistant composition, object inspection, or Inspect mode is active.

When auto-advance is eligible:

- resolve the next item through the existing account-scoped reading-feed session/cursor;
- recheck local pending saves and queue authority before navigation;
- never ask a recommendation controller directly for the next paper while queue mode is active;
- reaching the document end does not automatically mark Reviewed;
- reaching the final active queue item without an explicit state transition shows a natural stopping state, not recommendations.

---

## 3. Document domain model

The current normalized sections/chunks are useful but insufficient for robust annotations and visual objects. Introduce a versioned document model independent of parser-specific output.

### 3.1 Core concepts

```text
Paper manifestation/version
  -> Document generation
    -> Section tree
      -> Ordered blocks
        -> Inline spans and references
    -> Figures
    -> Tables
    -> Equations
    -> Bibliography entries
    -> Citation contexts
    -> Semantic spans
```

### 3.2 `DocumentBlock`

Proposed Rust domain type:

```rust
pub struct DocumentBlock {
    pub id: Uuid,
    pub paper_id: Uuid,
    pub generation: i32,
    pub stable_key: String,
    pub ordinal: i32,
    pub section_path: Vec<String>,
    pub kind: DocumentBlockKind,
    pub text: String,
    pub page_start: Option<i32>,
    pub page_end: Option<i32>,
    pub source_locator: Option<SourceLocator>,
    pub content_hash: String,
}
```

Block kinds:

- heading;
- paragraph;
- list item;
- quote;
- theorem/definition;
- caption;
- equation context;
- table context;
- figure context;
- footnote;
- other.

### 3.3 Stable keys

A block stable key should derive from normalized section path, kind, local ordinal, and content features. It is a re-anchoring aid, not a globally permanent identifier.

Persist both UUID and stable key. Generation remains the authority.

### 3.4 Inline references

Represent inline spans with Unicode-scalar offsets, consistent with the existing Introduction citation design:

- bibliography reference;
- figure reference;
- table reference;
- equation reference;
- footnote;
- term/symbol;
- external resource.

Validate offsets against block text before serving.

---

## 4. Parser adapter and benchmark

### 4.1 Architecture

```text
backend/crates/document_ingestion/
  src/lib.rs
  src/adapter.rs
  src/normalize.rs
  src/quality.rs
  src/grobid_adapter.rs
  src/docling_adapter.rs       # experimental behind flag
  src/fixtures.rs
```

Interface concept:

```rust
#[async_trait]
pub trait ScholarlyDocumentParser {
    fn parser_id(&self) -> &'static str;
    fn parser_version(&self) -> String;
    async fn parse(&self, input: ParseInput) -> Result<ParsedDocument, ParseError>;
}
```

The worker selects an adapter through configuration and records it in provenance.

### 4.2 GROBID baseline

Keep:

- pinned container version;
- current license/policy behavior;
- TEI fixtures;
- reference-resolution integration;
- bounded PDF and timeout controls.

Refactor only enough to produce the new normalized model.

### 4.3 Docling evaluation

Evaluate Docling or another maintained parser for:

- table structure;
- figure/caption extraction;
- reading order;
- equation objects;
- scanned PDFs;
- layout fidelity;
- operational cost and memory;
- license and dependency footprint.

Do not replace GROBID based on anecdotal examples.

### 4.4 Benchmark corpus

Create a legally suitable, versioned evaluation corpus with at least:

- two-column CS papers;
- papers with nested sections;
- many equations;
- dense tables;
- multi-panel figures;
- malformed references;
- scanned or image-heavy documents where permitted;
- very long appendices;
- unusual heading styles;
- older arXiv PDFs;
- non-English or multilingual papers if future scope requires it.

### 4.5 Ground-truth labels

Manual review fields:

- section ordering;
- paragraph boundary accuracy;
- introduction detection;
- citation target accuracy;
- figure count/caption association;
- table count/cell structure;
- equation count/context;
- page mapping;
- reference extraction;
- Unicode/math corruption;
- duplicated/missing content.

### 4.6 Parser quality gate

A new parser may become default only if:

- it improves target capabilities materially;
- regression thresholds pass existing core text/reference cases;
- resource use is within deployment budget;
- failure classification and fallback are defined;
- derived-artifact versioning and reprocessing are tested;
- content policy remains enforceable.

### 4.7 Fallback policy

Parser selection can be:

1. primary parser;
2. deterministic fallback for specific failure classes;
3. metadata-only terminal state when no reliable extraction exists.

Never merge outputs from two parsers silently. If hybrid normalization is later used, record component provenance per object.

---

## 5. PostgreSQL data model

Use expand-and-contract migrations, likely beginning with:

```text
backend/migrations/0005_document_model.sql
backend/migrations/0006_annotations_memory.sql
backend/migrations/0007_passport_provenance.sql
```

### 5.1 `document_blocks`

```text
id                      uuid primary key
paper_id                uuid references papers(id)
generation              integer not null
stable_key              text not null
ordinal                 integer not null
section_id              uuid null references paper_sections(id)
section_path            text[] not null
kind                    text not null
text                    text not null
content_hash            text not null
page_start              integer null
page_end                integer null
source_locator          jsonb null
inline_spans             jsonb not null default '[]'
created_at              timestamptz not null
unique(paper_id, generation, ordinal)
unique(paper_id, generation, stable_key)
```

Indexes:

- `(paper_id, generation, ordinal)`;
- `(paper_id, generation, kind)`;
- GIN over section path if needed;
- full-text index where block search is required.

### 5.2 `paper_figures`

```text
id
paper_id
generation
label
ordinal
caption
page_number null
asset_key null
width/height null
content_hash
source_locator jsonb
created_at
unique(paper_id, generation, ordinal)
```

Asset storage policy:

- private bounded object storage or generated derivative cache;
- never expose arbitrary parser paths;
- signed/authorized delivery if full-text policy requires it;
- deletion/rebuild tied to generation and policy;
- alternative text generated as a draft and clearly labeled unless sourced.

### 5.3 `paper_tables`

```text
id
paper_id
generation
label
ordinal
caption
page_number null
structure jsonb
plain_text
content_hash
source_locator
created_at
```

`structure` must have a versioned schema.

### 5.4 `paper_equations`

```text
id
paper_id
generation
label null
ordinal
latex null
mathml null
plain_text null
context_block_id null
page_number null
content_hash
source_locator
created_at
```

Do not fabricate LaTeX when parser confidence is insufficient.

### 5.5 `paper_terms`

```text
id
paper_id
generation
normalized_term
display_term
kind: term | acronym | symbol | method | dataset
canonical_topic_id null
definition_status
created_at
unique(paper_id, generation, normalized_term, kind)
```

### 5.6 `term_occurrences`

```text
term_id
block_id
start_offset
end_offset
occurrence_ordinal
primary key(term_id, block_id, occurrence_ordinal)
```

### 5.7 `term_definitions`

```text
id
term_id
source_type: current_paper | cited_paper | glossary | generated
source_block_ids uuid[]
definition
model_id null
prompt_version null
confidence_status
created_at
```

### 5.8 `paper_passports`

```text
id
paper_id
generation
schema_version
status: draft | ready | partial | failed
parser_id
model_id null
prompt_version null
created_at
updated_at
unique(paper_id, generation, schema_version)
```

### 5.9 `paper_passport_fields`

```text
passport_id
field_key
value_text null
value_json null
status: supported | inferred | not_found | not_applicable | conflicting
source_block_ids uuid[]
confidence_status
created_at
primary key(passport_id, field_key)
```

Field keys:

- research_question;
- contribution;
- method;
- data_or_sample;
- evaluation;
- main_result;
- limitations;
- assumptions_scope;
- code_resources;
- publication_status.

### 5.10 `annotations`

```text
id                      uuid primary key
user_id                 uuid references users(id)
paper_id                uuid references papers(id)
generation              integer not null
block_id                uuid null references document_blocks(id)
kind                    highlight | note | question | evidence
body                    text null
color_role              text null
quote_exact             text not null
quote_prefix            text null
quote_suffix            text null
start_offset            integer null
end_offset              integer null
section_hint            text[]
page_hint               integer null
anchor_status           anchored | uncertain | orphaned
revision                bigint not null
deleted_at              timestamptz null
created_at
updated_at
```

Never rely on color as semantic meaning alone.

### 5.11 `evidence_cards`

```text
id
user_id
paper_id
generation
title
claim_or_question null
user_note null
source_block_ids uuid[]
figure_ids uuid[]
table_ids uuid[]
citation_context_ids uuid[]
verification_status: user_selected | user_reviewed | superseded
revision
deleted_at
created_at
updated_at
```

### 5.12 `reading_sessions`

Use cautiously and minimize retention.

```text
id
user_id null
paper_id
generation
mode
started_at
ended_at null
start_stage
end_stage null
last_block_id null
created_at
expires_at
```

Do not persist per-second scroll telemetry. A session exists to support checkpoints and user-facing history, not engagement optimization.

### 5.13 `reading_checkpoints`

```text
user_id
paper_id
generation
mode
stage
block_id null
scroll_fraction null
last_read_at
revision
primary key(user_id, paper_id)
```

A checkpoint stores position and presentation mode only. Do not duplicate `reading` or `reviewed` here. `user_paper_library.state` from Plan 02 is the canonical state machine and the sole source for active queue membership. A checkpoint response may include a read-only `library_state` projection for UI convenience, but checkpoint writes cannot mutate it implicitly.

### 5.14 `memory_items`

```text
id
user_id
paper_id
generation
source_type: annotation | evidence_card | passport_field | user_question
source_id
prompt_text null
answer_text null
status: active | snoozed | retired
next_review_at null
review_count
revision
deleted_at
created_at
updated_at
```

Memory prompts are generated only from eligible user-selected or verified sources.

### 5.15 `provenance_records`

```text
id
artifact_type
artifact_id
paper_id null
generation null
activity_type
parser_id null
parser_version null
model_provider null
model_id null
prompt_or_schema_version null
input_entity_ids uuid[]
parameters jsonb bounded
created_at
superseded_by null
```

This is a practical PROV-inspired subset. Do not store secrets or full prompt bodies when a version/hash is sufficient.

---

## 6. Worker pipeline

### 6.1 Trigger gate and extended preparation stages

Preparation is demand-driven. The following actions do **not** enqueue PDF/document work:

- manual URL/title import;
- saving to Inbox/Read next;
- reading-feed pagination;
- recommendation candidate/batch generation;
- vertical prefetch;
- abstract-card display;
- notification/subscription evaluation.

A preparation request may begin only after:

- the user commits the horizontal transition to Introduction;
- the user explicitly selects a clearly labeled `Prepare/Inspect evidence` action;
- a previously approved server maintenance/reprocessing job runs under a documented policy, never because of feed prefetch.

Preserve progressive publication after a valid trigger:

```text
metadata
  -> PDF policy and acquisition
  -> parse/normalize document blocks
  -> Introduction ready
  -> later-section chunks and chat ready
  -> references/connections ready
  -> visual objects ready
  -> terms/semantic facets ready
  -> Paper Passport ready
```

Do not hold Introduction hostage to later enrichments. If a Passport or facet is not already prepared on the Abstract stage, show an honest unavailable/pending state without silently starting deep work.

### 6.2 Job decomposition

Possible jobs:

```text
prepare_core_document
enrich_visual_objects
extract_terms
build_paper_passport
build_faceted_spans
reanchor_annotations
compare_paper_versions
regenerate_accessibility_descriptions
```

Whether these are separate DB jobs or internal stages depends on retry/failure isolation. Visual/passport failures must not invalidate readable text. Every enqueue path must carry an approved trigger kind and be rejected if it originated only from feed/import/prefetch.

### 6.3 Idempotency

Keys include:

- paper ID;
- generation;
- job type;
- parser/model/schema version where a rebuild should coexist or supersede;
- optional artifact revision.

### 6.4 Supersession

When a new arXiv version appears:

- cancel stale queued/running enrichments;
- keep old generation inaccessible as current content but available to version-diff jobs under policy;
- mark old passport/visual/term artifacts superseded;
- attempt annotation re-anchoring;
- notify active library users according to Plan 02 settings;
- never overwrite source provenance.

### 6.5 Prompt injection defense

- delimit paper text as untrusted data;
- system/developer instructions explicitly prohibit following instructions in the paper;
- use strict structured output;
- validate IDs and field schemas;
- limit tools available to enrichment jobs;
- include adversarial documents in evaluation;
- log safe failure categories, not paper text.

---

## 7. Paper Passport implementation

### 7.1 Extraction strategy

Prefer hybrid deterministic + model extraction:

- publication status/identifiers/resources: metadata and regex/structured sources;
- section candidates: deterministic section classifier;
- field extraction: model over selected candidate blocks;
- validation: require source IDs and server-side support checks;
- missing field: explicit status;
- conflicting statements: preserve multiple evidence groups.

### 7.2 UI contract

Compact Passport card shows no more than 3–5 fields at once and appears only when a valid current-generation Passport is already ready or the user has explicitly triggered preparation. Merely rendering the Abstract stage must not enqueue Passport generation. Full Passport sheet shows:

- value;
- source coverage badge;
- exact evidence action;
- author-stated versus Pakperk-derived label;
- generated timestamp and version details in an information panel;
- correction/feedback action.

### 7.3 Field status semantics

- **Supported:** directly stated or strongly evidenced by source blocks.
- **Inferred:** reasonable synthesis from evidence; visibly labeled.
- **Conflicting:** source contains materially inconsistent statements or multiple interpretations.
- **Not found:** no reliable evidence in available document.
- **Not applicable:** field does not fit paper type.

### 7.4 Feedback

Users can report:

- wrong field;
- misleading compression;
- wrong evidence;
- missing limitation;
- parser issue.

Feedback creates an evaluation record; it does not directly mutate the shared artifact without review.

---

## 8. Semantic facets and definitions

### 8.1 Faceted spans

Initial facets:

- objective;
- method;
- result;
- limitation;
- claim;
- evidence;
- future work;
- definition.

Use a restrained default. A density control offers:

```text
Off | Key | Detailed
```

### 8.2 Generation

- deterministic section labels provide baseline;
- model may classify candidate sentences/blocks;
- spans require block IDs and offsets;
- overlapping spans use precedence rules;
- confidence threshold avoids visual noise;
- server validates spans against text.

### 8.3 Definition UI

Tap a highlighted term or long-press/select:

- anchored bottom sheet;
- current-paper definition first;
- cited-source definition second;
- trusted glossary if configured;
- generated explanation last and labeled;
- preserve reader position;
- no auto-popup covering text.

### 8.4 Symbol handling

For math-heavy papers:

- identify symbol definitions within nearby blocks;
- show first/nearest definition and section;
- do not claim semantic equivalence across sections without evidence;
- preserve MathML/LaTeX rendering accessibility where possible.

---

## 9. Figures, tables, and equations

### 9.1 Mobile object cards

Each object card includes:

- label;
- image/structured rendering;
- caption;
- source page;
- referenced-by context snippets;
- save as evidence action;
- ask about this object action;
- open original page/PDF.

### 9.2 Asset pipeline

- extract or render bounded derivatives;
- strip unsafe metadata where needed;
- compute hashes;
- generate responsive sizes;
- cache with generation keys;
- signed/authorized endpoint according to policy;
- accessible fallback when extraction fails.

### 9.3 Table rendering

- use semantic row/column headers where detected;
- allow horizontal pan within table only, with gesture conflict protection;
- provide plain-text/CSV-style view;
- never silently normalize units or missing values;
- preserve footnotes.

### 9.4 Equation rendering

- render MathML/LaTeX using a maintained package;
- accessible text alternative;
- zoom and copy source where policy permits;
- context sheet explains symbols from evidence;
- generated derivation must be a separate labeled assistant output.

### 9.5 Assistant scope

Questions can target:

- whole paper;
- selected text;
- one figure/table/equation;
- one section.

The UI always displays the active scope.

---

## 10. Evidence-first assistant

### 10.1 Interaction modes

- free question;
- starter question;
- selected-text question;
- object question;
- “show evidence for this Passport field”;
- “where do authors state limitations?”;
- “explain at beginner/expert depth” without changing the evidence set.

### 10.2 Retrieval scope

Request includes explicit scope:

```json
{
  "paper_id": "...",
  "generation": 3,
  "question": "What baseline gives the strongest result?",
  "scope": {
    "kind": "paper",
    "section_kinds": ["experiment", "result"],
    "object_ids": []
  },
  "answer_style": "concise",
  "thread_id": "..."
}
```

### 10.3 Response schema

```json
{
  "answer": "...",
  "status": "supported",
  "claims": [
    {
      "text": "...",
      "support": "direct",
      "evidence": [
        {
          "block_id": "...",
          "start": 120,
          "end": 254,
          "page_start": 7,
          "section": "Experiments"
        }
      ]
    }
  ],
  "limitations": [
    "The paper reports this result only on the stated benchmark."
  ],
  "provenance_id": "..."
}
```

### 10.4 Validation

Server verifies:

- block belongs to requested paper/generation;
- offsets match text;
- evidence was in retrieved context;
- each material claim has evidence or is removed;
- model did not cite arbitrary paper IDs/URLs;
- output size and schema limits;
- policy permits serving cited content.

### 10.5 UI

- answer first, but evidence chips immediately visible;
- tap evidence scrolls to exact block and highlights range;
- `Direct` versus `Inferred` label;
- `Not found in this paper` is a normal answer state;
- feedback asks about evidence correctness, not generic thumbs alone;
- disclaimer is contextual and unobtrusive, not a blanket wall of text.

### 10.6 Thread memory

Conversation history may help follow-up questions, but retrieval remains paper/generation scoped. Summarize or truncate prior turns without losing source constraints. Do not let an earlier hallucination become evidence for a later answer.

### 10.7 Cost controls

- cache deterministic starter answers only when paper/model/schema match;
- use retrieval before generation;
- route simple definition/extraction requests to smaller models when evaluated;
- cap context and output;
- rate limits and quotas;
- record per-capability cost metrics.

---

## 11. Annotation and note experience

### 11.1 Selection flow

User selects text and sees:

- Highlight;
- Add note;
- Ask;
- Save evidence;
- Copy/share quote subject to policy;
- Define term.

Selection mode temporarily disables horizontal pager gestures until dismissed.

### 11.2 Annotation body

Notes support plain text first. Defer rich markdown until cross-platform selection, export, and security are tested.

### 11.3 Anchor model

Use a practical W3C Web Annotation-inspired selector:

```json
{
  "source": {
    "paper_id": "...",
    "generation": 3,
    "block_id": "..."
  },
  "selector": {
    "type": "TextQuoteAndPosition",
    "exact": "...",
    "prefix": "...",
    "suffix": "...",
    "start": 100,
    "end": 180
  }
}
```

### 11.4 Synchronization

- optimistic local creation;
- UUID generated on client;
- idempotent PUT/POST;
- revision/tombstone sync;
- body conflict produces both versions or explicit merge UI; never silently overwrite two edited note bodies;
- highlight-only conflicts can use last accepted revision;
- account separation and local encryption decision documented.

### 11.5 Re-anchoring

On new generation:

1. exact quote in equivalent stable block;
2. quote + prefix/suffix within section;
3. fuzzy match with high threshold;
4. uncertain/orphaned state.

User can review and manually reattach. Old source remains identifiable.

### 11.6 Annotation export

At minimum:

- Markdown with citation metadata;
- JSON with selectors/provenance;
- CSL/BibTeX entry alongside notes;
- later Zotero note/highlight export in Plan 05.

---

## 12. Research memory

### 12.1 Intent

Research memory means recovering user-created understanding, not maximizing review streaks. It is a separate intentional workflow, not an alternate recommendation feed and not evidence that the active To-Read queue is empty.

Opening a memory item may navigate to its source paper even when that paper is Reviewed/Archived. This is explicit user-owned resurfacing; it must not append the paper to automatic queue navigation or change Library state unless the user chooses `Add back to To Read`.

### 12.2 Eligible memory sources

- explicit `Remember this` highlight;
- user note;
- user-reviewed evidence card;
- user-reviewed Passport field;
- unresolved question the user marked for later;
- new version affecting a saved annotation.

### 12.3 Review forms

- show quote, ask `Why did you save this?` then reveal note;
- show user question, ask for recall, then reveal source-linked answer;
- show a claim and ask which paper/evidence supported it;
- show new paper link to an older note.

Do not auto-generate trivia from arbitrary paper text.

### 12.4 Scheduling

Start rule-based and user-controlled:

- review later today/tomorrow/week/custom;
- snooze;
- retire;
- project-triggered resurfacing;
- no mandatory spaced-repetition algorithm.

A future adaptive scheduler requires evidence that it improves utility without creating burden. Memory scheduling must not be used to bypass queue-first feed eligibility or to infer that a paper is Reviewed.

### 12.5 Privacy and queue separation

Memory content stays private, is exportable/deletable, and is excluded from general recommendation training. `memory_items.status` is independent of Library state. Retiring a memory item does not archive a paper; reviewing a memory item does not mark a paper Reading/Reviewed; only explicit Library mutations change active queue membership.

---

## 13. Version diff

### 13.1 Product behavior

When a new arXiv version is detected, show:

- metadata changes;
- added/removed/modified sections;
- changed Passport fields;
- changed figures/tables where detectable;
- annotation anchor status;
- new/removed references;
- a warning that parser changes can create apparent differences.

### 13.2 Diff pipeline

1. retain normalized block hashes for previous/current generations under policy;
2. align section trees;
3. match blocks by stable key/content similarity;
4. compute text diff;
5. classify added/removed/modified/moved;
6. compare visual object hashes/captions;
7. compare Passport fields and evidence;
8. store diff artifact with parser versions;
9. surface only after validation thresholds.

### 13.3 Data model

`paper_version_diffs`:

- paper ID;
- from/to generation and arXiv versions;
- algorithm/schema version;
- status;
- summary JSON;
- created timestamp.

`paper_version_diff_items`:

- kind;
- old/new object IDs;
- change type;
- similarity;
- diff payload;
- confidence status.

### 13.4 Guardrails

- label parser-induced uncertainty;
- do not infer author intent;
- link to both original versions where available;
- do not migrate annotations automatically below threshold.

---

## 14. API contract

This plan does not introduce an alternate feed or next-paper endpoint. Automatic paper selection continues through Plan 02's `GET /v1/me/reading-feed`, its account/library revision fence, and its mobile queue-authority policy. Reader APIs operate on the selected paper only.

Checkpoint APIs never mutate Library state implicitly. Explicit state transitions use the canonical Library API and then refresh/reconcile the reading-feed session.

### 14.1 Document

```text
GET /v1/papers/{paper_id}/document/outline
GET /v1/papers/{paper_id}/document/blocks?cursor=&section=
GET /v1/papers/{paper_id}/figures
GET /v1/papers/{paper_id}/figures/{figure_id}
GET /v1/papers/{paper_id}/tables
GET /v1/papers/{paper_id}/tables/{table_id}
GET /v1/papers/{paper_id}/equations
GET /v1/papers/{paper_id}/terms?block_id=
```

All responses include generation and provenance summary.

### 14.2 Passport

```text
GET  /v1/papers/{paper_id}/passport
POST /v1/papers/{paper_id}/passport/feedback
```

### 14.3 Assistant

```text
POST /v1/papers/{paper_id}/assistant
GET  /v1/assistant/provenance/{provenance_id}
```

Retain old `/chat` endpoint during transition. Add new schema under a versioned route or content type, then deprecate safely.

### 14.4 Annotations

```text
GET    /v1/annotations?paper_id=&after_revision=
PUT    /v1/annotations/{annotation_id}
DELETE /v1/annotations/{annotation_id}
POST   /v1/annotations/{annotation_id}/reanchor
GET    /v1/annotations/export
```

### 14.5 Evidence cards

```text
GET    /v1/evidence-cards?paper_id=&cursor=
PUT    /v1/evidence-cards/{id}
DELETE /v1/evidence-cards/{id}
```

### 14.6 Checkpoints and memory

```text
GET /v1/reading/checkpoints
PUT /v1/reading/checkpoints/{paper_id}
GET /v1/memory/review?cursor=
PUT /v1/memory/items/{id}
POST /v1/memory/items/{id}/review
```

### 14.7 Version diff

```text
GET /v1/papers/{paper_id}/versions
GET /v1/papers/{paper_id}/version-diff?from=&to=
```

---

## 15. Mobile implementation structure

```text
mobile/lib/features/reader_modes/
  reader_mode.dart
  reader_mode_controller.dart
  reader_mode_selector.dart

mobile/lib/features/document_reader/
  document_screen.dart
  document_controller.dart
  queue_navigation_coordinator.dart
  reader_entry_context.dart
  section_outline_sheet.dart
  block_renderer.dart
  inline_span_renderer.dart
  source_evidence_sheet.dart
  selection_toolbar.dart

mobile/lib/features/passport/
  paper_passport_card.dart
  paper_passport_sheet.dart
  passport_controller.dart

mobile/lib/features/semantic/
  facet_controller.dart
  faceted_text.dart
  definition_sheet.dart

mobile/lib/features/visual_objects/
  figures_gallery.dart
  figure_card.dart
  table_view.dart
  equation_view.dart

mobile/lib/features/annotations/
  annotations_controller.dart
  annotation_editor.dart
  annotation_list.dart
  orphaned_annotations_screen.dart

mobile/lib/features/evidence/
  evidence_card_editor.dart
  evidence_cards_screen.dart

mobile/lib/features/memory/
  memory_review_screen.dart
  memory_controller.dart

mobile/lib/features/version_diff/
  version_diff_screen.dart
  version_diff_controller.dart

mobile/lib/core/models/
  document_block.dart
  paper_passport.dart
  semantic_span.dart
  annotation.dart
  evidence_card.dart
  provenance.dart
```

### 15.1 Queue navigation coordinator

The reader does not own feed eligibility. `queue_navigation_coordinator.dart` consumes Plan 02's account-scoped `ReadingFeedState` and performs only navigation-safe operations:

- identify whether the current paper came from queue, eligible recommendation batch, Library, search, Connections, or memory;
- request the next queue page through the reading-feed repository;
- reject stale cursor/library revisions;
- observe pending saves/imports and account/auth epoch;
- cancel recommendation next-paper intent after any save;
- enter checking state after final active-item transition;
- return explicit branches to their origin without mutating the feed;
- never synthesize queue emptiness from reader progress/checkpoints.

`DocumentController` may request content for the current paper but cannot query a recommendation source directly.

### 15.2 Local database additions

Mirror server entities needed offline:

- document outline and blocks;
- visual metadata and bounded asset cache;
- Passport fields;
- term definitions;
- annotations;
- evidence cards;
- checkpoints;
- memory items;
- version diff summaries;
- provenance metadata.

Do not mirror a second Library-state authority in reader tables. Read queue state from the existing account-scoped Library/reading-feed stores. A cached `library_state` shown alongside a checkpoint is only a projection and must reconcile against the canonical revision.

### 15.3 Asset cache

- separate budget from metadata database;
- generation-aware paths;
- LRU with pins for current/saved/evidence-linked objects;
- clear private assets on account cleanup;
- strict-policy handling;
- checksum validation;
- asset presence must not make an inactive paper appear in the automatic queue.

### 15.4 Reader performance

- virtualize long block lists;
- keep stable keys;
- avoid one widget per character span;
- precompute span segments;
- lazy-load visual objects;
- preserve selection and scroll anchors;
- benchmark large papers on supported low-end devices;
- cancellation of late document requests must not repopulate a reader after account/paper switch;
- vertical preloading may warm only already-authorized active queue metadata, never trigger PDF-derived work.

### 15.5 Save and state transitions inside the reader

For an active queue item:

- `Reading`, `Reviewed`, `Archived`, and remove actions call the canonical Library mutation path;
- reaching the end never calls those actions automatically;
- pending mutation overlays UI immediately and updates queue authority;
- final active-item transition enters checking until server confirmation.

For an eligible recommendation/search/connection paper:

- `Add to To Read` defaults to Inbox;
- local intent immediately cancels recommendation auto-advance;
- any server failure retains a visible pending/retry state;
- an unsupported/terminal import removes only the placeholder, not unrelated queue data.

---

## 16. Offline behavior

Available offline when cached and policy permits:

- paper metadata/abstract;
- document blocks;
- Passport;
- visual derivatives;
- definitions;
- annotations/notes/evidence cards;
- checkpoints/memory queue;
- version diff summary;
- safely account-scoped active queue items and pending Library mutations.

Unavailable offline initially:

- new assistant generation;
- uncached object extraction;
- server-side re-anchoring;
- uncached full PDF;
- authoritative confirmation that an apparently empty queue is truly empty;
- new recommendation pages unless the product has an explicitly approved, still-valid empty-revision cache policy. The default is to fail closed.

Offline reader rules:

- continue reading the current cached paper;
- auto-advance only to another safely cached active queue item;
- a pending save/import suppresses recommendations;
- completing/removing the apparent last item does not unlock cached recommendations;
- show `Queue verification requires connection` when no active item remains locally but server authority is unavailable;
- explicit memory/search/connection branches may reopen cached papers without altering automatic feed state.

Offline assistant UI states that cached evidence can be read, but a new answer requires connection. Do not generate an ungrounded fallback.

---

## 17. Security and privacy

### 17.1 Authorization

Every private artifact is authorized by user ID. Never accept a user ID from request body as authority.

### 17.2 Content handling

- note bodies encrypted in transit and protected at rest by infrastructure controls;
- evaluate local database encryption needs and platform threat model;
- exclude notes from logs/crash reports;
- sanitize Markdown/links if rich text is later enabled;
- asset endpoints validate paper, generation, object, and policy.

### 17.3 Export/delete

Account export includes:

- annotations and selectors;
- notes;
- evidence cards;
- checkpoints and memory settings;
- provenance references;
- library metadata.

Deletion removes/tombstones synchronized copies and queued jobs, subject to documented backup and audit retention.

### 17.4 Copyright and quoting

- annotations may contain source quotes; exports must include source metadata;
- avoid exporting entire reconstructed papers as a convenience feature without rights review;
- enforce reasonable quote/export boundaries where required;
- always link to original.

---

## 18. Evaluation program

### 18.1 Parser evaluation

Metrics:

- block order accuracy;
- section tree accuracy;
- citation link precision/recall;
- visual object extraction precision/recall;
- table structure accuracy;
- equation representation availability;
- text corruption rate;
- processing latency/memory;
- terminal/retryable failure distribution.

### 18.2 Passport evaluation

For each field:

- evidence precision;
- field correctness;
- missing-field abstention;
- inference-label correctness;
- contradiction handling;
- model/schema stability.

Use human review by domain-capable reviewers. Do not evaluate solely with another LLM.

### 18.3 Assistant evaluation

Question sets include:

- direct fact;
- method detail;
- result comparison;
- limitation;
- unsupported question;
- ambiguous question;
- figure/table question;
- equation/symbol question;
- adversarial prompt in paper text;
- stale generation;
- conflicting evidence.

Metrics:

- retrieval relevance;
- citation precision;
- claim faithfulness;
- completeness;
- abstention precision/recall;
- unsupported citation count;
- evidence navigation success;
- latency/cost.

### 18.4 Reading effectiveness research

Run a small, ethically reviewed product study before claiming comprehension benefits:

- compare plain reconstructed reading with restrained semantic enhancement;
- measure method/result/limitation recall and source verification;
- measure concentration and interruption;
- record whether AI causes overconfidence;
- include novice and experienced readers;
- avoid optimizing based only on subjective speed.

### 18.5 Annotation evaluation

- exact re-open;
- app restart;
- text reflow;
- parser patch;
- paper version update;
- Unicode/math selections;
- overlapping annotations;
- offline concurrent edits;
- export/import fidelity;
- orphan review.

### 18.6 Accessibility evaluation

- screen reader block navigation;
- semantic math alternatives;
- figure alt text labels and source status;
- table navigation;
- selection toolbar accessibility;
- text scale 2.0;
- reduced motion;
- switch/keyboard navigation where supported;
- color contrast and non-color facet cues.


### 18.7 Queue-safe reader navigation evaluation

Test:

- active queue auto-advance selects only active items;
- recommendation save cancels remaining recommendation navigation immediately;
- final-item Reviewed/Archived/remove waits for server-confirmed emptiness;
- end-of-document does not mark Reviewed;
- checkpoint writes do not change Library state;
- account switch rejects old reader/feed responses;
- stale library cursor returns to page one without mixed content;
- offline unknown state shows no recommendation fallback;
- explicit Connections/search/memory navigation returns to origin and does not mutate the feed;
- abstract rendering does not enqueue PDF/Passport/visual preparation;
- committed Introduction transition enqueues at most one idempotent preparation job.

The release target for automatic recommendation leakage during nonempty/unknown/pending queue state is zero.

---

## 19. Observability

Metrics:

- parser success/failure by adapter/version/document class;
- block/figure/table/equation counts and anomaly distributions;
- preparation requests by approved trigger kind;
- rejected preparation enqueue attempts from feed/import/prefetch, target all rejected;
- Passport ready/partial/not-found rates by field;
- assistant retrieval/answer latency and cost;
- validated evidence count;
- abstention and unsupported-output rejection;
- provenance lookup;
- annotation sync conflict and orphan rate;
- re-anchoring success by strategy;
- document cache hit/eviction/size;
- visual asset delivery errors;
- version-diff completion and uncertainty;
- memory item creation/review/retire without streak optimization;
- reader entry context distribution;
- queue auto-advance success and stale-cursor recovery;
- recommendation auto-advance cancelled after save;
- end-of-document Library mutation attempts, expected zero unless user explicitly acts;
- time in final-item checking state;
- recommendation leakage while queue active/unknown/pending, target zero;
- policy denial rates.

Logs may contain opaque paper/artifact IDs, generation, queue/library revision, entry-context code, and safe failure class. They must not contain paper text, private notes/annotations, raw search/import input, or account identifiers.

Alert on sudden changes after parser/model releases and on any confirmed queue-policy violation.

---

## 20. Implementation phases

### Phase 0 — Queue integration verification

1. Verify aligned Plan 02 reading-feed API, Library states, revision fencing, and mobile queue-authority interfaces.
2. Add reader entry-context and queue-navigation contracts.
3. Remove/avoid any reader-owned `reading/reviewed` state authority.
4. Add automatic-next-paper and final-item checking fixtures.
5. Add preparation-trigger audit so feed/import/prefetch cannot enqueue deep work.

Do not begin reader feature rollout if queue-first invariants are not executable in tests.

### Phase A — Document block model

1. Add schema and domain types.
2. Adapt GROBID normalization.
3. Backfill curated corpus.
4. Add outline/block APIs.
5. Build mobile virtualized block reader.
6. Preserve existing Introduction endpoint compatibility.
7. Establish parser benchmark baseline.
8. Require an approved explicit preparation trigger on enqueue.

### Phase B — Reader modes and source navigation

1. Add mode state/restoration.
2. Add Skim/Read/Inspect presentation.
3. Add outline and exact source navigation.
4. Implement selection gesture arbitration.
5. Add queue navigation coordinator.
6. Add explicit-branch return behavior for Search/Connections/Memory.
7. Add accessibility/performance tests.

### Phase C — Passport and semantic facets

1. Add passport schema and worker.
2. Build strict output/evidence validation.
3. Add compact/full UI without abstract-stage hidden preparation.
4. Add field feedback.
5. Add term/facet extraction and definition sheet.
6. Run manual evaluation before broad rollout.

### Phase D — Visual objects

1. Extend parser adapter.
2. Add figures first.
3. Add tables with structured/plain views.
4. Add equations and context.
5. Add object-scoped assistant retrieval.
6. Benchmark asset storage and device performance.

### Phase E — Evidence-first assistant v2

1. Add new request/response schema.
2. Validate claim/evidence mappings.
3. Add provenance records.
4. Build source navigation from answer.
5. Migrate starter questions.
6. Maintain old chat endpoint during compatibility window.
7. Run adversarial and method/detail evaluation.

### Phase F — Annotations and evidence cards

1. Add server/local schemas.
2. Implement selection toolbar.
3. Implement outbox and conflict behavior.
4. Add evidence cards.
5. Add export.
6. Add re-anchoring baseline.

### Phase G — Checkpoints, canonical state transitions, and memory

1. Add position-only reading checkpoints.
2. Integrate explicit canonical Library state transitions.
3. Prove checkpoint writes cannot alter queue membership.
4. Add user-selected memory items.
5. Add snooze/retire/review.
6. Keep memory navigation separate from automatic feed.
7. Evaluate burden and usefulness.

### Phase H — Version diff

1. Retain comparable normalized artifacts under policy.
2. Add alignment/diff worker.
3. Add annotation re-anchoring across versions.
4. Build diff UI.
5. Add queue-aware update notifications.

### Phase I — Parser adapter experiment

1. Implement Docling adapter behind flag.
2. Run benchmark.
3. Compare quality/cost.
4. Decide keep experimental, use selectively, or adopt through ADR.
5. Never switch default without rollback and reprocessing plan.

### Phase J — Stabilization

1. privacy/export/deletion review;
2. content-rights review;
3. cache/storage stress tests;
4. parser/model release dashboards;
5. queue-navigation concurrency and offline tests;
6. OpenAPI/client compatibility;
7. docs/runbooks/evaluation report;
8. staged rollout and rollback.

---

## 21. Detailed acceptance scenarios

### 21.1 Honest skim

- user sees Passport contribution/method/result only if already prepared;
- each field has evidence;
- limitation is `not_found` rather than invented;
- UI says generated from full paper version X;
- original opens in one action;
- merely opening the Abstract did not enqueue preparation.

### 21.2 Method inspection

- user commits to Introduction/Inspect;
- one idempotent preparation path runs if needed;
- opens method facet;
- sees exact method blocks and relevant figure/table;
- asks a question;
- answer cites exact passages;
- unsupported extension is labeled inferred or not found.

### 21.3 Definition without losing place

- user taps a term;
- sheet shows current-paper definition;
- closes sheet;
- reading position and selection persist;
- horizontal pager did not move.

### 21.4 Offline annotation

- user highlights and notes offline;
- app terminates;
- note restores;
- reconnect syncs idempotently;
- second device sees it;
- body never appeared in telemetry.

### 21.5 Concurrent note edit

- two devices edit same note;
- server detects revision conflict;
- client preserves both versions and prompts merge;
- no silent loss.

### 21.6 New paper version

- newer arXiv version arrives;
- old derived content becomes stale per generation;
- diff job runs;
- annotations re-anchor or show uncertain/orphaned;
- user can inspect both sources;
- no annotation silently moves to unrelated text.

### 21.7 Parser failure

- text extraction is unreliable;
- metadata/abstract remain available;
- Passport and document capabilities show unavailable;
- user can open original;
- no arbitrary fallback section is presented as Introduction.

### 21.8 Prompt injection

- paper contains text instructing an AI to ignore rules;
- assistant treats it as quoted data;
- output schema/evidence rules remain enforced;
- evaluation records success.

### 21.9 Visual object uncertainty

- parser extracts caption but image association is uncertain;
- UI does not show the wrong figure;
- object status explains extraction limitation;
- original page action remains.

### 21.10 Memory review

- user marks a note `Remember this`;
- review later shows their note/quote;
- no arbitrary generated quiz;
- user retires item permanently;
- paper Library state is unchanged;
- no streak pressure.

### 21.11 Queue-only auto-advance

- active queue has papers A and B;
- user reads A to the end without changing state;
- A remains active;
- next automatic paper, when chosen, is B or another active queue item according to Plan 02 order;
- no recommendation card appears.

### 21.12 Save from recommendation fallback

- server-proven empty queue allows recommendation R;
- user taps Add to To Read;
- local pending save cancels remaining recommendation pagination/auto-advance immediately;
- R becomes Inbox after acknowledgement;
- reader/feed enters queue mode;
- late recommendation responses are discarded.

### 21.13 Final active paper

- user explicitly marks the last active paper Reviewed;
- reader enters a checking/finishing state;
- no cached recommendation appears;
- Library mutation is acknowledged and revision advances;
- fresh reading-feed response proves zero active items;
- recommendation fallback may then begin.

### 21.14 Explicit connection branch

- user opens a cited paper not in To Read from Connections;
- UI labels it as outside the active queue and offers Add to To Read;
- back returns to the original paper/position;
- no automatic feed insertion occurred;
- saving it immediately activates queue mode.

### 21.15 Offline queue uncertainty

- user finishes/removes the apparent last cached active item offline;
- checkpoint/state mutation remains pending;
- UI says queue verification requires connection;
- no cached recommendation auto-advance occurs;
- reconnect synchronizes and rechecks before fallback.

### 21.16 Checkpoint authority

- user saves a checkpoint and changes Skim/Read/Inspect mode;
- Library state does not change;
- recommendation eligibility is unchanged;
- explicit `Mark Reviewed` uses the Library API and then reconciles queue state.

---

## 22. Release gates

v0.2 is not complete until:

- GROBID-to-block migration preserves existing demo capabilities;
- representative parser benchmark is published internally;
- no feed/import/prefetch/abstract-display path can enqueue PDF/document processing;
- committed Introduction/explicit prepare produces idempotent bounded work;
- Passport evidence precision and missing-field abstention pass thresholds;
- assistant has zero known acceptance of invented evidence IDs;
- unsupported citation rate is below release threshold;
- method/detail question quality is not worse than the current baseline;
- annotations survive restart/reflow and have explicit version behavior;
- concurrent note edits cannot silently lose data;
- visual objects meet extraction precision thresholds before default enablement;
- source navigation works from every generated artifact;
- private content is absent from general telemetry and recommendation inputs;
- reading checkpoints cannot mutate Library state or queue eligibility;
- reaching document end does not automatically mark Reviewed;
- active queue auto-advance returns only active queue items;
- saving a recommendation suppresses recommendation navigation immediately;
- final-item transition waits for server-confirmed emptiness;
- unknown/stale/offline/account-transition queue state never falls back to recommendations;
- explicit Search/Connections/Memory navigation does not inject papers into the automatic feed;
- strict content policy behavior passes;
- large-document device performance and accessibility pass;
- parser/model and queue-navigation release/rollback procedures are tested.

---

## 23. Handoff contract to Plan 04

Plan 04 may assume:

- normalized, source-linked document blocks;
- versioned Passport fields;
- figures/tables/equations as addressable objects;
- private annotations and evidence cards;
- evidence-first assistant schema;
- provenance records;
- robust Library and topic/search layers;
- position-only reading checkpoints;
- canonical Library state as the sole active-queue authority;
- queue-safe automatic navigation through `GET /v1/me/reading-feed`;
- explicit branch navigation that does not mutate the feed;
- paper version diffs;
- parser and model evaluation infrastructure;
- demand-driven preparation that cannot be triggered by feed/import/prefetch.

Plan 04 will combine these objects across multiple papers into projects, extraction schemas, claims, comparisons, and auditable agent runs. It must preserve claim-level source linkage and human verification states. Project workflows may intentionally select papers, but they must not silently rewrite personal Library state or bypass the queue-first Read feed.

---

## 24. Final implementation principle

The reader is successful when semantic assistance makes it easier to locate and verify meaning without fragmenting attention. Depth features may expand what can be learned from the current paper, but they must never weaken the user's control over which paper comes next: automatic progression remains anchored to active To Read until the queue is explicitly cleared and authoritatively confirmed empty.
