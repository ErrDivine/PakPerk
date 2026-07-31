# Comments and moderation contract

Pakperk Production v0.0 comments are flat, public, plain-text observations on
one paper node. They are not private notes, peer review, direct messages,
replies, reactions, votes, or inline annotations.

## Availability and permissions

`COMMENTS_ENABLED=true` publishes comment reads and the associated authenticated
safety routes. `COMMENT_CREATION_ENABLED=false` is the independent emergency
write switch: it rejects only new comment creation with 503
`FEATURE_DISABLED`; existing comments remain readable, authors can still edit
or delete, users can still report or block, and moderators can still act.
Neither flag changes guest paper reading or paper preparation.

Guests may list published comments. An active account may report a comment or
block another author without completing profile onboarding. Creating a comment
additionally requires a handle, the current Terms version, and the current
Community Guidelines version. Only the author may edit or delete a comment.
Suspended or deletion-pending accounts cannot mutate UGC.

Public deployment keeps comment creation off until the complete UGC policy gate
and Phase 6 account-deletion path are live. Development and staging may enable
creation to exercise the same production code path.

## HTTP surface

```text
GET    /v1/papers/{paper_id}/comments?cursor=&limit=
POST   /v1/papers/{paper_id}/comments
PATCH  /v1/comments/{comment_id}
DELETE /v1/comments/{comment_id}
POST   /v1/comments/{comment_id}/reports
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
for another paper or normalized body returns `IDEMPOTENCY_CONFLICT`. Edits carry
the complete replacement body and `expected_version`; stale versions return
`COMMENT_EDIT_CONFLICT`. Delete, report, block, and unblock are repeat-safe.

Lists are newest-first and use an opaque `(created_at, id)` cursor. Paper
comment lists contain published comments only. The authenticated
`GET /v1/me/comments` owner list is the sole listing surface that also exposes
that author's private `pending_review` records. Authenticated paper lists remove
blocked authors. The bounded author projection contains only local user ID,
handle, display name, and a public status marker. Report counts, moderation
reasons, provider decisions, OIDC identity, and private account data are never
returned.

Account-specific comment, report, block, and owner-list responses are always
`Cache-Control: private, no-store`. Comment bodies and report details are never
placed in tracing fields, analytics, error messages, or debug output.

## Text and moderation rules

The server is authoritative. It NFKC-normalizes input, normalizes newlines,
trims outer whitespace, collapses pathological blank-line runs, rejects
unsupported control characters, and enforces 2,000 Unicode scalar values plus
a strict UTF-8 byte bound. Stored content is normalized raw text, never HTML or
rendered Markdown. Attachments are not supported. URL count and deterministic
spam/risk checks are bounded.

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

Request-origin rate limiting never persists a raw network address. The API
canonicalizes the directly connected peer address and derives an HMAC-SHA-256
scope with `COMMENT_ORIGIN_HASH_SECRET_FILE`; forwarded-address headers are not
trusted. The file must be an owner-only, non-symlink regular file containing
32–4,096 non-placeholder bytes. Rotating it deliberately starts fresh origin
buckets while account buckets continue unchanged, so production rotation is
coordinated during an abuse-rate window and the previous deployment secret is
retained only until old replicas and their buckets have expired.

## Device behavior

Drift caches a bounded number of pages per `(paper, viewer account/guest)` and
shows them before refresh. Drafts are account-scoped, one per paper, and never
enter the sync outbox or auto-send after connectivity returns. Explicit Send is
required; a draft clears only after the server accepts the canonical result.
A `pending_review` result is visible privately to its author as “Under review.”

Block state is account-scoped and persisted. Blocking removes that author's
cached comments from the active view immediately, while server-side filtering
makes the choice persistent across devices. Sign-out/account switch clears
drafts, block projections, personalized pages, and in-flight account work while
preserving guest-safe public paper data.

The code-first [OpenAPI artifact](openapi-v1.json) is the machine-readable wire
contract. The [moderation runbook](runbooks/moderation.md) owns operational
response, and the [Community Guidelines](legal/community-guidelines.md) own the
reader-facing conduct rules.
