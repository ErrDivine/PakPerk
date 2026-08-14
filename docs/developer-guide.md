# Pakperk developer guide

This is the shortest safe path for developing, testing, and preparing a
Pakperk Production v0.0 candidate. The normative requirements remain in the
[Production v0.0 implementation plan](../pakperk_production_v0_0_implementation_plan.md),
and the difference between implemented source and approved release evidence is
tracked in the [completion audit](production-v0.0-completion-audit.md).

## Current status

The repository implementation is a dark-launch candidate. Guest
reading, optional accounts, To Read synchronization, comments and moderation,
account deletion, telemetry, deployment, release automation, and evidence
validators are implemented. The checked-in production configuration keeps
accounts, library, and comments off until the corresponding protected staging,
operations, legal, device, signing, and store gates pass.

Source checks do not authorize a public rollout. Do not turn an unchecked item
in the completion audit into a passing claim without its required immutable
artifact and owner approval.

## Repository map

| Path | Purpose |
| --- | --- |
| `backend/apps/api` | Axum public/account API |
| `backend/apps/worker` | paper metadata and preparation jobs |
| `backend/apps/deletion-worker` | leased provider/application deletion work |
| `backend/apps/migrate` | standalone production migration job |
| `backend/apps/admin` | recently authenticated moderation operations |
| `backend/apps/telemetry-gateway` | validates the closed mobile telemetry schema |
| `backend/crates` | domain, database, auth, library, comments, moderation, jobs, provider, and policy modules |
| `mobile` | Flutter Android/iOS application and native hosts |
| `site` | static policy, support, deletion, and association site |
| `deploy` | Keycloak reference deployment and production Helm chart |
| `scripts` | checks, evidence validators, release assembly, and operational drills |
| `docs/adr` | accepted architectural decisions |
| `docs/runbooks` | release, incident, restore, moderation, deletion, telemetry, and load procedures |

PostgreSQL is the production source of truth for application data, jobs, shared
rate limits, synchronization, and moderation. Do not introduce another network
service without an ADR.

## Toolchain

The complete local harness reports missing optional tools and every skipped
gate. A fully representative developer machine needs:

- the pinned Rust 1.91.1 toolchain used by CI and release images;
- Docker with Compose v2;
- Python 3 and `jq`;
- the pinned Flutter 3.44.8 / Dart 3.12.2 toolchain for current mobile release
  evidence;
- Android tooling, plus Xcode on macOS for iOS builds;
- Node/npm for the public-site suite;
- Helm 3.18.x for deployment rendering; and
- Java signing tools and Ruby only for the corresponding release checks.

Use lockfiles. Do not casually update Rust, Pub, npm, Gradle, SwiftPM, Ruby, or
workflow-action inputs: dependency automation, checksums, SBOM inventories, and
release evidence intentionally fail closed on unreviewed drift.

## Start the guest development stack

From the repository root:

```bash
cp .env.example .env
# Replace ARXIV_CONTACT_EMAIL with a real monitored address.
./scripts/prepare_dev_api_origin_secret.sh
docker compose up -d --build
```

The API is ready only when this returns HTTP 200:

```bash
curl --fail http://localhost:8080/health/ready
```

`/health/live` proves only that the process is running. The API and worker
reject placeholder arXiv contacts. Generated secret files are owner-only and
must not be printed, copied into `.env`, or committed.

Run the mobile app:

```bash
cd mobile
flutter pub get --enforce-lockfile
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

An Android emulator reaches the host API through `http://10.0.2.2:8080`; either
override the development API define or use a device/network configuration that
can reach the host. iOS simulators normally use `http://localhost:8080`.

## Enable reference accounts locally

Start the separate Keycloak database/provider profile:

```bash
docker compose stop api
docker compose --profile accounts up -d postgres keycloak
./scripts/prepare_dev_account_secrets.sh
```

The reference issuer is
`http://localhost:8081/realms/pakperk`. Run the API on the host with the account
settings documented in the root [README](../README.md#optional-local-oidc-accounts).
Do not run the Compose API at the same time: changing the issuer to a container
hostname would make tokens disagree with the public issuer embedded in them.
Verification mail is available in Mailpit at `http://localhost:8025`.

For an account-only client, use the public native OIDC defines in
[`mobile/README.md`](../mobile/README.md#pakperk-mobile). The checked-in
`mobile/config/dev.json` enables accounts, library, and comments together for
full-composition testing; when using it, enable the matching backend account,
library read/write, comment read/creation flags as well. A mobile build must
never contain a client secret, provider API key, admin token, or
deletion-worker credential.

## Feature flags

All production capabilities are independent fail-closed switches:

| Flag | Dependency and effect |
| --- | --- |
| `ACCOUNTS_ENABLED` | registers account verification/profile behavior |
| `LIBRARY_ENABLED` | requires accounts; enables To Read reads |
| `LIBRARY_WRITES_ENABLED` | requires library; enables save/remove mutations |
| `COMMENTS_ENABLED` | requires accounts; registers public discussion and safety routes |
| `COMMENT_CREATION_ENABLED` | requires comments; enables only new comment publication |
| `ACCOUNT_DELETION_ENABLED` | requires accounts and the complete worker/ledger/provider boundary |

The mobile build has compile-time `PAKPERK_ACCOUNTS_ENABLED`,
`PAKPERK_LIBRARY_ENABLED`, and `PAKPERK_COMMENTS_ENABLED` capabilities. Library
writes, comment creation, and account deletion remain independent server-side
operational switches. Backend and mobile values must still describe a
compatible deployed product. Turning comment creation off must leave reading,
reporting, blocking, author removal, and moderation available. Turning library
writes off must leave library reads available.

Production also requires `FULLTEXT_POLICY=strict`,
`PAKPERK_FULLTEXT_POLICY=strict`, `RUN_MIGRATIONS=false` for every long-running
API, paper-worker, and deletion-worker process, HTTPS public origins, trusted
ingress CIDRs, and mounted owner-only key files. The standalone migration job
owns schema changes.

## Normal change workflow

1. Read the relevant ADR and contract document before changing a boundary.
2. Keep API DTOs, domain rules, persistence, mobile parsing, and OpenAPI in
   agreement. Response parsers intentionally reject unknown fields.
3. Add a forward-only expand/contract migration. Never edit an applied
   migration or let production API replicas race migrations at startup.
4. Preserve idempotency for retried writes and generation scope for paper
   artifacts.
5. Preserve guest reading. Authentication is required only for cloud-owned or
   moderation-sensitive actions.
6. Never make startup, feed prefetch, cache hydration, or library sync prepare a
   paper. Preparation begins only after a committed reader transition or an
   explicit retry.
7. Keep tokens, passwords, comment/report text, paper full text, prompts, and
   identity attributes out of logs and telemetry.

When the API surface changes, regenerate and verify the checked contract:

```bash
./scripts/generate_openapi.sh > docs/openapi-v1.json
./scripts/check_openapi.sh
```

When a Drift table, index, converter, or annotated database declaration
changes, regenerate the checked-in database bindings through the pinned
generator; never edit `app_database.g.dart` by hand:

```bash
cd mobile
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart format lib/core/database/app_database.g.dart
```

Review and commit the generated diff together with the schema change and its
migration/upgrade tests. Unrelated generated drift is a dependency/toolchain
signal, not something to discard blindly.

For a backend schema migration:

1. add the next append-only `backend/migrations/NNNN_description.sql` file;
2. update the exact migration version in `.env.example`,
   `deploy/helm/pakperk/values.yaml`, `values.schema.json`,
   `templates/validate.yaml`, and `scripts/validate_helm_release.sh`;
3. add representative old-schema data-preservation and idempotent re-run
   assertions to the standalone migrator test; and
4. create a fresh disposable database as described in [Tests](#tests), then run
   the focused upgrade test against that exact database:

```bash
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk_test_local_run_01 \
  cargo test --manifest-path backend/Cargo.toml --locked \
  -p pakperk-migrate \
  tests::standalone_run_bootstraps_upgrades_and_rejects_wrong_extension_namespace \
  -- --exact
```

The migration job also requires a real protected backup identifier in staging
or production. A synthetic local value is never deployment evidence.

## Tests

Run the complete available harness from the repository root:

```bash
./scripts/check.sh
```

For PostgreSQL-backed tests, use a disposable database—not a developer or
production database:

```bash
docker compose up -d postgres
# Change the suffix for every run; this database must not already exist.
docker compose exec -T postgres \
  createdb -U pakperk pakperk_test_local_run_01
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk_test_local_run_01 \
  cargo test --manifest-path backend/Cargo.toml \
  --locked --workspace --all-features
docker compose exec -T postgres \
  dropdb -U pakperk pakperk_test_local_run_01
```

Choose a new `pakperk_test_local_*` name for every run. Never point
`TEST_DATABASE_URL` at the persistent `pakperk` development database; the
integration suite applies migrations and writes directly to its target. If a
run fails before cleanup, leave that database alone and choose another name;
inspect or drop the old database explicitly later.

The main harness covers repository contracts, Rust formatting/Clippy/tests,
OpenAPI, release metadata, dependency/SBOM policy, Flutter format/analyze/tests
and debug/simulator artifacts when available, site tests, Helm, and optional
container/device probes. A final line saying available checks passed is not a
release pass: review every explicit skip.

Useful focused commands are:

```bash
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo clippy --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features -- -D warnings

cd mobile
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test

cd ../site
npm ci --ignore-scripts
npm test
```

Do not reinterpret a skipped PostgreSQL test, simulator build, browser test,
container test, or physical-device lane as passing evidence.

## Release path

The release owner should use the [release runbook](runbooks/release.md) and the
[completion-audit evidence matrix](production-v0.0-completion-audit.md), in
order:

1. obtain a clean exact-source canonical check with a disposable PostgreSQL
   database and every required mobile/site/Helm/container lane;
2. run current networked source, dependency, secret, and container scans;
3. generate deterministic notices and source/native CycloneDX inventories;
4. execute migration/rollback and isolated restore/deletion-replay drills;
5. dark-deploy exact image digests and prove staging parity, load, telemetry,
   retention, alerts, auth rotation, replay, shared limits, and kill switches;
6. verify the public TLS edge, HSTS, gzip feed, policy/support pages, and mobile
   association files;
7. build and provenance-bind signed Android/iOS candidates;
8. pass the protected four-device acceptance matrix, performance thresholds,
   and crash-free observation window;
9. obtain moderation, privacy, legal, content-rights, support, and store-review
   approvals; and
10. upload, verify, and progressively release through the protected store
    workflows.

Every artifact must bind the exact source revision and promoted image/mobile
digests. A local log, mutable URL, ticket number, or human assertion cannot
replace the immutable evidence required by the completion audit.

## Common failures

- A feature route returns 404: confirm its backend flag is enabled; absent
  default-off routes are intentional.
- The API rejects startup: read the exact validation error and fix the missing
  dependent flag, HTTPS origin, contact, key file, or production assertion.
- Local OIDC tokens fail: use the public `localhost` issuer and host-run API;
  do not substitute a Docker-only issuer hostname.
- PostgreSQL tests silently do little: set a disposable `TEST_DATABASE_URL`.
- Flutter release checks drift: use the pinned SDK and lockfile, then review any
  dependency/SBOM delta rather than bypassing it.
- Derived content disappears in strict mode: this is fail-closed policy, not a
  cache bug; verify the paper license and backend/mobile policy pairing.
- `scripts/check.sh` succeeds with skips: install/provision the missing tool or
  run the corresponding protected lane before release.

Security incidents, deletion, restore, moderation, observability, and load
events have dedicated procedures under [`docs/runbooks`](runbooks/).
