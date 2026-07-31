-- Phase 5 public comments deliberately remain in the existing application
-- database. This migration is additive so binaries can roll forward before
-- the feature flags are enabled.

ALTER TABLE users
    ADD COLUMN community_guidelines_version text,
    ADD COLUMN community_guidelines_accepted_at timestamptz;

ALTER TABLE users
    ADD CONSTRAINT users_community_guidelines_paired CHECK (
        (community_guidelines_version IS NULL AND community_guidelines_accepted_at IS NULL)
        OR (
            community_guidelines_version IS NOT NULL
            AND community_guidelines_accepted_at IS NOT NULL
            AND community_guidelines_version = btrim(community_guidelines_version)
            AND char_length(community_guidelines_version) BETWEEN 1 AND 64
        )
    ),
    ADD CONSTRAINT users_community_guidelines_timestamp CHECK (
        community_guidelines_accepted_at IS NULL
        OR community_guidelines_accepted_at >= created_at
    );

CREATE TABLE paper_comments (
    id uuid PRIMARY KEY,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
    author_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_request_id uuid NOT NULL,
    body text NOT NULL,
    create_body_sha256 bytea NOT NULL,
    status text NOT NULL CHECK (
        status IN ('pending_review', 'published', 'hidden', 'deleted')
    ),
    moderation_reason text,
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    edited_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT paper_comments_create_request_unique UNIQUE (
        author_user_id,
        client_request_id
    ),
    CONSTRAINT paper_comments_client_request_non_nil CHECK (
        client_request_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    CONSTRAINT paper_comments_body_valid CHECK (
        body = btrim(body, E' \t\n\r')
        AND char_length(body) BETWEEN 1 AND 2000
        AND octet_length(body) <= 8000
        AND translate(body, E'\n', '') !~ '[[:cntrl:]]'
    ),
    CONSTRAINT paper_comments_create_hash_valid CHECK (
        octet_length(create_body_sha256) = 32
    ),
    CONSTRAINT paper_comments_moderation_reason_valid CHECK (
        moderation_reason IS NULL
        OR (
            moderation_reason = btrim(moderation_reason)
            AND char_length(moderation_reason) BETWEEN 1 AND 64
            AND moderation_reason ~ '^[a-z0-9_:-]+$'
        )
    ),
    CONSTRAINT paper_comments_timestamps_ordered CHECK (
        updated_at >= created_at
        AND (edited_at IS NULL OR edited_at >= created_at)
        AND (deleted_at IS NULL OR deleted_at >= created_at)
    ),
    CONSTRAINT paper_comments_deleted_state_paired CHECK (
        (status = 'deleted' AND deleted_at IS NOT NULL)
        OR (status <> 'deleted' AND deleted_at IS NULL)
    )
);

CREATE INDEX paper_comments_public_page_idx
    ON paper_comments (paper_id, created_at DESC, id DESC)
    WHERE status = 'published';

CREATE INDEX paper_comments_author_page_idx
    ON paper_comments (author_user_id, created_at DESC, id DESC);

CREATE INDEX paper_comments_moderation_queue_idx
    ON paper_comments (created_at, id)
    WHERE status = 'pending_review';

CREATE TABLE comment_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    comment_id uuid NOT NULL REFERENCES paper_comments(id) ON DELETE CASCADE,
    reporter_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason text NOT NULL CHECK (
        reason IN (
            'spam',
            'harassment',
            'hate',
            'threat',
            'sexual_content',
            'privacy',
            'impersonation',
            'copyright',
            'other'
        )
    ),
    detail text,
    status text NOT NULL DEFAULT 'open' CHECK (
        status IN ('open', 'reviewed', 'actioned', 'dismissed')
    ),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    reviewed_at timestamptz,
    reviewed_by uuid REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT comment_reports_reporter_unique UNIQUE (comment_id, reporter_user_id),
    CONSTRAINT comment_reports_detail_valid CHECK (
        detail IS NULL
        OR (
            detail = btrim(detail)
            AND char_length(detail) BETWEEN 1 AND 500
            AND octet_length(detail) <= 2000
            AND detail !~ '[[:cntrl:]]'
        )
    ),
    CONSTRAINT comment_reports_review_paired CHECK (
        (status = 'open' AND reviewed_at IS NULL AND reviewed_by IS NULL)
        OR (status <> 'open' AND reviewed_at IS NOT NULL)
    )
);

CREATE INDEX comment_reports_status_age_idx
    ON comment_reports (status, created_at, id);

CREATE TABLE user_blocks (
    blocker_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (blocker_user_id, blocked_user_id),
    CONSTRAINT user_blocks_not_self CHECK (blocker_user_id <> blocked_user_id)
);

CREATE INDEX user_blocks_blocked_user_idx
    ON user_blocks (blocked_user_id, blocker_user_id);

CREATE TABLE comment_moderation_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Audit targets intentionally have no foreign keys. Phase 6 deletion may
    -- erase the source row while retaining this narrowly scoped identifier.
    comment_id uuid,
    target_user_id uuid,
    actor_kind text NOT NULL CHECK (actor_kind IN ('system', 'admin')),
    actor_user_id uuid,
    actor_label text,
    action text NOT NULL CHECK (
        action = btrim(action)
        AND char_length(action) BETWEEN 1 AND 64
        AND action ~ '^[a-z0-9_:-]+$'
    ),
    reason_code text CHECK (
        reason_code IS NULL
        OR (
            reason_code = btrim(reason_code)
            AND char_length(reason_code) BETWEEN 1 AND 64
            AND reason_code ~ '^[a-z0-9_:-]+$'
        )
    ),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT comment_moderation_events_actor_valid CHECK (
        (
            actor_kind = 'system'
            AND actor_user_id IS NULL
            AND actor_label IS NULL
        )
        OR (
            actor_kind = 'admin'
            AND (actor_user_id IS NULL) <> (actor_label IS NULL)
        )
    ),
    CONSTRAINT comment_moderation_events_actor_label_valid CHECK (
        actor_label IS NULL
        OR (
            actor_label = btrim(actor_label)
            AND char_length(actor_label) BETWEEN 1 AND 128
            AND actor_label ~ '^[A-Za-z0-9@._:-]+$'
        )
    ),
    CONSTRAINT comment_moderation_events_target_valid CHECK (
        (comment_id IS NULL) <> (target_user_id IS NULL)
    )
);

CREATE INDEX comment_moderation_events_comment_idx
    ON comment_moderation_events (comment_id, created_at DESC, id DESC);
