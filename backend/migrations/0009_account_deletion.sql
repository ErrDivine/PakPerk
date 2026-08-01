-- Durable, replay-safe account erasure. Signed tombstones are external to
-- PostgreSQL; this ledger is the transactional guard against JIT resurrection.

ALTER TABLE users
    ALTER COLUMN oidc_issuer DROP NOT NULL,
    ALTER COLUMN oidc_subject DROP NOT NULL,
    ADD COLUMN identity_fingerprint_key_id text,
    ADD COLUMN identity_fingerprint bytea;

ALTER TABLE users
    DROP CONSTRAINT users_oidc_issuer_valid,
    DROP CONSTRAINT users_oidc_subject_valid,
    ADD CONSTRAINT users_oidc_identity_paired CHECK (
        (oidc_issuer IS NULL) = (oidc_subject IS NULL)
    ),
    ADD CONSTRAINT users_oidc_issuer_valid CHECK (
        oidc_issuer IS NULL OR (
            oidc_issuer = btrim(oidc_issuer)
            AND char_length(oidc_issuer) BETWEEN 1 AND 2048
        )
    ),
    ADD CONSTRAINT users_oidc_subject_valid CHECK (
        oidc_subject IS NULL OR (
            oidc_subject = btrim(oidc_subject)
            AND char_length(oidc_subject) BETWEEN 1 AND 512
        )
    ),
    ADD CONSTRAINT users_identity_fingerprint_paired CHECK (
        (identity_fingerprint_key_id IS NULL) = (identity_fingerprint IS NULL)
    ),
    ADD CONSTRAINT users_identity_fingerprint_key_valid CHECK (
        identity_fingerprint_key_id IS NULL OR (
            identity_fingerprint_key_id = btrim(identity_fingerprint_key_id)
            AND char_length(identity_fingerprint_key_id) BETWEEN 1 AND 64
            AND identity_fingerprint_key_id ~ '^[a-z0-9_-]+$'
        )
    ),
    ADD CONSTRAINT users_identity_fingerprint_valid CHECK (
        identity_fingerprint IS NULL OR octet_length(identity_fingerprint) = 32
    );

CREATE UNIQUE INDEX users_identity_fingerprint_unique
    ON users (identity_fingerprint_key_id, identity_fingerprint)
    WHERE identity_fingerprint IS NOT NULL;

CREATE TABLE account_deletion_ledger (
    operation_id uuid PRIMARY KEY,
    original_user_id uuid NOT NULL UNIQUE,
    identity_fingerprint_key_id text NOT NULL CHECK (
        identity_fingerprint_key_id = btrim(identity_fingerprint_key_id)
        AND char_length(identity_fingerprint_key_id) BETWEEN 1 AND 64
        AND identity_fingerprint_key_id ~ '^[a-z0-9_-]+$'
    ),
    identity_fingerprint bytea NOT NULL CHECK (octet_length(identity_fingerprint) = 32),
    requested_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    externalized_at timestamptz,
    completed_at timestamptz,
    expires_at timestamptz,
    CONSTRAINT account_deletion_ledger_identity_unique UNIQUE (
        identity_fingerprint_key_id,
        identity_fingerprint
    ),
    CONSTRAINT account_deletion_ledger_timestamps_ordered CHECK (
        (externalized_at IS NULL OR externalized_at >= requested_at)
        AND (completed_at IS NULL OR completed_at >= requested_at)
        AND (expires_at IS NULL OR expires_at > requested_at)
    )
);

CREATE INDEX account_deletion_ledger_externalization_age_idx
    ON account_deletion_ledger (requested_at, operation_id)
    WHERE externalized_at IS NULL;

CREATE INDEX account_deletion_ledger_expiry_idx
    ON account_deletion_ledger (expires_at, operation_id)
    WHERE expires_at IS NOT NULL;

CREATE TABLE account_deletion_jobs (
    operation_id uuid PRIMARY KEY REFERENCES account_deletion_ledger(operation_id) ON DELETE RESTRICT,
    user_id uuid NOT NULL UNIQUE,
    identity_fingerprint_key_id text NOT NULL,
    identity_fingerprint bytea NOT NULL,
    oidc_issuer text,
    oidc_subject text,
    state text NOT NULL DEFAULT 'requested' CHECK (
        state IN (
            'requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted',
            'completed', 'failed_retryable', 'failed_terminal'
        )
    ),
    retry_from text CHECK (
        retry_from IS NULL
        OR retry_from IN ('requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted')
    ),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts integer NOT NULL DEFAULT 12 CHECK (max_attempts BETWEEN 1 AND 100),
    available_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    provider_identity_deleted_at timestamptz,
    app_data_deleted_at timestamptz,
    last_error_class text,
    last_error_code text,
    last_error_message text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT account_deletion_jobs_ledger_identity_fk FOREIGN KEY (
        identity_fingerprint_key_id,
        identity_fingerprint
    ) REFERENCES account_deletion_ledger (
        identity_fingerprint_key_id,
        identity_fingerprint
    ) ON DELETE RESTRICT,
    CONSTRAINT account_deletion_jobs_provider_identity_paired CHECK (
        (oidc_issuer IS NULL) = (oidc_subject IS NULL)
    ),
    CONSTRAINT account_deletion_jobs_provider_identity_valid CHECK (
        oidc_issuer IS NULL OR (
            oidc_issuer = btrim(oidc_issuer)
            AND char_length(oidc_issuer) BETWEEN 1 AND 2048
            AND oidc_subject = btrim(oidc_subject)
            AND char_length(oidc_subject) BETWEEN 1 AND 512
        )
    ),
    CONSTRAINT account_deletion_jobs_lease_paired CHECK (
        (lease_owner IS NULL) = (lease_expires_at IS NULL)
    ),
    CONSTRAINT account_deletion_jobs_error_paired CHECK (
        (
            last_error_class IS NULL
            AND last_error_code IS NULL
            AND last_error_message IS NULL
        )
        OR (
            last_error_class IS NOT NULL
            AND last_error_code IS NOT NULL
            AND last_error_message IS NOT NULL
        )
    ),
    CONSTRAINT account_deletion_jobs_error_valid CHECK (
        last_error_class IS NULL OR (
            last_error_class ~ '^[a-z0-9_:-]{1,64}$'
            AND last_error_code ~ '^[a-z0-9_:-]{1,64}$'
            AND char_length(last_error_message) BETWEEN 1 AND 256
            AND last_error_message !~ '[[:cntrl:]]'
        )
    ),
    CONSTRAINT account_deletion_jobs_state_checkpoint_valid CHECK (
        (state = 'failed_retryable' AND retry_from IS NOT NULL)
        OR (state <> 'failed_retryable' AND retry_from IS NULL)
    ),
    CONSTRAINT account_deletion_jobs_timestamps_ordered CHECK (
        updated_at >= created_at
        AND (provider_identity_deleted_at IS NULL OR provider_identity_deleted_at >= created_at)
        AND (app_data_deleted_at IS NULL OR app_data_deleted_at >= created_at)
    )
);

CREATE INDEX account_deletion_jobs_claim_idx
    ON account_deletion_jobs (available_at, created_at, operation_id)
    WHERE state IN ('requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted', 'failed_retryable');

CREATE INDEX account_deletion_jobs_lease_recovery_idx
    ON account_deletion_jobs (lease_expires_at, operation_id)
    WHERE lease_expires_at IS NOT NULL;

CREATE INDEX account_deletion_jobs_state_age_idx
    ON account_deletion_jobs (state, updated_at, operation_id);

CREATE TABLE account_deletion_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_id uuid NOT NULL REFERENCES account_deletion_ledger(operation_id) ON DELETE RESTRICT,
    from_state text,
    to_state text NOT NULL CHECK (
        to_state IN (
            'requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted',
            'completed', 'failed_retryable', 'failed_terminal'
        )
    ),
    actor_kind text NOT NULL CHECK (actor_kind IN ('system', 'admin')),
    actor_label text,
    reason_code text CHECK (
        reason_code IS NULL OR reason_code ~ '^[a-z0-9_:-]{1,64}$'
    ),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz,
    CONSTRAINT account_deletion_events_from_state_valid CHECK (
        from_state IS NULL OR from_state IN (
            'requested', 'sessions_revoked', 'identity_deleted', 'app_data_deleted',
            'completed', 'failed_retryable', 'failed_terminal'
        )
    ),
    CONSTRAINT account_deletion_events_actor_valid CHECK (
        (actor_kind = 'system' AND actor_label IS NULL)
        OR (
            actor_kind = 'admin'
            AND actor_label = btrim(actor_label)
            AND char_length(actor_label) BETWEEN 1 AND 128
            AND actor_label ~ '^[A-Za-z0-9@._:-]+$'
        )
    ),
    CONSTRAINT account_deletion_events_expiry_valid CHECK (
        expires_at IS NULL OR expires_at > created_at
    )
);

CREATE INDEX account_deletion_events_operation_idx
    ON account_deletion_events (operation_id, created_at, id);

CREATE INDEX account_deletion_events_expiry_idx
    ON account_deletion_events (expires_at, id)
    WHERE expires_at IS NOT NULL;

-- Minimal operator evidence for explicit external-ledger erasure. This table
-- intentionally has no foreign key: it must survive cleanup of the
-- fingerprint/user-bearing local ledger and job rows.
CREATE TABLE account_deletion_external_purges (
    operation_id uuid PRIMARY KEY,
    actor_label text NOT NULL CHECK (
        actor_label = btrim(actor_label)
        AND char_length(actor_label) BETWEEN 1 AND 128
        AND actor_label ~ '^[A-Za-z0-9._:-]+$'
    ),
    evidence_id text NOT NULL CHECK (
        evidence_id = btrim(evidence_id)
        AND char_length(evidence_id) BETWEEN 1 AND 128
        AND evidence_id ~ '^[A-Za-z0-9._:/-]+$'
    ),
    completed_at timestamptz NOT NULL,
    oldest_recoverable_at timestamptz NOT NULL,
    authorized_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    purged_at timestamptz,
    expires_at timestamptz,
    CONSTRAINT account_deletion_external_purges_ordered CHECK (
        oldest_recoverable_at > completed_at
        AND (purged_at IS NULL OR purged_at >= authorized_at)
        AND (expires_at IS NULL OR (purged_at IS NOT NULL AND expires_at > purged_at))
    )
);

CREATE INDEX account_deletion_external_purges_expiry_idx
    ON account_deletion_external_purges (expires_at, operation_id)
    WHERE expires_at IS NOT NULL;

-- Random per-event pseudonyms are intentionally unrelated to the stable
-- fingerprint used by the restore ledger.
ALTER TABLE comment_moderation_events
    ADD COLUMN retention_pseudonym bytea,
    ADD COLUMN actor_retention_pseudonym bytea,
    ADD COLUMN retention_expires_at timestamptz;

ALTER TABLE comment_moderation_events
    DROP CONSTRAINT comment_moderation_events_actor_valid,
    DROP CONSTRAINT comment_moderation_events_target_valid,
    ADD CONSTRAINT comment_moderation_events_actor_valid CHECK (
        (
            actor_kind = 'system'
            AND actor_user_id IS NULL
            AND actor_label IS NULL
            AND actor_retention_pseudonym IS NULL
        )
        OR (
            actor_kind = 'admin'
            AND (
                (actor_user_id IS NOT NULL)::integer
                + (actor_label IS NOT NULL)::integer
                + (actor_retention_pseudonym IS NOT NULL)::integer
            ) = 1
        )
    ),
    ADD CONSTRAINT comment_moderation_events_target_valid CHECK (
        (
            (comment_id IS NOT NULL)::integer
            + (target_user_id IS NOT NULL)::integer
            + (retention_pseudonym IS NOT NULL)::integer
        ) = 1
    ),
    ADD CONSTRAINT comment_moderation_events_retention_valid CHECK (
        (retention_pseudonym IS NULL OR octet_length(retention_pseudonym) = 32)
        AND (
            actor_retention_pseudonym IS NULL
            OR octet_length(actor_retention_pseudonym) = 32
        )
        AND (retention_expires_at IS NULL OR retention_expires_at > created_at)
        AND (retention_pseudonym IS NULL OR retention_expires_at IS NOT NULL)
        AND (actor_retention_pseudonym IS NULL OR retention_expires_at IS NOT NULL)
    );

CREATE INDEX comment_moderation_events_retention_expiry_idx
    ON comment_moderation_events (retention_expires_at, id)
    WHERE retention_expires_at IS NOT NULL;
