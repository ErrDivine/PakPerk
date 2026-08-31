-- Plan 02 Phase E/F durable recommendation generation. This is deliberately
-- separate from the paper-processing jobs table: recommendation work is owned
-- by an account/revision tuple and never weakens the paper/generation invariant.

ALTER TABLE recommendation_batches
    ADD COLUMN next_published_at timestamptz,
    ADD COLUMN next_paper_id uuid REFERENCES papers(id) ON DELETE RESTRICT,
    ADD COLUMN saved_search_revision_digest bytea CHECK (
        saved_search_revision_digest IS NULL
        OR octet_length(saved_search_revision_digest) = 32
    ),
    ADD CONSTRAINT recommendation_batches_next_position_check CHECK (
        (next_published_at IS NULL) = (next_paper_id IS NULL)
    );

ALTER TABLE recommendation_candidates
    DROP CONSTRAINT recommendation_candidates_sources_check;
ALTER TABLE recommendation_candidates
    ADD CONSTRAINT recommendation_candidates_sources_check CHECK (
        cardinality(candidate_sources) BETWEEN 1 AND 10
        AND candidate_sources <@ ARRAY[
            'recent',
            'category_follow',
            'topic_follow',
            'author_follow',
            'saved_query',
            'feedback_affinity',
            'inferred_affinity',
            'semantic',
            'citation',
            'exploration'
        ]::text[]
    );

ALTER TABLE recommendation_candidates
    DROP CONSTRAINT recommendation_candidates_reasons_check;
ALTER TABLE recommendation_candidates
    ADD CONSTRAINT recommendation_candidates_reasons_check CHECK (
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
    );

ALTER TABLE paper_interactions
    DROP CONSTRAINT paper_interactions_reasons_check;
ALTER TABLE paper_interactions
    ADD CONSTRAINT paper_interactions_reasons_check CHECK (
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
    );

CREATE TABLE recommendation_generation_jobs (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    batch_id uuid NOT NULL UNIQUE,
    mode text NOT NULL CHECK (mode IN ('recent', 'following', 'for_you', 'explore')),
    query_key text NOT NULL,
    local_date date NOT NULL,
    profile_revision bigint,
    feedback_revision bigint NOT NULL CHECK (feedback_revision >= 0),
    library_revision bigint NOT NULL CHECK (library_revision >= 0),
    algorithm_version text NOT NULL,
    policy_version text NOT NULL,
    seed bigint NOT NULL CHECK (seed >= 0),
    page_limit integer NOT NULL CHECK (page_limit BETWEEN 1 AND 50),
    intent_fingerprint bytea NOT NULL CHECK (octet_length(intent_fingerprint) = 32),
    saved_search_revision_digest bytea CHECK (
        saved_search_revision_digest IS NULL
        OR octet_length(saved_search_revision_digest) = 32
    ),
    next_published_at timestamptz,
    next_paper_id uuid REFERENCES papers(id) ON DELETE RESTRICT,
    state text NOT NULL DEFAULT 'queued' CHECK (
        state IN ('queued', 'running', 'completed', 'superseded', 'failed')
    ),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts integer NOT NULL CHECK (max_attempts BETWEEN 1 AND 10),
    available_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    completed_at timestamptz,
    CONSTRAINT recommendation_generation_jobs_query_key_check CHECK (
        char_length(query_key) BETWEEN 1 AND 160
        AND query_key = btrim(query_key)
        AND position(chr(0) IN query_key) = 0
    ),
    CONSTRAINT recommendation_generation_jobs_revision_check CHECK (
        profile_revision IS NULL OR profile_revision >= 0
    ),
    CONSTRAINT recommendation_generation_jobs_version_check CHECK (
        algorithm_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
        AND policy_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
    ),
    CONSTRAINT recommendation_generation_jobs_next_position_check CHECK (
        (next_published_at IS NULL) = (next_paper_id IS NULL)
    ),
    CONSTRAINT recommendation_generation_jobs_attempts_check CHECK (
        attempts <= max_attempts
    ),
    CONSTRAINT recommendation_generation_jobs_lease_owner_check CHECK (
        lease_owner IS NULL OR (
            char_length(lease_owner) BETWEEN 1 AND 96
            AND lease_owner = btrim(lease_owner)
            AND position(chr(0) IN lease_owner) = 0
        )
    ),
    CONSTRAINT recommendation_generation_jobs_error_code_check CHECK (
        last_error_code IS NULL OR last_error_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
    ),
    CONSTRAINT recommendation_generation_jobs_state_check CHECK (
        (
            state = 'queued'
            AND lease_owner IS NULL
            AND lease_expires_at IS NULL
            AND completed_at IS NULL
        )
        OR (
            state = 'running'
            AND lease_owner IS NOT NULL
            AND lease_expires_at IS NOT NULL
            AND completed_at IS NULL
        )
        OR (
            state IN ('completed', 'superseded', 'failed')
            AND lease_owner IS NULL
            AND lease_expires_at IS NULL
            AND completed_at IS NOT NULL
        )
    ),
    CONSTRAINT recommendation_generation_jobs_user_intent_unique
        UNIQUE (user_id, intent_fingerprint)
);

CREATE UNIQUE INDEX recommendation_generation_jobs_exact_identity_idx
    ON recommendation_generation_jobs (
        user_id,
        mode,
        local_date,
        query_key,
        COALESCE(profile_revision, -1),
        feedback_revision,
        library_revision,
        algorithm_version,
        policy_version
    );
CREATE INDEX recommendation_generation_jobs_claim_idx
    ON recommendation_generation_jobs (available_at, created_at, id)
    WHERE state IN ('queued', 'running');
CREATE INDEX recommendation_generation_jobs_lease_idx
    ON recommendation_generation_jobs (lease_expires_at, id)
    WHERE state = 'running';
CREATE INDEX recommendation_generation_jobs_retention_idx
    ON recommendation_generation_jobs (completed_at, id)
    WHERE state IN ('completed', 'superseded', 'failed');
CREATE INDEX recommendation_generation_jobs_pending_retention_idx
    ON recommendation_generation_jobs (created_at, id)
    WHERE state IN ('queued', 'running');

CREATE TABLE recommendation_generation_candidates (
    job_id uuid NOT NULL REFERENCES recommendation_generation_jobs(id) ON DELETE CASCADE,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 49),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    PRIMARY KEY (job_id, ordinal),
    CONSTRAINT recommendation_generation_candidates_job_paper_unique
        UNIQUE (job_id, paper_id)
);

COMMENT ON TABLE recommendation_generation_jobs IS
    'Content-free account-owned generation intents with bounded leases; queue authority is re-proved before publication.';
COMMENT ON COLUMN recommendation_generation_jobs.intent_fingerprint IS
    'SHA-256 over the exact closed generation intent; no title, query, URL, token, or account identifier.';
COMMENT ON COLUMN recommendation_generation_jobs.saved_search_revision_digest IS
    'Content-free digest of saved-search ids/revisions used only by Following generation.';
COMMENT ON TABLE recommendation_generation_candidates IS
    'Only candidate paper identities from the authoritative reading-feed snapshot, never paper or profile content.';

-- Rollback-safe retention must find old queued or expired leased notification
-- work without scanning live work. Presentation remains feature-gated, but
-- deletion is always on.
CREATE INDEX notification_work_pending_retention_idx
    ON notification_work_items (updated_at, id)
    WHERE state IN ('queued', 'leased');
