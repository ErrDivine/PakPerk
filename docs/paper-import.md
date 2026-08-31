# Manual paper search and import contract

**Status:** Phase 2 implementation; endpoints remain dark unless their
default-off feature flags are enabled
**Extraction baseline:** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

Manual addition is split into a bounded title search and an idempotent exact
import. Both are authenticated server operations. Mobile never calls arXiv
directly, and the API never fetches a submitted URL.

Every success and error is account-private and has `Cache-Control: private,
no-store`, `Vary: Authorization`, and `X-Request-Id`. The routes are absent
unless their complete parent capability is enabled.

## Title search

```http
POST /v1/me/paper-searches
Authorization: Bearer <access-token>
Content-Type: application/json
```

Registration requires `ACCOUNTS_ENABLED=true`,
`PAPER_RESOLUTION_ENABLED=true`, and `PAPER_TITLE_SEARCH_ENABLED=true`.

Strict request schema:

| Field | Type | Bounds |
| --- | --- | --- |
| `query` | string | Required; Unicode/whitespace normalized; 3–300 Unicode scalar values; NUL and controls other than ordinary whitespace rejected. |
| `limit` | integer | Optional; positive and at most 10; server policy supplies the default. |

Unknown fields are rejected. The raw title is not placed in a URL, log,
metric, trace attribute, or persistent operation ledger.

```json
{
  "query": "Attention Is All You Need",
  "limit": 8
}
```

Successful strict response schema:

| Field | Type | Contract |
| --- | --- | --- |
| `query_id` | UUID string | Opaque request/result correlation identifier; not account identity. |
| `normalized_query` | string | Normalized submitted title returned to the caller; never logged by the service. |
| `candidates` | array | Zero to the accepted limit; search does not save any candidate. |
| `candidates[].arxiv_id` | string | Canonical versioned arXiv identifier when supplied by arXiv. |
| `candidates[].title` | string | Bounded arXiv metadata. |
| `candidates[].authors` | string array | Bounded author projection. |
| `candidates[].abstract` | string | Bounded abstract metadata. |
| `candidates[].primary_category` | string | Primary arXiv category. |
| `candidates[].categories` | string array | Bounded category projection. |
| `candidates[].published_at` | RFC 3339 UTC string | Publication timestamp. |
| `candidates[].updated_at` | RFC 3339 UTC string | Metadata update timestamp. |
| `candidates[].abs_url` | HTTPS URL string | Server-constructed canonical arXiv abstract URL. |
| `candidates[].match.kind` | `"title"` | Closed match kind for v1. |
| `candidates[].match.rank` | positive integer | Stable ordering within this result only. |

```json
{
  "query_id": "0198f500-0000-7000-8000-000000000001",
  "normalized_query": "Attention Is All You Need",
  "candidates": [
    {
      "arxiv_id": "1706.03762v7",
      "title": "Attention Is All You Need",
      "authors": ["Ashish Vaswani", "Noam Shazeer"],
      "abstract": "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
      "primary_category": "cs.CL",
      "categories": ["cs.CL", "cs.LG"],
      "published_at": "2017-06-12T00:00:00Z",
      "updated_at": "2023-08-02T00:00:00Z",
      "abs_url": "https://arxiv.org/abs/1706.03762v7",
      "match": {
        "kind": "title",
        "rank": 1
      }
    }
  ]
}
```

The server reuses the existing safe title-query builder, arXiv client, shared
PostgreSQL reservation/rate gate, and a persistent query-digest cache. It
returns candidates only and does not upsert every result or auto-select the
first match.

## Exact import

```http
POST /v1/me/library/imports
Authorization: Bearer <access-token>
Idempotency-Key: 0198f500-0000-7000-8000-000000000010
Content-Type: application/json
```

Parent route registration requires `ACCOUNTS_ENABLED=true`,
`LIBRARY_ENABLED=true`, and `PAPER_RESOLUTION_ENABLED=true`. Successful writes
also require `LIBRARY_WRITES_ENABLED=true` and
`LIBRARY_IMPORT_WRITES_ENABLED=true`; the latter remains an independent
runtime kill switch which returns `FEATURE_DISABLED` while closed.

The `Idempotency-Key` and body `operation_id` are the same canonical UUID.
The strict request is a discriminated union:

```json
{
  "operation_id": "0198f500-0000-7000-8000-000000000010",
  "source": {
    "kind": "arxiv_url",
    "value": "https://arxiv.org/abs/1706.03762"
  },
  "target_state": "inbox",
  "save_source_kind": "arxiv_url"
}
```

```json
{
  "operation_id": "0198f500-0000-7000-8000-000000000011",
  "source": {
    "kind": "arxiv_id",
    "value": "1706.03762v7"
  },
  "target_state": "inbox",
  "save_source_kind": "title_search"
}
```

| Field | Type | Contract |
| --- | --- | --- |
| `operation_id` | UUID string | Required durable idempotency identifier; must match the header. |
| `source.kind` | `"arxiv_url" \| "arxiv_id"` | Closed discriminator. Title selections use `arxiv_id`. |
| `source.value` | string | Required bounded input; parsed and normalized before resolution. |
| `target_state` | `"inbox"` | Required explicit queue intent; imports cannot write another library state. |
| `save_source_kind` | `"arxiv_url" \| "arxiv_id" \| "title_search" \| "lookup" \| "discovery" \| "connection" \| "other"` | Required closed provenance. Direct URL/ID provenance must agree with `source.kind`; contextual discovery flows retain their actual source. |

A successful response combines canonical resolution, the existing library row
shape, the existing `PaperSummary`, and the committed account revision:

```json
{
  "result": "saved",
  "resolution": {
    "input_kind": "arxiv_url",
    "canonical_arxiv_id": "1706.03762v7"
  },
  "item": {
    "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
    "state": "inbox",
    "private_note": null,
    "save_source_kind": "arxiv_url",
    "saved_at": "2026-08-19T12:00:00Z",
    "updated_at": "2026-08-19T12:00:00Z",
    "reviewed_at": null,
    "archived_at": null,
    "removed": false,
    "removed_at": null,
    "revision": 130,
    "last_operation_id": "0198f500-0000-7000-8000-000000000010"
  },
  "paper": {
    "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
    "arxiv_id": "1706.03762v7",
    "title": "Attention Is All You Need",
    "abstract": "Bounded public arXiv metadata.",
    "authors": ["Ashish Vaswani", "Noam Shazeer"],
    "primary_category": "cs.CL",
    "categories": ["cs.CL", "cs.LG"],
    "published_at": "2017-06-12T00:00:00Z",
    "updated_at": "2023-08-02T00:00:00Z",
    "abs_url": "https://arxiv.org/abs/1706.03762v7",
    "pdf_url": "https://arxiv.org/pdf/1706.03762v7",
    "capabilities": {
      "metadata": true,
      "introduction": false,
      "chat": false,
      "connections": false
    }
  },
  "sync_revision": 130
}
```

`result` is the closed value `saved` for v1, including an exact replay of an
already completed operation. The response uses the v2 library item so the
Inbox state, private-note slot, and accepted save provenance are not projected
back to the legacy `to_read` shape. The replay returns canonical current data
without allocating a second operation or queue row. The target state and save
source are part of the operation fingerprint, so reusing an operation ID with
different intent is a conflict.

## Accepted input and network boundary

The strict parser initially accepts:

```text
https://arxiv.org/abs/{id}
https://arxiv.org/pdf/{id}
https://arxiv.org/pdf/{id}.pdf
bare arXiv identifier through kind=arxiv_id
```

`https://export.arxiv.org/abs/{id}` is not accepted unless a later contract
change explicitly opts in and adds fixtures. Production/staging reject HTTP,
userinfo, custom ports, unexpected query/fragment data, non-arXiv hosts,
deceptive subdomains, IP literals, redirects, URL shorteners, arbitrary PDFs,
encoded-host tricks, traversal, and malformed/unsupported identifiers.

After parsing, the server discards the submitted URL and resolves by normalized
arXiv identifier through the shared exact-resolution service. The submitted URL
is never an HTTP destination. Resolution or import never downloads a PDF,
creates a preparation job, invokes GROBID, or calls a model.

## Idempotency and recovery

The additive migration reserves an import operation by
`(user_id, operation_id)` before an internal paper UUID necessarily exists. It
stores a versioned input fingerprint, normalized arXiv base only after
safe parsing, eventual paper ID, closed status, and timestamps. It never stores
the raw URL or title.

| Replay state | Result |
| --- | --- |
| Same operation and fingerprint, completed | Return the canonical saved result. |
| Same operation, different fingerprint | `409 PAPER_IMPORT_OPERATION_CONFLICT`. |
| Process stops after metadata upsert | Retry safely resolves/upserts and continues the library save. |
| Process stops after save before response | Retry returns the committed canonical saved state. |

No database transaction remains open while arXiv is called. Final library
state, per-user revision, existing library-operation record, and import
completion are committed atomically where the repository boundary permits.

## Stable errors

All failures use the existing `{ "error": { "code", "message",
"retryable", "request_id" } }` envelope.

| HTTP | Code | Retryable | Meaning |
| ---: | --- | :---: | --- |
| 400 | `INVALID_PAPER_INPUT` | no | Strict body, discriminator, identifier, or input is invalid. |
| 400 | `UNSUPPORTED_PAPER_URL` | no | URL is outside the accepted arXiv forms. |
| 400 | `PAPER_SEARCH_QUERY_TOO_SHORT` | no | Normalized title has fewer than three scalar values. |
| 404 | `PAPER_RESOLUTION_NOT_FOUND` | no | Exact arXiv paper is not found. |
| 409 | `PAPER_IMPORT_OPERATION_CONFLICT` | no | Operation ID was reused for a different input. |
| 429 | `RATE_LIMITED` | yes | Account/origin or upstream policy denied the attempt; honor `Retry-After`. |
| 503 | `PAPER_SEARCH_UNAVAILABLE` | yes | Search dependency is temporarily unavailable. |
| 503 | `FEATURE_DISABLED` | context-dependent | A deployment kill switch is closed. |

Contract fixtures live under
`backend/apps/api/tests/fixtures/to_read_first/` and complement the code-first
OpenAPI schemas and service/API invariant tests.

## Independent staging enablement

Enable `PAPER_RESOLUTION_ENABLED` first and prove that the existing public
exact-paper route is unchanged. Then exercise title search and import as two
independent staging changes:

- title search requires accounts, paper resolution, a monitored arXiv contact,
  and the shared database gate/cache before
  `PAPER_TITLE_SEARCH_ENABLED=true`; and
- import requires accounts, library, library writes, and resolution before
  `LIBRARY_IMPORT_WRITES_ENABLED=true`. Closing the import switch must preserve
  library reads and ordinary save/remove behavior.

For each switch, retain the rendered off/on/off values, allowed and disabled
request results, bounded quota/cache behavior, upstream degradation result, and
cleanup. Search/import enablement does not enable the reading feed or strict
queue-first enforcement.

The protected privacy scan must cover API logs, Collector output, the external
sink, and retained evidence. It must find no raw search query or paper title,
submitted URL, bearer or refresh token, account identifier, or cursor. The
submitted URL is discarded after parsing and must never appear as an outbound
destination. Evidence may retain only closed operation/input-kind/outcome
enums, length/result buckets, request IDs, aggregate counts, and approved
content-free canaries.

A passing parser test, mock arXiv response, or Helm render does not prove the
live boundary. Release evidence must bind the exact monitored arXiv contact,
shared multi-replica gate/cache, protected staging adapter, per-account and
upstream limits, retry behavior, no-preparation assertion, privacy scan, and
service/privacy/release approvals. Roll back title search and import
independently; turn resolution off only after both consumers are closed.
