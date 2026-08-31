-- Close the Plan 02 interaction evidence allowlist and add the indexes needed
-- by bounded engagement retention. Earlier migrations remain immutable.

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

CREATE INDEX reading_briefs_retention_idx
    ON reading_briefs (created_at, id);

CREATE INDEX notifications_retention_idx
    ON notifications (created_at, id);

CREATE INDEX notification_work_terminal_retention_idx
    ON notification_work_items (updated_at, id)
    WHERE state IN ('complete', 'failed');

CREATE INDEX reading_brief_progress_operations_retention_idx
    ON reading_brief_progress_operations (created_at, user_id, operation_id);

CREATE INDEX subscription_operations_retention_idx
    ON subscription_operations (created_at, user_id, operation_id);

CREATE INDEX notification_preference_operations_retention_idx
    ON notification_preference_operations (created_at, user_id, operation_id);
