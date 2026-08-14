# Comments and moderation contract

Pakperk Production v0.0 comments are flat, public, plain-text observations on
one paper node. They are not private notes, peer review, direct messages,
replies, reactions, votes, or inline annotations.

## Availability and permissions

`COMMENTS_ENABLED=true` publishes comment reads and the associated authenticated
safety routes. `COMMENT_CREATION_ENABLED=false` is the independent emergency
write switch: it rejects only new comment creation with 503
`FEATURE_DISABLED`; existing comments remain readable, authors can still edit
or delete, users can still report comments or users, block users, and
moderators can still act.
Neither flag changes guest paper reading or paper preparation.

Guests may list published comments. An active account may report a comment,
report a user, or block another author without completing profile onboarding.
Reporting and blocking are separate: a user report creates a private moderation
record but never hides content or creates a block. Creating a comment
additionally requires a handle, the current Terms version, and the current
Community Guidelines version. Only the author may edit or delete a comment.
Suspended or deletion-pending accounts cannot mutate UGC.

Public deployment keeps comment creation off until the complete UGC policy gate
and the implemented account-deletion path are exercised and approved in that
environment. Development and staging may enable creation to exercise the same
production code path.

## HTTP surface

```text
GET    /v1/papers/{paper_id}/comments?cursor=&limit=
POST   /v1/papers/{paper_id}/comments
PATCH  /v1/comments/{comment_id}
DELETE /v1/comments/{comment_id}
POST   /v1/comments/{comment_id}/reports
POST   /v1/users/{user_id}/reports
PUT    /v1/me/blocked-users/{user_id}
DELETE /v1/me/blocked-users/{user_id}
GET    /v1/me/blocked-users?cursor=&limit=
GET    /v1/me/comments?cursor=&limit=
```

Create uses a canonical client UUID:

```json
{
  "client_request_id": "0198f4da-383f-77f0-9404-e6d6614d26e1",
  "body": "The ablation in Section 4 changes how I read the main result."
}
```

An exact replay returns the existing canonical comment. Reusing the request ID
for another paper or normalized body returns `IDEMPOTENCY_CONFLICT`; that code
is intentionally separate from a library operation-ID reuse conflict. Edits
carry the complete replacement body and `expected_version`; stale versions
return `COMMENT_EDIT_CONFLICT`. Delete, comment report, user report, block, and
unblock are repeat-safe. Comment reports are unique per reporter/comment and
user reports are independently unique per reporter/reported-user pair.
Both report request bodies use a closed shape with required `reason` and an
optional bounded `detail`. Omitting `detail` and sending explicit JSON `null`
both mean that no detail was supplied; unknown properties fail with
`INVALID_REQUEST`, matching the code-first OpenAPI schema.

Lists are newest-first and use an opaque `(created_at, id)` cursor. Cursor
ordering coordinates are AES-256-GCM encrypted, authenticated, and
bound to the exact list purpose plus paper/account/status scope. Public paper
comment cursors additionally bind the paper to an explicit guest or account
viewer identity because account block lists change the visible result set.
Clients must return tokens unchanged; tokens from another list, viewer, or
filter are rejected.
The shared rotation-ordered API keyring keeps active replicas and admin CLI
invocations interoperable without exposing timestamps or identifiers.
Paper comment lists contain published comments only. The authenticated
`GET /v1/me/comments` owner list is the sole listing surface that also exposes
that author's private `pending_review` records. Authenticated paper lists remove
blocked authors. The bounded author projection contains only local user ID,
handle, display name, and a public status marker. Report counts, moderation
reasons, provider decisions, OIDC identity, and private account data are never
returned.

Account-specific comment, comment-report, user-report, block, and owner-list responses are always
`Cache-Control: private, no-store`. Comment bodies and report details are never
placed in tracing fields, analytics, error messages, or debug output.

## Text and moderation rules

The server is authoritative. It NFKC-normalizes input, normalizes newlines,
trims outer whitespace, collapses pathological blank-line runs, rejects
unsupported control characters, and enforces 2,000 Unicode scalar values plus
a strict UTF-8 byte bound. Stored content is normalized raw text, never HTML or
rendered Markdown. Attachments are not supported. URL count and deterministic
spam/risk checks are bounded.

The mobile composer mirrors that canonicalization with the pinned MIT-licensed
`unorm_dart` NFKC implementation and pinned `characters` grapheme segmenter
before it validates or counts text. Its visible counter therefore reports
normalized Unicode scalar values, not UTF-16 code units or the raw
pre-normalization input. A 6,000-UTF-16-code-unit raw ceiling plus a 64-code-unit
and 64-scalar extended-grapheme-cluster ceiling rejects pathological pastes in
linear time before normalization or draft persistence, while still accepting
2,000 supplementary scalars and 2,000 decomposed Hangul syllables. Lone
surrogate code units fail before JSON transport. Small counters update directly;
larger accepted drafts are debounced and normalized by at most one background
isolate at a time, with stale results discarded. Send and Save stay disabled
while validation is pending or invalid, and invalid edits stay open with an
explicit error. Explicit-send preparation atomically compares canonical body
intent with the canonical last-attempted body, preserving the request ID for
NFKC- or whitespace-equivalent retries and rotating it only for a genuinely
different canonical body. Unsafe bidi/format controls, Unicode 17 NFKC sanity
vectors, expansion, repeated blank lines, scalar/byte boundaries, URL limits,
pathological clusters, and idempotent retry intent have Rust or Dart
regressions. The server remains authoritative and repeats canonicalization plus
the semantic safety, length, and link checks on create and edit.

The synchronous pipeline is:

1. Normalize and validate.
2. Apply deterministic spam, URL, and high-risk rules.
3. Enforce shared account and request-origin rate limits.
4. Recheck account/profile/community eligibility.
5. Ask the configured `ContentModerator`, when present.
6. Publish, reject, or store privately as `pending_review`.

Deterministically invalid content is rejected. A deterministic high-risk match
is held for review. With no external adapter configured, a low-risk
deterministic pass may publish. When a configured adapter is unavailable or
uncertain, the comment is held privately instead of failing open. Moderator
output and error detail remain private and content-free in diagnostics.

`COMMENT_MODERATION_PROVIDER=rules` selects the deterministic-only baseline.
`http` enables the provider-neutral server-side adapter and requires
`COMMENT_MODERATION_URL`, an owner-only
`COMMENT_MODERATION_TOKEN_FILE`, and an optional timeout of at most 10 seconds.
Deployed URLs are HTTPS, redirects are disabled, responses are capped at 64
KiB, and the accepted JSON shape is deliberately closed: `publish` has no
reason, while `pending_review` and `reject` require one bounded stable
`reason_code`. Configuration, credentials, request/response content, and
provider errors remain redacted. The Helm values mirror this contract and the
provider address must be included in the API's reviewed HTTPS egress ranges.

Request-origin rate limiting never persists a raw network address. A direct
development connection uses its peer address. A deployed API requires
`API_TRUSTED_PROXY_CIDRS`; it accepts `X-Forwarded-For` only from a peer in
those reviewed ingress ranges, walks the chain right-to-left through trusted
proxies, and uses the first untrusted address. Missing, malformed, oversized,
or untrusted metadata falls back to the direct peer, so a caller cannot choose
a fresh bucket. The selected address is canonicalized and immediately becomes
an HMAC-SHA-256 scope under `API_ORIGIN_HASH_SECRET_FILE`; it is not logged
or persisted. The file must be an owner-only, non-symlink regular file
containing 32–4,096 non-placeholder bytes. Rotating it deliberately starts
fresh origin buckets while account buckets continue unchanged, so production
rotation is coordinated during an abuse-rate window and the previous
deployment secret is retained only until old replicas and their buckets have
expired.

## Device behavior

Drift caches a bounded number of pages per `(paper, viewer account/guest)` and
shows them before refresh. Drafts are account-scoped, one per paper, and never
enter the sync outbox or auto-send after connectivity returns. Explicit Send is
required; a draft clears only after the server accepts the canonical result.
A `pending_review` result is visible privately to its author as “Under review.”
`COMMENT_PENDING_REVIEW` remains a reserved stable name, not an emitted error:
the current v0.0 contract accepts the write and returns the private canonical
comment with status `pending_review`.

Block state is account-scoped and persisted. Blocking removes that author's
cached comments from the active view immediately, while server-side filtering
makes the choice persistent across devices. Sign-out/account switch clears
drafts, block projections, personalized pages, and in-flight account work while
preserving guest-safe public paper data.

`USER_BLOCKED` is likewise reserved rather than emitted as an error. Blocking
and unblocking are idempotent relation mutations, and blocked authors are
removed by list filtering instead of turning an otherwise valid read into an
error response.

The comment action menu labels **Report comment**, **Report user**, and
**Block user** separately. A successful user report confirms that no block was
added; only the explicit block action removes the author's comments.

The code-first [OpenAPI artifact](openapi-v1.json) is the machine-readable wire
contract. The [API error catalogue](api-error-catalogue.md) distinguishes
emitted error codes from reserved stable names. The
[moderation runbook](runbooks/moderation.md) owns operational response, and the
[Community Guidelines](legal/community-guidelines.md) own the reader-facing
conduct rules.
