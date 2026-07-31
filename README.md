# Pakperk

Pakperk is a phone-first arXiv reader built around one interaction: read an
abstract, swipe left into a parsed Introduction with paper-grounded chat, then
swipe left again into understandable links to important references.

The currently released demo behavior deliberately stays narrow:

- Flutter client for iOS and Android.
- Rust/Axum API and Tokio worker.
- PostgreSQL 16 with pgvector and a PostgreSQL-leased job queue.
- GROBID for scholarly PDF structure.
- arXiv only, with one global cached/rate-limited backend client.
- Anonymous device sessions and provider-neutral model configuration.

The preserved demo requirements remain in
[`pakperk_demo_implementation_plan.md`](pakperk_demo_implementation_plan.md).
The active production migration is governed by the authoritative
[`Production v0.0 implementation plan`](pakperk_production_v0_0_implementation_plan.md)
and its [documentation entrypoint](docs/production-v0.0-plan.md).

## Production migration status

Phases 0, 1, and 2 are complete. The backend has safe extension
seams, typed deployment configuration, a checked code-first OpenAPI contract,
and conditional feed responses. The mobile app has a persistent Read/You shell,
exact paper and arXiv links, a guest You surface, light/dark design tokens,
native launch assets, a bounded cached-first opening transition, and a
relational cache-ahead feed. Accounts, library, and comments remain off until
their complete later phases—including safety and policy gates—land.

The demo baseline is frozen at the annotated `production-v0.0-baseline` tag.
Architecture choices for OIDC, Drift, stateful navigation, comments, and shared
rate limiting are recorded in [`docs/adr/`](docs/adr/).
Phase evidence is recorded under [`docs/phase-reports/`](docs/phase-reports/).

## Run the backend

Requirements: Docker with Compose v2. The pinned local stack uses PostgreSQL 16
with pgvector 0.8.2 and the CPU-friendly GROBID 0.9.0 CRF image.

```bash
cp .env.example .env
# Edit .env and replace ARXIV_CONTACT_EMAIL with a monitored, real address.
docker compose up -d --build
```

Both Rust processes deliberately reject placeholder or example-domain contact
addresses so that every arXiv request has an accountable `User-Agent`.

The API migrates a clean database on startup:

```text
GET http://localhost:8080/health/live
GET http://localhost:8080/health/ready
```

`/health/live` only proves that the process is running. `/health/ready` checks
the dependencies needed to serve cached content. GROBID or a model provider can
be unavailable while already-prepared papers remain readable.

## Run the mobile app

Requirements: a current stable Flutter SDK and an iOS/Android development
toolchain.

```bash
cd mobile
flutter pub get
flutter run --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080
```

Use `http://10.0.2.2:8080` from an Android emulator. The app starts with its
bundled cache when the API cannot be reached, then refreshes in place when
connectivity returns.

Bulk feed, paper, processing, Introduction, Connections, and anonymous-chat
content now lives in the versioned Drift database `pakperk_content.sqlite`.
SharedPreferences retains only small identity/restoration state after a
transactional one-time import of valid legacy cache blobs. Strict-policy builds
mask metadata and do not retain derived fallback content.

The feed caches exact category/limit queries and conditionally revalidates their
first pages with ETags. Committed vertical page changes keep 2 papers behind and
6 ahead readable, fetch when 10 remain, and target 60 durable papers ahead. The
default cache bounds are 500 metadata rows, 64 MiB, and a 7-day metadata TTL.
Prefetch is compile-time limited to feed requests: it never prepares a paper or
calls processing, Introduction, chat, Connections, arXiv, PDF, or model
providers. See the [Phase 2 report](docs/phase-reports/phase-2.md) for the
implementation and current verification record.

Native mobile builds compile the audited official SQLite 3.53.3 amalgamation
vendored under `mobile/third_party/sqlite` through the pinned `sqlite3` package
source hook. This keeps Android and iOS builds reproducible without fetching a
precompiled SQLite binary during the build.

The production shell has exactly two primary destinations: **Read** and
**You**. Read retains the current vertical paper feed and horizontal reader
stages. You is an honest guest surface until the account phase is enabled.
Supported local links and the platform-association work required before release
are documented in [`docs/mobile-app-links.md`](docs/mobile-app-links.md).

Mobile configuration is validated before general storage is opened. The
development defaults preserve the current guest reader with all production
features disabled. Staging/production builds set `PAKPERK_ENV`, an HTTPS
`PAKPERK_API_BASE_URL`, and explicit feature flags. Production additionally
requires `PAKPERK_FULLTEXT_POLICY=strict`. Account-enabled builds must provide
the native OIDC issuer/client/redirect values; client secrets and provider API
keys are rejected because they must never be compiled into the app.

The reading model is fixed:

```text
vertical: next/previous paper
horizontal: Abstract <-> Introduction + Chat <-> Connections
```

Visible stage labels and buttons are equivalents for every swipe. Preparation is
triggered only by the horizontal pager's committed transition to Introduction,
never by prebuilding that widget.

## Prepare the real demo corpus

The manifest contains six real arXiv papers. Five form the prepared
Transformer-language-model lineage (`prepared: true`); LoRA
`2106.09685v2` is deliberately metadata-only (`prepared: false`) for the final
lazy-processing demonstration. Start the stack first, then run these commands.
They use exact-ID metadata lookups and the ordinary worker pipeline:

```bash
./scripts/validate_demo_content.sh
./scripts/seed_demo.sh
./scripts/preprocess_demo.sh
./scripts/export_mobile_cache.sh
./scripts/review_demo_chat.sh
```

Set `PAKPERK_USE_DOCKER=0` to run the worker through local Cargo instead. The
commands have deliberately separate effects:

- `seed_demo.sh` upserts exact arXiv metadata for all six papers.
- `preprocess_demo.sh` runs and waits for ordinary preparation jobs only for the
  five entries marked `prepared: true`. It never queues LoRA.
- `validate_demo_content.sh` checks the five-paper labeled question and
  connection-review specification without requiring a database, then writes
  `demo/content_evaluation_structure_report.json`.
- `verify_demo.sh` writes `demo/verification_report.json` and fails if a
  required capability, expected high-confidence link, content-evaluation
  structure, persisted relationship prompt version, or lazy-paper invariant is
  missing. It also fails unless the content evaluation has complete
  `manually_evaluated` observations.
- `export_mobile_cache.sh` exports metadata for all six papers, but
  Introduction and Connections responses only for the five prepared entries.
  It also mirrors the ordinary-API feed into `demo/fallback_feed.json`.
- `review_demo_chat.sh` sends the 15 labeled questions through the real public
  chat API and writes `demo/chat_review_run.json` with raw answers, trusted
  evidence badges, and abstention diagnostics. It never edits
  `content_evaluation.json` or claims a quality label; a reviewer must inspect
  the cited chunks and transfer justified observations manually.

The verification report records paper/version/license/parser/model provenance,
Introduction paragraphs, chat chunks, resolved references, key connections, and
failed capabilities. It also records the labeled evaluation-set counts and its
result status. The checked-in `demo/content_evaluation.json` records the
completed manual review of the named release build: 15 chat cases and six
connection cases covering evidence, abstention, attribution, reference match,
relationship support, and importance. If the corpus, parser, retrieval, or
models change, reset the observed fields to `not_run`, generate a new review
artifact, and re-review every case before restoring `manually_evaluated`. The
validator requires a timestamp, model IDs, labels for every chat case, all four
connection judgments, and review notes. Run the following for an alternate
review artifact:

```bash
DEMO_CHAT_REVIEW_REPORT=/path/to/run.json ./scripts/review_demo_chat.sh
```

Compare each raw response with its embedded
`specification.evidence_requirements`, verify the source badge against the
prepared paper, and record a label only after that manual check.
The tool waits 6.1 seconds between questions to respect the API's default
10-per-minute chat limit. If the deployed limit is 30, set
`DEMO_CHAT_REVIEW_DELAY_SECONDS=2.1`.
After that review, run `./scripts/verify_demo.sh`; a successful report proves
both the five prepared papers and that LoRA still has stage `not_requested` with
no derived artifacts.

The checked-in mobile fallback uses the same public API shapes and real arXiv
metadata. Bundled explanatory content is visibly identified in the app; refresh
it with `export_mobile_cache.sh` after preprocessing for a presentation build.
It is not a separately coded demonstration screen. To exercise definition of
done step 7, navigate vertically to the final LoRA card and commit the first
left swipe. Because LoRA has metadata but no bundled Introduction or
Connections and was excluded from preprocessing, the app submits the ordinary
idempotent prepare request and displays genuine asynchronous stages. Run this
only after verification if LoRA must remain pristine for the report.

The same lazy path can be exercised noninteractively against a disposable
database copy while an API and worker are running:

```bash
PAKPERK_API_BASE_URL=http://localhost:8081 \
LAZY_TEST_REPORT=/tmp/pakperk-lazy-report.json \
./scripts/test_live_lazy_preparation.sh
```

The script requires the target LoRA row to be pristine, submits the prepare
request twice to exercise API idempotency, records progressive capability
states, and fails unless a nonempty Introduction and final Connections response
become available. The checked-in
`demo/lazy_preparation_validation.json` is the successful run from a disposable
clone of the verified release database; the release LoRA row remains pristine.

## HTTP API

All product routes are under `/v1`:

```text
GET  /v1/feed
GET  /v1/papers/{paper_id}
GET  /v1/papers/by-arxiv/{arxiv_id}
POST /v1/papers/{paper_id}/prepare
GET  /v1/papers/{paper_id}/processing
GET  /v1/papers/{paper_id}/introduction
POST /v1/papers/{paper_id}/chat
GET  /v1/papers/{paper_id}/connections
```

Development and staging also expose `GET /openapi.json`. The reviewed artifact
is checked in at [`docs/openapi-v1.json`](docs/openapi-v1.json). Regenerate and
verify it with:

```bash
./scripts/generate_openapi.sh > docs/openapi-v1.json
./scripts/check_openapi.sh
```

CI rejects generated drift and compares later artifacts with the base revision
for removed routes, operations, response codes, fields, component schemas, and
narrowed enum values.

Feed pagination uses an opaque cursor backed by `(published_at, paper_id)`.
`prepare` is atomic and idempotent for a paper generation. Capability endpoints
return a stable `CAPABILITY_NOT_READY` conflict while their independent work is
unfinished. Errors have this public shape:

```json
{
  "error": {
    "code": "CAPABILITY_NOT_READY",
    "message": "The introduction is still being prepared.",
    "retryable": true,
    "request_id": "019..."
  }
}
```

Introduction paragraphs retain an optional nested `heading`. Their optional
`citations` entries use Unicode-scalar `start`/`end` offsets and include paper
targets only after a reference has been resolved above the configured
confidence threshold; markers without such an entry remain ordinary readable
text.

Chat requests require an anonymous UUID in `X-Session-Id`. Questions are
retrieved only from the requested paper and current generation. Returned
evidence identifiers are checked against the exact chunks supplied to the model.

## Model providers

Model and embedding identifiers are environment values. `LLM_PROVIDER` selects
an adapter; no provider payload crosses into domain or API types. The default
`deterministic` adapter makes tests and local orchestration reproducible. Point
the OpenAI-compatible adapter at a supported service by setting:

```dotenv
LLM_PROVIDER=openai_compatible
LLM_BASE_URL=https://provider.example/v1
LLM_API_KEY=...
LLM_CHAT_MODEL=...
LLM_EMBEDDING_MODEL=...
EMBEDDING_DIMENSION=...
```

Provider output is parsed as a strict schema. Invented chunk IDs or citation
context IDs are discarded, and weak relationship output uses an evidence-labeled
deterministic fallback.

## Full-text policy

`FULLTEXT_POLICY=prototype` keeps PDFs transient and private for local research
or competition demonstrations. `strict` requires a compatible cached license
before derived full text is served. The API re-evaluates the policy on every
derived-content request, so cached prototype artifacts remain inaccessible
after a strict-mode restart. Both modes link to the original arXiv record;
neither exposes the cached PDF.

For a strict mobile build, pass
`--dart-define=PAKPERK_FULLTEXT_POLICY=strict` as well. Strict offline clients
retain cached metadata and original arXiv links but suppress cached or bundled
Introduction, Connections, chat answers, and derived capability flags.

Pakperk uses arXiv metadata and is not affiliated with or endorsed by arXiv.
See [`docs/content-policy.md`](docs/content-policy.md) before deploying beyond a
local demo.

## Development checks

```bash
./scripts/check.sh
```

This runs Rust formatting, Clippy, and all workspace tests, then Flutter format,
analysis, and widget tests when Flutter is installed. Database integration tests
use the Compose PostgreSQL service and a separate opt-in test URL:

```bash
docker compose up -d postgres
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk \
  cargo test --manifest-path backend/Cargo.toml --workspace --all-features
```

Without `TEST_DATABASE_URL`, the PostgreSQL behavior test returns early; all
pure unit, fixture, HTTP-boundary, and widget tests still run.

The repository architecture, generation rules, and trust boundaries are
summarized in [`docs/architecture.md`](docs/architecture.md).
