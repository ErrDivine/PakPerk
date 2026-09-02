# Pakperk developer guide

This guide is the starting point for working on Pakperk. It explains what runs
where, gets a guest build working locally, and then points to the deeper guides
for real phones and server deployment.

Unless a paragraph says otherwise, treat every shell block in this guide as an
independent block that starts at the repository root. A block that begins with
`cd mobile` or `cd docs-site` changes directory only for that block.

> **First visit?** Follow [Run Pakperk locally](#run-pakperk-locally) from top to
> bottom before enabling accounts or optional features. The default guest stack
> is deliberately small and is the easiest place to learn the system.

## Choose the path you need

| Goal | Start here |
| --- | --- |
| Run the API and app on one development machine | [Run Pakperk locally](#run-pakperk-locally) |
| Debug on a physical Android phone or iPhone | [Test Pakperk on a physical phone](mobile-device-development.md) |
| Install the backend on a staging or production server | [Deploy the backend](backend-deployment.md) |
| Understand why the system has these boundaries | [Architecture](architecture.md) and [deployment boundaries](deployment-boundaries.md) |
| Build a signed mobile release | [Mobile release](mobile-release.md) |
| See which production claims still need evidence | [Production v0.0 completion audit](production-v0.0-completion-audit.md) |

The repository is a dark-launch candidate, not proof that a public release is
approved. Source code, local tests, and a healthy staging route cannot replace
the protected operational, legal, privacy, accessibility, signing, store, and
human-review evidence tracked by the completion audit.

## Build a useful mental model first

Pakperk has five main moving parts:

1. The Flutter app asks the API for public feed and paper data. Account-owned
   features are optional and stay hidden unless both the app and backend enable
   compatible flags.
2. The Axum API validates requests and reads or writes PostgreSQL. PostgreSQL is
   also the durable queue, shared rate-limit store, and moderation source of
   truth; there is no Redis, Kafka, or NATS dependency.
3. A paper worker leases preparation jobs from PostgreSQL, fetches permitted
   source material, asks GROBID to parse it, and can call a configured model
   provider. Preparing a paper is an explicit action, never a side effect of
   merely opening the app or refreshing a feed.
4. A separate deletion worker coordinates account deletion with the identity
   provider and an independently backed-up signed ledger. It is intentionally
   isolated from the ordinary paper worker.
5. The static `site/` project serves public policy, support, deletion, and app
   association files. The `docs-site/` project is this developer documentation
   site. Neither one is the API.

For local guest development, Docker Compose runs PostgreSQL, GROBID, the API,
and the paper worker. For staging and production, the supported shape is the
Kubernetes Helm chart. Compose is intentionally convenient and intentionally
unsafe for a public Internet deployment.

## Install the development tools

Use the versions pinned by the repository rather than whichever versions are
newest today.

| Tool | Why it is needed |
| --- | --- |
| Rust 1.91.1 | Backend builds, tests, and release images |
| Docker with Compose v2 | The local database, parser, API, and workers |
| Flutter 3.44.8 with Dart 3.12.2 | The current Android and iOS app |
| Android SDK tools | Android builds, emulators, `adb`, and physical-device debugging |
| Xcode on macOS | iOS builds, simulators, signing, and physical iPhone debugging |
| OpenSSL | Generates the owner-only local API and account key files |
| Python 3 and `jq` | Repository validators and small maintenance tools |
| Node.js 22.13 or newer, npm, and Pandoc | Public site and developer docs site |
| Helm 3.18.x | Rendering and validating the deployment chart |

Java signing tools, Ruby, and store CLIs are needed only for their corresponding
release gates. The main check script reports missing optional tools and skipped
gates rather than quietly treating them as successful.

Lockfiles and pinned workflow inputs are part of the release controls. Do not
casually update Rust, Pub, npm, Gradle, SwiftPM, Ruby, image, or workflow-action
versions. Their checksums, software inventories, and evidence validators are
designed to notice unreviewed drift.

## Run Pakperk locally

All commands in this section start at the repository root unless a step says
otherwise.

### 1. Create the local configuration

Copy the fail-closed template:

```bash
cp .env.example .env
```

Open `.env` and replace the rejected `ARXIV_CONTACT_EMAIL` placeholder with a
real, monitored address. arXiv asks API clients to identify a reachable contact,
and both the API and worker reject placeholder or example-domain values.

Leave the optional capability flags `false` for the first run. In particular,
do not enable accounts, Library, comments, deletion, discovery, or Deep Reader
features until the basic guest path works.

Generate the local origin-hashing and cursor-encryption key files:

```bash
./scripts/prepare_dev_api_origin_secret.sh
```

The script writes owner-only files beneath `.local/pakperk-secrets/`. It prints
their paths, not their values. Do not copy the values into `.env`, print them in
logs, or commit them.

### 2. Start the guest backend

```bash
docker compose up -d --build
```

The first build can take several minutes. Watch the service state and API logs:

```bash
docker compose ps
docker compose logs --tail=100 api
```

Wait for the readiness endpoint:

```bash
curl --fail http://localhost:8080/health/ready
```

An HTTP 200 means the API can reach PostgreSQL and that the migration and
required-extension contract is valid. `/health/live` proves only that the API
process is running. Readiness does **not** prove that GROBID, a model provider,
OIDC, background workers, telemetry delivery, DNS, or TLS is healthy.

If readiness fails, inspect the API and migration logs before restarting
anything:

```bash
docker compose logs --tail=200 api postgres
```

The Compose API applies migrations for local convenience. Long-running staging
and production processes must instead use `RUN_MIGRATIONS=false`; their
standalone migration Job owns schema changes.

The migration creates tables but does not seed papers. If the next task needs
to prove live API data rather than only networking, load the checked-in demo
metadata now:

```bash
./scripts/seed_demo.sh
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

The count should be greater than zero. `seed_demo.sh` contacts arXiv using the
identity configured in `.env`. Preparing Introduction and Connections content
is a separate, slower, provider-dependent action; run
`./scripts/preprocess_demo.sh` only when the task needs that path. The mobile app
also contains clearly labeled bundled demo papers, so seeing a paper on screen
does not by itself prove that the live database contains it.

### 3. Run the Flutter app

In a second terminal:

```bash
cd mobile
flutter pub get --enforce-lockfile
flutter devices
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

This URL works directly in an iOS Simulator. An Android emulator reaches the
host through `http://10.0.2.2:8080`, so replace the API base URL with that value.
A physical phone needs additional routing and signing setup; follow the
[physical-phone guide](mobile-device-development.md) rather than guessing a LAN
address.

The flavor and environment are a checked pair:

| Flutter flavor | `PAKPERK_ENV` | Application identity suffix |
| --- | --- | --- |
| `dev` | `development` | `.dev` |
| `staging` | `staging` | `.staging` |
| `prod` | `production` | none |

Startup rejects a mismatched pair. That early failure prevents a build carrying
one environment's identity from silently talking as another environment.

### 4. Prove the basic path

In the app, confirm that the public feed opens and that a paper can be selected.
Keep `flutter run` attached, open the DevTools link it prints, select the
**Network** view, refresh the feed, and confirm a successful `GET /v1/feed`.
Also verify the live API response independently from the development computer:

```bash
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

The default compact API logger does not emit one line for every request, so
searching `docker compose logs` for `/v1/feed` is not a valid reachability test.
An item count of zero is valid on a fresh database, and the app can still show
its bundled demo feed. When live data matters, run the seed step above, confirm
that the API count is greater than zero, and use the phone's DevTools request to
prove which network path the app exercised.

For the same repeatable backend test command used by the repository gate, run:

```bash
cargo test --manifest-path backend/Cargo.toml --locked --workspace --all-features
```

For a repeatable mobile check:

```bash
cd mobile
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

The complete repository gate is:

```bash
./scripts/check.sh
```

It is deliberately broad and can be slow. Read its final skip report: a skipped
device, signing, Helm, or external-service gate is not a pass.

### 5. Stop the local stack

```bash
docker compose down
```

This preserves the named database volume. Use a volume-removing command only
when you intentionally want to destroy local database state and have confirmed
that nothing in it is needed.

## Enable local accounts only when you need them

The reference identity provider is a separate Compose profile. The issuer URL
is public `localhost`, so the API must run on the host during this workflow;
tokens issued for `localhost` must not be validated against a container-only
hostname.

First stop the Compose API, start PostgreSQL and Keycloak, and create the local
account key material:

```bash
docker compose stop api
docker compose --profile accounts up -d postgres keycloak
./scripts/prepare_dev_account_secrets.sh
```

Then follow [Account authentication](account-authentication.md) for the exact
host API environment. The reference issuer is
`http://localhost:8081/realms/pakperk`, and verification mail appears in Mailpit
at `http://localhost:8025`.

The checked-in `mobile/config/dev.json` enables accounts, Library, and comments
together. The backend must enable the compatible account, Library read/write,
and comment read/creation switches too. A mobile build must never contain a
client secret, provider API key, administrative token, or deletion-worker
credential.

When several features are involved, enable dependencies from the bottom up and
disable them in reverse order. Startup rejects invalid combinations. The full
dependency graph and rollout evidence live in the relevant feature document,
including [Discovery and Library](discovery-and-library.md) and the
[Deep Reader rollout runbook](runbooks/deep-reader-rollout.md).

## Use a focused edit-and-test loop

### Backend change

1. Read the relevant ADR and contract before changing a boundary.
2. Keep domain rules, persistence, API DTOs, OpenAPI, and mobile parsing in
   agreement. Mobile response parsers intentionally reject unknown fields.
3. Add tests next to the changed crate or application, then run the focused
   package tests before the full workspace suite.
4. If the API contract changed, regenerate it and inspect the diff:

   ```bash
   ./scripts/generate_openapi.sh > docs/openapi-v1.json
   ./scripts/check_openapi.sh
   ```

5. For schema changes, add a new forward-only migration. Never edit an applied
   migration and never let production API replicas race one another to migrate.

Preserve idempotency for retried writes, generation scope for prepared paper
artifacts, and guest reading for public surfaces. Keep access tokens, passwords,
identity attributes, paper full text, prompts, comments, and reports out of logs
and telemetry.

### Mobile change

Run formatting, analysis, and the smallest relevant widget or unit test while
iterating. Before handoff, run the full Flutter test suite and exercise the
changed flow on the platforms it affects. A simulator is useful for speed; a
physical phone is required for the signed-device and native-behavior evidence
described in [Test Pakperk on a physical phone](mobile-device-development.md).

### Documentation change

Edit the authoritative English Markdown in `docs/`; do not hand-edit generated
files in `docs-site/app/generated/` or `docs-site/public/docs-data/`.

```bash
cd docs-site
npm ci
npm run sync-docs
npm test
```

Pandoc is required by `sync-docs`. The docs site may show an English fallback
when a matching reviewed Chinese translation is not present; the interface must
not present a stale translation as current.

## Know what local success does not prove

A green local run means the tested code path worked in a developer environment.
It does not prove any of the following:

- public DNS, TLS, ingress, trusted-proxy, or HSTS behavior;
- production PostgreSQL roles, backups, restore compatibility, or migration
  ownership;
- OIDC browser/native clients, provider permissions, or deletion-ledger replay;
- live GROBID, model-provider, telemetry, alerting, or worker behavior;
- physical-device accessibility, backgrounding, offline recovery, signing, or
  store acceptance; or
- release-owner, privacy, legal, safety, and human-domain approval.

Use the server deployment guide, physical-phone guide, runbooks, and completion
audit to collect that evidence. Do not turn a feature on in production merely
because its route exists or its local test passes.

## Repository map

| Path | What belongs there |
| --- | --- |
| `backend/apps/api` | Public and account Axum API |
| `backend/apps/worker` | Paper metadata and preparation jobs |
| `backend/apps/deletion-worker` | Provider and application deletion work |
| `backend/apps/migrate` | Standalone deployment migration job |
| `backend/apps/admin` | Recently authenticated moderation operations |
| `backend/apps/telemetry-gateway` | Closed-schema mobile telemetry intake |
| `backend/crates` | Domain, database, auth, policy, queue, and provider modules |
| `mobile` | Flutter application and Android/iOS hosts |
| `site` | Public policy, support, deletion, and association site |
| `docs` | Authoritative English documentation and runbooks |
| `docs-site` | Generated, searchable developer-documentation interface |
| `deploy` | Reference identity configuration and Kubernetes Helm chart |
| `scripts` | Checks, evidence validators, release tools, and drills |

## Common first-run problems

**The API rejects the arXiv contact.** Replace the placeholder in `.env` with a
real monitored address, then recreate the affected API and worker containers.

**`/health/live` works but `/health/ready` fails.** The process is alive but its
database contract is not ready. Read API, migration, and PostgreSQL logs; do not
paper over the failure with a restart loop.

**The Android emulator cannot reach `localhost:8080`.** `localhost` is the
emulator itself. Use `http://10.0.2.2:8080`. For a physical Android phone, use
the documented `adb reverse` path.

**A physical iPhone cannot reach the Mac's `localhost`.** `localhost` is the
iPhone itself, and this repository does not provide an iOS reverse tunnel. Use a
reachable trusted HTTPS development or staging API as described in the phone
guide.

**The app exits immediately after launch.** Check that flavor and environment
match and that all enabled mobile capabilities have their prerequisite defines.

**Account tokens fail only in the container API.** The token issuer and API
discovery URL disagree. Keep the public issuer as `localhost` and run the API on
the host for the reference local account workflow.

**A feature route is missing.** Most optional routes are not merely hidden in
the UI; the backend does not register them while their fail-closed flags are
off. Confirm the dependency chain before changing a flag.
