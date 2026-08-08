# Reference development identity provider

The optional Compose `accounts` profile runs Keycloak 26.7.0, a separate
PostgreSQL 16.14 database, and Mailpit. Keycloak is pinned by its multi-platform
OCI digest; the checked-in realm is development-only and contains no client
secret or seeded user password.

Start it with:

```bash
docker compose --profile accounts up -d postgres keycloak
```

- Issuer: `http://localhost:8081/realms/pakperk`
- Native client: `pakperk-mobile-dev`
- Redirect: `pakperk-auth-dev://oauth/callback`
- Post-logout redirect: `pakperk-auth-dev://oauth/logout`
- Moderation operator client/audience: `pakperk-admin-dev`
- Moderation operator callback: `pakperk-admin-dev://oauth/callback`
- Browser deletion client: `pakperk-web-deletion-dev`
- Browser callback: `http://localhost:8082/account-deletion/`
- Deletion service account: `pakperk-deletion-worker-dev`
- Mailpit verification inbox: `http://localhost:8025`

An Android emulator must reach the same exact `localhost` issuer that the API
verifies. Reverse the host ports before launching the account-enabled app:

```bash
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8081 tcp:8081
```

Using `10.0.2.2` for only the browser/client changes the issuer identity and
will correctly fail the exact-issuer check.

The matching API runs on the host, not in the Compose `api` container:

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

This is required because `localhost` inside the Compose API container refers
to the container itself, while changing the issuer hostname for just one
participant breaks OIDC exact-issuer validation.

The initializer creates the API request-origin key, cursor-encryption keyring,
rotation-capable identity fingerprint/deletion-ledger/provider-coordinate
keyrings, and the ledger directory. The provider-coordinate AES-256-GCM key is
exactly 32 random bytes; the fingerprint and signing key generators retain 48
random bytes. It never prints key values, never overwrites an existing keyring,
rejects symlinks, and enforces owner-only modes. The account/deletion keyrings
are consumed only by the documented host-run API/worker commands and are not
bind-mounted into Compose. The generic request-origin and cursor-encryption
sources are the only exceptions: a root one-shot Compose initializer reads them from the host directory,
copies them into a named volume with mode `0400`, and transfers ownership to the
API's UID 10001. The API mounts only that volume read-only. This avoids relying
on a host UID mapping that is not portable across Linux and Docker Desktop.
Account/deletion development still keeps Keycloak/PostgreSQL in Compose and
runs the matching Rust process on the host. Deployed containers use the
equivalent Helm init-copy contract.

The deletion worker service account is least-privilege twice: its user receives
only `realm-management/manage-users`, and the confidential client scope exposes
only that same role while `fullScopeAllowed` remains false. Omitting either
mapping yields a deliberately failing worker permission probe.

Self-registration, email verification, password recovery, refresh-token
rotation, brute-force protection, exact redirect URIs, and PKCE S256 are
enabled. The public moderation operator client has its own audience, has no
secret or refresh token, and cannot be substituted with the mobile/API
audience. Production must use a separately registered, HTTPS-backed operator
client and issuer policy. The deletion worker is a confidential service account with only
`manage-users`. Runtime deletion addresses a previously verified subject UUID
directly and never lists or searches users. The startup probe additionally
runs one ID-prefixed, one-result query for the reserved nil UUID; `manage-users`
already authorizes that read, so `query-users` and `view-users` are not granted.
Keycloak generates its secret at import, and a local harness must
retrieve it into an owner-only temporary file. No client secret exists in the
realm export. Verify this contract with `./scripts/validate_keycloak_realm.sh`.
The validator enforces the realm-wide provider policy, the exact four-client
set, the sole least-privilege service-account user, and the absence of imported
roles, groups, identity providers, custom authentication flows, or other
extension surfaces. This development reference is a closed reviewed export:
unknown realm/client/mapper fields are rejected, `sslRequired=external` is
bound to the local Docker boundary, and SMTP is exactly unauthenticated Mailpit
on `mailpit:1025`. `scripts/test_validate_keycloak_realm.py` proves that each
required control and additive principal surface fails closed when tampered.
Worker readiness exchanges those credentials and performs two
non-destructive reads for the reserved nil UUID: the direct `GET` must return a
bounded `404`, and an ID-prefixed query bounded to one result must return a JSON
`[]`. The positive second response prevents a generic reverse-proxy 404 from
passing. `401` or `403` catches a missing/incorrect `manage-users` grant before
deletion traffic is enabled, while any surprising status, non-empty result,
redirect, or malformed response fails closed. The probe cannot return a real
user and never modifies, logs out, or deletes one.

The local bootstrap administrator defaults are deliberately confined
to Compose development; override them in `.env` even for a shared test host.
Staging and production must use externally managed secrets, HTTPS, separate
realms and clients, and their own reviewed realm export. Their different HTTPS
origins, TLS-authenticated SMTP provider, session policy, and secret-backed
confidential clients require an equivalent protected closed-contract validator;
they are substitutions to review, not reasons to relax this development
reference.

The API remains independently startable when this profile is absent. If
accounts are disabled, public reading never waits for OIDC. If accounts are
enabled and discovery/JWKS are unavailable, authenticated routes fail closed
while public reading remains available.

## Disposable account-deletion acceptance

The repository includes a deliberately opt-in, loopback-only end-to-end suite
for the destructive provider path:

```bash
LIVE_ACCOUNT_DELETION_CONFIRM=RUN_DISPOSABLE_KEYCLOAK_DELETION \
  ./scripts/test_live_account_deletion.sh
```

The wrapper starts only missing `postgres`/`accounts` Compose services, builds
the API and deletion worker, creates one verified disposable Keycloak identity,
retrieves the runtime-generated worker secret into an owner-only temporary
file, and runs the Rust API on `127.0.0.1:18084`. It refuses non-loopback API,
Keycloak, or PostgreSQL targets and refuses to share a host with an already
ready deletion worker. It stops only services it started and never removes
Compose volumes.

The suite waits long enough to prove stale `auth_time` is rejected, performs a
fresh Authorization Code + PKCE login, then verifies immediate local disable,
the signed external tombstone, the database ledger/job/event binding, session
revocation, provider identity deletion, application-data purge, completed
request replay, and a signed-ledger provider reconciliation when the Keycloak
identity is already absent. Credentials and tokens remain in an owner-only
temporary directory, are checked against captured logs, and are removed with
all scoped database/provider fixtures on exit. The suite takes at least the
configured recent-auth window (30 seconds by default).

Use `LIVE_ACCOUNT_DELETION_MANAGE_COMPOSE=0` only when the same local Compose
services are already running. Use `LIVE_ACCOUNT_DELETION_SKIP_BUILD=1` only
after building `pakperk-api` and `pakperk-deletion-worker` from the current
checkout. GitHub's `live account deletion` workflow exposes the same suite as
a manual dispatch requiring the exact confirmation phrase. It is development
acceptance evidence, not a substitute for the protected staging deletion and
restore evidence required by a production Helm release.

## Disposable comments/moderation acceptance

The manual `live comments acceptance` workflow runs
`scripts/test_live_comments.sh` only from an exact reviewed `main` tip and
declares the `live-comments-acceptance` GitHub environment gate. It creates
a unique Compose project, uses the reference PostgreSQL/Keycloak/Mailpit images
by reviewed digest, obtains mobile and dedicated-operator tokens through
Authorization Code + PKCE, and removes the complete Compose project and volumes
afterward. Dispatch requires the exact source SHA and
`RUN_DISPOSABLE_LIVE_COMMENTS` confirmation. No repository or environment
secret is consumed.

Before the first dispatch, a repository administrator must configure the
out-of-band `live-comments-acceptance` GitHub environment with required
reviewers and a deployment-branch restriction that permits only `main`.
Reconfirm those settings before release-bound regression runs. The checked-in
`environment:` and job `if:` declarations fail closed on source selection but
cannot prove that the GitHub-hosted reviewer and deployment-branch rules exist.

The retained tar contains only a closed-schema, owner-only JSON statement and
its checksum. It excludes UGC, email addresses, subjects, bearer tokens, and
dynamic database/provider identifiers. Its classification and domain-separated
reference content ID make it disposable reference evidence only. The retained
environment value is always `manual_ci_disposable_reference`; it does not claim
that GitHub's required reviewers or deployment-branch restriction were
configured or applied. The artifact cannot be used as Helm
`releaseEvidence.moderationReadinessId`. The checked-in workflow and evidence
validators do not mean the Docker acceptance was run.
