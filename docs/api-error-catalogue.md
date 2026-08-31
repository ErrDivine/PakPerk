# Production v0.0 API error catalogue

The canonical Production v0.0 plan mandates the stable names below. This is a
compatibility catalogue, not an exhaustive list of every validation or
service-specific error the API can return; endpoint-specific errors remain in
the code-first [OpenAPI artifact](openapi-v1.json).

An **emitted** name can appear in the `error.code` field of the standard error
envelope. A **reserved** name is part of the stable vocabulary but is not
currently emitted as an error. Clients must use the documented successful
representation for reserved behavior and must not wait for a reserved error
before updating local state.

The canonical plan lists 19 names:

| Stable name | Status | Current v0.0 meaning |
| --- | --- | --- |
| `UNAUTHENTICATED` | Emitted (401) | A bearer token is absent, malformed, invalid, or cannot identify an account. |
| `TOKEN_EXPIRED` | Emitted (401) | An otherwise recognized bearer token is expired. |
| `REAUTHENTICATION_REQUIRED` | Emitted (401) | A sensitive action requires a sufficiently recent sign-in. |
| `ACCOUNT_INCOMPLETE` | Emitted (403) | A community action requires the account's profile setup to be complete. |
| `ACCOUNT_SUSPENDED` | Emitted (403) | The account is suspended and cannot perform the requested private action. |
| `ACCOUNT_DELETION_PENDING` | Emitted (403) | The account is unavailable because deletion is pending or already committed. |
| `FORBIDDEN` | Reserved | The API currently returns narrower domain codes for authorization denials instead of this generic name. |
| `PROFILE_VERSION_CONFLICT` | Emitted (412) | A profile precondition is stale; reload the current profile and entity tag. |
| `HANDLE_UNAVAILABLE` | Emitted (409) | The requested public handle cannot be claimed. |
| `TERMS_ACCEPTANCE_REQUIRED` | Emitted (403) | A community action requires current terms and guidelines acceptance. |
| `LIBRARY_OPERATION_CONFLICT` | Emitted (409) | A library operation ID was reused for a different paper or mutation intent. |
| `COMMENT_NOT_FOUND` | Emitted (404) | The requested comment is absent or is not visible to the caller. |
| `COMMENT_EDIT_CONFLICT` | Emitted (409) | The comment version changed before the submitted edit. |
| `COMMENT_REJECTED` | Emitted (422) | The moderation pipeline rejected a comment body. |
| `COMMENT_PENDING_REVIEW` | Reserved | Pending review is a successful accepted write whose private canonical comment has status `pending_review`; it is not an error response. |
| `USER_BLOCKED` | Reserved | Block/unblock are idempotent relation mutations and reads filter blocked authors; the relation is not surfaced as an error response. |
| `RATE_LIMITED` | Emitted (429) | A shared request or mutation limit was reached; honor `Retry-After`. |
| `IDEMPOTENCY_CONFLICT` | Emitted (409) | A comment `client_request_id` was reused for a different paper or normalized body. |
| `FEATURE_DISABLED` | Emitted (route-dependent 404 or 503) | The requested feature or write path is disabled by configuration or an emergency switch. |

Stable names are compared exactly and must not be repurposed. In particular,
library operation-ID conflicts use `LIBRARY_OPERATION_CONFLICT`, while comment
creation request-ID conflicts continue to use `IDEMPOTENCY_CONFLICT`.

## To Read First reserved vocabulary

The To Read First contracts add the following names. Search/import and
reading-feed names are emitted by the checked API when their default-off
parent routes are enabled. A disabled parent capability still leaves its route
absent; the checked OpenAPI is a capability contract, not rollout authority.

| Stable name | Status | Frozen meaning |
| --- | --- | --- |
| `INVALID_PAPER_INPUT` | Emitted (400) | The strict import/search body, input kind, or identifier is invalid. |
| `UNSUPPORTED_PAPER_URL` | Emitted (400) | A submitted URL is outside the explicitly accepted HTTPS arXiv forms. |
| `PAPER_SEARCH_QUERY_TOO_SHORT` | Emitted (400) | The normalized title is below the minimum three Unicode scalar values. |
| `PAPER_RESOLUTION_NOT_FOUND` | Emitted (404) | Exact arXiv resolution found no paper. |
| `PAPER_IMPORT_OPERATION_CONFLICT` | Emitted (409) | An import operation ID was reused with a different input fingerprint. |
| `READING_FEED_CURSOR_STALE` | Emitted (409) | The account library revision changed; discard the cursor and restart page one. |
| `LIBRARY_SYNC_RESET_REQUIRED` | Emitted (410) | Existing library behavior; replace the account projection before resuming changes. |
| `PAPER_SEARCH_UNAVAILABLE` | Emitted (503) | The bounded title-search dependency is temporarily unavailable. |
| `QUEUE_AUTHORITY_UNAVAILABLE` | Emitted (503) | The server cannot authoritatively choose queue or recommendation mode and fails closed. |

The new operations also reuse `UNAUTHENTICATED`, `ACCOUNT_SUSPENDED`,
`ACCOUNT_DELETION_PENDING`, `RATE_LIMITED`, and `FEATURE_DISABLED` without
changing their meanings. See [Authenticated reading feed](reading-feed.md) and
[Manual paper search and import](paper-import.md) for route-specific status and
retry behavior.

## Queue-first discovery vocabulary

The default-off v0.1 discovery surfaces add these stable names. They do not
authorize recommendation mode; queue eligibility remains an independent,
server-proven reading-feed decision.

| Stable name | Status | Frozen meaning |
| --- | --- | --- |
| `INVALID_RECOMMENDATION_FEEDBACK` | Emitted (400) | Feedback is structurally invalid or combines a positive signal with a negative reason. |
| `RECOMMENDATION_ITEM_NOT_FOUND` | Emitted (404) | The authenticated account does not own the requested server-created batch/item pair, or it no longer exists. |
| `RECOMMENDATION_SERVICE_UNAVAILABLE` | Emitted (503) | Immutable explanation or explicit-feedback persistence is temporarily unavailable. |
| `ACCOUNT_UNAVAILABLE` | Emitted (403) | The account became unavailable during a recommendation persistence operation. |
| `INVALID_EVENT_BATCH` | Emitted (400) | The optional content-free event batch violates its closed schema, time, count, or retention bounds. |
| `INVALID_EVENT_PRINCIPAL` | Emitted (400) | Event ingestion received neither a verified account nor a valid anonymous session identifier. |
| `INVALID_RECOMMENDATION_EVENT` | Emitted (400) | A recommendation event does not match a current server-owned batch/item binding. |
| `INTERACTION_CONSENT_REQUIRED` | Emitted (400) | An account attempted behavioral collection without its stored personalization opt-in, or an anonymous session attempted any event collection before a verifiable guest-consent authority exists. Essential account Library state remains independent. |
| `EVENT_SERVICE_UNAVAILABLE` | Emitted (503) | Optional event persistence is temporarily unavailable; product and queue state remain authoritative without it. |
| `SAVED_SEARCH_ID_INVALID` | Emitted (400) | A saved-query deletion path contains the nil UUID. Absent and foreign-scoped non-nil IDs instead receive the same repeat-safe 204 response. |

## Deep Reader Assistant feedback vocabulary

The default-off Assistant v2 evidence-feedback route adds three emitted names.
They describe only correction persistence for one exact answer; they are not a
generic rating or sentiment vocabulary.

| Stable name | Status | Frozen meaning |
| --- | --- | --- |
| `INVALID_ASSISTANT_FEEDBACK` | Emitted (400) | The closed evidence-correction category, optional private detail, or required claim/evidence target shape is invalid, or the claimed target is not present in the persisted answer evidence map. |
| `ASSISTANT_FEEDBACK_TARGET_NOT_FOUND` | Emitted (404) | The exact response/thread/provenance tuple does not belong to the caller, paper, and current generation, has expired, or is otherwise unavailable. These cases intentionally share one non-disclosing response. |
| `ASSISTANT_FEEDBACK_IDEMPOTENCY_CONFLICT` | Emitted (409) | The principal already used the operation ID for different Assistant evidence feedback. An exact replay instead returns the original successful receipt. |

## Deep Reader research export vocabulary

The private research export keeps legacy single-response downloads for small
archives and provides `paged=true` for lossless bounded traversal. Pagination
cursors are opaque and bound to the authenticated principal and optional paper
scope.

| Stable name | Status | Frozen meaning |
| --- | --- | --- |
| `INVALID_RESEARCH_CURSOR` | Emitted (400) | The cursor is malformed, expired by key rotation, or belongs to another principal, paper scope, or export contract. Restart at the first page without a cursor. |
| `RESEARCH_EXPORT_REQUIRES_PAGING` | Emitted (413) | A legacy single-response JSON or Markdown export exceeds its safe bound. Retry with `paged=true` and follow every returned next cursor; users are never instructed to delete valid private text. |
| `RESEARCH_EXPORT_ARTIFACT_INVALID` | Emitted (500) | Persisted data violated the per-artifact response invariant. The service fails closed without reflecting private content. |
