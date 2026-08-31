-- Plan 02 Phase E/F recommendation records. Queue eligibility remains owned by
-- the reading-feed snapshot. These constraints make it impossible to persist
-- a ready/served authenticated batch without a proven-empty library revision.

CREATE TABLE recommendation_batches (
    id uuid PRIMARY KEY,
    user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    mode text NOT NULL CHECK (mode IN ('recent', 'following', 'for_you', 'explore')),
    query_key text NOT NULL,
    local_date date NOT NULL,
    profile_revision bigint,
    feedback_revision bigint NOT NULL DEFAULT 0 CHECK (feedback_revision >= 0),
    library_revision bigint,
    queue_proven_empty boolean,
    algorithm_version text NOT NULL,
    policy_version text NOT NULL,
    seed bigint NOT NULL CHECK (seed >= 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL,
    status text NOT NULL CHECK (
        status IN (
            'building',
            'ready',
            'served',
            'superseded',
            'blocked_by_queue',
            'expired',
            'failed'
        )
    ),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT recommendation_batches_principal_check CHECK (
        (user_id IS NOT NULL) <> (anonymous_session_id IS NOT NULL)
    ),
    CONSTRAINT recommendation_batches_query_key_check CHECK (
        char_length(query_key) BETWEEN 1 AND 160
        AND query_key = btrim(query_key)
        AND position(chr(0) IN query_key) = 0
    ),
    CONSTRAINT recommendation_batches_revision_check CHECK (
        (profile_revision IS NULL OR profile_revision >= 0)
        AND (library_revision IS NULL OR library_revision >= 0)
    ),
    CONSTRAINT recommendation_batches_version_check CHECK (
        algorithm_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
        AND policy_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
    ),
    CONSTRAINT recommendation_batches_expiry_check CHECK (expires_at > created_at),
    CONSTRAINT recommendation_batches_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 4096
    ),
    CONSTRAINT recommendation_batches_account_authority_check CHECK (
        user_id IS NULL
        OR (
            status IN ('building', 'failed', 'expired', 'superseded')
            AND (
                (library_revision IS NULL AND queue_proven_empty IS NULL)
                OR library_revision IS NOT NULL
            )
        )
        OR (
            status IN ('ready', 'served')
            AND library_revision IS NOT NULL
            AND queue_proven_empty IS TRUE
        )
        OR (
            status = 'blocked_by_queue'
            AND library_revision IS NOT NULL
            AND queue_proven_empty IS FALSE
        )
    )
);

CREATE UNIQUE INDEX recommendation_batches_account_idempotency_idx
    ON recommendation_batches (
        user_id,
        mode,
        local_date,
        query_key,
        COALESCE(profile_revision, -1),
        feedback_revision,
        COALESCE(library_revision, -1),
        algorithm_version,
        policy_version
    )
    WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX recommendation_batches_anonymous_idempotency_idx
    ON recommendation_batches (
        anonymous_session_id,
        mode,
        local_date,
        query_key,
        algorithm_version,
        policy_version
    )
    WHERE anonymous_session_id IS NOT NULL;
CREATE INDEX recommendation_batches_account_ready_idx
    ON recommendation_batches (user_id, status, created_at DESC, id)
    WHERE user_id IS NOT NULL;
CREATE INDEX recommendation_batches_expiry_idx
    ON recommendation_batches (expires_at, status, id);

CREATE TABLE recommendation_candidates (
    batch_id uuid NOT NULL REFERENCES recommendation_batches(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    candidate_sources text[] NOT NULL,
    raw_features jsonb NOT NULL,
    base_score real NOT NULL,
    reranked_position integer,
    reason_codes text[] NOT NULL,
    reason_evidence jsonb NOT NULL,
    served_at timestamptz,
    PRIMARY KEY (batch_id, paper_id),
    CONSTRAINT recommendation_candidates_sources_check CHECK (
        cardinality(candidate_sources) BETWEEN 1 AND 8
        AND candidate_sources <@ ARRAY[
            'recent',
            'category_follow',
            'topic_follow',
            'author_follow',
            'feedback_affinity',
            'inferred_affinity',
            'semantic',
            'citation',
            'exploration'
        ]::text[]
    ),
    CONSTRAINT recommendation_candidates_features_check CHECK (
        jsonb_typeof(raw_features) = 'object'
        AND pg_column_size(raw_features) <= 4096
    ),
    CONSTRAINT recommendation_candidates_score_check CHECK (
        base_score <> 'NaN'::real AND base_score BETWEEN -10.0 AND 10.0
    ),
    CONSTRAINT recommendation_candidates_position_check CHECK (
        reranked_position IS NULL OR reranked_position >= 0
    ),
    CONSTRAINT recommendation_candidates_reasons_check CHECK (
        cardinality(reason_codes) BETWEEN 1 AND 16
        AND reason_codes <@ ARRAY[
            'recent_category',
            'followed_category',
            'followed_topic',
            'followed_author',
            'saved_query_match',
            'feedback_category_affinity',
            'inferred_category_affinity',
            'reviewed_paper_similarity',
            'archived_paper_similarity',
            'reviewed_paper_citation',
            'archived_paper_citation',
            'adjacent_topic_exploration',
            'underrepresented_category_exploration',
            'diversity_slot'
        ]::text[]
    ),
    CONSTRAINT recommendation_candidates_evidence_check CHECK (
        jsonb_typeof(reason_evidence) = 'array'
        AND jsonb_array_length(reason_evidence) BETWEEN 1 AND 16
        AND pg_column_size(reason_evidence) <= 4096
    )
);

CREATE UNIQUE INDEX recommendation_candidates_position_idx
    ON recommendation_candidates (batch_id, reranked_position)
    WHERE reranked_position IS NOT NULL;
CREATE INDEX recommendation_candidates_paper_idx
    ON recommendation_candidates (paper_id, batch_id);

CREATE TABLE recommendation_feedback (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    batch_id uuid REFERENCES recommendation_batches(id) ON DELETE SET NULL,
    feedback_type text NOT NULL CHECK (
        feedback_type IN ('relevant', 'not_relevant', 'dismissed')
    ),
    reason text CHECK (
        reason IS NULL OR reason IN (
            'already_seen',
            'off_topic',
            'too_basic',
            'too_advanced',
            'low_quality',
            'other'
        )
    ),
    idempotency_key uuid NOT NULL CHECK (
        idempotency_key <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT recommendation_feedback_user_idempotency_unique
        UNIQUE (user_id, idempotency_key)
);

CREATE INDEX recommendation_feedback_account_time_idx
    ON recommendation_feedback (user_id, created_at DESC, id);
CREATE INDEX recommendation_feedback_batch_item_idx
    ON recommendation_feedback (batch_id, paper_id)
    WHERE batch_id IS NOT NULL;

-- Feedback is an independent personalization input. Its revision fences
-- account batches even when the optional research-profile feature is dormant,
-- preventing a served pre-feedback batch from being replayed after a user
-- explicitly hides or rates an item.
CREATE TABLE recommendation_feedback_revisions (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    current_revision bigint NOT NULL CHECK (current_revision >= 0),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE paper_interactions (
    id uuid PRIMARY KEY,
    user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    installation_id_hash text,
    event_type text NOT NULL CHECK (
        event_type IN (
            'impression_qualified',
            'abstract_opened',
            'introduction_committed',
            'connections_opened',
            'saved',
            'unsaved',
            'marked_relevant',
            'marked_not_relevant',
            'dismissed',
            'opened_original',
            'opened_connection',
            'library_state_changed'
        )
    ),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    feed_mode text CHECK (
        feed_mode IS NULL OR feed_mode IN ('to_read', 'recent', 'following', 'for_you', 'explore')
    ),
    batch_id uuid REFERENCES recommendation_batches(id) ON DELETE SET NULL,
    position integer CHECK (position IS NULL OR position >= 0),
    reason_codes text[] NOT NULL DEFAULT ARRAY[]::text[],
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT paper_interactions_principal_check CHECK (
        (user_id IS NOT NULL) <> (anonymous_session_id IS NOT NULL)
    ),
    CONSTRAINT paper_interactions_installation_hash_check CHECK (
        installation_id_hash IS NULL OR installation_id_hash ~ '^[A-Za-z0-9_-]{43}$'
    ),
    CONSTRAINT paper_interactions_reasons_check CHECK (
        cardinality(reason_codes) <= 16
        AND reason_codes <@ ARRAY[
            'recent_category',
            'followed_category',
            'followed_topic',
            'followed_author',
            'saved_query_match',
            'feedback_category_affinity',
            'inferred_category_affinity',
            'reviewed_paper_similarity',
            'archived_paper_similarity',
            'reviewed_paper_citation',
            'archived_paper_citation',
            'adjacent_topic_exploration',
            'underrepresented_category_exploration',
            'diversity_slot'
        ]::text[]
    ),
    CONSTRAINT paper_interactions_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object'
        AND pg_column_size(metadata) <= 2048
    ),
    CONSTRAINT paper_interactions_time_check CHECK (
        occurred_at <= received_at + interval '5 minutes'
        AND expires_at > received_at
    )
);

CREATE INDEX paper_interactions_account_time_idx
    ON paper_interactions (user_id, occurred_at DESC, id)
    WHERE user_id IS NOT NULL;
CREATE INDEX paper_interactions_expiry_idx
    ON paper_interactions (expires_at, id);
CREATE INDEX paper_interactions_batch_idx
    ON paper_interactions (batch_id, paper_id)
    WHERE batch_id IS NOT NULL;

COMMENT ON TABLE recommendation_batches IS
    'Servable authenticated batches are bound to a proven-empty library revision.';
COMMENT ON COLUMN recommendation_candidates.raw_features IS
    'Closed numeric/symbolic features only; never notes, full text, dwell content, or identity attributes.';
COMMENT ON COLUMN recommendation_candidates.reason_evidence IS
    'Immutable typed evidence for template explanations, including exact inactive seed identities.';
COMMENT ON TABLE paper_interactions IS
    'Content-free bounded product/evaluation events; never queue or library authority.';
