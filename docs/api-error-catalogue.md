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
