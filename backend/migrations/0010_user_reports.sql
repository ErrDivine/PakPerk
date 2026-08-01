-- User reports are a distinct safety signal from comment reports and blocks.
-- Submitting one never changes visibility or creates a user_blocks row; an
-- attributable moderator must review it through the dedicated queue.

CREATE TABLE user_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reported_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
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
    CONSTRAINT user_reports_reporter_unique UNIQUE (
        reported_user_id,
        reporter_user_id
    ),
    CONSTRAINT user_reports_not_self CHECK (
        reported_user_id <> reporter_user_id
    ),
    CONSTRAINT user_reports_detail_valid CHECK (
        detail IS NULL
        OR (
            detail = btrim(detail)
            AND char_length(detail) BETWEEN 1 AND 500
            AND octet_length(detail) <= 2000
            AND detail !~ '[[:cntrl:]]'
        )
    ),
    CONSTRAINT user_reports_review_paired CHECK (
        (status = 'open' AND reviewed_at IS NULL AND reviewed_by IS NULL)
        OR (status <> 'open' AND reviewed_at IS NOT NULL)
    )
);

CREATE INDEX user_reports_status_age_idx
    ON user_reports (status, created_at, id);

CREATE INDEX user_reports_reported_user_idx
    ON user_reports (reported_user_id, created_at, id);

-- PostgreSQL does not automatically index referencing foreign-key columns.
-- These indexes keep reporter/reviewer account deletion from degrading into
-- full queue scans (and extended locks) as safety history grows.
CREATE INDEX user_reports_reporter_user_idx
    ON user_reports (reporter_user_id, created_at, id);

CREATE INDEX user_reports_reviewed_by_idx
    ON user_reports (reviewed_by)
    WHERE reviewed_by IS NOT NULL;
