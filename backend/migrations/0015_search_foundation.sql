-- Plan 02 Phase D keeps explicit Lookup and Explore navigation separate from
-- recommendation generation and library authority. These indexes cover only
-- already persisted paper metadata; no search operation starts PDF work.

ALTER TABLE papers ADD COLUMN search_document tsvector;

CREATE FUNCTION refresh_paper_search_document()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.search_document :=
        setweight(to_tsvector('english'::regconfig, coalesce(NEW.title, '')), 'A')
        || setweight(to_tsvector('english'::regconfig, coalesce(NEW.abstract, '')), 'B')
        || setweight(to_tsvector('simple'::regconfig, coalesce(NEW.authors::text, '')), 'A')
        || setweight(
            to_tsvector(
                'simple'::regconfig,
                coalesce(array_to_string(NEW.categories, ' '), '')
            ),
            'A'
        );
    RETURN NEW;
END;
$$;

CREATE TRIGGER papers_search_document_refresh
BEFORE INSERT OR UPDATE OF title, abstract, authors, categories ON papers
FOR EACH ROW EXECUTE FUNCTION refresh_paper_search_document();

UPDATE papers
SET search_document =
    setweight(to_tsvector('english'::regconfig, coalesce(title, '')), 'A')
    || setweight(to_tsvector('english'::regconfig, coalesce(abstract, '')), 'B')
    || setweight(to_tsvector('simple'::regconfig, coalesce(authors::text, '')), 'A')
    || setweight(
        to_tsvector(
            'simple'::regconfig,
            coalesce(array_to_string(categories, ' '), '')
        ),
        'A'
    );

ALTER TABLE papers ALTER COLUMN search_document SET NOT NULL;

CREATE INDEX papers_search_document_idx
    ON papers USING gin (search_document);
CREATE INDEX papers_authors_trgm_idx
    ON papers USING gin ((lower(authors::text)) gin_trgm_ops);
CREATE INDEX papers_search_source_recency_idx
    ON papers (metadata_source, published_at DESC, id DESC);

-- A row exists only after an authenticated user explicitly saves a query.
-- The normalized query is account-owned product data and cascades on account
-- deletion. Unsaved query text is never persisted by this schema.
CREATE TABLE saved_searches (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    definition_fingerprint bytea NOT NULL CHECK (octet_length(definition_fingerprint) = 32),
    normalized_query text NOT NULL,
    categories text[] NOT NULL DEFAULT ARRAY[]::text[],
    topics text[] NOT NULL DEFAULT ARRAY[]::text[],
    published_after date,
    published_before date,
    sources text[] NOT NULL DEFAULT ARRAY['arxiv']::text[],
    sort text NOT NULL CHECK (sort IN ('relevance', 'recency')),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT saved_searches_user_definition_unique UNIQUE (user_id, definition_fingerprint),
    CONSTRAINT saved_searches_query_check CHECK (
        normalized_query = btrim(normalized_query)
        AND char_length(normalized_query) BETWEEN 2 AND 300
        AND position(chr(0) IN normalized_query) = 0
    ),
    CONSTRAINT saved_searches_categories_check CHECK (
        cardinality(categories) <= 8
        AND array_position(categories, NULL) IS NULL
    ),
    CONSTRAINT saved_searches_topics_check CHECK (
        cardinality(topics) <= 8
        AND array_position(topics, NULL) IS NULL
    ),
    CONSTRAINT saved_searches_sources_check CHECK (
        cardinality(sources) = 1
        AND sources <@ ARRAY['arxiv']::text[]
    ),
    CONSTRAINT saved_searches_date_check CHECK (
        published_after IS NULL
        OR published_before IS NULL
        OR published_after <= published_before
    ),
    CONSTRAINT saved_searches_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX saved_searches_user_updated_idx
    ON saved_searches (user_id, updated_at DESC, id DESC);

-- Retry keys are separated from saved content so even a deduplicated save
-- binds the accepted operation ID to one exact intent. The ledger contains no
-- query/filter material and is removed on a bounded schedule.
CREATE TABLE saved_search_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    intent_fingerprint bytea NOT NULL CHECK (octet_length(intent_fingerprint) = 32),
    saved_search_id uuid NOT NULL REFERENCES saved_searches(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT saved_search_operations_expiry_check CHECK (expires_at > created_at)
);

CREATE INDEX saved_search_operations_expiry_idx
    ON saved_search_operations (expires_at, user_id, operation_id);

COMMENT ON COLUMN papers.search_document IS
    'Local metadata-only search vector; indexing does not authorize PDF preparation.';
COMMENT ON TABLE saved_searches IS
    'Explicit account-owned search definitions only; never library or queue authority.';
COMMENT ON TABLE saved_search_operations IS
    'Bounded content-free saved-search idempotency ledger; never query history or queue authority.';
