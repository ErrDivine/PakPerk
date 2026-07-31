-- Phase 4 originally fenced commits through one global revision clock. That
-- serialized unrelated accounts and exposed aggregate write activity through
-- otherwise empty change feeds. Move the same ordered ledger onto independent
-- per-user clocks without changing the public bigint wire shape.
--
-- Existing clients may hold a global checkpoint. Rebased users start at a
-- high, exactly representable epoch (2^42), and their reset floor starts at
-- that epoch. Every valid legacy checkpoint is therefore below the floor and
-- receives one safe full-sync reset. The guard fails closed instead of risking
-- an ambiguous checkpoint if a pre-release deployment somehow reached 2^42
-- global operations.
DO $migration$
DECLARE
    per_user_epoch constant bigint := 4398046511104;
BEGIN
    IF EXISTS (
        SELECT 1 FROM library_revision_clock
        WHERE current_revision >= per_user_epoch
    ) OR EXISTS (
        SELECT 1 FROM user_paper_library
        WHERE revision >= per_user_epoch
    ) OR EXISTS (
        SELECT 1 FROM library_operations
        WHERE accepted_revision >= per_user_epoch
    ) OR EXISTS (
        SELECT 1 FROM library_sync_metadata
        WHERE current_revision >= per_user_epoch
           OR purged_through_revision >= per_user_epoch
    ) THEN
        RAISE EXCEPTION
            'global library revision is too large for an unambiguous per-user migration'
            USING ERRCODE = '22003';
    END IF;
END
$migration$;

CREATE TEMPORARY TABLE library_revision_remap ON COMMIT DROP AS
SELECT
    user_id,
    operation_id,
    accepted_revision AS old_revision,
    4398046511104::bigint + row_number() OVER (
        PARTITION BY user_id
        ORDER BY accepted_revision, operation_id
    ) AS new_revision
FROM library_operations;

CREATE UNIQUE INDEX library_revision_remap_operation_idx
    ON library_revision_remap (user_id, operation_id);
CREATE UNIQUE INDEX library_revision_remap_revision_idx
    ON library_revision_remap (user_id, new_revision);

-- Calculate metadata from the old revision values before rewriting the
-- ledger. The epoch itself is a reset barrier; operations at or below a prior
-- tombstone floor are then added to retain an accurate post-reset floor.
CREATE TEMPORARY TABLE library_sync_metadata_remap ON COMMIT DROP AS
WITH scoped_users AS (
    SELECT user_id FROM library_sync_metadata
    UNION
    SELECT user_id FROM library_operations
    UNION
    SELECT user_id FROM user_paper_library
)
SELECT
    scoped.user_id,
    4398046511104::bigint + count(operation.operation_id) AS current_revision,
    4398046511104::bigint + count(operation.operation_id) FILTER (
        WHERE operation.accepted_revision
            <= COALESCE(metadata.purged_through_revision, 0)
    ) AS purged_through_revision
FROM scoped_users AS scoped
LEFT JOIN library_sync_metadata AS metadata
    ON metadata.user_id = scoped.user_id
LEFT JOIN library_operations AS operation
    ON operation.user_id = scoped.user_id
GROUP BY scoped.user_id;

-- A canonical row without its durable operation would make safe remapping and
-- replay impossible. Abort rather than silently inventing history.
DO $migration$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM user_paper_library AS library
        LEFT JOIN library_revision_remap AS remap
          ON remap.user_id = library.user_id
         AND remap.operation_id = library.last_operation_id
        WHERE remap.operation_id IS NULL
    ) THEN
        RAISE EXCEPTION
            'library canonical row is missing its durable operation ledger entry'
            USING ERRCODE = '23514';
    END IF;
END
$migration$;

UPDATE user_paper_library AS library
SET revision = remap.new_revision
FROM library_revision_remap AS remap
WHERE remap.user_id = library.user_id
  AND remap.operation_id = library.last_operation_id;

UPDATE library_operations AS operation
SET accepted_revision = remap.new_revision
FROM library_revision_remap AS remap
WHERE remap.user_id = operation.user_id
  AND remap.operation_id = operation.operation_id;

INSERT INTO library_sync_metadata (
    user_id,
    current_revision,
    purged_through_revision,
    updated_at
)
SELECT
    user_id,
    current_revision,
    purged_through_revision,
    statement_timestamp()
FROM library_sync_metadata_remap
ON CONFLICT (user_id) DO UPDATE
SET current_revision = EXCLUDED.current_revision,
    purged_through_revision = EXCLUDED.purged_through_revision,
    updated_at = EXCLUDED.updated_at;

DROP TABLE library_revision_clock;
DROP SEQUENCE library_revision_seq;

COMMENT ON COLUMN library_sync_metadata.current_revision IS
    'Account-scoped committed library watermark; never compare across users.';
COMMENT ON COLUMN library_sync_metadata.purged_through_revision IS
    'Account-scoped floor below which a full library reset is required.';
