# Production v0.0 Phase 0 report

**Phase:** Baseline freeze, ADRs, and no-behavior refactor
**Status:** Complete
**Completed:** 2026-07-31
**Baseline:** `8dd3bc6aab1ab0fe058c5ace8ab1107813cfb441`
(`production-v0.0-baseline` annotated tag)

This report records evidence for Phase 0 only. It does not claim that later
production features or the Production v0.0 definition of done are complete.

## Checks run

Before Phase 0, the existing Rust formatting, Clippy, workspace tests, Flutter
formatting, Flutter analysis, and 58 Flutter tests passed. The first wrapper
invocation could not update the Flutter SDK cache under the workspace sandbox;
the same Flutter commands were rerun with SDK-cache permission and passed.

After Phase 0, the integrated command below passed with no skipped product
step:

```bash
./scripts/check.sh
```

That run included:

- Rust formatting and workspace Clippy with `-D warnings`;
- all Rust workspace unit, integration, and documentation tests;
- deterministic OpenAPI generation, checked-artifact byte comparison, and four
  compatibility-checker tests;
- Flutter dependency resolution, formatting, analysis, and 69 tests;
- JSON validation and shell syntax checks.

The opt-in migration test that explicitly requires `TEST_DATABASE_URL` remains
ignored by its existing guard during a run without that variable. The other
PostgreSQL test binaries completed successfully but returned early through their
documented `TEST_DATABASE_URL` guard, so this local run is not evidence of live
database assertions. CI supplies PostgreSQL and exercises them; the local Docker
daemon was unavailable for an additional service-backed run.

## Migrations added

None. Phase 0 deliberately adds no account, library, comment, moderation, or
rate-limit tables. Existing migrations remain unchanged.

## API changes

- Split the former API monolith into application assembly, validated config,
  stable errors, HTTP DTOs, request-ID/timeout/rate-limit middleware, and
  health/feed/paper/chat/support route modules.
- Added typed `development`, `staging`, and `production` environments.
- Added independent account, library, and comment flags with dependency
  validation. The flags are retained in `AppState`, but Phase 0 registers no
  incomplete feature routes.
- Added deployed-environment CORS validation. Staging and production require
  explicit HTTPS origins without wildcards, credentials, paths, queries, or
  fragments.
- Production refuses runtime migrations, non-strict full-text policy, and the
  deterministic model provider.
- Added code-first `utoipa` documentation for all ten existing public routes,
  including success/error bodies and stable wire enums.
- Added `/openapi.json` in development/staging only.
- Added deterministic generation and a checked
  [`openapi-v1.json`](../openapi-v1.json) artifact. CI rejects generation drift
  and removed routes, methods, response codes, properties, component schemas,
  and narrowed enum values. Schema-enum tests bind the documented values to the
  actual domain serialization.

Existing paper routes, response serialization, preparation intent, full-text
masking, chat ownership, and rate-limit behavior are unchanged. The existing
PostgreSQL API integration test changed only to provide the newly required
environment/feature configuration fields.

## Database changes

- Replaced the 3,385-line repository module with a stable public facade and
  focused paper, chat, and private row/codec modules.
- Preserved every public repository method and SQL string. The split was
  verified against all 325 original Rust string/raw-string literals and by the
  DB unit and PostgreSQL behavior suites.
- Added no speculative account repository or schema.

## Mobile changes

- Added typed build environments and independent account, library, comments,
  and opening-motion flags. Development defaults preserve the current guest
  demo with all production flags disabled.
- Centralized API base URL and full-text policy through validated build config.
- Production requires HTTPS and strict full-text policy; account-owned flags
  require accounts; comments require a non-placeholder support URL.
- Account-enabled builds require issuer, client ID, app-owned callback, and
  post-logout callback values. Unsafe redirect schemes, loopback production-like
  universal links, placeholders, and query-bearing callbacks are rejected.
- Client secrets and provider API keys supplied as mobile build values fail
  validation instead of being silently bundled.
- Added eleven focused build-configuration tests while all existing reader,
  restoration, gesture, resilience, content-policy, and chat tests remain green.

## Documentation and operational changes

- Added the Production v0.0 documentation entrypoint and ADRs 0001–0005.
- Updated architecture and content policy docs to distinguish the implemented
  demo from the planned production target.
- Updated `.env.example` and `README.md` with the Phase 0 feature/configuration
  boundaries and contract commands.
- Added a dedicated CI `contract` job with full history for base-artifact
  compatibility comparison.

## Exit-criteria evidence

- **Demo flows unchanged:** all pre-existing Rust and Flutter tests pass; no
  account UI or database table exists; feature defaults are disabled.
- **API fixtures unchanged:** existing runtime assertions and wire serializers
  pass unchanged; the new artifact documents rather than replaces their shapes.
- **Release check:** `./scripts/check.sh` exits successfully.
- **OpenAPI coverage:** the checked document contains exactly the ten existing
  health/paper routes, and a route-coverage test fails on undocumented drift.
- **No public accounts:** no `/v1/me`, library, comment, or block route is
  registered, regardless of Phase 0 flag values.

## Known risks carried into later phases

- Phase 1–6 product behavior is intentionally not implemented by this report.
- The runtime feature manifests must be extended only alongside each complete
  server safety stack; a flag alone is not authorization.
- OpenAPI response schemas are compile- and regression-checked, but future
  account DTOs must continue the same checked-artifact discipline.
- Device-level navigation and launch-motion acceptance testing belongs to Phase
  1 because Phase 0 makes no navigation or visual change.
- The live PostgreSQL assertions need confirmation in CI or a later local run
  with `TEST_DATABASE_URL`; this phase's integrated local check exercised their
  build and guards, not their database bodies.
- The local baseline tag must be published with the repository refs when the
  project is pushed; no remote mutation was performed during this phase.
