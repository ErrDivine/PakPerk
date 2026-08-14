# Pakperk

Pakperk is a phone-first arXiv reader built around one interaction: read an
abstract, swipe left into a parsed Introduction with paper-grounded chat, then
swipe left again into understandable links to important references.

The current demo baseline deliberately stays narrow:

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

For day-to-day work, start with the [developer guide](docs/developer-guide.md).
For product behavior, privacy, safety, deletion, and troubleshooting, use the
[user guide](docs/user-guide.md).

## Production migration status

Phases 0–5 are complete and accepted. The Phase 6 repository implementation is
present as a dark-launch candidate; live restore, deployment,
physical-device, signing/store, performance, crash-window, and legal approvals
remain external release blockers. Phase 3 OIDC account integration is
[accepted](docs/phase-reports/phase-3.md), and Phase 4 To Read synchronization
is [accepted](docs/phase-reports/phase-4.md) with its exact server/mobile
contract in [the To Read synchronization document](docs/library-sync.md).
Phase 5 adds the complete default-off public-comment safety boundary, with
separate comment reporting, user reporting, and blocking actions; its
contract and acceptance evidence are in
[Comments and moderation](docs/comments-and-moderation.md) and the
[Phase 5 report](docs/phase-reports/phase-5.md).
The backend has safe extension seams,
typed deployment configuration, a checked code-first OpenAPI contract,
conditional feed responses, and the accepted Phase 3 account/authentication
foundation.
The mobile app has a persistent Read/You shell, exact paper and arXiv links,
light/dark design tokens, native launch assets, a bounded cached-first opening
transition, a relational cache-ahead feed, and the account session/onboarding
foundation plus an offline-first synchronized To Read list, account-scoped
comment drafts/pages/blocks, and guest/authenticated discussion surfaces.
Account, library, comment, and deletion controls remain off by default. The
recent-auth deletion API/mobile/web flow, dedicated provider-deletion worker,
independent signed restore ledger, hosted policy/support site, validating mobile
telemetry gateway, OTLP deployment, Helm topology, security/SBOM jobs, signed
candidate workflow, and operational runbooks are implemented. The
[Phase 6 report](docs/phase-reports/phase-6.md) distinguishes repository evidence
from the public/store/deployed evidence that is still required.
The opt-in [backend staging load runbook](docs/runbooks/backend-load-testing.md)
defines the bounded, redacted HTTP latency gate and its mobile-only limitations.

The accepted Phase 4 API uses authenticated list/change/save/remove routes with durable
operation IDs, server revisions, removal tombstones, and an independent
read-only kill switch. Its exact synchronization and preparation boundaries
are documented in [the To Read contract](docs/library-sync.md). Both library
flags remain off by default so deployments can dark-launch the capability.

Phase 5 keeps flat paper comments in the same backend and PostgreSQL database.
It requires an active account, handle, and current Terms/Community Guidelines
before posting; applies bounded normalization, deterministic rules,
provider-neutral moderation, shared account/origin limits, distinct repeat-safe
comment and user reports, durable blocking, and audited moderator actions; and
never places comment/report text in ordinary diagnostics. Reporting does not
hide content or create a block, and blocking does not create a report. The
operator CLI requires a recently authenticated OIDC identity whose local user
UUID is in the deployment's explicit admin allowlist. `COMMENTS_ENABLED`
registers the surface, while
`COMMENT_CREATION_ENABLED` can stop only new publication without disabling
reading, author removal, reporting, blocking, or moderation. Public deployment
must keep creation off until its deletion, moderation, telemetry, legal,
restore, and store-review evidence is approved.

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
./scripts/prepare_dev_api_origin_secret.sh
docker compose up -d --build
```

The preparation step creates separate owner-only request-origin and rotating
cursor-encryption key files; it never prints or overwrites their values.

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

### Optional local OIDC accounts

Start the application PostgreSQL database, the pinned development Keycloak
realm with its separate PostgreSQL database, and Mailpit without making them
prerequisites for paper-only development:

```bash
docker compose --profile accounts up -d postgres keycloak
```

The realm issuer is `http://localhost:8081/realms/pakperk`, the public native
client is `pakperk-mobile-dev`, and verification mail is visible at
`http://localhost:8025`. Set `ACCOUNTS_ENABLED=true` plus the OIDC/profile
values in `.env.example` only for an API process that can reach that exact
issuer. For the reference topology, run the API on the host (and do not also
start the Compose `api` service):

```bash
./scripts/prepare_dev_account_secrets.sh
set -a
source .env
set +a
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_ORIGIN_HASH_SECRET_FILE="$PWD/.local/pakperk-secrets/API_ORIGIN_HASH_SECRET" \
API_CURSOR_ENCRYPTION_KEYS_FILE="$PWD/.local/pakperk-secrets/API_CURSOR_ENCRYPTION_KEYS" \
ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$PWD/.local/pakperk-secrets/ACCOUNT_IDENTITY_FINGERPRINT_KEYS" \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

The host process is intentional: `localhost` inside the Compose API container
would refer to that container, not to host-published Keycloak, and substituting
a container hostname would change the token issuer. Guest routes continue to
serve if the provider later becomes unavailable; required-auth routes fail
closed.

The exact callback values, mobile build command, token-storage boundary,
profile wire contract, and Android-emulator issuer caveat are documented in
[Account authentication and profile contract](docs/account-authentication.md).
The realm itself is documented in
[the development-provider runbook](deploy/keycloak/README.md).

The reproducible Phase 5 acceptance harness starts only the missing local
Compose services, builds three independently configured APIs plus the audited
admin binary, creates disposable Keycloak users, and drives genuine
Authorization Code + S256 PKCE, comment report, user report, independent block,
authorized moderation, kill-switch, and provider-outage scenarios. It scans
captured logs and removes every fixture/identity afterward:

```bash
./scripts/test_live_comments.sh
```

The driver requires Python `requests` and `beautifulsoup4`; it deliberately
keeps credentials/tokens in memory and stores temporary state in an owner-only
directory outside the repository.

## Run the mobile app

Requirements: Flutter 3.44.8 with bundled Dart 3.12.2 for current release
evidence, plus an iOS/Android development toolchain. Another compatible SDK is
development-only evidence.

```bash
cd mobile
flutter pub get --enforce-lockfile
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080
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

Phase 3 uses Authorization Code with PKCE in the system browser. Access tokens
remain in memory, while refresh/session material is stored only in the platform
secure store. Concurrent refresh is single-flight, a challenged request is
replayed at most once under an explicit safety policy, and sign-out clears only
account-owned data; the public Drift cache and reader restoration remain.

With comments compiled in, guests may read published paper discussion and are
given an explicit sign-in rationale before a posting intent is retained.
Authenticated drafts are stored per account and paper, never auto-send, and
clear only after the server accepts a canonical comment. Pending-review content
is private to its author. Blocking filters immediately on-device and reconciles
durably across API instances/devices. A comments-enabled build must also supply
`PAKPERK_COMMENT_SUPPORT_CONTACT_URL`; staging/production require HTTPS.

The reading model is fixed:

```text
vertical: next/previous paper
horizontal: Abstract <-> Introduction <-> Connections
```

Visible stage labels and buttons are equivalents for every swipe. Preparation is
triggered only by the horizontal pager's committed transition to Introduction,
never by prebuilding that widget. Chat opens separately from the persistent
composer on the Introduction view; it is not a fourth pager stage.

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

With `ACCOUNTS_ENABLED=true`, Phase 3 additionally registers:

```text
GET   /v1/me
PATCH /v1/me
```

These operations require an OIDC bearer token. Both return a private account
envelope and strong `"profile-N"` ETag; `PATCH` requires the matching
`If-Match` value. The routes are absent when accounts are disabled.

With the corresponding default-off Phase 4–6 flags enabled, the API also
registers:

```text
GET    /v1/me/library
GET    /v1/me/library/changes
PUT    /v1/me/library/{paper_id}
DELETE /v1/me/library/{paper_id}

GET    /v1/papers/{paper_id}/comments
POST   /v1/papers/{paper_id}/comments
PATCH  /v1/comments/{comment_id}
DELETE /v1/comments/{comment_id}
POST   /v1/comments/{comment_id}/reports
POST   /v1/users/{user_id}/reports
GET    /v1/me/comments
GET    /v1/me/blocked-users
PUT    /v1/me/blocked-users/{user_id}
DELETE /v1/me/blocked-users/{user_id}
DELETE /v1/me
GET    /v1/me/deletion-verification
```

Library, personalized comment, and deletion responses are private/no-store.
Library mutations use an `Idempotency-Key`; comment creation carries a durable
client request ID in its strict JSON body, while each report or block has a
canonical account/target identity that makes duplicate retries converge.
Comment/user reporting and blocking are independent operations: a report does
not change visibility and a block does not submit a moderation report. Deletion
routes register only when
`ACCOUNT_DELETION_ENABLED=true`; every `DELETE /v1/me` attempt, including a
replay, requires recent authentication, while deletion verification accepts any
currently valid access token. The durable worker/ledger/provider configuration
must pass startup.

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

Account-aware CORS permits `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, and
`OPTIONS`; allows `Authorization`, `Content-Type`, `X-Session-Id`,
`X-Request-Id`, `Idempotency-Key`, `If-Match`, and `If-None-Match`; and exposes
`X-Request-Id`, `ETag`, and `Retry-After` to explicit deployed origins.

Feed pagination uses a purpose/category-bound authenticated-encryption cursor
backed by `(published_at, paper_id)`; ordering fields are never exposed to or
accepted from clients as readable JSON.
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
# Change the suffix for every run; this database must not already exist.
docker compose exec -T postgres \
  createdb -U pakperk pakperk_test_local_run_01
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk_test_local_run_01 \
  cargo test --manifest-path backend/Cargo.toml --locked --workspace --all-features
docker compose exec -T postgres \
  dropdb -U pakperk pakperk_test_local_run_01
```

Without `TEST_DATABASE_URL`, the PostgreSQL behavior test returns early; all
pure unit, fixture, HTTP-boundary, and widget tests still run. The URL must
always name a separate disposable test database, never the persistent
development database named `pakperk`. Choose a new `pakperk_test_local_*` name
for every run. If a run is interrupted before cleanup, leave that target alone
and use another fresh name. Account-deletion binaries serialize their global
queue claims and reject unfinished residue; never let a later test claim an
abandoned job.

The repository architecture, generation rules, and trust boundaries are
summarized in [`docs/architecture.md`](docs/architecture.md).
