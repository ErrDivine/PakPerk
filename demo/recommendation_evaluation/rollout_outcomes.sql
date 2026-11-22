-- Run with psql -v window_start=... -v window_end=... -f rollout_outcomes.sql.
-- Use UTC bounds and finish the window at least 30 minutes before collection.
BEGIN READ ONLY;

WITH bounds AS (
    SELECT :'window_start'::timestamptz AS starts_at, :'window_end'::timestamptz AS ends_at
),
served_batches AS MATERIALIZED (
    SELECT batch.id, batch.user_id, batch.policy_version, batch.library_revision,
           batch.created_at, COALESCE(exposure.first_served_at, batch.created_at) AS first_served_at
    FROM recommendation_batches AS batch
    CROSS JOIN bounds
    CROSS JOIN LATERAL (
        SELECT min(served_at) AS first_served_at
        FROM recommendation_candidates
        WHERE batch_id = batch.id
    ) AS exposure
    WHERE batch.mode = 'for_you'
      AND batch.queue_proven_empty IS TRUE
      AND batch.user_id IS NOT NULL
      AND batch.algorithm_version = 'recommendations_v1'
      AND batch.policy_version IN ('weighted_v1', 'citation_online_v1')
      AND batch.created_at >= bounds.starts_at - interval '25 hours'
      AND batch.created_at < bounds.ends_at
      AND (exposure.first_served_at IS NOT NULL OR batch.status = 'served')
),
previous_page AS (
    SELECT *,
           lag(first_served_at) OVER account_pages AS previous_at,
           lag(policy_version) OVER account_pages AS previous_policy,
           lag(library_revision) OVER account_pages AS previous_library_revision
    FROM served_batches
    WINDOW account_pages AS (PARTITION BY user_id ORDER BY first_served_at, id)
),
session_numbers AS (
    SELECT *,
           count(*) FILTER (
               WHERE previous_at IS NULL
                  OR first_served_at - previous_at > interval '30 minutes'
                  OR previous_policy <> policy_version
                  OR previous_library_revision <> library_revision
           ) OVER (PARTITION BY user_id ORDER BY first_served_at, id) AS session_number
    FROM previous_page
),
sessions AS (
    SELECT page.user_id, page.policy_version, page.session_number
    FROM session_numbers AS page
    CROSS JOIN bounds
    GROUP BY page.user_id, page.policy_version, page.session_number, bounds.starts_at, bounds.ends_at
    HAVING min(page.first_served_at) >= bounds.starts_at
       AND min(page.first_served_at) < bounds.ends_at
),
cards AS MATERIALIZED (
    SELECT page.user_id, page.policy_version, page.session_number, page.id AS batch_id,
           card.paper_id, card.served_at, paper.arxiv_base_id
    FROM sessions
    JOIN session_numbers AS page USING (user_id, policy_version, session_number)
    JOIN recommendation_candidates AS card ON card.batch_id = page.id
    JOIN papers AS paper ON paper.id = card.paper_id
    CROSS JOIN bounds
    WHERE card.served_at < bounds.ends_at
),
attributed_saves AS (
    SELECT DISTINCT card.user_id, card.policy_version, card.session_number, card.arxiv_base_id
    FROM cards AS card
    JOIN paper_interactions AS event
      ON event.batch_id = card.batch_id AND event.paper_id = card.paper_id
     AND event.user_id = card.user_id AND event.feed_mode = 'for_you' AND event.event_type = 'saved'
     AND event.occurred_at BETWEEN card.served_at AND card.served_at + interval '30 minutes'
    WHERE EXISTS (
        SELECT 1
        FROM library_operations AS operation
        WHERE operation.user_id = card.user_id AND operation.paper_id = card.paper_id
          AND operation.operation_id = event.id
          AND operation.intent = 'save' AND operation.accepted_removed_at IS NULL
          AND operation.accepted_save_source_kind = 'discovery'
          AND operation.accepted_saved_at = operation.accepted_updated_at
          AND operation.created_at BETWEEN card.served_at AND card.served_at + interval '30 minutes'
    )
),
dismissed_cards AS (
    SELECT card.policy_version, card.batch_id, card.paper_id
    FROM cards AS card
    WHERE EXISTS (
        SELECT 1
        FROM recommendation_feedback AS feedback
        WHERE feedback.batch_id = card.batch_id AND feedback.paper_id = card.paper_id
          AND feedback.user_id = card.user_id AND feedback.feedback_type = 'dismissed'
          AND feedback.created_at BETWEEN card.served_at AND card.served_at + interval '30 minutes'
    )
),
cohorts(policy_version) AS (VALUES ('weighted_v1'), ('citation_online_v1')),
counts AS (
    SELECT cohort.policy_version,
           (SELECT count(*) FROM sessions WHERE policy_version = cohort.policy_version) AS sessions,
           (SELECT count(*) FROM attributed_saves WHERE policy_version = cohort.policy_version) AS saves,
           (SELECT count(*) FROM cards WHERE policy_version = cohort.policy_version) AS served_cards,
           (SELECT count(*) FROM dismissed_cards WHERE policy_version = cohort.policy_version) AS dismissals
    FROM cohorts AS cohort
)
SELECT *,
       saves::numeric / NULLIF(sessions, 0) AS saves_per_session,
       dismissals::numeric / NULLIF(served_cards, 0) AS dismissals_per_served_card
FROM counts
ORDER BY policy_version;

COMMIT;
