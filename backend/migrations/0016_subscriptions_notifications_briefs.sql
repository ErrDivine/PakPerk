-- Plan 02 Phase G keeps briefs and discovery delivery subordinate to the
-- canonical account library. All rows are account-owned and cascade with the
-- user. The notification work queue is deliberately separate from the
-- document-processing `jobs` table: its leases never authorize PDF work.

CREATE TABLE reading_briefs (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    intent_fingerprint bytea NOT NULL CHECK (octet_length(intent_fingerprint) = 32),
    source_mode text NOT NULL CHECK (source_mode IN ('queue', 'discovery')),
    recommendation_mode text CHECK (
        recommendation_mode IS NULL
        OR recommendation_mode IN ('recent', 'following', 'for_you', 'explore')
    ),
    library_revision bigint NOT NULL CHECK (library_revision >= 0),
    recommendation_batch_id uuid REFERENCES recommendation_batches(id) ON DELETE CASCADE,
    local_date date NOT NULL,
    item_count integer NOT NULL CHECK (item_count BETWEEN 1 AND 25),
    position integer NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND item_count),
    progress_revision bigint NOT NULL DEFAULT 1 CHECK (progress_revision > 0),
    status text NOT NULL CHECK (status IN ('current', 'complete', 'superseded')),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT reading_briefs_user_id_unique UNIQUE (user_id, id),
    CONSTRAINT reading_briefs_user_operation_unique UNIQUE (user_id, operation_id),
    CONSTRAINT reading_briefs_authority_check CHECK (
        (
            source_mode = 'queue'
            AND recommendation_mode IS NULL
            AND recommendation_batch_id IS NULL
        )
        OR (
            source_mode = 'discovery'
            AND recommendation_mode IS NOT NULL
            AND recommendation_batch_id IS NOT NULL
        )
    ),
    CONSTRAINT reading_briefs_timestamps_check CHECK (
        updated_at >= created_at
        AND (completed_at IS NULL OR completed_at BETWEEN created_at AND updated_at)
    ),
    CONSTRAINT reading_briefs_completion_check CHECK (
        (status = 'complete' AND position = item_count AND completed_at IS NOT NULL)
        OR (status <> 'complete' AND completed_at IS NULL)
    )
);

CREATE UNIQUE INDEX reading_briefs_current_day_idx
    ON reading_briefs (user_id, local_date)
    WHERE status = 'current';
CREATE INDEX reading_briefs_account_recent_idx
    ON reading_briefs (user_id, status, local_date DESC, created_at DESC, id);

CREATE TABLE reading_brief_items (
    user_id uuid NOT NULL,
    brief_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 24),
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    source text NOT NULL CHECK (
        source IN (
            'to_read',
            'discovery_v1',
            'recent_v1',
            'following_v1',
            'for_you_v1',
            'explore_v1'
        )
    ),
    reason_codes text[] NOT NULL DEFAULT ARRAY[]::text[],
    PRIMARY KEY (brief_id, ordinal),
    CONSTRAINT reading_brief_items_owner_fk
        FOREIGN KEY (user_id, brief_id)
        REFERENCES reading_briefs(user_id, id) ON DELETE CASCADE,
    CONSTRAINT reading_brief_items_paper_unique UNIQUE (brief_id, paper_id),
    CONSTRAINT reading_brief_items_reasons_check CHECK (
        cardinality(reason_codes) <= 16
        AND array_position(reason_codes, NULL) IS NULL
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
    )
);

CREATE INDEX reading_brief_items_account_idx
    ON reading_brief_items (user_id, brief_id, ordinal);

CREATE TABLE reading_brief_progress_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    brief_id uuid NOT NULL,
    payload_fingerprint bytea NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
    accepted_progress_revision bigint NOT NULL CHECK (accepted_progress_revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT reading_brief_progress_owner_fk
        FOREIGN KEY (user_id, brief_id)
        REFERENCES reading_briefs(user_id, id) ON DELETE CASCADE
);

CREATE TABLE subscriptions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('topic', 'category', 'author', 'saved_query')),
    key text NOT NULL,
    label text NOT NULL,
    query_definition jsonb,
    frequency text NOT NULL CHECK (frequency IN ('immediate', 'daily', 'weekly', 'off')),
    last_evaluated_at timestamptz,
    revision bigint NOT NULL CHECK (revision > 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    last_operation_id uuid NOT NULL,
    CONSTRAINT subscriptions_user_id_unique UNIQUE (user_id, id),
    CONSTRAINT subscriptions_key_check CHECK (
        char_length(key) BETWEEN 1 AND 160
        AND key = btrim(key)
        AND position(chr(0) IN key) = 0
    ),
    CONSTRAINT subscriptions_label_check CHECK (
        char_length(label) BETWEEN 1 AND 160
        AND label = btrim(label)
        AND position(chr(0) IN label) = 0
    ),
    CONSTRAINT subscriptions_query_check CHECK (
        (kind = 'saved_query') = (query_definition IS NOT NULL)
        AND (
            query_definition IS NULL
            OR (
                jsonb_typeof(query_definition) = 'object'
                AND pg_column_size(query_definition) <= 4096
            )
        )
    ),
    CONSTRAINT subscriptions_timestamps_check CHECK (
        updated_at >= created_at
        AND (deleted_at IS NULL OR deleted_at = updated_at)
    )
);

CREATE UNIQUE INDEX subscriptions_active_identity_idx
    ON subscriptions (user_id, kind, key)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX subscriptions_user_revision_idx
    ON subscriptions (user_id, revision);
CREATE INDEX subscriptions_due_idx
    ON subscriptions (frequency, last_evaluated_at, id)
    WHERE deleted_at IS NULL AND frequency <> 'off';

CREATE TABLE subscription_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    subscription_id uuid NOT NULL,
    intent text NOT NULL CHECK (intent IN ('create', 'update', 'delete')),
    payload_fingerprint bytea NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
    accepted_revision bigint NOT NULL CHECK (accepted_revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, operation_id),
    CONSTRAINT subscription_operations_user_revision_unique
        UNIQUE (user_id, accepted_revision)
);

CREATE TABLE notification_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    discovery_frequency text NOT NULL DEFAULT 'daily' CHECK (
        discovery_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    -- Canonical Plan 02 per-notification-type preferences. The legacy columns
    -- remain writable so a rolled-back server can still operate against this
    -- additive schema; current writes update both representations.
    discovery_match_frequency text NOT NULL DEFAULT 'off' CHECK (
        discovery_match_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    discovery_digest_frequency text NOT NULL DEFAULT 'daily' CHECK (
        discovery_digest_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    user_selected_reminder_frequency text NOT NULL DEFAULT 'immediate' CHECK (
        user_selected_reminder_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    active_paper_version_frequency text NOT NULL DEFAULT 'off' CHECK (
        active_paper_version_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    sync_failure_frequency text NOT NULL DEFAULT 'immediate' CHECK (
        sync_failure_frequency IN ('immediate', 'daily', 'weekly', 'off')
    ),
    quiet_hours_start time,
    quiet_hours_end time,
    timezone text NOT NULL DEFAULT 'UTC',
    in_app_enabled boolean NOT NULL DEFAULT true,
    push_enabled boolean NOT NULL DEFAULT false CHECK (push_enabled IS FALSE),
    email_enabled boolean NOT NULL DEFAULT false CHECK (email_enabled IS FALSE),
    global_pause boolean NOT NULL DEFAULT false,
    active_updates_enabled boolean NOT NULL DEFAULT false,
    daily_budget integer NOT NULL DEFAULT 5 CHECK (daily_budget BETWEEN 1 AND 20),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    last_operation_id uuid,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CONSTRAINT notification_preferences_timezone_check CHECK (
        char_length(timezone) BETWEEN 1 AND 64
        AND timezone = btrim(timezone)
        AND timezone ~ '^[A-Za-z0-9_+./-]+$'
    ),
    CONSTRAINT notification_preferences_quiet_hours_check CHECK (
        (quiet_hours_start IS NULL) = (quiet_hours_end IS NULL)
    ),
    CONSTRAINT notification_preferences_discovery_exclusive_check CHECK (
        discovery_match_frequency = 'off' OR discovery_digest_frequency = 'off'
    ),
    CONSTRAINT notification_preferences_discovery_projection_check CHECK (
        discovery_frequency = CASE
            WHEN discovery_match_frequency <> 'off' THEN discovery_match_frequency
            ELSE discovery_digest_frequency
        END
    ),
    CONSTRAINT notification_preferences_active_projection_check CHECK (
        active_updates_enabled = (active_paper_version_frequency <> 'off')
    ),
    CONSTRAINT notification_preferences_timestamps_check CHECK (updated_at >= created_at)
);

-- Rollback compatibility is bidirectional. An older server writes only the two
-- legacy columns, while a current server writes the canonical and projected
-- columns together. The trigger recognizes which representation changed and
-- refreshes the other before the consistency constraints run.
CREATE FUNCTION notification_discovery_frequency_projection(
    match_frequency text,
    digest_frequency text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN match_frequency <> 'off' THEN match_frequency
        ELSE digest_frequency
    END
$$;

CREATE FUNCTION synchronize_notification_preference_frequencies()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    legacy_discovery_changed boolean;
    canonical_discovery_changed boolean;
    legacy_active_changed boolean;
    canonical_active_changed boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF notification_discovery_frequency_projection(
            NEW.discovery_match_frequency,
            NEW.discovery_digest_frequency
        ) <> NEW.discovery_frequency THEN
            IF NEW.discovery_match_frequency = 'off'
                AND NEW.discovery_digest_frequency = 'daily' THEN
                IF NEW.discovery_frequency = 'immediate' THEN
                    NEW.discovery_match_frequency := 'immediate';
                    NEW.discovery_digest_frequency := 'off';
                ELSIF NEW.discovery_frequency IN ('daily', 'weekly') THEN
                    NEW.discovery_match_frequency := 'off';
                    NEW.discovery_digest_frequency := NEW.discovery_frequency;
                ELSE
                    NEW.discovery_match_frequency := 'off';
                    NEW.discovery_digest_frequency := 'off';
                END IF;
            ELSE
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    CONSTRAINT = 'notification_preferences_discovery_projection_check',
                    MESSAGE = 'notification preference discovery frequencies disagree';
            END IF;
        END IF;
        IF (NEW.active_paper_version_frequency <> 'off')
            <> NEW.active_updates_enabled THEN
            IF NEW.active_paper_version_frequency = 'off' THEN
                NEW.active_paper_version_frequency := CASE
                    WHEN NEW.active_updates_enabled THEN 'immediate'
                    ELSE 'off'
                END;
            ELSE
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    CONSTRAINT = 'notification_preferences_active_projection_check',
                    MESSAGE = 'notification preference active-paper frequencies disagree';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    legacy_discovery_changed :=
        NEW.discovery_frequency IS DISTINCT FROM OLD.discovery_frequency;
    canonical_discovery_changed :=
        NEW.discovery_match_frequency IS DISTINCT FROM OLD.discovery_match_frequency
        OR NEW.discovery_digest_frequency IS DISTINCT FROM OLD.discovery_digest_frequency;
    IF legacy_discovery_changed AND NOT canonical_discovery_changed THEN
        IF NEW.discovery_frequency = 'immediate' THEN
            NEW.discovery_match_frequency := 'immediate';
            NEW.discovery_digest_frequency := 'off';
        ELSIF NEW.discovery_frequency IN ('daily', 'weekly') THEN
            NEW.discovery_match_frequency := 'off';
            NEW.discovery_digest_frequency := NEW.discovery_frequency;
        ELSE
            NEW.discovery_match_frequency := 'off';
            NEW.discovery_digest_frequency := 'off';
        END IF;
    ELSIF canonical_discovery_changed AND NOT legacy_discovery_changed THEN
        NEW.discovery_frequency := notification_discovery_frequency_projection(
            NEW.discovery_match_frequency,
            NEW.discovery_digest_frequency
        );
    ELSIF notification_discovery_frequency_projection(
        NEW.discovery_match_frequency,
        NEW.discovery_digest_frequency
    ) <> NEW.discovery_frequency THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'notification_preferences_discovery_projection_check',
            MESSAGE = 'notification preference discovery frequencies disagree';
    END IF;

    legacy_active_changed :=
        NEW.active_updates_enabled IS DISTINCT FROM OLD.active_updates_enabled;
    canonical_active_changed :=
        NEW.active_paper_version_frequency IS DISTINCT FROM OLD.active_paper_version_frequency;
    IF legacy_active_changed AND NOT canonical_active_changed THEN
        NEW.active_paper_version_frequency := CASE
            WHEN NEW.active_updates_enabled THEN 'immediate'
            ELSE 'off'
        END;
    ELSIF canonical_active_changed AND NOT legacy_active_changed THEN
        NEW.active_updates_enabled := NEW.active_paper_version_frequency <> 'off';
    ELSIF (NEW.active_paper_version_frequency <> 'off')
        <> NEW.active_updates_enabled THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'notification_preferences_active_projection_check',
            MESSAGE = 'notification preference active-paper frequencies disagree';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER notification_preferences_frequency_projection
BEFORE INSERT OR UPDATE ON notification_preferences
FOR EACH ROW EXECUTE FUNCTION synchronize_notification_preference_frequencies();

CREATE TABLE notification_preference_operations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL CHECK (
        operation_id <> '00000000-0000-0000-0000-000000000000'::uuid
    ),
    payload_fingerprint bytea NOT NULL CHECK (octet_length(payload_fingerprint) = 32),
    accepted_revision bigint NOT NULL CHECK (accepted_revision > 0),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (user_id, operation_id)
);

CREATE TABLE notifications (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    notification_type text NOT NULL CHECK (
        notification_type IN (
            'discovery_match',
            'discovery_digest',
            'user_selected_reminder',
            'active_paper_version',
            'sync_failure'
        )
    ),
    notification_scope text NOT NULL CHECK (notification_scope IN ('queue_owned', 'discovery')),
    entity_type text NOT NULL CHECK (entity_type IN ('paper', 'subscription', 'digest', 'sync')),
    entity_id uuid,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    batch_key text,
    delivery_eligibility text NOT NULL CHECK (
        delivery_eligibility IN (
            'eligible',
            'deferred_queue_nonempty',
            'deferred_unknown',
            'expired'
        )
    ),
    eligibility_library_revision bigint CHECK (eligibility_library_revision >= 0),
    eligible_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    read_at timestamptz,
    dismissed_at timestamptz,
    expires_at timestamptz,
    CONSTRAINT notifications_payload_check CHECK (
        jsonb_typeof(payload) = 'object' AND pg_column_size(payload) <= 4096
    ),
    CONSTRAINT notifications_batch_key_check CHECK (
        batch_key IS NULL OR (
            char_length(batch_key) BETWEEN 1 AND 96
            AND batch_key = btrim(batch_key)
            AND position(chr(0) IN batch_key) = 0
        )
    ),
    CONSTRAINT notifications_authority_check CHECK (
        (
            notification_scope = 'queue_owned'
            AND delivery_eligibility IN ('eligible', 'expired')
            AND eligibility_library_revision IS NULL
            AND notification_type IN (
                'user_selected_reminder',
                'active_paper_version',
                'sync_failure'
            )
        )
        OR (
            notification_scope = 'discovery'
            AND notification_type IN ('discovery_match', 'discovery_digest')
            AND (
                delivery_eligibility <> 'eligible'
                OR eligibility_library_revision IS NOT NULL
            )
        )
    ),
    CONSTRAINT notifications_timestamps_check CHECK (
        (read_at IS NULL OR read_at >= created_at)
        AND (dismissed_at IS NULL OR dismissed_at >= created_at)
        AND (expires_at IS NULL OR expires_at > created_at)
        AND (delivery_eligibility <> 'eligible' OR eligible_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX notifications_dedupe_idx
    ON notifications (
        user_id,
        notification_type,
        entity_type,
        COALESCE(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(batch_key, '')
    );
CREATE INDEX notifications_account_inbox_idx
    ON notifications (user_id, created_at DESC, id DESC)
    WHERE delivery_eligibility = 'eligible' AND dismissed_at IS NULL;
CREATE INDEX notifications_deferred_idx
    ON notifications (user_id, delivery_eligibility, created_at, id)
    WHERE notification_scope = 'discovery';
CREATE INDEX notifications_expiry_idx
    ON notifications (expires_at, id)
    WHERE expires_at IS NOT NULL AND delivery_eligibility <> 'expired';
CREATE INDEX notifications_account_budget_idx
    ON notifications (user_id, eligible_at)
    WHERE eligible_at IS NOT NULL;

CREATE TABLE notification_digest_items (
    notification_id uuid NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
    paper_id uuid NOT NULL REFERENCES papers(id) ON DELETE RESTRICT,
    ordinal integer NOT NULL CHECK (ordinal BETWEEN 0 AND 19),
    PRIMARY KEY (notification_id, ordinal),
    CONSTRAINT notification_digest_items_paper_unique UNIQUE (notification_id, paper_id)
);

CREATE TABLE notification_work_items (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    work_kind text NOT NULL CHECK (
        work_kind IN (
            'evaluate_subscriptions',
            'evaluate_reminders',
            'evaluate_active_papers',
            'build_notification_digest',
            'expire_notifications',
            'recheck_notification_queue_eligibility'
        )
    ),
    subscription_id uuid REFERENCES subscriptions(id) ON DELETE CASCADE,
    window_key text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    state text NOT NULL DEFAULT 'queued' CHECK (
        state IN ('queued', 'leased', 'complete', 'failed')
    ),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 20),
    max_attempts integer NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 20),
    available_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    completed_at timestamptz,
    CONSTRAINT notification_work_window_key_check CHECK (
        char_length(window_key) BETWEEN 1 AND 96
        AND window_key = btrim(window_key)
        AND position(chr(0) IN window_key) = 0
    ),
    CONSTRAINT notification_work_payload_check CHECK (
        jsonb_typeof(payload) = 'object' AND pg_column_size(payload) <= 2048
    ),
    CONSTRAINT notification_work_lease_check CHECK (
        (state = 'leased') = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    ),
    CONSTRAINT notification_work_owner_check CHECK (
        lease_owner IS NULL OR (
            char_length(lease_owner) BETWEEN 1 AND 128
            AND lease_owner = btrim(lease_owner)
            AND position(chr(0) IN lease_owner) = 0
        )
    ),
    CONSTRAINT notification_work_error_check CHECK (
        last_error_code IS NULL OR last_error_code ~ '^[A-Z0-9_]{1,64}$'
    ),
    CONSTRAINT notification_work_timestamps_check CHECK (
        updated_at >= created_at
        AND (completed_at IS NULL OR completed_at >= created_at)
    )
);

CREATE UNIQUE INDEX notification_work_logical_idx
    ON notification_work_items (
        user_id,
        work_kind,
        COALESCE(subscription_id, '00000000-0000-0000-0000-000000000000'::uuid),
        window_key
    );
CREATE INDEX notification_work_claim_idx
    ON notification_work_items (available_at, created_at, id)
    WHERE state = 'queued';

COMMENT ON TABLE notification_work_items IS
    'Account-owned, content-free notification work; never authorizes paper preparation.';
COMMENT ON COLUMN notifications.payload IS
    'Bounded content-free identifiers and reason codes only; no titles, queries, notes, or account identity.';
COMMENT ON COLUMN subscriptions.query_definition IS
    'Explicit account-owned saved-query definition; never emitted to telemetry.';
