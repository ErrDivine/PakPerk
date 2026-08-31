-- Plan 02 Phase B expands the canonical account library in place. `to_read`
-- remains the physical Inbox spelling while v0.0 binaries may share this
-- schema. New code projects it as `inbox` on v2 wires and writes it back as
-- `to_read`, preserving old reads, writes, replays, and code rollback.

ALTER TABLE user_paper_library
    DROP CONSTRAINT user_paper_library_state_check;
ALTER TABLE library_operations
    DROP CONSTRAINT library_operations_state_check;

ALTER TABLE user_paper_library
    ADD COLUMN private_note text,
    ADD COLUMN save_source_kind text,
    ADD COLUMN reminder_at timestamptz,
    ADD COLUMN reviewed_at timestamptz,
    ADD COLUMN archived_at timestamptz;

ALTER TABLE library_operations
    ADD COLUMN v2_intent_fingerprint bytea CHECK (
        v2_intent_fingerprint IS NULL
        OR octet_length(v2_intent_fingerprint) = 32
    ),
    ADD COLUMN accepted_private_note text,
    ADD COLUMN accepted_save_source_kind text,
    ADD COLUMN accepted_reminder_at timestamptz,
    ADD COLUMN accepted_reviewed_at timestamptz,
    ADD COLUMN accepted_archived_at timestamptz;

-- Keep the legacy state and fingerprint columns byte-for-byte intact. Old
-- binaries validate `intent_fingerprint` with their concatenated v0 formula.
-- New binaries write the full v2 intent into the nullable column above; NULL
-- identifies an operation accepted by a v0 writer and is valid only for the
-- exact metadata-preserving legacy mutation shape.

ALTER TABLE user_paper_library
    ADD CONSTRAINT user_paper_library_state_check CHECK (
        state IN ('to_read', 'read_next', 'reading', 'reviewed', 'archived')
    ),
    ADD CONSTRAINT user_paper_library_private_note_check CHECK (
        private_note IS NULL OR (
            char_length(private_note) BETWEEN 1 AND 500
            AND private_note = btrim(private_note)
            AND position(E'\n' IN private_note) = 0
            AND position(E'\r' IN private_note) = 0
            AND position(chr(0) IN private_note) = 0
        )
    ),
    ADD CONSTRAINT user_paper_library_save_source_check CHECK (
        save_source_kind IS NULL OR save_source_kind IN (
            'discovery',
            'lookup',
            'title_search',
            'arxiv_url',
            'arxiv_id',
            'connection',
            'other'
        )
    ),
    ADD CONSTRAINT user_paper_library_reminder_check CHECK (
        reminder_at IS NULL OR (
            removed_at IS NULL
            AND state IN ('to_read', 'read_next', 'reading')
        )
    ),
    ADD CONSTRAINT user_paper_library_state_timestamps_check CHECK (
        (state = 'reviewed') = (reviewed_at IS NOT NULL)
        AND (state = 'archived') = (archived_at IS NOT NULL)
        AND (reviewed_at IS NULL OR reviewed_at BETWEEN saved_at AND updated_at)
        AND (archived_at IS NULL OR archived_at BETWEEN saved_at AND updated_at)
    );

ALTER TABLE library_operations
    ADD CONSTRAINT library_operations_state_check CHECK (
        state IN ('to_read', 'read_next', 'reading', 'reviewed', 'archived')
    ),
    ADD CONSTRAINT library_operations_private_note_check CHECK (
        accepted_private_note IS NULL OR (
            char_length(accepted_private_note) BETWEEN 1 AND 500
            AND accepted_private_note = btrim(accepted_private_note)
            AND position(E'\n' IN accepted_private_note) = 0
            AND position(E'\r' IN accepted_private_note) = 0
            AND position(chr(0) IN accepted_private_note) = 0
        )
    ),
    ADD CONSTRAINT library_operations_save_source_check CHECK (
        accepted_save_source_kind IS NULL OR accepted_save_source_kind IN (
            'discovery',
            'lookup',
            'title_search',
            'arxiv_url',
            'arxiv_id',
            'connection',
            'other'
        )
    ),
    ADD CONSTRAINT library_operations_reminder_check CHECK (
        accepted_reminder_at IS NULL OR (
            accepted_removed_at IS NULL
            AND state IN ('to_read', 'read_next', 'reading')
        )
    ),
    ADD CONSTRAINT library_operations_state_timestamps_check CHECK (
        (state = 'reviewed') = (accepted_reviewed_at IS NOT NULL)
        AND (state = 'archived') = (accepted_archived_at IS NOT NULL)
        AND (
            accepted_reviewed_at IS NULL
            OR accepted_reviewed_at BETWEEN accepted_saved_at AND accepted_updated_at
        )
        AND (
            accepted_archived_at IS NULL
            OR accepted_archived_at BETWEEN accepted_saved_at AND accepted_updated_at
        )
    );

DROP INDEX user_paper_library_active_list_idx;
CREATE INDEX user_paper_library_active_list_idx
    ON user_paper_library (user_id, saved_at ASC, paper_id ASC)
    WHERE removed_at IS NULL
      AND state IN ('to_read', 'read_next', 'reading');
CREATE INDEX user_paper_library_v2_state_list_idx
    ON user_paper_library (user_id, state, saved_at DESC, paper_id DESC)
    WHERE removed_at IS NULL;
CREATE INDEX user_paper_library_reminders_due_idx
    ON user_paper_library (reminder_at, user_id, paper_id)
    WHERE reminder_at IS NOT NULL
      AND removed_at IS NULL
      AND state IN ('to_read', 'read_next', 'reading');

CREATE TABLE library_lists (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name text NOT NULL,
    normalized_name text NOT NULL,
    description text,
    sort_order integer NOT NULL DEFAULT 0,
    revision bigint NOT NULL CHECK (revision > 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    last_operation_id uuid NOT NULL,
    CONSTRAINT library_lists_user_id_unique UNIQUE (user_id, id),
    CONSTRAINT library_lists_name_check CHECK (
        char_length(name) BETWEEN 1 AND 100
        AND name = btrim(name)
        AND char_length(normalized_name) BETWEEN 1 AND 100
        AND normalized_name = lower(btrim(normalized_name))
        AND position(chr(0) IN name) = 0
    ),
    CONSTRAINT library_lists_description_check CHECK (
        description IS NULL OR (
            char_length(description) BETWEEN 1 AND 500
            AND description = btrim(description)
            AND position(chr(0) IN description) = 0
        )
    ),
    CONSTRAINT library_lists_timestamps_check CHECK (
        updated_at >= created_at
        AND (deleted_at IS NULL OR deleted_at = updated_at)
    )
);

CREATE UNIQUE INDEX library_lists_active_name_unique
    ON library_lists (user_id, normalized_name)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX library_lists_user_revision_unique
    ON library_lists (user_id, revision);
CREATE INDEX library_lists_account_order_idx
    ON library_lists (user_id, deleted_at, sort_order, normalized_name, id);

CREATE TABLE library_list_items (
    user_id uuid NOT NULL,
    list_id uuid NOT NULL,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    position_rank bigint NOT NULL DEFAULT 0,
    note text,
    revision bigint NOT NULL CHECK (revision > 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    last_operation_id uuid NOT NULL,
    PRIMARY KEY (list_id, paper_id),
    CONSTRAINT library_list_items_owner_fk
        FOREIGN KEY (user_id, list_id)
        REFERENCES library_lists(user_id, id) ON DELETE CASCADE,
    CONSTRAINT library_list_items_note_check CHECK (
        note IS NULL OR (
            char_length(note) BETWEEN 1 AND 500
            AND note = btrim(note)
            AND position(chr(0) IN note) = 0
        )
    ),
    CONSTRAINT library_list_items_timestamps_check CHECK (
        updated_at >= created_at
        AND (deleted_at IS NULL OR deleted_at = updated_at)
    )
);

CREATE UNIQUE INDEX library_list_items_user_revision_unique
    ON library_list_items (user_id, revision);
CREATE INDEX library_list_items_order_idx
    ON library_list_items (user_id, list_id, deleted_at, position_rank, paper_id);

CREATE TABLE library_tags (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name text NOT NULL,
    normalized_name text NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    last_operation_id uuid NOT NULL,
    CONSTRAINT library_tags_user_id_unique UNIQUE (user_id, id),
    CONSTRAINT library_tags_name_check CHECK (
        char_length(name) BETWEEN 1 AND 60
        AND name = btrim(name)
        AND char_length(normalized_name) BETWEEN 1 AND 60
        AND normalized_name = lower(btrim(normalized_name))
        AND position(chr(0) IN name) = 0
    ),
    CONSTRAINT library_tags_timestamps_check CHECK (
        updated_at >= created_at
        AND (deleted_at IS NULL OR deleted_at = updated_at)
    )
);

CREATE UNIQUE INDEX library_tags_active_name_unique
    ON library_tags (user_id, normalized_name)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX library_tags_user_revision_unique
    ON library_tags (user_id, revision);
CREATE INDEX library_tags_account_name_idx
    ON library_tags (user_id, deleted_at, normalized_name, id);

CREATE TABLE library_item_tags (
    user_id uuid NOT NULL,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    tag_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    last_operation_id uuid NOT NULL,
    PRIMARY KEY (user_id, paper_id, tag_id),
    CONSTRAINT library_item_tags_owner_fk
        FOREIGN KEY (user_id, tag_id)
        REFERENCES library_tags(user_id, id) ON DELETE CASCADE,
    CONSTRAINT library_item_tags_timestamps_check CHECK (
        updated_at >= created_at
        AND (deleted_at IS NULL OR deleted_at = updated_at)
    )
);

CREATE UNIQUE INDEX library_item_tags_user_revision_unique
    ON library_item_tags (user_id, revision);
CREATE INDEX library_item_tags_account_paper_idx
    ON library_item_tags (user_id, paper_id, deleted_at, tag_id);

-- Retryable collection mutations use the same account revision fence. Only
-- content-free identities and a payload digest are retained; names, notes, and
-- other private values do not enter the operation ledger.
CREATE TABLE library_collection_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    entity_kind text NOT NULL CHECK (
        entity_kind IN ('list', 'list_item', 'tag', 'item_tag')
    ),
    entity_id uuid NOT NULL,
    secondary_id uuid,
    intent text NOT NULL CHECK (
        intent IN ('create', 'update', 'delete', 'put', 'remove')
    ),
    payload_fingerprint bytea NOT NULL CHECK (
        octet_length(payload_fingerprint) = 32
    ),
    accepted_revision bigint NOT NULL CHECK (accepted_revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT library_collection_operations_user_revision_unique
        UNIQUE (user_id, accepted_revision),
    CONSTRAINT library_collection_operations_identity_check CHECK (
        (entity_kind IN ('list', 'tag') AND secondary_id IS NULL)
        OR (entity_kind IN ('list_item', 'item_tag') AND secondary_id IS NOT NULL)
    )
);

CREATE INDEX library_collection_operations_entity_idx
    ON library_collection_operations (
        user_id,
        entity_kind,
        entity_id,
        secondary_id,
        accepted_revision DESC
    );

COMMENT ON COLUMN user_paper_library.state IS
    'Canonical five-state library value; Inbox/Read next/Reading are active.';
COMMENT ON COLUMN user_paper_library.private_note IS
    'Account-private save note; forbidden from telemetry and recommendation features.';
COMMENT ON COLUMN user_paper_library.reminder_at IS
    'User-selected UTC reminder for an active item; never derived from behavior or note content.';
