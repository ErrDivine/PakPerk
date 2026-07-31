# Pakperk Privacy Notice

**Version:** `2026-07-31`
**Publication status:** release-candidate text; hosting, jurisdiction-specific
review, and final controller/contact details remain Phase 6 gates.

Pakperk is designed to work for guest readers. Guest paper reading does not
require an account. The service stores only the data needed for the features a
reader chooses:

- for accounts: OIDC issuer/subject, local user ID, public handle/display name,
  status, policy acceptances, and operational timestamps;
- for To Read: account-to-paper relationships, revisions, tombstones, and
  idempotency records;
- for comments: public normalized text, author, paper, status, versions, and
  timestamps;
- for safety: reports, blocks, rate-limit records, moderation decisions, and
  a redacted audit trail; and
- for operation: request IDs and content-free reliability/security telemetry.

Pakperk does not copy identity-provider email by default and does not collect
contacts, precise location, advertising ID, an avatar, or a personalized
ranking profile. Access/refresh tokens are not stored in general preferences,
SQLite, logs, analytics, or crash reports. Comment bodies, report details,
paper full text, model prompts, and chat messages are excluded from telemetry.

Comments are public. A block is private to the blocking account. Reports and
moderation records are restricted to operators. Service providers may process
data only to host identity, database, delivery, security, or telemetry systems
under the configured deployment.

The public retention schedule, deletion request route, provider-identity
deletion, backup/PITR deletion ledger, and jurisdiction-specific rights process
must be completed and tested in Phase 6 before public comments are enabled.
Until then, comments remain off by default. Questions use the
[support route](support.md).
