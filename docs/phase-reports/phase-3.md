# Production v0.0 Phase 3 report

**Phase:** OIDC accounts
**Status:** Complete — accepted
**Implementation snapshot:** 2026-07-31
**Starting commit:** `16cf9c7`

This is the accepted Phase 3 record. It documents the implemented identity and
account boundary and the evidence used to close the phase. It does **not** claim
that later library/comment/deletion behavior or the Production v0.0 definition
of done is complete.

## Scope and preserved invariants

- Guest feed, paper, preparation, processing, Introduction, anonymous chat,
  Connections, arXiv links, and cached reading remain independent of account
  availability.
- `ACCOUNTS_ENABLED=false` registers no `/v1/me` route and performs no OIDC
  discovery. Library, comments, blocks, reports, and deletion routes remain
  unpublished regardless of their later-phase flags.
- Account-enabled required-auth routes fail closed when discovery, JWKS, token
  verification, or account storage is unavailable. That failure does not make
  the public reading service unready.
- Authentication never changes the preparation boundary: startup, session
  restore, JIT provisioning, profile refresh, onboarding, and sign-out cannot
  submit a paper preparation request.
- No password enters Pakperk. Tokens and OIDC subjects remain outside general
  preferences, Drift/SQLite, logs, analytics, crash reports, and public profile
  responses.

The exact setup, storage boundary, profile shapes, concurrency headers, error
classes, and CORS contract are recorded in
[Account authentication and profile contract](../account-authentication.md).

## Backend identity boundary

The isolated `auth` crate provides:

- bounded, redirect-free OIDC discovery and JWKS reads;
- an explicit asymmetric algorithm allow-list;
- exact issuer and audience checks plus required `exp`, `iss`, `aud`, and
  nonempty `sub` claims;
- expiration/not-before validation with bounded clock skew;
- signing-key lookup by `kid`, single-flight unknown-key refresh, a refresh
  cooldown, TTL-based refresh, and size/key-count bounds;
- sanitized startup and verification failures that retain no token, claim,
  issuer, key ID, or upstream response body; and
- a cloneable auth runtime that can atomically publish an available verifier
  after a background discovery retry without rebuilding the public router.

The Phase 3 identity-admin boundary is intentionally incomplete for destructive
operations. `NoopIdentityAdmin` never reports false success, and the validated
Keycloak adapter reports `Unwired` until Phase 6 supplies credential loading,
provider calls, bounded retries, and deletion idempotency.

## Local account and profile model

Migration `0004_accounts.sql` introduces one local `users` row per exact
`(oidc_issuer, oidc_subject)` identity. OIDC issuer and subject are private.
The owner projection contains a server UUID, optional immutable handle,
optional display name, status, monotonic profile version, terms acceptance, and
timestamps.

JIT provisioning is transactional and safe under concurrent first requests.
It does not copy provider email or profile fields and never reactivates a
suspended/deletion-state account. `last_seen_at` updates at a bounded cadence
instead of writing on every request.

Handles are canonical lowercase ASCII values containing only letters, digits,
and underscore, 3–30 characters, with reserved/system names and URL/email
shapes rejected. The database enforces defensive case-insensitive uniqueness.
Display names are optional, NFKC-normalized, whitespace-collapsed, bounded to
80 Unicode scalar values, and reject control/directionality characters.

Profile writes use a strong `"profile-N"` validator and compare-and-swap
versioning. Omitted and explicit-null display names remain distinct; handle is
set-once and cannot be cleared; accepted terms must match the configured
current version. A profile is complete only for an active account with a
handle and current terms acceptance.

## Shared rate-limit foundation

Migration `0005_shared_rate_limits.sql` adds one bounded fixed-window row per
`(bucket, scope_key)`. Database statement time and atomic
`INSERT ... ON CONFLICT ... DO UPDATE` make enforcement common to all API
replicas. The first consumer is `profile_update`, keyed only by the verified
Pakperk user UUID. A bounded skip-locked cleanup operation removes expired
windows. Later phases add library, comments, reports, deletion, and eventual
prepare/chat migration without another network service.

## Authenticated profile API

When accounts are enabled, the server publishes:

```text
GET   /v1/me
PATCH /v1/me
```

Both require the OpenAPI `oidcBearer` security scheme, JIT-map the verified
identity, return `Cache-Control: private, no-store`, and return a strong ETag
matching the profile version. `PATCH` requires exact `If-Match`, rejects
unknown or empty input, and increments the profile version on success.

The stable error envelope covers authentication, account status, validation,
handle conflict, precondition conflict, shared rate limiting, and temporary
auth/storage availability. Challenges and retry timing are headers rather than
token/provider details in response bodies. The checked
[OpenAPI artifact](../openapi-v1.json) must be regenerated from the code-first
contract and pass compatibility checks before this phase can be accepted.

## Mobile session and profile behavior

The mobile auth layer is separated from Dio, Riverpod UI, and account APIs:

- AppAuth opens the system browser for Authorization Code + PKCE and provider
  logout.
- The access token lives only in memory. Platform secure storage holds the
  refresh token, optional ID-token logout hint, issuer/client binding, and
  optional non-secret local account UUID with a strict versioned codec.
- Concurrent callers share one proactive or challenge-driven refresh. A 401
  can replay once; write replay additionally requires a bounded `If-Match` or
  idempotency header.
- Bearer credentials attach only to the exact configured Pakperk API origin.
  Public requests never wait for auth, and external origins never receive a
  token.
- Epoch guards prevent late sign-in, refresh, account fetch, onboarding, or
  cleanup work from reviving an obsolete session.
- `invalid_grant` produces guest state; ordinary provider/network errors
  preserve an offline/auth-unknown session.
- Sign-out clears secure credentials and account-owned Drift rows while
  preserving public feed/paper cache and reader restoration.

The account client strictly parses the owner envelope and ETag, distinguishes
omitted/null/value patches, and uses one current-account controller. The You
branch keeps its guest state when the feature is off, launches real system
authentication when enabled, JIT-loads `/v1/me`, requests handle/current terms
onboarding for an incomplete account, shows the authenticated owner state, and
supports sign-out. Pending authenticated actions hold at most one validated
intent for later Save/comment phases.

## Native and development-provider integration

- Android declares the exact AppAuth redirect scheme, uses API level 23 or
  later for secure storage, disables backup, and supplies backup/data-extraction
  exclusions.
- iOS registers the same callback scheme, uses a device-bound Keychain
  accessibility class, and disables the shared on-disk URL cache so an AppAuth
  response URL containing token material is not persisted.
- The optional Compose `accounts` profile pins Keycloak 26.7.0 by digest,
  PostgreSQL 16.14, and Mailpit 1.30.6. Its imported development realm has a
  public native client, exact callback/logout URIs, PKCE S256, API audience,
  self-registration, email verification/recovery, brute-force protection, and
  rotating refresh tokens.

## Checks and acceptance evidence

The settled Phase 3 tree passed the repository gate and the following focused
acceptance runs on 2026-07-31:

- [x] Final Rust formatting and workspace Clippy with warnings denied.
- [x] Final Rust workspace unit, integration, and documentation tests.
- [x] Deterministic OpenAPI generation, checked-artifact byte comparison, route
  coverage, security/header assertions, and compatibility checks.
- [x] Dart formatting and Flutter analysis with no issues.
- [x] Complete Flutter test suite: 291 tests passed.
- [x] Repository-integrated `./scripts/check.sh` completed successfully.
- [x] Android account-enabled debug APK built at
  `mobile/build/app/outputs/flutter-apk/app-debug.apk`; the merged manifest and
  resources report minimum API 24, target API 36, backup disabled, explicit
  backup exclusions, and the exact `pakperk-auth` AppAuth receiver scheme.
- [x] iOS account-enabled simulator debug build produced
  `mobile/build/ios/iphonesimulator/Runner.app`; its built property list reports
  the exact bundle ID and `pakperk`/`pakperk-auth` schemes, iOS 13 minimum, and
  only the development localhost transport exception. Source entitlements use
  the device-bound, non-synchronizing Keychain configuration required by the
  secure-storage integration.
- [x] Keycloak registration, verification email, sign-in, profile onboarding,
  token refresh, and sign-out smoke flow.
- [x] Live PostgreSQL account/JIT/concurrency/profile/rate-limit scenarios with
  `TEST_DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk`:
  `cargo test -p db --test postgres_accounts -- --nocapture` passed. The test
  covers 24 concurrent JIT requests, profile compare-and-swap conflict,
  case-insensitive handle uniqueness, suspended status, and a rate limit shared
  by independent repository instances.
- [x] Storage schemas, codecs, generated native configuration, and diagnostic
  formatting were inspected to confirm that secure/general storage and logs
  contain no
  forbidden token, OIDC subject, email, or authorization-header material.

The deterministic OpenAPI checker ran four compatibility tests. Focused mobile
authentication tests passed 34/34, including concurrent refresh, one-time
replay, `invalid_grant`, secure-store failure, restart, and bounded sign-out
paths. The account/widget set passed 22/22 before the complete mobile run.

The real provider smoke used the pinned local Keycloak, its PostgreSQL store,
and Mailpit. A disposable account self-registered, received and followed its
verification email, completed Authorization Code + PKCE with the exact native
callback and matching state, and exchanged the code for the configured
`openid profile` audience. The API transactionally JIT-created the local user;
`GET /v1/me` returned profile ETag `"profile-1"`; profile/terms onboarding
returned `"profile-2"`; and a stale `If-Match` returned 412
`PROFILE_VERSION_CONFLICT`. Refresh-token rotation produced a working access
token, a bogus refresh produced `invalid_grant`, and RP-initiated logout used
the exact callback/state and invalidated the refresh session. No disposable
credential or token was retained in the repository or this report.

Finally, Keycloak was stopped while the API remained running. `/health/ready`
and an anonymous `/v1/feed?limit=1` request both returned 200, proving that
guest availability is independent of the identity provider.

## Exit-criteria ledger

- **Guest reading works with OIDC offline/unavailable:** accepted by the live
  provider-outage route check and required/optional-principal tests.
- **Test user can register, verify, and sign in:** accepted by the real
  Keycloak/Mailpit/PKCE smoke flow.
- **Tokens are absent from general storage/logs:** accepted by strict secure
  codec/schema inspection plus secret-redaction tests.
- **Expired access token refreshes once:** accepted by single-flight and
  replay-once transport tests plus real refresh-token rotation.
- **Invalid refresh returns to guest without clearing public cache:** accepted
  by `invalid_grant`, durable invalidation, restart, and scoped-cleanup tests.
- **Handle uniqueness and profile versioning work:** accepted by live
  PostgreSQL and HTTP ETag/precondition scenarios.
- **Account feature can be disabled coherently:** accepted by backend route
  absence, no-discovery, mobile feature-flag, and guest-shell tests.

## Known risks and later-phase boundaries

- Simulator builds and source/resource inspection do not replace final
  Keychain/Keystore, callback, backup/restore, and logout checks on signed
  physical-device release candidates.
- OIDC startup retry must remain bounded and content-free under a long provider
  outage; required-auth failure must not alter public readiness.
- Production-like identity deployments need their own HTTPS issuer, realm,
  native client, secret management, backups, and availability plan. The
  development realm is not a production configuration.
- Keycloak admin session revocation and identity deletion are deliberately
  unwired until Phase 6; `/v1/me` deletion must remain absent in Phase 3.
- Library actions, public comments, UGC controls, moderation, and deletion are
  not made complete by the account profile surface and remain independently
  gated in Phases 4–6.
