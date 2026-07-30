# Full-text and arXiv data policy

Pakperk uses arXiv metadata and links every record back to its original arXiv
page. Pakperk is not affiliated with or endorsed by arXiv.

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
