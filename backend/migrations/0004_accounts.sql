CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    oidc_issuer text NOT NULL,
    oidc_subject text NOT NULL,
    handle text,
    display_name text,
    status text NOT NULL DEFAULT 'active' CHECK (
        status IN ('active', 'suspended', 'deletion_pending', 'deleted')
    ),
    profile_version bigint NOT NULL DEFAULT 1 CHECK (profile_version > 0),
    terms_version text,
    terms_accepted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT users_oidc_identity_unique UNIQUE (oidc_issuer, oidc_subject),
    CONSTRAINT users_oidc_issuer_valid CHECK (
        oidc_issuer = btrim(oidc_issuer)
        AND char_length(oidc_issuer) BETWEEN 1 AND 2048
    ),
    CONSTRAINT users_oidc_subject_valid CHECK (
        oidc_subject = btrim(oidc_subject)
        AND char_length(oidc_subject) BETWEEN 1 AND 512
    ),
    CONSTRAINT users_handle_valid CHECK (
        handle IS NULL
        OR (
            handle = lower(handle)
            AND handle ~ '^[a-z0-9_]{3,30}$'
            AND handle ~ '[a-z0-9]'
        )
    ),
    CONSTRAINT users_display_name_valid CHECK (
        display_name IS NULL
        OR (
            display_name = btrim(display_name)
            AND char_length(display_name) BETWEEN 1 AND 80
        )
    ),
    CONSTRAINT users_terms_paired CHECK (
        (terms_version IS NULL AND terms_accepted_at IS NULL)
        OR (
            terms_version IS NOT NULL
            AND terms_accepted_at IS NOT NULL
            AND terms_version = btrim(terms_version)
            AND char_length(terms_version) BETWEEN 1 AND 64
        )
    ),
    CONSTRAINT users_timestamps_ordered CHECK (
        updated_at >= created_at
        AND last_seen_at >= created_at
        AND (terms_accepted_at IS NULL OR terms_accepted_at >= created_at)
    )
);

-- The application persists canonical lowercase handles, while the functional
-- index provides defense in depth if a future writer misses normalization.
CREATE UNIQUE INDEX users_handle_ci_unique
    ON users (lower(handle))
    WHERE handle IS NOT NULL;

CREATE INDEX users_active_idx
    ON users (id)
    WHERE status = 'active';

CREATE INDEX users_last_seen_idx
    ON users (last_seen_at)
    WHERE status = 'active';
