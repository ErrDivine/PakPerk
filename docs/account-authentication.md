# Account authentication and profile contract

**Phase:** Production v0.0 Phase 3
**Feature gate:** `ACCOUNTS_ENABLED`
**Verification status:** Implemented and accepted; see the
[Phase 3 report](phase-reports/phase-3.md) for the exact evidence and remaining
physical-device release-candidate checks.

Pakperk uses OpenID Connect Authorization Code with PKCE. The mobile app is a
public native client and the Rust API is a resource server. Passwords,
registration, email verification, recovery, and provider sessions belong to
the configured identity provider; Pakperk stores only its local account and
public profile.

Guest reading does not depend on this feature. When accounts are disabled,
`GET /v1/me` and `PATCH /v1/me` are not registered. When accounts are enabled
but OIDC discovery or signing keys are temporarily unavailable, public paper
routes remain available and the account routes fail closed.

## Reference development provider

The optional Compose profile starts the pinned development-only Keycloak realm,
its separate PostgreSQL database, and Mailpit:

```bash
docker compose --profile accounts up -d postgres keycloak
```

The checked-in realm uses:

```text
issuer:                  http://localhost:8081/realms/pakperk
API audience:            pakperk-api
native client:           pakperk-mobile-dev
redirect URI:            pakperk-auth-dev://oauth/callback
post-logout redirect:    pakperk-auth-dev://oauth/logout
browser deletion client: pakperk-web-deletion-dev
browser redirect URI:    http://localhost:8082/account-deletion/
deletion admin client:   pakperk-deletion-worker-dev (runtime-generated secret)
requested scopes:        openid profile
verification inbox:      http://localhost:8025
```

The public native client has no client secret and requires PKCE S256. The realm
enables self-registration, email verification, password recovery, brute-force
protection, short access-token lifetime, and refresh-token rotation. See the
[realm runbook](../deploy/keycloak/README.md) for the development boundary.
The realm export and Compose bootstrap defaults must not be reused as
production secrets or production identity policy.

Run the account-enabled API on the host so both it and the native client see
the exact `localhost` issuer. First copy `.env.example` to `.env`, replace
the arXiv contact placeholder as documented in the root README, then:

```bash
set -a
source .env
set +a
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

Do not start the Compose `api` service for this topology. Inside that
container, `localhost` is the API container itself; changing only the backend
issuer to `keycloak:8080` would then violate exact issuer validation for the
native client.

Backend account configuration is read only when `ACCOUNTS_ENABLED=true`:

```dotenv
ACCOUNTS_ENABLED=true
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk
OIDC_AUDIENCE=pakperk-api
OIDC_ALLOWED_ALGORITHMS=RS256
OIDC_DISCOVERY_TIMEOUT_SECONDS=5
OIDC_JWKS_CACHE_TTL_SECONDS=900
OIDC_JWKS_MIN_REFRESH_SECONDS=30
OIDC_CLOCK_SKEW_SECONDS=30
ACCOUNT_LAST_SEEN_INTERVAL_SECONDS=900
OIDC_RETRY_INITIAL_SECONDS=5
OIDC_RETRY_MAX_SECONDS=300
CURRENT_TERMS_VERSION=2026-07-31
PROFILE_UPDATE_LIMIT=5
PROFILE_UPDATE_WINDOW_SECONDS=3600
```

Plain HTTP issuers are accepted only for loopback development. Staging and
production require HTTPS, an exact issuer, an explicit audience, and an
allow-list of asymmetric signing algorithms. Provider metadata and JWKS reads
are redirect-free, byte-bounded, timeout-bounded, and cached. An unknown
signing-key ID triggers a single-flight refresh subject to a cooldown.

Enable the native client with matching build values:

```bash
cd mobile
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_ACCOUNTS_ENABLED=true \
  --dart-define=PAKPERK_OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
  --dart-define=PAKPERK_OIDC_CLIENT_ID=pakperk-mobile-dev \
  --dart-define=PAKPERK_OIDC_REDIRECT_URI=pakperk-auth-dev://oauth/callback \
  --dart-define=PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI=pakperk-auth-dev://oauth/logout \
  --dart-define='PAKPERK_OIDC_SCOPES=openid profile'
```

Android emulators normally use `http://10.0.2.2:8080` for the Pakperk API. For
this realm's `localhost` issuer, preserve exact issuer identity by reversing the
host ports before launch:

```bash
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8081 tcp:8081
```

Then the Android app can use both documented `localhost` URLs. The issuer used
by the app, the token, discovery, and the API verifier must be exactly the same;
do not substitute an emulator or internal container hostname for only one side
of that boundary.

## Token and local-data boundary

- Authorization opens in the system browser through AppAuth; no embedded
  WebView or password form exists in Pakperk.
- The access token is held in memory. The refresh token, optional provider
  logout hint, issuer/client binding, and local Pakperk account ID are the only
  durable session record, stored in platform secure storage.
- Tokens, authorization codes, PKCE verifiers, OIDC subjects, and profile data
  are absent from SharedPreferences, Drift/SQLite, logs, analytics, crash
  reports, and Riverpod snapshots.
- The auth invalidation entry in SharedPreferences is only a boolean. It is
  written before secure-token deletion and prevents a residual keychain or
  keystore record from being restored after restart; it contains no token,
  account ID, subject, or profile data.
- Concurrent token requests share one refresh. A challenged request may
  refresh and replay at most once; writes replay only when protected by a
  bounded concurrency or idempotency header.
- `invalid_grant` returns the app to guest state. A provider/network outage
  retains the secure session as auth-unknown rather than destroying it.
- Sign-out invalidates in-flight auth work, clears secure credentials and
  account-owned local rows, and preserves public paper/feed cache plus reading
  restoration.

## Authenticated profile API

The checked OpenAPI artifact at [openapi-v1.json](openapi-v1.json) is the
machine-readable source of truth. The profile operations use the OpenAPI
`oidcBearer` HTTP bearer security scheme and never accept a client-supplied
Pakperk user ID.

Existing `/v1/feed` and `/v1/papers/...` operations publish anonymous and
`oidcBearer` alternatives in OpenAPI: guest access remains valid, while a
supplied bearer may be verified and JIT-mapped. This optional security notation
must not be interpreted as an account wall. Health operations have no bearer
security requirement.

### `GET /v1/me`

The first valid request transactionally maps the verified `(issuer, subject)`
to one Pakperk account. The response is private and non-cacheable:

```http
HTTP/1.1 200 OK
ETag: "profile-3"
Cache-Control: private, no-store
Content-Type: application/json
```

```json
{
  "account": {
    "id": "018f06f0-65f2-7e2e-9a6e-8f349a84730f",
    "handle": "ada_2026",
    "display_name": "Ada",
    "status": "active",
    "profile_version": 3,
    "profile_complete": true,
    "terms_version": "2026-07-31",
    "terms_accepted_at": "2026-07-31T12:00:00Z",
    "current_terms_version": "2026-07-31",
    "terms_current": true,
    "created_at": "2026-07-31T11:55:00Z",
    "updated_at": "2026-07-31T12:00:00Z"
  }
}
```

`profile_complete` is true only when the account is active, has a handle, and
has accepted the current terms version. `terms_current` is reported separately
so clients can explain why an otherwise named profile is incomplete. Provider
issuer, subject, email, claims, and `last_seen_at` are never returned.

### `PATCH /v1/me`

Profile mutation is compare-and-swap. `If-Match` is required and accepts only
the exact strong profile validator returned by the latest account response:

```http
PATCH /v1/me HTTP/1.1
Authorization: Bearer <access-token>
If-Match: "profile-3"
Content-Type: application/json
```

```json
{
  "handle": "ada_2026",
  "display_name": "Ada",
  "accept_terms_version": "2026-07-31"
}
```

Unknown fields are rejected and at least one supported field is required.
Omitting `display_name` leaves it unchanged; sending `null` clears it. A handle
cannot be `null`, is normalized to lowercase ASCII, must match
`[a-z0-9_]{3,30}`, and may be set only once. `accept_terms_version` must equal
the server's current version. Success returns the same envelope and private
cache headers as `GET`, with the incremented ETag.

Stable failures retain the ordinary error envelope:

| Status | Stable codes | Response headers |
|---:|---|---|
| 400 | `INVALID_REQUEST`, `INVALID_PROFILE_VERSION`, `INVALID_PROFILE_UPDATE`, `INVALID_HANDLE`, `INVALID_DISPLAY_NAME`, `INVALID_TERMS_VERSION`, `TERMS_VERSION_MISMATCH` | — |
| 401 | `UNAUTHENTICATED`, `TOKEN_EXPIRED` | `WWW-Authenticate: Bearer` |
| 403 | `ACCOUNT_SUSPENDED`, `ACCOUNT_DELETION_PENDING` | — |
| 409 | `HANDLE_ALREADY_SET`, `HANDLE_UNAVAILABLE` | — |
| 412 | `PROFILE_VERSION_CONFLICT` | current `ETag` |
| 428 | `PROFILE_VERSION_REQUIRED` | — |
| 429 | `RATE_LIMITED` | delta-seconds `Retry-After` |
| 503 | `AUTHENTICATION_UNAVAILABLE`, `ACCOUNT_SERVICE_UNAVAILABLE` | delta-seconds `Retry-After` when known |

`PROFILE_VERSION_REQUIRED` means the `If-Match` header is absent; malformed,
weak, wildcard, list, duplicate, zero, negative, or noncanonical validators use
`INVALID_PROFILE_VERSION`. Challenges and temporary-auth failures never expose
token, claim, provider, issuer, subject, or signing-key details.

## CORS contract

Deployed origins remain explicit HTTPS values. The API accepts these methods:

```text
GET, POST, PUT, PATCH, DELETE, OPTIONS
```

Preflight allows:

```text
Authorization, Content-Type, X-Session-Id, X-Request-Id,
Idempotency-Key, If-Match, If-None-Match
```

Browser clients may read:

```text
X-Request-Id, ETag, Retry-After
```

Native Flutter requests do not rely on CORS, but this contract prevents web
tooling from requiring broader wildcard or credential behavior.

## Account-owned and deletion extensions

Phase 4 now publishes library routes only when its independent account,
library, and write gates allow them. Saving does not require a handle or terms
acceptance; remote sync additionally requires an epoch-bound `/v1/me` account
verification. The provider-neutral identity-admin boundary now has a bounded
Keycloak implementation used only by the dedicated deletion worker. Recent-auth
`DELETE /v1/me`, deletion verification, the durable state machine, signed
external restore ledger, provider session/identity removal, and replay tooling
are implemented behind `ACCOUNT_DELETION_ENABLED`. They remain default-off
until the target provider grant, independent ledger/backup topology, restore
drill, alerts, and public disclosures have approved evidence. Comments are
implemented behind independent read/publication flags and must not be enabled
without their UGC operational gates.
