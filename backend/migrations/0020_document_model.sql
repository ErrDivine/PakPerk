-- Plan 03 Phase A/D document model. The manifest is the generation-scoped
-- publication boundary; readers join it to paper_processing so an older
-- generation can never be served as current by accident.

CREATE TABLE document_generations (
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    arxiv_version integer NOT NULL CHECK (arxiv_version > 0),
    schema_version text NOT NULL CHECK (
        char_length(schema_version) BETWEEN 1 AND 64
        AND schema_version = btrim(schema_version)
    ),
    parser_id text NOT NULL CHECK (
        char_length(parser_id) BETWEEN 1 AND 64
        AND parser_id = btrim(parser_id)
    ),
    parser_version text NOT NULL CHECK (
        char_length(parser_version) BETWEEN 1 AND 128
        AND parser_version = btrim(parser_version)
    ),
    document_hash text NOT NULL CHECK (
        document_hash ~ '^[0-9a-f]{64}$'
    ),
    metadata_snapshot jsonb NOT NULL CHECK (
        jsonb_typeof(metadata_snapshot) = 'object'
        AND pg_column_size(metadata_snapshot) <= 1048576
    ),
    metadata_hash text NOT NULL CHECK (metadata_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (paper_id, generation),
    UNIQUE (paper_id, generation, arxiv_version)
);

CREATE INDEX document_generations_created_idx
    ON document_generations (created_at DESC, paper_id, generation);

-- This key lets document blocks prove that a linked legacy section belongs to
-- the same paper generation instead of trusting a UUID alone.
ALTER TABLE paper_sections
    ADD CONSTRAINT paper_sections_document_scope_unique
    UNIQUE (id, paper_id, generation);

CREATE TABLE document_blocks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    stable_key text NOT NULL CHECK (
        char_length(stable_key) BETWEEN 1 AND 128
        AND stable_key = btrim(stable_key)
    ),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    section_id uuid,
    section_path text[] NOT NULL DEFAULT '{}'::text[] CHECK (
        cardinality(section_path) <= 32
    ),
    kind text NOT NULL CHECK (kind IN (
        'heading',
        'paragraph',
        'list_item',
        'quote',
        'theorem_definition',
        'caption',
        'equation_context',
        'table_context',
        'figure_context',
        'footnote',
        'other'
    )),
    text text NOT NULL CHECK (
        char_length(text) BETWEEN 1 AND 1000000
        AND btrim(text) <> ''
        AND position(chr(0) IN text) = 0
    ),
    content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    page_start integer CHECK (page_start IS NULL OR page_start > 0),
    page_end integer CHECK (page_end IS NULL OR page_end > 0),
    source_locator jsonb CHECK (
        source_locator IS NULL OR jsonb_typeof(source_locator) = 'object'
    ),
    inline_spans jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
        jsonb_typeof(inline_spans) = 'array'
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT document_blocks_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CONSTRAINT document_blocks_section_scope_fk
        FOREIGN KEY (section_id, paper_id, generation)
        REFERENCES paper_sections(id, paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, ordinal),
    UNIQUE (paper_id, generation, stable_key),
    UNIQUE (id, paper_id, generation),
    CHECK (page_start IS NULL OR page_end IS NULL OR page_end >= page_start),
    CHECK (array_position(section_path, NULL) IS NULL)
);

CREATE INDEX document_blocks_scope_idx
    ON document_blocks (paper_id, generation, ordinal);
CREATE INDEX document_blocks_kind_idx
    ON document_blocks (paper_id, generation, kind, ordinal);
CREATE INDEX document_blocks_section_path_idx
    ON document_blocks USING gin (section_path);

CREATE TABLE paper_figures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    label text NOT NULL CHECK (
        char_length(label) BETWEEN 1 AND 128 AND label = btrim(label)
    ),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    caption text NOT NULL CHECK (
        char_length(caption) BETWEEN 1 AND 100000 AND btrim(caption) <> ''
    ),
    page_number integer CHECK (page_number IS NULL OR page_number > 0),
    asset_key text CHECK (
        asset_key IS NULL OR (
            char_length(asset_key) BETWEEN 1 AND 512
            AND asset_key = btrim(asset_key)
            AND position(chr(0) IN asset_key) = 0
        )
    ),
    width integer CHECK (width IS NULL OR width > 0),
    height integer CHECK (height IS NULL OR height > 0),
    extraction_status text NOT NULL DEFAULT 'ready' CHECK (
        extraction_status IN ('ready', 'caption_only', 'uncertain', 'unavailable')
    ),
    content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    source_locator jsonb CHECK (
        source_locator IS NULL OR jsonb_typeof(source_locator) = 'object'
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT paper_figures_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, ordinal),
    UNIQUE (id, paper_id, generation)
);

CREATE INDEX paper_figures_scope_idx
    ON paper_figures (paper_id, generation, ordinal);

CREATE TABLE paper_tables (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    label text NOT NULL CHECK (
        char_length(label) BETWEEN 1 AND 128 AND label = btrim(label)
    ),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    caption text NOT NULL CHECK (
        char_length(caption) BETWEEN 1 AND 100000 AND btrim(caption) <> ''
    ),
    page_number integer CHECK (page_number IS NULL OR page_number > 0),
    structure_schema_version text NOT NULL CHECK (
        char_length(structure_schema_version) BETWEEN 1 AND 64
        AND structure_schema_version = btrim(structure_schema_version)
    ),
    structure jsonb NOT NULL CHECK (
        jsonb_typeof(structure) = 'object'
        AND structure ? 'schema_version'
        AND structure->>'schema_version' = structure_schema_version
    ),
    plain_text text NOT NULL CHECK (
        char_length(plain_text) BETWEEN 1 AND 500000
        AND btrim(plain_text) <> ''
        AND position(chr(0) IN plain_text) = 0
    ),
    extraction_status text NOT NULL DEFAULT 'ready' CHECK (
        extraction_status IN ('ready', 'partial', 'uncertain', 'unavailable')
    ),
    content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    source_locator jsonb CHECK (
        source_locator IS NULL OR jsonb_typeof(source_locator) = 'object'
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT paper_tables_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, ordinal),
    UNIQUE (id, paper_id, generation)
);

CREATE INDEX paper_tables_scope_idx
    ON paper_tables (paper_id, generation, ordinal);

CREATE TABLE paper_equations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    label text CHECK (
        label IS NULL OR (char_length(label) BETWEEN 1 AND 128 AND label = btrim(label))
    ),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    latex text CHECK (
        latex IS NULL OR (char_length(latex) BETWEEN 1 AND 100000 AND btrim(latex) <> '')
    ),
    mathml text CHECK (
        mathml IS NULL OR (char_length(mathml) BETWEEN 1 AND 500000 AND btrim(mathml) <> '')
    ),
    plain_text text CHECK (
        plain_text IS NULL OR (
            char_length(plain_text) BETWEEN 1 AND 100000
            AND btrim(plain_text) <> ''
        )
    ),
    context_block_id uuid,
    page_number integer CHECK (page_number IS NULL OR page_number > 0),
    confidence_status text NOT NULL DEFAULT 'supported' CHECK (
        confidence_status IN ('supported', 'partial', 'uncertain', 'unavailable')
    ),
    content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    source_locator jsonb CHECK (
        source_locator IS NULL OR jsonb_typeof(source_locator) = 'object'
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT paper_equations_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CONSTRAINT paper_equations_context_scope_fk
        FOREIGN KEY (context_block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, ordinal),
    UNIQUE (id, paper_id, generation),
    CHECK (
        latex IS NOT NULL OR mathml IS NOT NULL OR plain_text IS NOT NULL
        OR context_block_id IS NOT NULL
    )
);

CREATE INDEX paper_equations_scope_idx
    ON paper_equations (paper_id, generation, ordinal);

CREATE TABLE paper_terms (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    normalized_term text NOT NULL CHECK (
        char_length(normalized_term) BETWEEN 1 AND 512
        AND normalized_term = btrim(normalized_term)
    ),
    display_term text NOT NULL CHECK (
        char_length(display_term) BETWEEN 1 AND 512
        AND display_term = btrim(display_term)
    ),
    kind text NOT NULL CHECK (kind IN ('term', 'acronym', 'symbol', 'method', 'dataset')),
    canonical_topic_id uuid,
    definition_status text NOT NULL CHECK (
        definition_status IN ('available', 'not_found', 'not_applicable', 'uncertain')
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT paper_terms_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, normalized_term, kind),
    UNIQUE (id, paper_id, generation)
);

CREATE INDEX paper_terms_scope_idx
    ON paper_terms (paper_id, generation, normalized_term, kind);

CREATE TABLE term_occurrences (
    term_id uuid NOT NULL,
    block_id uuid NOT NULL,
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    start_offset integer NOT NULL CHECK (start_offset >= 0),
    end_offset integer NOT NULL CHECK (end_offset > start_offset),
    occurrence_ordinal integer NOT NULL CHECK (occurrence_ordinal >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT term_occurrences_term_scope_fk
        FOREIGN KEY (term_id, paper_id, generation)
        REFERENCES paper_terms(id, paper_id, generation)
        ON DELETE CASCADE,
    CONSTRAINT term_occurrences_block_scope_fk
        FOREIGN KEY (block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE CASCADE,
    PRIMARY KEY (term_id, block_id, occurrence_ordinal)
);

CREATE INDEX term_occurrences_block_idx
    ON term_occurrences (block_id, start_offset, end_offset);

CREATE TABLE term_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    term_id uuid NOT NULL,
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    source_type text NOT NULL CHECK (
        source_type IN ('current_paper', 'cited_paper', 'glossary', 'generated')
    ),
    source_block_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(source_block_ids) <= 64
        AND array_position(source_block_ids, NULL) IS NULL
    ),
    definition text NOT NULL CHECK (
        char_length(definition) BETWEEN 1 AND 100000
        AND btrim(definition) <> ''
        AND position(chr(0) IN definition) = 0
    ),
    model_id text CHECK (
        model_id IS NULL OR (char_length(model_id) BETWEEN 1 AND 128 AND model_id = btrim(model_id))
    ),
    prompt_version text CHECK (
        prompt_version IS NULL OR (
            char_length(prompt_version) BETWEEN 1 AND 128
            AND prompt_version = btrim(prompt_version)
        )
    ),
    confidence_status text NOT NULL CHECK (
        confidence_status IN ('supported', 'inferred', 'uncertain')
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT term_definitions_term_scope_fk
        FOREIGN KEY (term_id, paper_id, generation)
        REFERENCES paper_terms(id, paper_id, generation)
        ON DELETE CASCADE,
    CHECK (
        source_type = 'generated'
        OR cardinality(source_block_ids) > 0
    )
);

CREATE INDEX term_definitions_term_idx
    ON term_definitions (term_id, created_at, id);

COMMENT ON TABLE document_generations IS
    'Generation-scoped publication, source-version, and parser provenance boundary for normalized reader artifacts.';
COMMENT ON COLUMN document_blocks.inline_spans IS
    'Versioned inline references with Unicode-scalar offsets; application validation is authoritative.';
COMMENT ON COLUMN paper_figures.asset_key IS
    'Private object-store key, never a parser filesystem path and never served directly to clients.';
