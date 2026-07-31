CREATE SEQUENCE library_revision_seq AS bigint;

-- Allocating through this singleton row creates a transactional commit fence.
-- A sequence alone can hand out revision N+1 to a transaction that commits
-- before revision N. Holding this row until commit makes the published clock
-- and the canonical mutation become visible in revision order.
CREATE TABLE library_revision_clock (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    current_revision bigint NOT NULL DEFAULT 0 CHECK (current_revision >= 0)
);

INSERT INTO library_revision_clock (singleton) VALUES (true);

CREATE TABLE user_paper_library (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    state text NOT NULL CHECK (state = 'to_read'),
    saved_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    removed_at timestamptz,
    revision bigint NOT NULL CHECK (revision > 0),
    last_operation_id uuid NOT NULL,
    PRIMARY KEY (user_id, paper_id),
    CONSTRAINT user_paper_library_timestamps_valid CHECK (
        updated_at >= saved_at
        AND (removed_at IS NULL OR removed_at = updated_at)
    )
);

CREATE UNIQUE INDEX user_paper_library_user_revision_unique
    ON user_paper_library (user_id, revision);
CREATE INDEX user_paper_library_active_list_idx
    ON user_paper_library (user_id, saved_at DESC, paper_id DESC)
    WHERE removed_at IS NULL;
CREATE INDEX user_paper_library_state_list_idx
    ON user_paper_library (
        user_id,
        removed_at,
        saved_at DESC,
        paper_id DESC
    );
CREATE INDEX user_paper_library_active_paper_idx
    ON user_paper_library (paper_id)
    WHERE removed_at IS NULL;
CREATE INDEX user_paper_library_changes_idx
    ON user_paper_library (user_id, revision, paper_id);
CREATE INDEX user_paper_library_tombstone_cleanup_idx
    ON user_paper_library (removed_at, user_id, revision)
    WHERE removed_at IS NOT NULL;

-- This ledger outlives compacted tombstones. Besides detecting conflicting
-- operation-ID reuse, its accepted snapshot lets a very late duplicate return
-- the latest canonical removal without recreating an active row.
CREATE TABLE library_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    intent text NOT NULL CHECK (intent IN ('save', 'remove')),
    state text NOT NULL CHECK (state = 'to_read'),
    intent_fingerprint bytea NOT NULL CHECK (octet_length(intent_fingerprint) = 32),
    accepted_revision bigint NOT NULL CHECK (accepted_revision > 0),
    accepted_saved_at timestamptz NOT NULL,
    accepted_updated_at timestamptz NOT NULL,
    accepted_removed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT library_operations_user_revision_unique
        UNIQUE (user_id, accepted_revision),
    CONSTRAINT library_operations_timestamps_valid CHECK (
        accepted_updated_at >= accepted_saved_at
        AND (
            accepted_removed_at IS NULL
            OR accepted_removed_at = accepted_updated_at
        )
        AND created_at >= accepted_updated_at
    )
);

CREATE INDEX library_operations_paper_revision_idx
    ON library_operations (user_id, paper_id, accepted_revision DESC);

CREATE TABLE library_sync_metadata (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    current_revision bigint NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
    purged_through_revision bigint NOT NULL DEFAULT 0 CHECK (
        purged_through_revision >= 0
        AND purged_through_revision <= current_revision
    ),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
