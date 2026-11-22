ALTER TABLE recommendation_feedback
    ADD COLUMN feature_mask smallint CHECK (feature_mask BETWEEN 0 AND 7);

ALTER TABLE recommendation_candidates
    ADD COLUMN citation_evidence jsonb
        CHECK (jsonb_typeof(citation_evidence) = 'object' AND pg_column_size(citation_evidence) <= 4096);

COMMENT ON COLUMN recommendation_feedback.feature_mask IS
    'NULL means consent was absent, erased, or unknown. Non-NULL records consent and the served feature bits credited to the feedback.';
COMMENT ON COLUMN recommendation_candidates.citation_evidence IS
    'Immutable citation tier, feature mask, adjustment and bounded public root evidence for citation_online_v1.';
