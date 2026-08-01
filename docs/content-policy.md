# Full-text and arXiv data policy

Pakperk uses arXiv metadata and links every record back to its original arXiv
page. Pakperk is not affiliated with or endorsed by arXiv.

## Production v0.0 policy status

The production migration now contains a feature-gated public paper-comment
implementation. It includes authenticated posting, explicit Terms and
Community Guidelines acceptance, normalized plain-text validation, distinct
comment and user reporting, durable user blocking, audited moderation actions,
shared rate limits, and a stable support contract. Reporting never creates a
block or changes visibility. Both comment flags remain off by default. The
repository now supplies account deletion, hosted policy/support, retention
enforcement, telemetry, and operational controls, but public creation remains
prohibited until those controls are exercised in the target environment and
legal/store/moderation owners approve the evidence. This is an implemented
dark-launch capability, not a claim that public UGC is live.

When comments are enabled in a production release, comments are public
user-generated content. They are not private notes or scholarly endorsements;
the product discloses that fact and provides separate **Report comment**,
**Report user**, **Block user**, support, and author-removal routes.
`COMMENT_CREATION_ENABLED=false` stops only new posts so that
reading and safety operations remain available. The authoritative product,
moderation, retention, and deletion requirements are in
[the Production v0.0 plan](production-v0.0-plan.md) and
[ADR 0004](adr/0004-public-comments-and-moderation.md); the concrete wire and
device behavior is in the
[comments and moderation contract](comments-and-moderation.md).

`FULLTEXT_POLICY` has two modes:

- `prototype` is for local research and demonstration. A worker downloads a
  validated arXiv PDF to a random temporary path, never serves that PDF, parses
  it, and removes it after normalization.
- `strict` publishes introduction/full-text-derived capabilities only when the
  cached paper license permits the configured reuse. Otherwise the paper remains
  metadata-only with an external arXiv link.

The worker checks this policy before creating artifacts and the API checks it
again every time derived content is served. The second check is intentional:
switching a deployment from `prototype` to `strict` immediately masks old
capabilities and denies persisted Introduction, Chat, and Connections data for
unknown or unsupported licenses; a database cleanup is not required.

Mobile builds have a corresponding compile-time switch:

```sh
--dart-define=PAKPERK_FULLTEXT_POLICY=strict
```

Use it together with backend strict mode. When offline, a strict build retains
metadata and original arXiv links but never falls back to device-cached or
bundled derived content. A backend policy denial uses HTTP 403 with stable code
`FULLTEXT_POLICY_DENIED` and is never treated as a transient fallback signal.

Metadata, licenses, exact-ID lookups, and search results are cached. All legacy
arXiv API requests pass through one database-backed cross-process gate with a
minimum interval of three seconds by default and honor `Retry-After`.

Before a public launch, the display and retention policy for derived full text
requires review by qualified counsel. The prototype switch is not a legal
determination.
