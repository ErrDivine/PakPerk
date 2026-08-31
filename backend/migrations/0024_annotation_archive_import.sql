-- Lossless, principal-scoped annotation archive import and explicit conflict
-- resolution. Import batches keep only a content-free digest and counts; note
-- bodies and source quotes remain in their existing private artifact tables.

ALTER TABLE annotation_conflicts
    ADD COLUMN merged_body text CHECK (
        merged_body IS NULL OR (
            char_length(merged_body) BETWEEN 1 AND 100000
            AND btrim(merged_body) <> ''
            AND position(chr(0) IN merged_body) = 0
        )
    );

-- Migration 0022 exposed the resolution columns before the application had a
-- first-class resolution write path. Preserve any principal-scoped legacy
-- `merged` decision using the only retained accepted value: the annotation's
-- current private body. Fail closed if a legacy row has no recoverable body;
-- inventing one from either rejected side would destroy conflict fidelity.
UPDATE annotation_conflicts AS conflict
SET merged_body = annotation.body
FROM annotations AS annotation
WHERE conflict.user_id = annotation.user_id
  AND conflict.annotation_id = annotation.id
  AND conflict.resolution = 'merged'
  AND conflict.merged_body IS NULL
  AND annotation.body IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM annotation_conflicts
        WHERE resolution = 'merged' AND merged_body IS NULL
    ) THEN
        RAISE EXCEPTION
            'cannot preserve legacy merged annotation conflict without a retained accepted body';
    END IF;
END
$$;

ALTER TABLE annotation_conflicts
    ADD CONSTRAINT annotation_conflicts_resolution_body_ck CHECK (
        (resolution = 'merged' AND merged_body IS NOT NULL)
        OR (resolution IS DISTINCT FROM 'merged' AND merged_body IS NULL)
    );

ALTER TABLE annotation_conflicts
    DROP CONSTRAINT annotation_conflicts_pkey;
ALTER TABLE annotation_conflicts
    ADD PRIMARY KEY (user_id, id);

ALTER TABLE annotation_reanchor_attempts
    DROP CONSTRAINT annotation_reanchor_attempts_pkey;
ALTER TABLE annotation_reanchor_attempts
    ADD PRIMARY KEY (user_id, id);

CREATE TABLE annotation_imports (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL,
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    schema_version text NOT NULL CHECK (
        schema_version = 'pakperk.research-export.v1'
    ),
    imported_annotations integer NOT NULL CHECK (imported_annotations >= 0),
    imported_conflicts integer NOT NULL CHECK (imported_conflicts >= 0),
    imported_reanchor_attempts integer NOT NULL CHECK (
        imported_reanchor_attempts >= 0
    ),
    skipped_annotations integer NOT NULL CHECK (skipped_annotations >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, operation_id)
);

COMMENT ON TABLE annotation_imports IS
    'Idempotency ledger for principal-scoped annotation archive imports; stores no note or quote content.';
