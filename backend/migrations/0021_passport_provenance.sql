-- Plan 03 Phase C/D shared enrichment artifacts. All artifacts are scoped to
-- one immutable document generation. Shared provenance is deliberately
-- principal-free; private assistant provenance is bound to exactly one
-- account or anonymous session and is never addressable by UUID alone.

ALTER TABLE paper_processing
    ADD COLUMN visual_objects_ready boolean NOT NULL DEFAULT false,
    ADD COLUMN terms_ready boolean NOT NULL DEFAULT false,
    ADD COLUMN semantic_facets_ready boolean NOT NULL DEFAULT false,
    ADD COLUMN paper_passport_ready boolean NOT NULL DEFAULT false;

ALTER TABLE jobs
    ADD COLUMN identity_key text NOT NULL DEFAULT 'legacy-v1' CHECK (
        char_length(identity_key) BETWEEN 1 AND 192
        AND identity_key = btrim(identity_key)
        AND identity_key ~ '^[a-z0-9][a-z0-9._:/-]*$'
    ),
    ADD CONSTRAINT jobs_plan03_job_type_valid CHECK (job_type IN (
        'prepare_core_document',
        'enrich_visual_objects',
        'extract_terms',
        'build_paper_passport',
        'build_faceted_spans',
        'reanchor_annotations',
        'compare_paper_versions',
        'regenerate_accessibility_descriptions',
        -- Rolling-deploy compatibility aliases.
        'prepare_document',
        'index_chat',
        'resolve_connections'
    ));

ALTER TABLE jobs
    DROP CONSTRAINT jobs_paper_id_generation_job_type_key;
ALTER TABLE jobs
    ADD CONSTRAINT jobs_generation_artifact_identity_unique
    UNIQUE (paper_id, generation, job_type, identity_key);

DROP INDEX jobs_paper_idx;
CREATE INDEX jobs_paper_idx
    ON jobs (paper_id, generation, job_type, identity_key);

CREATE TABLE paper_enrichment_state (
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    capability text NOT NULL CHECK (capability IN (
        'visual_objects',
        'terms',
        'semantic_facets',
        'paper_passport',
        'accessibility_descriptions'
    )),
    artifact_version text NOT NULL CHECK (
        char_length(artifact_version) BETWEEN 1 AND 64
        AND artifact_version = btrim(artifact_version)
        AND artifact_version ~ '^[a-z0-9][a-z0-9._-]*$'
    ),
    status text NOT NULL DEFAULT 'not_requested' CHECK (status IN (
        'not_requested', 'queued', 'running', 'ready', 'failed'
    )),
    last_error_category text CHECK (
        last_error_category IS NULL OR last_error_category IN (
            'external_temporary',
            'external_permanent',
            'parser_temporary',
            'parser_document',
            'model_temporary',
            'validation',
            'internal'
        )
    ),
    last_error_code text CHECK (
        last_error_code IS NULL OR char_length(last_error_code) BETWEEN 1 AND 128
    ),
    last_error_message text CHECK (
        last_error_message IS NULL OR char_length(last_error_message) BETWEEN 1 AND 1000
    ),
    started_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (paper_id, generation, capability, artifact_version),
    CONSTRAINT paper_enrichment_state_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CHECK (
        (status = 'failed' AND last_error_category IS NOT NULL
            AND last_error_code IS NOT NULL AND last_error_message IS NOT NULL)
        OR (status <> 'failed' AND last_error_category IS NULL
            AND last_error_code IS NULL AND last_error_message IS NULL)
    ),
    CHECK (completed_at IS NULL OR status IN ('ready', 'failed'))
);

CREATE INDEX paper_enrichment_state_current_idx
    ON paper_enrichment_state (paper_id, generation, capability, status);

CREATE TABLE provenance_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_type text NOT NULL CHECK (artifact_type IN (
        'document',
        'visual_objects',
        'terms',
        'semantic_spans',
        'paper_passport',
        'paper_passport_field',
        'assistant_answer',
        'version_diff',
        'accessibility_description'
    )),
    artifact_id uuid NOT NULL,
    paper_id uuid,
    generation integer CHECK (generation IS NULL OR generation > 0),
    activity_type text NOT NULL CHECK (activity_type IN (
        'parser_normalization',
        'visual_extraction',
        'term_extraction',
        'semantic_classification',
        'passport_synthesis',
        'assistant_generation',
        'version_comparison',
        'accessibility_generation'
    )),
    parser_id text CHECK (
        parser_id IS NULL OR (
            char_length(parser_id) BETWEEN 1 AND 64 AND parser_id = btrim(parser_id)
        )
    ),
    parser_version text CHECK (
        parser_version IS NULL OR (
            char_length(parser_version) BETWEEN 1 AND 128
            AND parser_version = btrim(parser_version)
        )
    ),
    model_provider text CHECK (
        model_provider IS NULL OR (
            char_length(model_provider) BETWEEN 1 AND 64
            AND model_provider = btrim(model_provider)
        )
    ),
    model_id text CHECK (
        model_id IS NULL OR (
            char_length(model_id) BETWEEN 1 AND 128 AND model_id = btrim(model_id)
        )
    ),
    prompt_or_schema_version text CHECK (
        prompt_or_schema_version IS NULL OR (
            char_length(prompt_or_schema_version) BETWEEN 1 AND 128
            AND prompt_or_schema_version = btrim(prompt_or_schema_version)
        )
    ),
    input_entity_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(input_entity_ids) <= 128
        AND array_position(input_entity_ids, NULL) IS NULL
    ),
    parameters jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(parameters) = 'object'
        AND octet_length(parameters::text) <= 16384
        -- Strings and nested values could accidentally retain prompt text or
        -- secrets. Shared typed code only emits booleans and numbers.
        AND NOT jsonb_path_exists(
            parameters,
            '$.* ? (@.type() == "string" || @.type() == "object" || @.type() == "array")'
        )
    ),
    owner_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_by uuid REFERENCES provenance_records(id) ON DELETE SET NULL,
    CONSTRAINT provenance_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CHECK ((paper_id IS NULL) = (generation IS NULL)),
    CHECK (superseded_by IS NULL OR superseded_by <> id),
    CHECK (
        (
            artifact_type = 'assistant_answer'
            AND activity_type = 'assistant_generation'
            AND ((owner_user_id IS NULL) <> (anonymous_session_id IS NULL))
        )
        OR (
            artifact_type <> 'assistant_answer'
            AND activity_type <> 'assistant_generation'
            AND owner_user_id IS NULL
            AND anonymous_session_id IS NULL
        )
    )
);

CREATE INDEX provenance_records_shared_artifact_idx
    ON provenance_records (paper_id, generation, artifact_type, artifact_id, created_at DESC)
    WHERE owner_user_id IS NULL AND anonymous_session_id IS NULL;
CREATE INDEX provenance_records_owner_idx
    ON provenance_records (owner_user_id, created_at DESC, id DESC)
    WHERE owner_user_id IS NOT NULL;
CREATE INDEX provenance_records_session_idx
    ON provenance_records (anonymous_session_id, created_at DESC, id DESC)
    WHERE anonymous_session_id IS NOT NULL;

CREATE TABLE paper_passports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    schema_version text NOT NULL CHECK (
        char_length(schema_version) BETWEEN 1 AND 64
        AND schema_version = btrim(schema_version)
    ),
    status text NOT NULL CHECK (status IN ('draft', 'ready', 'partial', 'failed')),
    parser_id text NOT NULL CHECK (
        char_length(parser_id) BETWEEN 1 AND 64 AND parser_id = btrim(parser_id)
    ),
    model_id text CHECK (
        model_id IS NULL OR (
            char_length(model_id) BETWEEN 1 AND 128 AND model_id = btrim(model_id)
        )
    ),
    prompt_version text CHECK (
        prompt_version IS NULL OR (
            char_length(prompt_version) BETWEEN 1 AND 128
            AND prompt_version = btrim(prompt_version)
        )
    ),
    provenance_id uuid NOT NULL REFERENCES provenance_records(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    superseded_at timestamptz,
    CONSTRAINT paper_passports_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, schema_version),
    UNIQUE (id, paper_id, generation),
    CHECK (updated_at >= created_at),
    CHECK (superseded_at IS NULL OR superseded_at >= created_at)
);

CREATE INDEX paper_passports_current_idx
    ON paper_passports (paper_id, generation, updated_at DESC, id DESC)
    WHERE superseded_at IS NULL;

CREATE TABLE paper_passport_fields (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    passport_id uuid NOT NULL,
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    field_key text NOT NULL CHECK (field_key IN (
        'research_question',
        'contribution',
        'method',
        'data_or_sample',
        'evaluation',
        'main_result',
        'limitations',
        'assumptions_scope',
        'code_resources',
        'publication_status'
    )),
    value_text text CHECK (
        value_text IS NULL OR (
            char_length(value_text) BETWEEN 1 AND 10000
            AND btrim(value_text) <> '' AND position(chr(0) IN value_text) = 0
        )
    ),
    value_json jsonb CHECK (
        value_json IS NULL OR (
            jsonb_typeof(value_json) IN ('object', 'array')
            AND octet_length(value_json::text) <= 32768
        )
    ),
    status text NOT NULL CHECK (status IN (
        'supported', 'inferred', 'conflicting', 'not_found', 'not_applicable'
    )),
    source_block_ids uuid[] NOT NULL DEFAULT '{}'::uuid[] CHECK (
        cardinality(source_block_ids) <= 64
        AND array_position(source_block_ids, NULL) IS NULL
    ),
    confidence_status text NOT NULL CHECK (
        confidence_status IN ('supported', 'inferred', 'uncertain')
    ),
    provenance_id uuid NOT NULL REFERENCES provenance_records(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT paper_passport_fields_passport_scope_fk
        FOREIGN KEY (passport_id, paper_id, generation)
        REFERENCES paper_passports(id, paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (passport_id, field_key),
    UNIQUE (id, passport_id),
    CHECK (
        (
            status IN ('supported', 'inferred', 'conflicting')
            AND cardinality(source_block_ids) > 0
            AND ((value_text IS NULL) <> (value_json IS NULL))
        )
        OR (
            status IN ('not_found', 'not_applicable')
            AND cardinality(source_block_ids) = 0
            AND value_text IS NULL
            AND value_json IS NULL
        )
    )
);

CREATE INDEX paper_passport_fields_sources_idx
    ON paper_passport_fields USING gin (source_block_ids);

CREATE TABLE paper_passport_feedback_evaluations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_id uuid NOT NULL,
    passport_id uuid NOT NULL,
    field_id uuid,
    owner_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    feedback_type text NOT NULL CHECK (feedback_type IN (
        'wrong_field',
        'misleading_compression',
        'wrong_evidence',
        'missing_limitation',
        'parser_issue'
    )),
    detail text CHECK (
        detail IS NULL OR (
            char_length(detail) BETWEEN 1 AND 2000
            AND btrim(detail) <> '' AND position(chr(0) IN detail) = 0
        )
    ),
    evaluation_status text NOT NULL DEFAULT 'received' CHECK (
        evaluation_status IN ('received', 'reviewed', 'rejected')
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz,
    CONSTRAINT passport_feedback_passport_fk
        FOREIGN KEY (passport_id) REFERENCES paper_passports(id) ON DELETE CASCADE,
    CONSTRAINT passport_feedback_field_fk
        FOREIGN KEY (field_id, passport_id)
        REFERENCES paper_passport_fields(id, passport_id)
        ON DELETE CASCADE,
    CHECK ((owner_user_id IS NULL) <> (anonymous_session_id IS NULL)),
    CHECK (reviewed_at IS NULL OR evaluation_status IN ('reviewed', 'rejected'))
);

CREATE UNIQUE INDEX passport_feedback_owner_operation_idx
    ON paper_passport_feedback_evaluations (owner_user_id, operation_id)
    WHERE owner_user_id IS NOT NULL;
CREATE UNIQUE INDEX passport_feedback_session_operation_idx
    ON paper_passport_feedback_evaluations (anonymous_session_id, operation_id)
    WHERE anonymous_session_id IS NOT NULL;

CREATE TABLE semantic_spans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    block_id uuid NOT NULL,
    span_ordinal integer NOT NULL CHECK (span_ordinal >= 0),
    start_offset integer NOT NULL CHECK (start_offset >= 0),
    end_offset integer NOT NULL CHECK (end_offset > start_offset),
    facet text NOT NULL CHECK (facet IN (
        'objective', 'method', 'result', 'limitation', 'claim', 'evidence',
        'future_work', 'definition'
    )),
    minimum_density text NOT NULL CHECK (minimum_density IN ('key', 'detailed')),
    source_kind text NOT NULL CHECK (source_kind IN ('deterministic', 'model')),
    confidence_basis_points integer NOT NULL CHECK (
        confidence_basis_points BETWEEN 0 AND 10000
    ),
    support_status text NOT NULL CHECK (support_status IN ('supported', 'inferred')),
    provenance_id uuid NOT NULL REFERENCES provenance_records(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_at timestamptz,
    CONSTRAINT semantic_spans_block_scope_fk
        FOREIGN KEY (block_id, paper_id, generation)
        REFERENCES document_blocks(id, paper_id, generation)
        ON DELETE CASCADE,
    UNIQUE (paper_id, generation, block_id, span_ordinal, provenance_id),
    CHECK (superseded_at IS NULL OR superseded_at >= created_at)
);

CREATE UNIQUE INDEX semantic_spans_current_block_idx
    ON semantic_spans (paper_id, generation, block_id, minimum_density, span_ordinal)
    WHERE superseded_at IS NULL;

CREATE TABLE assistant_threads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
    CONSTRAINT assistant_threads_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CHECK ((owner_user_id IS NULL) <> (anonymous_session_id IS NULL)),
    CHECK (updated_at >= created_at),
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '90 days')
);

CREATE INDEX assistant_threads_owner_idx
    ON assistant_threads (owner_user_id, paper_id, updated_at DESC, id DESC)
    WHERE owner_user_id IS NOT NULL;
CREATE INDEX assistant_threads_session_idx
    ON assistant_threads (anonymous_session_id, paper_id, updated_at DESC, id DESC)
    WHERE anonymous_session_id IS NOT NULL;
CREATE INDEX assistant_threads_expiry_idx
    ON assistant_threads (expires_at, id);

CREATE TABLE assistant_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL REFERENCES assistant_threads(id) ON DELETE CASCADE,
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    role text NOT NULL CHECK (role IN ('user', 'assistant')),
    content text NOT NULL CHECK (
        char_length(content) BETWEEN 1 AND 32000
        AND btrim(content) <> '' AND position(chr(0) IN content) = 0
    ),
    provenance_id uuid REFERENCES provenance_records(id) ON DELETE CASCADE,
    evidence_map jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
        jsonb_typeof(evidence_map) = 'array'
        AND jsonb_array_length(evidence_map) <= 16
        AND pg_column_size(evidence_map) <= 65536
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (thread_id, ordinal),
    UNIQUE (id, thread_id, provenance_id),
    CHECK (
        (role = 'user' AND provenance_id IS NULL AND evidence_map = '[]'::jsonb)
        OR (role = 'assistant' AND provenance_id IS NOT NULL)
    )
);

CREATE INDEX assistant_messages_thread_idx
    ON assistant_messages (thread_id, ordinal DESC);

CREATE FUNCTION trim_assistant_thread_messages() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM assistant_messages
    WHERE thread_id = NEW.thread_id
      AND id NOT IN (
          SELECT id
          FROM assistant_messages
          WHERE thread_id = NEW.thread_id
          ORDER BY ordinal DESC
          LIMIT 50
      );
    RETURN NEW;
END;
$$;

CREATE TRIGGER assistant_messages_bounded_retention
AFTER INSERT ON assistant_messages
FOR EACH ROW EXECUTE FUNCTION trim_assistant_thread_messages();

CREATE TABLE assistant_evidence_feedback_evaluations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_id uuid NOT NULL,
    thread_id uuid NOT NULL REFERENCES assistant_threads(id) ON DELETE CASCADE,
    response_id uuid NOT NULL,
    provenance_id uuid NOT NULL,
    paper_id uuid NOT NULL,
    generation integer NOT NULL CHECK (generation > 0),
    owner_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    anonymous_session_id uuid,
    feedback_type text NOT NULL CHECK (feedback_type IN (
        'incorrect_citation',
        'evidence_does_not_support_claim',
        'missing_evidence',
        'incorrect_support_label',
        'incorrect_source_location'
    )),
    claim_index smallint CHECK (claim_index BETWEEN 0 AND 15),
    evidence_block_id uuid,
    detail text CHECK (
        detail IS NULL OR (
            char_length(detail) BETWEEN 1 AND 1000
            AND detail = btrim(detail)
            AND position(chr(0) IN detail) = 0
        )
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT assistant_feedback_response_fk
        FOREIGN KEY (response_id, thread_id, provenance_id)
        REFERENCES assistant_messages(id, thread_id, provenance_id)
        ON DELETE CASCADE,
    CONSTRAINT assistant_feedback_generation_fk
        FOREIGN KEY (paper_id, generation)
        REFERENCES document_generations(paper_id, generation)
        ON DELETE CASCADE,
    CHECK ((owner_user_id IS NULL) <> (anonymous_session_id IS NULL)),
    CHECK (
        (feedback_type = 'missing_evidence'
            AND claim_index IS NULL AND evidence_block_id IS NULL)
        OR (feedback_type = 'incorrect_support_label'
            AND claim_index IS NOT NULL AND evidence_block_id IS NULL)
        OR (feedback_type IN (
                'incorrect_citation',
                'evidence_does_not_support_claim',
                'incorrect_source_location'
            ) AND claim_index IS NOT NULL AND evidence_block_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX assistant_feedback_owner_operation_idx
    ON assistant_evidence_feedback_evaluations (owner_user_id, operation_id)
    WHERE owner_user_id IS NOT NULL;
CREATE UNIQUE INDEX assistant_feedback_session_operation_idx
    ON assistant_evidence_feedback_evaluations (anonymous_session_id, operation_id)
    WHERE anonymous_session_id IS NOT NULL;
CREATE INDEX assistant_feedback_owner_export_idx
    ON assistant_evidence_feedback_evaluations (owner_user_id, paper_id, created_at, id)
    WHERE owner_user_id IS NOT NULL;
CREATE INDEX assistant_feedback_response_idx
    ON assistant_evidence_feedback_evaluations (response_id, created_at, id);

ALTER TABLE paper_figures ADD COLUMN superseded_at timestamptz;
ALTER TABLE paper_tables ADD COLUMN superseded_at timestamptz;
ALTER TABLE paper_equations ADD COLUMN superseded_at timestamptz;
ALTER TABLE paper_terms
    ADD COLUMN artifact_version text NOT NULL DEFAULT 'core-v1' CHECK (
        char_length(artifact_version) BETWEEN 1 AND 64
        AND artifact_version = btrim(artifact_version)
        AND artifact_version ~ '^[a-z0-9][a-z0-9._-]*$'
    ),
    ADD COLUMN provenance_id uuid REFERENCES provenance_records(id) ON DELETE RESTRICT,
    ADD COLUMN superseded_at timestamptz;
ALTER TABLE paper_terms
    DROP CONSTRAINT paper_terms_paper_id_generation_normalized_term_kind_key;
ALTER TABLE paper_terms
    ADD CONSTRAINT paper_terms_generation_artifact_term_unique
    UNIQUE (paper_id, generation, normalized_term, kind, artifact_version);
CREATE UNIQUE INDEX paper_terms_one_current_term_idx
    ON paper_terms (paper_id, generation, normalized_term, kind)
    WHERE superseded_at IS NULL;

CREATE FUNCTION supersede_plan03_shared_artifacts() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.arxiv_version > OLD.arxiv_version THEN
        UPDATE paper_processing
        SET visual_objects_ready = false,
            terms_ready = false,
            semantic_facets_ready = false,
            paper_passport_ready = false,
            updated_at = now()
        WHERE paper_id = NEW.id;

        UPDATE paper_passports
        SET superseded_at = COALESCE(superseded_at, now()), updated_at = now()
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
        UPDATE semantic_spans
        SET superseded_at = COALESCE(superseded_at, now())
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
        UPDATE paper_figures
        SET superseded_at = COALESCE(superseded_at, now())
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
        UPDATE paper_tables
        SET superseded_at = COALESCE(superseded_at, now())
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
        UPDATE paper_equations
        SET superseded_at = COALESCE(superseded_at, now())
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
        UPDATE paper_terms
        SET superseded_at = COALESCE(superseded_at, now())
        WHERE paper_id = NEW.id AND superseded_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER papers_supersede_plan03_shared_artifacts
AFTER UPDATE OF arxiv_version ON papers
FOR EACH ROW EXECUTE FUNCTION supersede_plan03_shared_artifacts();

COMMENT ON TABLE paper_passport_feedback_evaluations IS
    'Immutable evaluation input. Feedback never updates a Passport or field directly.';
COMMENT ON COLUMN provenance_records.parameters IS
    'Bounded scalar controls only; prompt bodies, user text, paths, tokens and secrets are prohibited.';
COMMENT ON TABLE assistant_messages IS
    'Prior turns are bounded conversation context only and are never input evidence.';
COMMENT ON COLUMN assistant_messages.evidence_map IS
    'Bounded structural claim/evidence targets for exact feedback fencing; source text is prohibited.';
COMMENT ON TABLE assistant_evidence_feedback_evaluations IS
    'Immutable evidence-correctness evaluations. Generic sentiment is intentionally unsupported.';
