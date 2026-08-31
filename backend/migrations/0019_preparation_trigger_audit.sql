-- Plan 03 demand-driven preparation provenance.
--
-- The default keeps a rolling deploy safe when an older pod inserts a job
-- without the new column. All new code supplies an explicit approved value;
-- the legacy value exists only to identify rows written through that narrow
-- compatibility window.
ALTER TABLE jobs
    ADD COLUMN preparation_trigger_kind text NOT NULL
        DEFAULT 'legacy_introduction_transition',
    ADD CONSTRAINT jobs_preparation_trigger_kind_valid CHECK (
        preparation_trigger_kind IN (
            'introduction_transition',
            'inspect_evidence',
            'explicit_prepare',
            'approved_reprocessing',
            'legacy_introduction_transition'
        )
    );

CREATE INDEX jobs_preparation_trigger_audit_idx
    ON jobs (preparation_trigger_kind, created_at DESC, id DESC);

COMMENT ON COLUMN jobs.preparation_trigger_kind IS
    'Approved demand-driven origin inherited by all jobs in a paper generation; metadata-only surfaces are intentionally excluded.';
