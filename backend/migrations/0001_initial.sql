CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE papers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    arxiv_base_id text NOT NULL UNIQUE,
    arxiv_version integer NOT NULL CHECK (arxiv_version > 0),
    title text NOT NULL CHECK (btrim(title) <> ''),
    normalized_title text GENERATED ALWAYS AS (
        btrim(regexp_replace(lower(title), '[^[:alnum:]]+', ' ', 'g'))
    ) STORED,
    abstract text NOT NULL,
    authors jsonb NOT NULL CHECK (jsonb_typeof(authors) = 'array'),
    primary_category text NOT NULL CHECK (btrim(primary_category) <> ''),
    categories text[] NOT NULL CHECK (cardinality(categories) > 0),
    published_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    abs_url text NOT NULL,
    pdf_url text NOT NULL,
    doi text,
    journal_reference text,
    comment text,
    license_uri text,
    metadata_source text NOT NULL DEFAULT 'arxiv',
    metadata_fetched_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (btrim(arxiv_base_id) <> ''),
    CHECK (updated_at >= published_at)
);

CREATE INDEX papers_feed_idx ON papers (published_at DESC, id DESC);
CREATE INDEX papers_categories_idx ON papers USING gin (categories);
CREATE INDEX papers_normalized_title_trgm_idx
    ON papers USING gin (normalized_title gin_trgm_ops);
CREATE INDEX papers_doi_idx ON papers (doi) WHERE doi IS NOT NULL;

CREATE TABLE paper_processing (
    paper_id uuid PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    stage text NOT NULL DEFAULT 'not_requested' CHECK (
        stage IN (
            'not_requested',
            'queued',
            'fetching_license',
            'fetching_pdf',
            'parsing_pdf',
            'introduction_ready',
            'indexing_chat',
            'resolving_references',
            'ready',
            'failed_retryable',
            'failed_terminal'
        )
    ),
    metadata_ready boolean NOT NULL DEFAULT true,
    introduction_ready boolean NOT NULL DEFAULT false,
    chat_ready boolean NOT NULL DEFAULT false,
    connections_ready boolean NOT NULL DEFAULT false,
    retryable boolean NOT NULL DEFAULT false,
    last_error_category text CHECK (
        last_error_category IS NULL
        OR last_error_category IN (
            'external_temporary',
            'external_permanent',
            'parser_temporary',
            'parser_document',
            'model_temporary',
            'validation',
            'internal'
        )
    ),
    last_error_code text,
    last_error_message text,
    started_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    parser_version text,
    embedding_model text,
    summary_model text,
    CHECK (NOT retryable OR stage = 'failed_retryable'),
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);

CREATE INDEX paper_processing_stage_idx ON paper_processing (stage, updated_at);

CREATE TABLE paper_sections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    kind text NOT NULL CHECK (
        kind IN (
            'abstract',
            'introduction',
            'background',
            'related_work',
            'method',
            'experiment',
            'result',
            'discussion',
            'limitation',
            'conclusion',
            'appendix',
            'acknowledgment',
            'references',
            'other'
        )
    ),
    heading text,
    text text NOT NULL CHECK (btrim(text) <> ''),
    paragraphs jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
        jsonb_typeof(paragraphs) = 'array'
    ),
    page_start integer CHECK (page_start IS NULL OR page_start > 0),
    page_end integer CHECK (page_end IS NULL OR page_end > 0),
    visible_in_app boolean NOT NULL,
    detection_confidence real CHECK (
        detection_confidence IS NULL
        OR detection_confidence BETWEEN 0.0 AND 1.0
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (paper_id, generation, ordinal),
    CHECK (page_start IS NULL OR page_end IS NULL OR page_end >= page_start)
);

CREATE INDEX paper_sections_current_idx
    ON paper_sections (paper_id, generation, kind, ordinal);

CREATE TABLE paper_chunks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    section_id uuid NOT NULL REFERENCES paper_sections(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    text text NOT NULL CHECK (btrim(text) <> ''),
    page_start integer CHECK (page_start IS NULL OR page_start > 0),
    page_end integer CHECK (page_end IS NULL OR page_end > 0),
    token_count integer CHECK (token_count IS NULL OR token_count > 0),
    embedding vector,
    search_tsv tsvector GENERATED ALWAYS AS (
        to_tsvector('english'::regconfig, text)
    ) STORED,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (section_id, ordinal),
    CHECK (page_start IS NULL OR page_end IS NULL OR page_end >= page_start)
);

CREATE INDEX paper_chunks_scope_idx
    ON paper_chunks (paper_id, generation, section_id, ordinal);
CREATE INDEX paper_chunks_search_idx ON paper_chunks USING gin (search_tsv);

CREATE TABLE paper_references (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    citing_paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    raw_text text NOT NULL CHECK (btrim(raw_text) <> ''),
    extracted_title text,
    extracted_authors jsonb CHECK (
        extracted_authors IS NULL OR jsonb_typeof(extracted_authors) = 'array'
    ),
    extracted_year integer,
    doi text,
    extracted_arxiv_id text,
    resolved_paper_id uuid REFERENCES papers(id) ON DELETE SET NULL,
    resolution_status text NOT NULL DEFAULT 'unresolved' CHECK (
        resolution_status IN (
            'unresolved',
            'resolving',
            'resolved',
            'ambiguous',
            'not_arxiv',
            'failed'
        )
    ),
    resolution_confidence real CHECK (
        resolution_confidence IS NULL
        OR resolution_confidence BETWEEN 0.0 AND 1.0
    ),
    resolution_method text,
    key_score real,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (citing_paper_id, generation, ordinal),
    CHECK (
        resolution_status <> 'resolved'
        OR (
            resolved_paper_id IS NOT NULL
            AND resolution_confidence IS NOT NULL
            AND resolution_confidence >= 0.90
        )
    )
);

CREATE INDEX paper_references_scope_idx
    ON paper_references (citing_paper_id, generation, ordinal);
CREATE INDEX paper_references_resolved_idx
    ON paper_references (resolved_paper_id)
    WHERE resolved_paper_id IS NOT NULL;
CREATE INDEX paper_references_arxiv_idx
    ON paper_references (extracted_arxiv_id)
    WHERE extracted_arxiv_id IS NOT NULL;

CREATE TABLE citation_contexts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reference_id uuid NOT NULL REFERENCES paper_references(id) ON DELETE CASCADE,
    section_kind text NOT NULL,
    section_heading text,
    context_text text NOT NULL CHECK (btrim(context_text) <> ''),
    page_number integer CHECK (page_number IS NULL OR page_number > 0),
    occurrence_ordinal integer NOT NULL CHECK (occurrence_ordinal >= 0),
    UNIQUE (reference_id, occurrence_ordinal)
);

CREATE INDEX citation_contexts_reference_idx
    ON citation_contexts (reference_id, occurrence_ordinal);

CREATE TABLE paper_connections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    citing_paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    cited_paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    reference_id uuid NOT NULL REFERENCES paper_references(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    relation_type text NOT NULL CHECK (
        relation_type IN (
            'builds_on',
            'uses',
            'extends',
            'applies',
            'compares_with',
            'contrasts_with',
            'background',
            'related_work',
            'unknown'
        )
    ),
    summary text NOT NULL CHECK (btrim(summary) <> ''),
    confidence real NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    source_context_ids uuid[] NOT NULL,
    model_id text,
    prompt_version text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (citing_paper_id, cited_paper_id, generation),
    CHECK (citing_paper_id <> cited_paper_id)
);

CREATE INDEX paper_connections_scope_idx
    ON paper_connections (citing_paper_id, generation, confidence DESC);

CREATE TABLE jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type text NOT NULL CHECK (btrim(job_type) <> ''),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    state text NOT NULL DEFAULT 'queued' CHECK (
        state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')
    ),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_owner text,
    lease_expires_at timestamptz,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    last_error_class text CHECK (
        last_error_class IS NULL
        OR last_error_class IN (
            'external_temporary',
            'external_permanent',
            'parser_temporary',
            'parser_document',
            'model_temporary',
            'validation',
            'internal'
        )
    ),
    last_error_code text,
    last_error_message text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    UNIQUE (paper_id, generation, job_type),
    CHECK (
        (state = 'running' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
        OR state <> 'running'
    ),
    CHECK (completed_at IS NULL OR state IN ('succeeded', 'failed', 'cancelled'))
);

CREATE INDEX jobs_claim_idx
    ON jobs (available_at, created_at)
    WHERE state IN ('queued', 'running');
CREATE INDEX jobs_paper_idx ON jobs (paper_id, generation, job_type);

CREATE TABLE chat_threads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    anonymous_session_id uuid NOT NULL,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, anonymous_session_id, paper_id)
);

CREATE INDEX chat_threads_session_idx
    ON chat_threads (anonymous_session_id, updated_at DESC);

CREATE TABLE chat_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('user', 'assistant')),
    content text NOT NULL CHECK (btrim(content) <> ''),
    source_metadata jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
        jsonb_typeof(source_metadata) = 'array'
    ),
    provider_request_id text,
    model_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX chat_messages_thread_idx
    ON chat_messages (thread_id, created_at DESC, id DESC);

-- Cached arXiv query results are shared by the API and worker. `cache_key`
-- includes the normalized exact ID or normalized search expression.
CREATE TABLE arxiv_query_cache (
    cache_key text PRIMARY KEY,
    query_kind text NOT NULL CHECK (query_kind IN ('exact_id', 'title_search', 'recent')),
    payload jsonb NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CHECK (expires_at > fetched_at)
);

CREATE INDEX arxiv_query_cache_expiry_idx ON arxiv_query_cache (expires_at);

-- A locked row implements a cross-process start-time gate. Both binaries use
-- this before external arXiv calls, in addition to the client's local gate.
CREATE TABLE external_rate_limits (
    service text PRIMARY KEY,
    last_started_at timestamptz NOT NULL
);

INSERT INTO external_rate_limits (service, last_started_at)
VALUES ('arxiv', '1970-01-01T00:00:00Z'::timestamptz);

-- Configurable vector columns have no fixed typmod. This durable setting makes
-- dimension changes explicit and lets startup reject a model/DB mismatch.
CREATE TABLE service_configuration (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION initialize_paper_processing() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO paper_processing (paper_id, generation)
    VALUES (NEW.id, 1)
    ON CONFLICT (paper_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER papers_initialize_processing
AFTER INSERT ON papers
FOR EACH ROW EXECUTE FUNCTION initialize_paper_processing();

CREATE FUNCTION invalidate_new_arxiv_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.arxiv_version < OLD.arxiv_version THEN
        RAISE EXCEPTION 'arXiv version cannot decrease (% -> %)',
            OLD.arxiv_version, NEW.arxiv_version;
    END IF;

    IF NEW.arxiv_version > OLD.arxiv_version THEN
        UPDATE paper_processing
        SET generation = generation + 1,
            stage = 'not_requested',
            metadata_ready = true,
            introduction_ready = false,
            chat_ready = false,
            connections_ready = false,
            retryable = false,
            last_error_category = NULL,
            last_error_code = NULL,
            last_error_message = NULL,
            started_at = NULL,
            updated_at = now(),
            completed_at = NULL,
            parser_version = NULL,
            embedding_model = NULL,
            summary_model = NULL
        WHERE paper_id = NEW.id;

        UPDATE jobs
        SET state = 'cancelled',
            lease_owner = NULL,
            lease_expires_at = NULL,
            completed_at = now(),
            updated_at = now(),
            last_error_class = 'validation',
            last_error_code = 'STALE_GENERATION',
            last_error_message = 'Cancelled because a newer arXiv version was observed.'
        WHERE paper_id = NEW.id
          AND state IN ('queued', 'running');
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER papers_invalidate_new_version
AFTER UPDATE OF arxiv_version ON papers
FOR EACH ROW EXECUTE FUNCTION invalidate_new_arxiv_version();
