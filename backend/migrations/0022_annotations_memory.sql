-- Plan 03 private research artifacts. Revisions are account-scoped and share
-- a content-free operation ledger. No table in this migration can represent
-- Library state or queue eligibility.

CREATE TABLE research_artifact_sync_metadata (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    current_revision bigint NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
    purged_through_revision bigint NOT NULL DEFAULT 0 CHECK (
        purged_through_revision >= 0
        AND purged_through_revision <= current_revision
    ),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE research_artifact_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL,
    accepted_revision bigint NOT NULL CHECK (accepted_revision > 0),
    artifact_kind text NOT NULL CHECK (artifact_kind IN (
        'annotation', 'evidence_card', 'checkpoint', 'memory_item'
    )),
    artifact_id uuid NOT NULL,
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, operation_id),
    UNIQUE (user_id, accepted_revision),
    UNIQUE (user_id, operation_id, accepted_revision)
);

CREATE INDEX research_artifact_operations_revision_idx
    ON research_artifact_operations (user_id, accepted_revision);

CREATE TABLE annotations (
    id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    block_id uuid,
    kind text NOT NULL CHECK (kind IN ('highlight', 'note', 'question', 'evidence')),
    body text CHECK (
        body IS NULL OR (
            char_length(body) BETWEEN 1 AND 100000
            AND btrim(body) <> ''
            AND position(chr(0) IN body) = 0
        )
    ),
    color_role text CHECK (
        color_role IS NULL OR color_role IN ('yellow', 'blue', 'green', 'pink', 'purple')
    ),
    quote_exact text CHECK (
        quote_exact IS NULL OR (
            char_length(quote_exact) BETWEEN 1 AND 20000
            AND quote_exact <> ''
            AND position(chr(0) IN quote_exact) = 0
        )
    ),
    quote_prefix text CHECK (
        quote_prefix IS NULL OR (
            char_length(quote_prefix) BETWEEN 1 AND 2000
            AND position(chr(0) IN quote_prefix) = 0
        )
    ),
    quote_suffix text CHECK (
        quote_suffix IS NULL OR (
            char_length(quote_suffix) BETWEEN 1 AND 2000
            AND position(chr(0) IN quote_suffix) = 0
        )
    ),
    start_offset integer CHECK (start_offset IS NULL OR start_offset >= 0),
    end_offset integer CHECK (end_offset IS NULL OR end_offset > 0),
    section_hint text[] NOT NULL DEFAULT '{}'::text[] CHECK (
        cardinality(section_hint) <= 32
        AND array_position(section_hint, NULL) IS NULL
    ),
    page_hint integer CHECK (page_hint IS NULL OR page_hint > 0),
    anchor_status text NOT NULL CHECK (
        anchor_status IN ('anchored', 'uncertain', 'orphaned')
    ),
    revision bigint NOT NULL CHECK (revision > 0),
    last_operation_id uuid NOT NULL,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, id),
    CONSTRAINT annotations_block_scope_fk
        FOREIGN KEY (block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE NO ACTION
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT annotations_operation_fk
        FOREIGN KEY (user_id, last_operation_id, revision)
        REFERENCES research_artifact_operations(user_id, operation_id, accepted_revision),
    CHECK (
        (start_offset IS NULL AND end_offset IS NULL)
        OR (start_offset IS NOT NULL AND end_offset > start_offset)
    ),
    CHECK (
        deleted_at IS NOT NULL
        OR (
            quote_exact IS NOT NULL
            AND (kind = 'highlight' OR body IS NOT NULL)
        )
    ),
    CHECK (
        deleted_at IS NULL
        OR (
            body IS NULL
            AND color_role IS NULL
            AND quote_exact IS NULL
            AND quote_prefix IS NULL
            AND quote_suffix IS NULL
            AND start_offset IS NULL
            AND end_offset IS NULL
        )
    ),
    CHECK (updated_at >= created_at AND (deleted_at IS NULL OR deleted_at >= created_at))
);

CREATE UNIQUE INDEX annotations_user_revision_idx ON annotations (user_id, revision);
CREATE INDEX annotations_paper_sync_idx
    ON annotations (user_id, paper_id, revision, id);
CREATE INDEX annotations_anchor_review_idx
    ON annotations (user_id, anchor_status, updated_at DESC, id)
    WHERE deleted_at IS NULL AND anchor_status <> 'anchored';
CREATE INDEX annotations_pending_reanchor_idx
    ON annotations (paper_id, generation, user_id, id) INCLUDE (revision)
    WHERE deleted_at IS NULL AND quote_exact IS NOT NULL;

-- A rejected stale write is retained privately so two edited note bodies can
-- never collapse into last-write-wins data loss. Resolution is explicit.
CREATE TABLE annotation_conflicts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    annotation_id uuid NOT NULL,
    attempted_operation_id uuid NOT NULL,
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    base_revision bigint NOT NULL CHECK (base_revision >= 0),
    server_revision bigint NOT NULL CHECK (server_revision > 0),
    attempted_body text CHECK (
        attempted_body IS NULL OR (
            char_length(attempted_body) BETWEEN 1 AND 100000
            AND btrim(attempted_body) <> ''
            AND position(chr(0) IN attempted_body) = 0
        )
    ),
    server_body text CHECK (
        server_body IS NULL OR (
            char_length(server_body) BETWEEN 1 AND 100000
            AND btrim(server_body) <> ''
            AND position(chr(0) IN server_body) = 0
        )
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolution text CHECK (
        resolution IS NULL OR resolution IN ('keep_server', 'keep_attempted', 'merged', 'dismissed')
    ),
    CONSTRAINT annotation_conflicts_annotation_fk
        FOREIGN KEY (user_id, annotation_id)
        REFERENCES annotations(user_id, id)
        ON DELETE CASCADE,
    UNIQUE (user_id, attempted_operation_id),
    CHECK (
        attempted_body IS DISTINCT FROM server_body
        AND ((resolved_at IS NULL) = (resolution IS NULL))
    )
);

CREATE INDEX annotation_conflicts_open_idx
    ON annotation_conflicts (user_id, created_at, id)
    WHERE resolved_at IS NULL;

CREATE TABLE annotation_reanchor_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    annotation_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    from_generation integer NOT NULL CHECK (from_generation > 0),
    to_generation integer NOT NULL CHECK (to_generation > from_generation),
    source_block_id uuid,
    source_stable_key text CHECK (
        source_stable_key IS NULL OR (
            char_length(source_stable_key) BETWEEN 1 AND 128
            AND source_stable_key = btrim(source_stable_key)
        )
    ),
    source_quote_exact text NOT NULL CHECK (
        char_length(source_quote_exact) BETWEEN 1 AND 20000
        AND source_quote_exact <> ''
        AND position(chr(0) IN source_quote_exact) = 0
    ),
    source_quote_prefix text CHECK (
        source_quote_prefix IS NULL OR (
            char_length(source_quote_prefix) BETWEEN 1 AND 2000
            AND position(chr(0) IN source_quote_prefix) = 0
        )
    ),
    source_quote_suffix text CHECK (
        source_quote_suffix IS NULL OR (
            char_length(source_quote_suffix) BETWEEN 1 AND 2000
            AND position(chr(0) IN source_quote_suffix) = 0
        )
    ),
    source_start_offset integer CHECK (source_start_offset IS NULL OR source_start_offset >= 0),
    source_end_offset integer CHECK (source_end_offset IS NULL OR source_end_offset > 0),
    strategy text CHECK (strategy IS NULL OR strategy IN (
        'stable_block_exact', 'quote_context', 'fuzzy_high_threshold', 'manual'
    )),
    result text NOT NULL CHECK (result IN ('anchored', 'uncertain', 'orphaned')),
    target_block_id uuid,
    target_start_offset integer CHECK (target_start_offset IS NULL OR target_start_offset >= 0),
    target_end_offset integer CHECK (target_end_offset IS NULL OR target_end_offset > 0),
    similarity real CHECK (similarity IS NULL OR similarity BETWEEN 0.0 AND 1.0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT annotation_reanchor_annotation_fk
        FOREIGN KEY (user_id, annotation_id)
        REFERENCES annotations(user_id, id)
        ON DELETE CASCADE,
    UNIQUE (user_id, operation_id),
    CHECK (
        (source_start_offset IS NULL AND source_end_offset IS NULL)
        OR (
            source_start_offset IS NOT NULL
            AND source_end_offset > source_start_offset
        )
    ),
    CHECK (
        (target_start_offset IS NULL AND target_end_offset IS NULL)
        OR (
            target_start_offset IS NOT NULL
            AND target_end_offset > target_start_offset
        )
    ),
    CHECK (
        (result = 'orphaned'
            AND strategy IS NULL
            AND target_block_id IS NULL
            AND target_start_offset IS NULL
            AND target_end_offset IS NULL)
        OR (result = 'anchored'
            AND strategy IN ('stable_block_exact', 'quote_context', 'manual')
            AND target_block_id IS NOT NULL
            AND target_start_offset IS NOT NULL
            AND target_end_offset IS NOT NULL)
        OR (result = 'uncertain'
            AND strategy = 'fuzzy_high_threshold'
            AND target_block_id IS NOT NULL
            AND target_start_offset IS NULL
            AND target_end_offset IS NULL)
    )
);

CREATE INDEX annotation_reanchor_history_idx
    ON annotation_reanchor_attempts (user_id, annotation_id, created_at DESC, id DESC);
CREATE INDEX annotation_reanchor_target_idx
    ON annotation_reanchor_attempts (user_id, annotation_id, to_generation);

CREATE TABLE evidence_cards (
    id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    title text CHECK (
        title IS NULL OR (
            char_length(title) BETWEEN 1 AND 500
            AND btrim(title) <> ''
            AND position(chr(0) IN title) = 0
        )
    ),
    claim_or_question text CHECK (
        claim_or_question IS NULL OR (
            char_length(claim_or_question) BETWEEN 1 AND 10000
            AND btrim(claim_or_question) <> ''
            AND position(chr(0) IN claim_or_question) = 0
        )
    ),
    user_note text CHECK (
        user_note IS NULL OR (
            char_length(user_note) BETWEEN 1 AND 100000
            AND btrim(user_note) <> ''
            AND position(chr(0) IN user_note) = 0
        )
    ),
    source_block_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(source_block_ids) BETWEEN 0 AND 64
        AND array_position(source_block_ids, NULL) IS NULL
    ),
    figure_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(figure_ids) <= 32 AND array_position(figure_ids, NULL) IS NULL
    ),
    table_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(table_ids) <= 32 AND array_position(table_ids, NULL) IS NULL
    ),
    citation_context_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(citation_context_ids) <= 64
        AND array_position(citation_context_ids, NULL) IS NULL
    ),
    verification_status text NOT NULL CHECK (
        verification_status IN ('user_selected', 'user_reviewed', 'superseded')
    ),
    revision bigint NOT NULL CHECK (revision > 0),
    last_operation_id uuid NOT NULL,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, id),
    CONSTRAINT evidence_cards_operation_fk
        FOREIGN KEY (user_id, last_operation_id, revision)
        REFERENCES research_artifact_operations(user_id, operation_id, accepted_revision),
    CHECK (
        deleted_at IS NOT NULL
        OR (
            title IS NOT NULL
            AND cardinality(source_block_ids) + cardinality(figure_ids)
                + cardinality(table_ids) + cardinality(citation_context_ids) > 0
        )
    ),
    CHECK (
        deleted_at IS NULL
        OR (
            title IS NULL
            AND claim_or_question IS NULL
            AND user_note IS NULL
            AND cardinality(source_block_ids) = 0
            AND cardinality(figure_ids) = 0
            AND cardinality(table_ids) = 0
            AND cardinality(citation_context_ids) = 0
        )
    )
);

CREATE UNIQUE INDEX evidence_cards_user_revision_idx ON evidence_cards (user_id, revision);
CREATE INDEX evidence_cards_paper_idx
    ON evidence_cards (user_id, paper_id, updated_at DESC, id DESC)
    WHERE deleted_at IS NULL;

-- Short-lived reading sessions support position restoration and a
-- user-visible reading history. They intentionally contain no Library state
-- and no high-frequency scroll/event stream.
CREATE TABLE reading_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    mode text NOT NULL CHECK (mode IN ('skim', 'read', 'inspect')),
    started_at timestamptz NOT NULL,
    ended_at timestamptz,
    start_stage text NOT NULL CHECK (start_stage IN ('abstract', 'introduction', 'connections')),
    end_stage text CHECK (end_stage IS NULL OR end_stage IN ('abstract', 'introduction', 'connections')),
    last_block_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT reading_sessions_block_scope_fk
        FOREIGN KEY (last_block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE SET NULL (last_block_id),
    CHECK (ended_at IS NULL OR ended_at >= started_at),
    CHECK ((ended_at IS NULL) = (end_stage IS NULL)),
    CHECK (expires_at > created_at)
);

CREATE INDEX reading_sessions_user_history_idx
    ON reading_sessions (user_id, started_at DESC, id DESC)
    WHERE user_id IS NOT NULL;
CREATE INDEX reading_sessions_expiry_idx ON reading_sessions (expires_at);

CREATE TABLE reading_checkpoints (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    mode text NOT NULL CHECK (mode IN ('skim', 'read', 'inspect')),
    stage text NOT NULL CHECK (stage IN ('abstract', 'introduction', 'connections')),
    block_id uuid,
    scroll_fraction real CHECK (scroll_fraction IS NULL OR scroll_fraction BETWEEN 0.0 AND 1.0),
    last_read_at timestamptz NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    last_operation_id uuid NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, paper_id),
    CONSTRAINT reading_checkpoints_block_scope_fk
        FOREIGN KEY (block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE SET NULL (block_id),
    CONSTRAINT reading_checkpoints_operation_fk
        FOREIGN KEY (user_id, last_operation_id, revision)
        REFERENCES research_artifact_operations(user_id, operation_id, accepted_revision)
);

CREATE UNIQUE INDEX reading_checkpoints_user_revision_idx
    ON reading_checkpoints (user_id, revision);
CREATE INDEX reading_checkpoints_recent_idx
    ON reading_checkpoints (user_id, last_read_at DESC, paper_id);

CREATE TABLE memory_items (
    id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    generation integer NOT NULL CHECK (generation > 0),
    source_type text NOT NULL CHECK (source_type IN (
        'annotation', 'evidence_card', 'passport_field', 'user_question'
    )),
    source_id uuid NOT NULL,
    prompt_text text CHECK (
        prompt_text IS NULL OR (
            char_length(prompt_text) BETWEEN 1 AND 10000
            AND btrim(prompt_text) <> ''
            AND position(chr(0) IN prompt_text) = 0
        )
    ),
    answer_text text CHECK (
        answer_text IS NULL OR (
            char_length(answer_text) BETWEEN 1 AND 100000
            AND btrim(answer_text) <> ''
            AND position(chr(0) IN answer_text) = 0
        )
    ),
    status text NOT NULL CHECK (status IN ('active', 'snoozed', 'retired')),
    next_review_at timestamptz,
    review_count integer NOT NULL DEFAULT 0 CHECK (review_count >= 0),
    revision bigint NOT NULL CHECK (revision > 0),
    last_operation_id uuid NOT NULL,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, id),
    CONSTRAINT memory_items_operation_fk
        FOREIGN KEY (user_id, last_operation_id, revision)
        REFERENCES research_artifact_operations(user_id, operation_id, accepted_revision),
    UNIQUE (user_id, source_type, source_id),
    CHECK (
        (status = 'snoozed' AND next_review_at IS NOT NULL)
        OR (status <> 'snoozed' AND next_review_at IS NULL)
    ),
    CHECK (
        deleted_at IS NULL
        OR (prompt_text IS NULL AND answer_text IS NULL AND status = 'retired')
    )
);

CREATE UNIQUE INDEX memory_items_user_revision_idx ON memory_items (user_id, revision);
CREATE INDEX memory_items_review_idx
    ON memory_items (user_id, next_review_at, created_at, id)
    WHERE deleted_at IS NULL AND status IN ('active', 'snoozed');

COMMENT ON TABLE reading_checkpoints IS
    'Position and presentation mode only. Canonical Library state and queue eligibility are intentionally absent.';
COMMENT ON TABLE reading_sessions IS
    'Retention-bounded restoration/history records; never a high-frequency engagement or Library-state stream.';
COMMENT ON TABLE memory_items IS
    'Intentional user-owned resurfacing; reviewing or retiring an item never mutates Library state.';
COMMENT ON TABLE annotation_conflicts IS
    'Private rejected edits retained until explicit user resolution; never emitted to general telemetry.';
COMMENT ON COLUMN annotations.block_id IS
    'A live annotation protects its exact source block from generation cleanup; whole-paper/account cascades remain possible through the deferred constraint.';
COMMENT ON COLUMN annotation_reanchor_attempts.target_block_id IS
    'Validated against paper/to_generation on insert but intentionally not foreign-keyed so audit identity survives source-retention cleanup.';
