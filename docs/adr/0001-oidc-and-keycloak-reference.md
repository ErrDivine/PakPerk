# ADR 0001: OIDC and Keycloak reference deployment

**Status:** Accepted — implementation pending Phase 3
**Date:** 2026-07-31

## Context

Pakperk must retain guest reading while allowing users to own synchronized saves
and participate in moderated public comments. The application must not collect
or store passwords. Native clients also need a safe token lifecycle and account
deletion must revoke and remove the upstream identity in the reference
deployment.

## Decision

Pakperk is an OpenID Connect native client and resource server. Mobile uses the
Authorization Code flow with PKCE (S256) in the system browser. The API validates
tokens using OIDC discovery and JWKS, including signature, allowed algorithm,
issuer, audience, expiration/not-before, clock skew, and a required subject.

Keycloak is the local, staging, and default self-hosted production reference
provider. API authorization remains provider-neutral: verified `(issuer,
subject)` values are mapped transactionally to a local user, and destructive
provider actions are behind an `IdentityAdmin` adapter. Keycloak implements that
adapter; a no-op adapter is limited to explicitly incomplete tests/local flows.

Only refresh tokens and minimum session metadata are persisted in platform
secure storage. Access tokens remain in memory where practical. Pakperk does
not copy email into its database by default.

## Consequences

- Users can browse and read without an account; saves, comments, reports,
  blocks, and account settings require an authenticated local user.
- Mobile must implement secure storage, single-flight refresh, reauthentication,
  logout cleanup, and idempotency-aware retries.
- Backend configuration must include issuer, audience, allowed algorithms,
  discovery/JWKS timeouts, and a functioning identity-admin configuration when
  account deletion is enabled in production.
- Pakperk gains a local user record and public handle independent of provider
  display data, avoiding authorization based on client-supplied profile fields.

## Security and operational implications

- Native clients are public: no embedded client secret, and redirect/post-logout
  URIs must be exact.
- Token contents, authorization headers, OIDC subject identifiers, and emails
  must be redacted from logs, telemetry, crash reports, and local general
  storage.
- Verification fails closed when required validation metadata is unavailable;
  unsigned tokens and token-selected algorithms are never accepted.
- Keycloak must enforce email verification for self-registration, brute-force
  protection, password recovery, short-lived access tokens, and protected
  refresh-token rotation/session policy.
- Account deletion disables the local account immediately, revokes upstream
  sessions, and then performs idempotent asynchronous erasure. Production
  startup must reject an enabled deletion feature without a working admin
  adapter.
