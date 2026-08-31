-- Plan 02 Phase C stores future-discovery preferences independently from the
-- canonical account library. Every account-owned row cascades from users, and
-- no table references or mutates library revisions or queue membership.

CREATE TABLE research_profiles (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Behavioral personalization is opt-in. Explicit Following preferences
    -- remain useful while this is false.
    personalization_enabled boolean NOT NULL DEFAULT false,
    preferred_discovery_mode text NOT NULL DEFAULT 'recent' CHECK (
        preferred_discovery_mode IN ('recent', 'following', 'for_you', 'explore')
    ),
    discovery_mode text NOT NULL DEFAULT 'balanced' CHECK (
        discovery_mode IN ('focused', 'balanced', 'exploratory')
    ),
    brief_size integer NOT NULL DEFAULT 20 CHECK (brief_size BETWEEN 15 AND 25),
    recency_weight real NOT NULL DEFAULT 0.5 CHECK (
        recency_weight <> 'NaN'::real AND recency_weight BETWEEN 0.0 AND 1.0
    ),
    novelty_weight real NOT NULL DEFAULT 0.3 CHECK (
        novelty_weight <> 'NaN'::real AND novelty_weight BETWEEN 0.0 AND 1.0
    ),
    diversity_weight real NOT NULL DEFAULT 0.3 CHECK (
        diversity_weight <> 'NaN'::real AND diversity_weight BETWEEN 0.0 AND 1.0
    ),
    profile_revision bigint NOT NULL CHECK (profile_revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT research_profiles_timestamps_check CHECK (updated_at >= created_at)
);

CREATE TABLE topics (
    id uuid PRIMARY KEY,
    canonical_key text NOT NULL UNIQUE,
    label text NOT NULL,
    normalized_label text NOT NULL,
    source_vocabulary text NOT NULL,
    -- Server-owned bounded enrichment only. User-entered aliases belong in
    -- profile_topics so inference can never silently become an explicit follow.
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT topics_canonical_key_check CHECK (
        canonical_key = lower(btrim(canonical_key))
        AND char_length(canonical_key) BETWEEN 1 AND 160
        AND canonical_key ~ '^[a-z0-9][a-z0-9:_./-]*$'
    ),
    CONSTRAINT topics_label_check CHECK (
        label = btrim(label)
        AND normalized_label = lower(btrim(normalized_label))
        AND char_length(label) BETWEEN 1 AND 200
        AND char_length(normalized_label) BETWEEN 1 AND 200
        AND position(chr(0) IN label) = 0
    ),
    CONSTRAINT topics_vocabulary_check CHECK (
        source_vocabulary = lower(btrim(source_vocabulary))
        AND char_length(source_vocabulary) BETWEEN 1 AND 64
        AND source_vocabulary ~ '^[a-z0-9][a-z0-9_-]*$'
    ),
    CONSTRAINT topics_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 4096
    ),
    CONSTRAINT topics_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX topics_normalized_label_idx ON topics (normalized_label, canonical_key);

CREATE TABLE profile_categories (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category text NOT NULL,
    weight real NOT NULL,
    source text NOT NULL CHECK (source IN ('explicit', 'feedback', 'inferred')),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, category, source),
    CONSTRAINT profile_categories_category_check CHECK (
        char_length(category) BETWEEN 1 AND 32
        AND category ~ '^[a-z][A-Za-z0-9-]{0,15}([.][A-Za-z0-9-]{1,15})?$'
    ),
    CONSTRAINT profile_categories_weight_check CHECK (
        weight <> 'NaN'::real AND weight BETWEEN 0.0 AND 1.0
    ),
    CONSTRAINT profile_categories_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX profile_categories_source_idx
    ON profile_categories (user_id, source, category);

CREATE TABLE profile_topics (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    topic_id uuid NOT NULL REFERENCES topics(id) ON DELETE RESTRICT,
    polarity text NOT NULL CHECK (polarity IN ('positive', 'negative')),
    strength real NOT NULL CHECK (
        strength <> 'NaN'::real AND strength BETWEEN 0.0 AND 1.0
    ),
    source text NOT NULL CHECK (source IN ('explicit', 'feedback', 'inferred')),
    user_alias text,
    explanation_source_id uuid,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, topic_id, source),
    CONSTRAINT profile_topics_alias_check CHECK (
        user_alias IS NULL OR (
            source = 'explicit'
            AND user_alias = btrim(user_alias)
            AND char_length(user_alias) BETWEEN 1 AND 160
            AND position(chr(0) IN user_alias) = 0
        )
    ),
    CONSTRAINT profile_topics_provenance_check CHECK (
        (source = 'explicit' AND explanation_source_id IS NULL)
        OR source = 'feedback'
        OR (source = 'inferred' AND explanation_source_id IS NOT NULL)
    ),
    CONSTRAINT profile_topics_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX profile_topics_source_idx
    ON profile_topics (user_id, source, topic_id);

CREATE TABLE profile_authors (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    author_key text NOT NULL,
    display_name text NOT NULL,
    source text NOT NULL CHECK (source IN ('explicit', 'feedback', 'inferred')),
    explanation_source_id uuid,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, author_key, source),
    CONSTRAINT profile_authors_key_check CHECK (
        author_key = lower(btrim(author_key))
        AND char_length(author_key) BETWEEN 1 AND 256
        AND position(chr(0) IN author_key) = 0
    ),
    CONSTRAINT profile_authors_display_name_check CHECK (
        display_name = btrim(display_name)
        AND char_length(display_name) BETWEEN 1 AND 200
        AND position(chr(0) IN display_name) = 0
    ),
    CONSTRAINT profile_authors_provenance_check CHECK (
        (source = 'explicit' AND explanation_source_id IS NULL)
        OR source = 'feedback'
        OR (source = 'inferred' AND explanation_source_id IS NOT NULL)
    ),
    CONSTRAINT profile_authors_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX profile_authors_source_idx
    ON profile_authors (user_id, source, author_key);

-- Durable retry protection retains only a content-free intent label and a
-- SHA-256 fingerprint. Raw topic/author/category labels are not duplicated in
-- this ledger and expiry is mandatory.
CREATE TABLE research_profile_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    intent text NOT NULL CHECK (
        intent IN (
            'update_settings',
            'upsert_topic',
            'delete_topic',
            'upsert_author',
            'delete_author',
            'reset_inferred',
            'reset_all'
        )
    ),
    intent_fingerprint bytea NOT NULL CHECK (octet_length(intent_fingerprint) = 32),
    accepted_revision bigint NOT NULL CHECK (accepted_revision >= 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT research_profile_operations_expiry_check CHECK (expires_at > created_at)
);

CREATE INDEX research_profile_operations_expiry_idx
    ON research_profile_operations (expires_at, user_id, operation_id);

COMMENT ON TABLE research_profiles IS
    'Future-discovery preferences only; never queue or library authority.';
COMMENT ON COLUMN research_profiles.personalization_enabled IS
    'Opt-in behavioral personalization toggle; false purges non-explicit interests.';
COMMENT ON TABLE research_profile_operations IS
    'Bounded content-free idempotency ledger; account deletion cascades every row.';
