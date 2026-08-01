# Pakperk Privacy Notice

**Version:** `2026-07-31`
**Publication status:** release-candidate text. A production release must
configure the monitored controller/support contact shown on the public policy
site and complete the jurisdiction-specific review recorded in the release
evidence.

Pakperk is the service controller unless the published support page identifies
a different operating entity. The production-configured monitored address on
that page is the contact for privacy, access, correction, deletion, objection,
and legal requests. A placeholder or unreachable contact blocks release.

Pakperk works for guest readers without an account. The service stores only the
data needed for features a reader chooses:

- accounts: the identity provider retains verified email for optional
  registration, login, and recovery; Pakperk stores OIDC issuer/subject, local
  user ID, public handle/display name, status, policy acceptances, and
  operational timestamps in its application database;
- To Read: account-to-paper relationships, revisions, tombstones, and
  idempotency records;
- comments: public normalized text, author, paper, status, versions, and
  timestamps;
- safety: reports, blocks, rate-limit records, moderation decisions, and a
  redacted audit trail; and
- operation: request IDs and content-free reliability/security telemetry.

The Pakperk application profile database does not copy the identity-provider
email. Pakperk does not collect address-book contacts, precise location, an
advertising ID, an avatar, or a personalized ranking profile. Access and
refresh tokens are excluded from general preferences, SQLite, and
Pakperk-managed telemetry. Comment bodies, report details, paper full text,
model prompts, chat messages, handles, email, and identity-provider subjects
are excluded from operational telemetry.

Pakperk sends its telemetry provider only a sanitized error category, never a
raw exception or stack. An uncaught fatal error is not swallowed and may create
an OS-managed Apple or Google crash diagnostic containing a native crash record
or runtime stack under the platform's settings and policy. This platform path
is separate from Pakperk's custom telemetry and is reviewed with the signed
release and configured processors.

For shared abuse limits on comments and expensive public paper actions such as
preparation and chat, the application resolves a request-origin address from a
forwarded chain only when the direct peer belongs to a configured ingress-proxy
CIDR. It evaluates that chain right-to-left; missing, malformed, or untrusted
chains fall back to the direct peer. The application immediately derives an
HMAC-SHA-256 scope from the selected address, does not log or persist the raw
address, and persists only the keyed pseudonym through the configured
rate-limit window, which cannot exceed 30 days. Production edge security/access
logs may separately retain a source network address for up to 30 days. These
network/security identifiers are not used for advertising or tracking and are
separate from identifier-free mobile telemetry.

Comments are public. A block is private to the blocking account. Reports and
moderation records are restricted to authorized operators. Contracted
providers process data only for configured identity, database, delivery,
security, backup, or telemetry functions.

## Retention schedule

The production release is configured to the following maximum/default
schedule. Increasing a period requires a reviewed policy update before the
configuration change is deployed.

- Live profile, library, comments, blocks, reports, and provider identity,
  including its verified email, are kept while the account is active, then
  removed by the deletion workflow.
- Keyed request-origin abuse-limit scopes are kept until the configured rate
  window expires (at most **30 days**) and are then removed by bounded
  maintenance. Recoverable copies remain subject to the backup horizon below.
- Recoverable PostgreSQL/identity backups and PITR history expire within
  **35 days**. A restore is never returned to service until current deletion
  authority has been reapplied and verified.
- Anonymized security and moderation audit records expire after **90 days**.
- Content-free operational telemetry and application/platform logs expire
  after **30 days** at the upstream telemetry and logging systems.
- A separately backed-up, signed deletion-authority record is kept for at
  least **400 days** and, if longer, until evidence proves no recoverable
  backup can resurrect the deleted account. It contains a keyed identity
  fingerprint and encrypted provider issuer/subject recovery coordinates, not
  profile or comment content. Those coordinates are decryptable only by the
  restricted account-deletion API and worker components while the record
  remains authorized.

After the backup-safety condition is met, an operator-controlled final purge
removes the deletion-authority record and its encrypted provider coordinates.
Historical verification/decryption keys are retained only while a retained
record or recoverable backup needs them. A specific preservation obligation
may pause deletion only through a documented, access-controlled case with a
recorded basis, scope, owner, and expiry; it is not an open-ended default.

## Account deletion and requests

Deleting an account disables access immediately. The worker revokes provider
sessions, deletes the provider identity, and removes the profile, To Read
library, comments, blocks, reports, and pending account-owned operations.
Public paper metadata that is not account-owned remains. The signed deletion
authority makes retries idempotent and prevents a restored backup from
silently recreating the account.

Use the public account-deletion route or the in-app action for removal. Use the
[support route](support.md) for access, correction, privacy, copyright, or
legal questions. Include an operation ID when available; never send a
password, authorization code, or token.
