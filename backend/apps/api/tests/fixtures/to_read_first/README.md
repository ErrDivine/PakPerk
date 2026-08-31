# To Read First contract fixtures

These executable JSON examples mirror the implemented contracts in
`docs/reading-feed.md` and `docs/paper-import.md`:

- `reading_feed_to_read.json`;
- `reading_feed_recommendations.json`;
- `paper_search_request.json`;
- `paper_search_response.json`;
- `library_import_url_request.json`; and
- `library_import_saved_response.json`.

`../../to_read_first_contract_scaffold.rs` parses every exact file, validates
its strict shape against the API's generated OpenAPI components, and enforces
the queue-first, search-only, idempotent-import, metadata-only, and privacy
invariants without a database or network. Keep these examples synchronized
with the code-first serializers. Avoid adding placeholders, secrets, account
identifiers, raw access tokens, non-null private notes, or arbitrary external
URLs.
