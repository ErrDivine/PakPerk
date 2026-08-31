-- Plan 03 paper-version comparison artifacts. Diffs retain object identities
-- and parser provenance so parser-induced changes can be labeled rather than
-- presented as author intent.

CREATE TABLE paper_version_diffs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    from_generation integer NOT NULL CHECK (from_generation > 0),
    to_generation integer NOT NULL CHECK (to_generation > from_generation),
    from_arxiv_version integer NOT NULL CHECK (from_arxiv_version > 0),
    to_arxiv_version integer NOT NULL CHECK (to_arxiv_version > from_arxiv_version),
    algorithm_version text NOT NULL CHECK (
        char_length(algorithm_version) BETWEEN 1 AND 64
        AND algorithm_version = btrim(algorithm_version)
    ),
    schema_version text NOT NULL CHECK (
        char_length(schema_version) BETWEEN 1 AND 64
        AND schema_version = btrim(schema_version)
    ),
    from_parser_id text NOT NULL CHECK (
        char_length(from_parser_id) BETWEEN 1 AND 64
        AND from_parser_id = btrim(from_parser_id)
    ),
    from_parser_version text NOT NULL CHECK (
        char_length(from_parser_version) BETWEEN 1 AND 128
        AND from_parser_version = btrim(from_parser_version)
    ),
    to_parser_id text NOT NULL CHECK (
        char_length(to_parser_id) BETWEEN 1 AND 64
        AND to_parser_id = btrim(to_parser_id)
    ),
    to_parser_version text NOT NULL CHECK (
        char_length(to_parser_version) BETWEEN 1 AND 128
        AND to_parser_version = btrim(to_parser_version)
    ),
    parser_change_uncertainty boolean NOT NULL,
    status text NOT NULL CHECK (status IN ('pending', 'ready', 'partial', 'failed')),
    summary jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(summary) = 'object'
        AND pg_column_size(summary) <= 1048576
    ),
    failure_code text CHECK (
        failure_code IS NULL OR (
            char_length(failure_code) BETWEEN 1 AND 64
            AND failure_code ~ '^[A-Z0-9_]+$'
        )
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    CONSTRAINT paper_version_diffs_from_source_fk
        FOREIGN KEY (paper_id, from_generation, from_arxiv_version)
        REFERENCES document_generations(paper_id, generation, arxiv_version)
        ON DELETE CASCADE,
    CONSTRAINT paper_version_diffs_to_source_fk
        FOREIGN KEY (paper_id, to_generation, to_arxiv_version)
        REFERENCES document_generations(paper_id, generation, arxiv_version)
        ON DELETE CASCADE,
    UNIQUE (paper_id, from_generation, to_generation, algorithm_version, schema_version),
    CHECK (
        (status IN ('ready', 'partial', 'failed') AND completed_at IS NOT NULL)
        OR (status = 'pending' AND completed_at IS NULL)
    ),
    CHECK ((status = 'failed') = (failure_code IS NOT NULL))
);

CREATE INDEX paper_version_diffs_paper_idx
    ON paper_version_diffs (paper_id, to_generation DESC, from_generation DESC, created_at DESC);

CREATE TABLE paper_version_diff_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    diff_id uuid NOT NULL REFERENCES paper_version_diffs(id) ON DELETE CASCADE,
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    kind text NOT NULL CHECK (kind IN (
        'metadata', 'section', 'block', 'figure', 'table', 'equation',
        'passport_field', 'reference', 'annotation_anchor'
    )),
    old_object_id uuid,
    new_object_id uuid,
    change_type text NOT NULL CHECK (change_type IN ('added', 'removed', 'modified', 'moved')),
    similarity real CHECK (similarity IS NULL OR similarity BETWEEN 0.0 AND 1.0),
    diff_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(diff_payload) = 'object'
        AND pg_column_size(diff_payload) <= 262144
    ),
    confidence_status text NOT NULL CHECK (
        confidence_status IN ('supported', 'uncertain', 'unavailable')
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (diff_id, ordinal),
    CHECK (old_object_id IS NOT NULL OR new_object_id IS NOT NULL),
    CHECK (
        (change_type = 'added' AND old_object_id IS NULL AND new_object_id IS NOT NULL)
        OR (change_type = 'removed' AND old_object_id IS NOT NULL AND new_object_id IS NULL)
        OR (change_type IN ('modified', 'moved')
            AND old_object_id IS NOT NULL AND new_object_id IS NOT NULL)
    )
);

CREATE INDEX paper_version_diff_items_kind_idx
    ON paper_version_diff_items (diff_id, kind, ordinal);

COMMENT ON COLUMN paper_version_diffs.parser_change_uncertainty IS
    'True when adapter/version differences may explain apparent content changes; UI must display this warning.';
COMMENT ON COLUMN paper_version_diff_items.diff_payload IS
    'Bounded structural/hash summary, not an unrestricted reconstructed-paper export.';
