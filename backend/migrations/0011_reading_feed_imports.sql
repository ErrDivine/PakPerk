-- Durable idempotency begins before exact resolution necessarily has an
-- internal paper UUID. The ledger stores only a caller-supplied keyed or versioned
-- 32-byte fingerprint and the canonical arXiv base after safe parsing; raw
-- submitted URLs and titles never belong here.
CREATE TABLE paper_import_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    input_kind text NOT NULL CHECK (
        input_kind IN ('arxiv_url', 'arxiv_id')
    ),
    input_fingerprint bytea NOT NULL CHECK (
        octet_length(input_fingerprint) = 32
    ),
    normalized_arxiv_base text,
    paper_id uuid REFERENCES papers(id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'resolving' CHECK (
        status IN (
            'resolving',
            'completed',
            'retryable_failure',
            'terminal_failure'
        )
    ),
    error_code text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    completed_at timestamptz,
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT paper_import_operations_arxiv_base_valid CHECK (
        normalized_arxiv_base IS NULL OR (
            char_length(normalized_arxiv_base) BETWEEN 1 AND 128
            AND normalized_arxiv_base = btrim(normalized_arxiv_base)
            AND normalized_arxiv_base ~
                '^([0-9]{4}[.][0-9]{4,5}|[A-Za-z][A-Za-z0-9.-]*/[0-9]{7})$'
        )
    ),
    CONSTRAINT paper_import_operations_error_code_valid CHECK (
        error_code IS NULL OR (
            char_length(error_code) BETWEEN 1 AND 64
            AND error_code ~ '^[A-Z][A-Z0-9_]*$'
        )
    ),
    CONSTRAINT paper_import_operations_state_shape_valid CHECK (
        (
            status = 'resolving'
            AND paper_id IS NULL
            AND error_code IS NULL
            AND completed_at IS NULL
        )
        OR (
            status = 'completed'
            AND normalized_arxiv_base IS NOT NULL
            AND paper_id IS NOT NULL
            AND error_code IS NULL
            AND completed_at IS NOT NULL
        )
        OR (
            status = 'retryable_failure'
            AND paper_id IS NULL
            AND error_code IS NOT NULL
            AND completed_at IS NULL
        )
        OR (
            status = 'terminal_failure'
            AND paper_id IS NULL
            AND error_code IS NOT NULL
            AND completed_at IS NOT NULL
        )
    ),
    CONSTRAINT paper_import_operations_timestamps_valid CHECK (
        updated_at >= created_at
        AND (
            completed_at IS NULL
            OR (
                completed_at >= created_at
                AND completed_at <= updated_at
            )
        )
    )
);

-- Bounded cleanup can walk terminal operations in deterministic age order.
CREATE INDEX paper_import_operations_terminal_cleanup_idx
    ON paper_import_operations (completed_at, user_id, operation_id)
    WHERE status IN ('completed', 'terminal_failure');

-- A repair/reconciliation pass can find abandoned or repeatedly retryable
-- operations without scanning durable terminal replay history.
CREATE INDEX paper_import_operations_incomplete_cleanup_idx
    ON paper_import_operations (updated_at, user_id, operation_id)
    WHERE status IN ('resolving', 'retryable_failure');

CREATE INDEX paper_import_operations_paper_idx
    ON paper_import_operations (paper_id, user_id, operation_id)
    WHERE paper_id IS NOT NULL;

-- Title search deliberately reuses arxiv_query_cache with
-- query_kind='title_search'. Do not create a second title-search cache table.
