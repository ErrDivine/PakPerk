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
- Redirect: `pakperk-auth://oauth/callback`
- Post-logout redirect: `pakperk-auth://oauth/logout`
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
set -a
source .env
set +a
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

This is required because `localhost` inside the Compose API container refers
to the container itself, while changing the issuer hostname for just one
participant breaks OIDC exact-issuer validation.

Self-registration, email verification, password recovery, refresh-token
rotation, brute-force protection, exact redirect URIs, and PKCE S256 are
enabled. The local bootstrap administrator defaults are deliberately confined
to Compose development; override them in `.env` even for a shared test host.
Staging and production must use externally managed secrets, HTTPS, separate
realms and clients, and their own reviewed realm export.

The API remains independently startable when this profile is absent. If
accounts are disabled, public reading never waits for OIDC. If accounts are
enabled and discovery/JWKS are unavailable, authenticated routes fail closed
while public reading remains available.
