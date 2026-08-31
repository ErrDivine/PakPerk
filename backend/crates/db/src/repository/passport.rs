use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use domain::{
    ArtifactConfidenceStatus, DocumentProvenanceSummary, DocumentTerm, PaperId, PaperPassport,
    PassportFeedback, PassportField, PassportFieldKey, PassportFieldStatus, PassportStatus,
    PassportValidationError, ProcessingGeneration, ProvenanceActivityType, ProvenanceArtifactType,
    ProvenancePrincipal, ProvenanceRecord, SemanticDensity, SemanticFacet, SemanticSpan,
    SemanticSpanSourceKind, SemanticSupportStatus, TermOccurrence, normalize_term,
};
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::{DbError, DocumentRepository};

pub const ASSISTANT_THREAD_CONTEXT_MAX: i64 = 20;
pub const ASSISTANT_MESSAGE_MAX_SCALARS: usize = 32_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnrichmentCapability {
    VisualObjects,
    Terms,
    SemanticFacets,
    PaperPassport,
    AccessibilityDescriptions,
}

impl EnrichmentCapability {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::VisualObjects => "visual_objects",
            Self::Terms => "terms",
            Self::SemanticFacets => "semantic_facets",
            Self::PaperPassport => "paper_passport",
            Self::AccessibilityDescriptions => "accessibility_descriptions",
        }
    }

    const fn processing_column(self) -> Option<&'static str> {
        match self {
            Self::VisualObjects => Some("visual_objects_ready"),
            Self::Terms => Some("terms_ready"),
            Self::SemanticFacets => Some("semantic_facets_ready"),
            Self::PaperPassport => Some("paper_passport_ready"),
            Self::AccessibilityDescriptions => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactPersistOutcome {
    Inserted,
    Updated,
    Unchanged,
}

#[derive(Debug, Clone)]
pub struct CurrentPassport {
    pub document_provenance: DocumentProvenanceSummary,
    pub passport: PaperPassport,
    pub provenance: Vec<ProvenanceRecord>,
}

#[derive(Debug, Clone)]
pub struct CurrentSemanticSpans {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub document_provenance: DocumentProvenanceSummary,
    pub spans: Vec<SemanticSpan>,
    pub provenance: Vec<ProvenanceRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeedbackEvaluationOutcome {
    Inserted(Uuid),
    Replayed(Uuid),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantHistoryRole {
    User,
    Assistant,
}

impl AssistantHistoryRole {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AssistantThread {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct AssistantMessage {
    pub id: Uuid,
    pub thread_id: Uuid,
    pub ordinal: u32,
    pub role: AssistantHistoryRole,
    pub content: String,
    pub provenance_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone)]
pub struct PassportRepository {
    pool: PgPool,
}

impl PassportRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Publishes all ten fields atomically. Existing rows may be refined by a
    /// worker, but their UUIDs are immutable so feedback and deep links remain
    /// stable. Feedback rows are never read by this mutation path.
    #[allow(clippy::too_many_lines)]
    pub async fn publish_passport(
        &self,
        passport: &PaperPassport,
        provenance: &[ProvenanceRecord],
        artifact_version: &str,
    ) -> Result<ArtifactPersistOutcome, DbError> {
        passport
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        validate_artifact_version(artifact_version)?;
        let provenance_by_id = validate_passport_provenance(passport, provenance)?;
        let current_blocks = DocumentRepository::new(self.pool.clone())
            .current_blocks_for_enrichment(passport.paper_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("current document is unavailable".to_owned()))?;
        if current_blocks.generation != passport.generation {
            return Err(DbError::StaleGeneration);
        }
        let block_ids = current_blocks
            .value
            .iter()
            .map(|block| block.id)
            .collect::<HashSet<_>>();
        if passport
            .fields
            .iter()
            .flat_map(|field| &field.source_block_ids)
            .any(|block_id| !block_ids.contains(block_id))
        {
            return Err(DbError::InvalidData(
                "Passport source block is outside the current document".to_owned(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, passport.paper_id, passport.generation)
            .await?;
        for record in provenance_by_id.values() {
            insert_provenance(&mut transaction, record).await?;
        }

        let existing = sqlx::query_as::<_, ExistingPassportRow>(
            r"
            SELECT id, provenance_id, status, parser_id, model_id, prompt_version
            FROM paper_passports
            WHERE paper_id = $1 AND generation = $2 AND schema_version = $3
            FOR UPDATE
            ",
        )
        .bind(passport.paper_id)
        .bind(passport.generation)
        .bind(&passport.schema_version)
        .fetch_optional(&mut *transaction)
        .await?;
        let outcome = match &existing {
            None => ArtifactPersistOutcome::Inserted,
            Some(row) if row.matches(passport) => ArtifactPersistOutcome::Unchanged,
            Some(row) => {
                if row.id != passport.id {
                    return Err(DbError::InvalidData(
                        "Passport UUID changed for an existing schema".to_owned(),
                    ));
                }
                if row.provenance_id != passport.provenance_id {
                    sqlx::query(
                        "UPDATE provenance_records SET superseded_by = $2 WHERE id = $1 AND superseded_by IS NULL",
                    )
                    .bind(row.provenance_id)
                    .bind(passport.provenance_id)
                    .execute(&mut *transaction)
                    .await?;
                }
                ArtifactPersistOutcome::Updated
            }
        };

        sqlx::query(
            r"
            INSERT INTO paper_passports (
                id, paper_id, generation, schema_version, status, parser_id,
                model_id, prompt_version, provenance_id, created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            ON CONFLICT (paper_id, generation, schema_version) DO UPDATE
            SET status = EXCLUDED.status,
                parser_id = EXCLUDED.parser_id,
                model_id = EXCLUDED.model_id,
                prompt_version = EXCLUDED.prompt_version,
                provenance_id = EXCLUDED.provenance_id,
                updated_at = EXCLUDED.updated_at,
                superseded_at = NULL
            WHERE paper_passports.id = EXCLUDED.id
            ",
        )
        .bind(passport.id)
        .bind(passport.paper_id)
        .bind(passport.generation)
        .bind(&passport.schema_version)
        .bind(passport.status.as_str())
        .bind(&passport.parser_id)
        .bind(&passport.model_id)
        .bind(&passport.prompt_version)
        .bind(passport.provenance_id)
        .bind(passport.created_at)
        .bind(passport.updated_at)
        .execute(&mut *transaction)
        .await?;

        for field in &passport.fields {
            let previous = sqlx::query_scalar::<_, Uuid>(
                "SELECT provenance_id FROM paper_passport_fields WHERE passport_id = $1 AND field_key = $2 FOR UPDATE",
            )
            .bind(passport.id)
            .bind(field.key.as_str())
            .fetch_optional(&mut *transaction)
            .await?;
            if let Some(previous) = previous
                && previous != field.provenance_id
            {
                sqlx::query(
                    "UPDATE provenance_records SET superseded_by = $2 WHERE id = $1 AND superseded_by IS NULL",
                )
                .bind(previous)
                .bind(field.provenance_id)
                .execute(&mut *transaction)
                .await?;
            }
            let changed = sqlx::query(
                r"
                INSERT INTO paper_passport_fields (
                    id, passport_id, paper_id, generation, field_key, value_text,
                    value_json, status, source_block_ids, confidence_status,
                    provenance_id, created_at
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
                ON CONFLICT (passport_id, field_key) DO UPDATE
                SET value_text = EXCLUDED.value_text,
                    value_json = EXCLUDED.value_json,
                    status = EXCLUDED.status,
                    source_block_ids = EXCLUDED.source_block_ids,
                    confidence_status = EXCLUDED.confidence_status,
                    provenance_id = EXCLUDED.provenance_id
                WHERE paper_passport_fields.id = EXCLUDED.id
                ",
            )
            .bind(field.id)
            .bind(passport.id)
            .bind(passport.paper_id)
            .bind(passport.generation)
            .bind(field.key.as_str())
            .bind(&field.value_text)
            .bind(&field.value_json)
            .bind(field.status.as_str())
            .bind(&field.source_block_ids)
            .bind(field.confidence_status.as_str())
            .bind(field.provenance_id)
            .bind(field.created_at)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            if changed != 1 {
                return Err(DbError::InvalidData(
                    "Passport field UUID changed for an existing key".to_owned(),
                ));
            }
        }
        publish_enrichment_ready(
            &mut transaction,
            passport.paper_id,
            passport.generation,
            EnrichmentCapability::PaperPassport,
            artifact_version,
        )
        .await?;
        transaction.commit().await?;
        Ok(outcome)
    }

    pub async fn current_passport(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentPassport>, DbError> {
        let Some(header) = sqlx::query_as::<_, PassportHeaderRow>(
            r"
            SELECT
                passport.id, passport.paper_id, passport.generation,
                passport.schema_version, passport.status, passport.parser_id,
                passport.model_id, passport.prompt_version, passport.provenance_id,
                passport.created_at, passport.updated_at,
                document.arxiv_version, document.parser_id AS document_parser_id,
                document.parser_version AS document_parser_version,
                document.schema_version AS document_schema_version,
                document.document_hash, document.created_at AS document_created_at
            FROM paper_passports AS passport
            JOIN paper_processing AS processing
              ON processing.paper_id = passport.paper_id
             AND processing.generation = passport.generation
             AND processing.paper_passport_ready
            JOIN document_generations AS document
              ON document.paper_id = passport.paper_id
             AND document.generation = passport.generation
            WHERE passport.paper_id = $1
              AND passport.superseded_at IS NULL
              AND passport.status <> 'failed'
            ORDER BY passport.updated_at DESC, passport.id DESC
            LIMIT 1
            ",
        )
        .bind(paper_id)
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        let fields = sqlx::query_as::<_, PassportFieldRow>(
            r"
            SELECT
                id, field_key, value_text, value_json, status, source_block_ids,
                confidence_status, provenance_id, created_at
            FROM paper_passport_fields
            WHERE passport_id = $1
            ORDER BY field_key
            ",
        )
        .bind(header.id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(PassportFieldRow::try_into_domain)
        .collect::<Result<Vec<_>, _>>()?;
        let passport = header.passport(fields)?;
        passport
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let mut provenance_ids = passport
            .fields
            .iter()
            .map(|field| field.provenance_id)
            .collect::<Vec<_>>();
        provenance_ids.push(passport.provenance_id);
        let provenance = self
            .shared_provenance_records(paper_id, passport.generation, &provenance_ids)
            .await?;
        if provenance.len() != provenance_ids.into_iter().collect::<HashSet<_>>().len() {
            return Err(DbError::InvalidData(
                "Passport provenance is incomplete".to_owned(),
            ));
        }
        Ok(Some(CurrentPassport {
            document_provenance: header.document_provenance()?,
            passport,
            provenance,
        }))
    }

    /// A shared record is addressable only with current paper/generation
    /// scope; UUID-only lookup is intentionally not offered.
    pub async fn shared_provenance(
        &self,
        paper_id: PaperId,
        provenance_id: Uuid,
    ) -> Result<Option<ProvenanceRecord>, DbError> {
        let Some(generation) = current_generation(&self.pool, paper_id).await? else {
            return Ok(None);
        };
        self.shared_provenance_records(paper_id, generation, &[provenance_id])
            .await
            .map(|mut values| values.pop())
    }

    async fn shared_provenance_records(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        provenance_ids: &[Uuid],
    ) -> Result<Vec<ProvenanceRecord>, DbError> {
        sqlx::query_as::<_, ProvenanceRow>(
            r"
            SELECT
                provenance.id, provenance.artifact_type, provenance.artifact_id,
                provenance.paper_id, provenance.generation, provenance.activity_type,
                provenance.parser_id, provenance.parser_version,
                provenance.model_provider, provenance.model_id,
                provenance.prompt_or_schema_version, provenance.input_entity_ids,
                provenance.parameters, provenance.owner_user_id,
                provenance.anonymous_session_id, provenance.created_at,
                provenance.superseded_by
            FROM provenance_records AS provenance
            JOIN paper_processing AS processing
              ON processing.paper_id = provenance.paper_id
             AND processing.generation = provenance.generation
            JOIN document_generations AS document
              ON document.paper_id = provenance.paper_id
             AND document.generation = provenance.generation
            WHERE provenance.paper_id = $1
              AND provenance.generation = $2
              AND provenance.id = ANY($3::uuid[])
              AND provenance.owner_user_id IS NULL
              AND provenance.anonymous_session_id IS NULL
            ORDER BY provenance.created_at, provenance.id
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(provenance_ids)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(ProvenanceRow::try_into_domain)
        .collect()
    }

    #[allow(clippy::too_many_lines)]
    pub async fn replace_semantic_spans(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        provenance: &ProvenanceRecord,
        spans: &[SemanticSpan],
        artifact_version: &str,
    ) -> Result<ArtifactPersistOutcome, DbError> {
        provenance
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        validate_artifact_version(artifact_version)?;
        if provenance.paper_id != paper_id
            || provenance.generation != generation
            || provenance.artifact_type != ProvenanceArtifactType::SemanticSpans
            || provenance.activity_type != ProvenanceActivityType::SemanticClassification
            || provenance.principal.is_some()
            || spans.iter().any(|span| {
                span.paper_id != paper_id
                    || span.generation != generation
                    || span.provenance_id != provenance.id
            })
        {
            return Err(DbError::InvalidData(
                "semantic provenance does not match its artifact".to_owned(),
            ));
        }
        let current_blocks = DocumentRepository::new(self.pool.clone())
            .current_blocks_for_enrichment(paper_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("current document is unavailable".to_owned()))?;
        if current_blocks.generation != generation {
            return Err(DbError::StaleGeneration);
        }
        let blocks = current_blocks
            .value
            .iter()
            .map(|block| (block.id, block))
            .collect::<HashMap<_, _>>();
        let mut identities = HashSet::new();
        for span in spans {
            let block = blocks.get(&span.block_id).ok_or_else(|| {
                DbError::InvalidData("semantic span block is outside the document".to_owned())
            })?;
            span.validate_for_block(block)
                .map_err(|error| DbError::InvalidData(error.to_string()))?;
            if !identities.insert((span.block_id, span.ordinal)) {
                return Err(DbError::InvalidData(
                    "semantic span identity is duplicated".to_owned(),
                ));
            }
        }

        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        insert_provenance(&mut transaction, provenance).await?;
        let previous_ids = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT DISTINCT provenance_id
            FROM semantic_spans
            WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
            FOR UPDATE
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .fetch_all(&mut *transaction)
        .await?;
        let outcome = if previous_ids.is_empty() {
            ArtifactPersistOutcome::Inserted
        } else if previous_ids == [provenance.id] {
            ArtifactPersistOutcome::Unchanged
        } else {
            ArtifactPersistOutcome::Updated
        };
        for previous in previous_ids {
            if previous != provenance.id {
                sqlx::query(
                    "UPDATE provenance_records SET superseded_by = $2 WHERE id = $1 AND superseded_by IS NULL",
                )
                .bind(previous)
                .bind(provenance.id)
                .execute(&mut *transaction)
                .await?;
            }
        }
        sqlx::query(
            "UPDATE semantic_spans SET superseded_at = now() WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL AND provenance_id <> $3",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(provenance.id)
        .execute(&mut *transaction)
        .await?;
        for span in spans {
            sqlx::query(
                r"
                INSERT INTO semantic_spans (
                    id, paper_id, generation, block_id, span_ordinal,
                    start_offset, end_offset, facet, minimum_density, source_kind,
                    confidence_basis_points, support_status, provenance_id, created_at
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
                ON CONFLICT (id) DO NOTHING
                ",
            )
            .bind(span.id)
            .bind(span.paper_id)
            .bind(span.generation)
            .bind(span.block_id)
            .bind(i32::try_from(span.ordinal).map_err(|_| invalid_number())?)
            .bind(i32::try_from(span.start_offset).map_err(|_| invalid_number())?)
            .bind(i32::try_from(span.end_offset).map_err(|_| invalid_number())?)
            .bind(span.facet.as_str())
            .bind(span.minimum_density.as_str())
            .bind(span.source_kind.as_str())
            .bind(i32::from(span.confidence_basis_points))
            .bind(span.support_status.as_str())
            .bind(span.provenance_id)
            .bind(span.created_at)
            .execute(&mut *transaction)
            .await?;
        }
        publish_enrichment_ready(
            &mut transaction,
            paper_id,
            generation,
            EnrichmentCapability::SemanticFacets,
            artifact_version,
        )
        .await?;
        transaction.commit().await?;
        Ok(outcome)
    }

    #[allow(clippy::too_many_lines)]
    pub async fn replace_terms(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        provenance: &ProvenanceRecord,
        terms: &[DocumentTerm],
        occurrences: &[TermOccurrence],
        artifact_version: &str,
    ) -> Result<ArtifactPersistOutcome, DbError> {
        provenance
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        validate_artifact_version(artifact_version)?;
        if provenance.paper_id != paper_id
            || provenance.generation != generation
            || provenance.artifact_type != ProvenanceArtifactType::Terms
            || provenance.activity_type != ProvenanceActivityType::TermExtraction
            || provenance.principal.is_some()
            || terms.len() > 10_000
            || occurrences.len() > 100_000
        {
            return Err(DbError::InvalidData(
                "term enrichment provenance or bounds are invalid".to_owned(),
            ));
        }
        let current_blocks = DocumentRepository::new(self.pool.clone())
            .current_blocks_for_enrichment(paper_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("current document is unavailable".to_owned()))?;
        if current_blocks.generation != generation {
            return Err(DbError::StaleGeneration);
        }
        let blocks = current_blocks
            .value
            .iter()
            .map(|block| (block.id, block))
            .collect::<HashMap<_, _>>();
        let mut term_ids = HashSet::new();
        let mut term_keys = HashSet::new();
        for term in terms {
            if term.id.is_nil()
                || term.paper_id != paper_id
                || term.generation != generation
                || normalize_term(&term.display_term) != term.normalized_term
                || term.normalized_term.is_empty()
                || term.normalized_term.chars().count() > 512
                || !term_ids.insert(term.id)
                || !term_keys.insert((term.normalized_term.as_str(), term.kind))
            {
                return Err(DbError::InvalidData(
                    "term enrichment contains an invalid term".to_owned(),
                ));
            }
        }
        let mut occurrence_keys = HashSet::new();
        for occurrence in occurrences {
            let block = blocks.get(&occurrence.block_id).ok_or_else(|| {
                DbError::InvalidData("term occurrence block is outside the document".to_owned())
            })?;
            let end = usize::try_from(occurrence.end_offset).unwrap_or(usize::MAX);
            if occurrence.paper_id != paper_id
                || occurrence.generation != generation
                || !term_ids.contains(&occurrence.term_id)
                || occurrence.start_offset >= occurrence.end_offset
                || end > block.text.chars().count()
                || !occurrence_keys.insert((
                    occurrence.term_id,
                    occurrence.block_id,
                    occurrence.occurrence_ordinal,
                ))
            {
                return Err(DbError::InvalidData(
                    "term enrichment contains an invalid occurrence".to_owned(),
                ));
            }
        }

        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        insert_provenance(&mut transaction, provenance).await?;
        let previous_provenance = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT DISTINCT provenance_id
            FROM paper_terms
            WHERE paper_id = $1 AND generation = $2
              AND superseded_at IS NULL AND provenance_id IS NOT NULL
            FOR UPDATE
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .fetch_all(&mut *transaction)
        .await?;
        let outcome = if previous_provenance.is_empty() {
            ArtifactPersistOutcome::Inserted
        } else if previous_provenance == [provenance.id] {
            ArtifactPersistOutcome::Unchanged
        } else {
            ArtifactPersistOutcome::Updated
        };
        for previous in previous_provenance {
            if previous != provenance.id {
                sqlx::query(
                    "UPDATE provenance_records SET superseded_by = $2 WHERE id = $1 AND superseded_by IS NULL",
                )
                .bind(previous)
                .bind(provenance.id)
                .execute(&mut *transaction)
                .await?;
            }
        }
        sqlx::query(
            r"
            UPDATE paper_terms
            SET superseded_at = now()
            WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
              AND artifact_version <> $3
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(artifact_version)
        .execute(&mut *transaction)
        .await?;
        let incoming_term_ids = terms.iter().map(|term| term.id).collect::<Vec<_>>();
        sqlx::query(
            r"
            UPDATE paper_terms
            SET superseded_at = now()
            WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
              AND artifact_version = $3 AND NOT (id = ANY($4::uuid[]))
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(artifact_version)
        .bind(&incoming_term_ids)
        .execute(&mut *transaction)
        .await?;
        for term in terms {
            let changed = sqlx::query(
                r"
                INSERT INTO paper_terms (
                    id, paper_id, generation, normalized_term, display_term,
                    kind, canonical_topic_id, definition_status,
                    artifact_version, provenance_id
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                ON CONFLICT (paper_id, generation, normalized_term, kind, artifact_version)
                DO UPDATE SET
                    display_term = EXCLUDED.display_term,
                    canonical_topic_id = EXCLUDED.canonical_topic_id,
                    definition_status = EXCLUDED.definition_status,
                    provenance_id = EXCLUDED.provenance_id,
                    superseded_at = NULL
                WHERE paper_terms.id = EXCLUDED.id
                ",
            )
            .bind(term.id)
            .bind(term.paper_id)
            .bind(term.generation)
            .bind(&term.normalized_term)
            .bind(&term.display_term)
            .bind(term.kind.as_str())
            .bind(term.canonical_topic_id)
            .bind(term.definition_status.as_str())
            .bind(artifact_version)
            .bind(provenance.id)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            if changed != 1 {
                return Err(DbError::InvalidData(
                    "term UUID changed for an existing artifact key".to_owned(),
                ));
            }
            sqlx::query("DELETE FROM term_occurrences WHERE term_id = $1")
                .bind(term.id)
                .execute(&mut *transaction)
                .await?;
            sqlx::query("DELETE FROM term_definitions WHERE term_id = $1")
                .bind(term.id)
                .execute(&mut *transaction)
                .await?;
        }
        for occurrence in occurrences {
            sqlx::query(
                r"
                INSERT INTO term_occurrences (
                    term_id, block_id, paper_id, generation,
                    start_offset, end_offset, occurrence_ordinal
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                ",
            )
            .bind(occurrence.term_id)
            .bind(occurrence.block_id)
            .bind(occurrence.paper_id)
            .bind(occurrence.generation)
            .bind(i32::try_from(occurrence.start_offset).map_err(|_| invalid_number())?)
            .bind(i32::try_from(occurrence.end_offset).map_err(|_| invalid_number())?)
            .bind(i32::try_from(occurrence.occurrence_ordinal).map_err(|_| invalid_number())?)
            .execute(&mut *transaction)
            .await?;
        }
        publish_enrichment_ready(
            &mut transaction,
            paper_id,
            generation,
            EnrichmentCapability::Terms,
            artifact_version,
        )
        .await?;
        transaction.commit().await?;
        Ok(outcome)
    }

    pub async fn persist_shared_provenance(
        &self,
        record: &ProvenanceRecord,
    ) -> Result<(), DbError> {
        record
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if record.principal.is_some()
            || record.artifact_type == ProvenanceArtifactType::AssistantAnswer
            || record.activity_type == ProvenanceActivityType::AssistantGeneration
        {
            return Err(DbError::InvalidData(
                "shared provenance cannot have a principal".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, record.paper_id, record.generation).await?;
        insert_provenance(&mut transaction, record).await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn current_semantic_spans(
        &self,
        paper_id: PaperId,
        block_id: Option<Uuid>,
        density: SemanticDensity,
    ) -> Result<Option<CurrentSemanticSpans>, DbError> {
        let Some(manifest) =
            current_manifest(&self.pool, paper_id, "semantic_facets_ready").await?
        else {
            return Ok(None);
        };
        if density == SemanticDensity::Off {
            return Ok(Some(CurrentSemanticSpans {
                paper_id,
                generation: manifest.generation,
                document_provenance: manifest.provenance()?,
                spans: Vec::new(),
                provenance: Vec::new(),
            }));
        }
        if let Some(block_id) = block_id {
            let valid = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM document_blocks WHERE id = $1 AND paper_id = $2 AND generation = $3)",
            )
            .bind(block_id)
            .bind(paper_id)
            .bind(manifest.generation)
            .fetch_one(&self.pool)
            .await?;
            if !valid {
                return Err(DbError::InvalidData(
                    "semantic span block is outside the current document".to_owned(),
                ));
            }
        }
        let rows = sqlx::query_as::<_, SemanticSpanRow>(
            r"
            SELECT
                id, paper_id, generation, block_id, span_ordinal,
                start_offset, end_offset, facet, minimum_density, source_kind,
                confidence_basis_points, support_status, provenance_id, created_at
            FROM semantic_spans
            WHERE paper_id = $1
              AND generation = $2
              AND superseded_at IS NULL
              AND ($3::uuid IS NULL OR block_id = $3)
              AND ($4 = 'detailed' OR minimum_density = 'key')
            ORDER BY block_id, span_ordinal
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .bind(block_id)
        .bind(density.as_str())
        .fetch_all(&self.pool)
        .await?;
        let spans = rows
            .into_iter()
            .map(SemanticSpanRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        let provenance_ids = spans
            .iter()
            .map(|span| span.provenance_id)
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let provenance = self
            .shared_provenance_records(paper_id, manifest.generation, &provenance_ids)
            .await?;
        if provenance.len() != provenance_ids.len() {
            return Err(DbError::InvalidData(
                "semantic span provenance is incomplete".to_owned(),
            ));
        }
        Ok(Some(CurrentSemanticSpans {
            paper_id,
            generation: manifest.generation,
            document_provenance: manifest.provenance()?,
            spans,
            provenance,
        }))
    }

    /// Records an immutable quality evaluation. This transaction performs no
    /// UPDATE against `paper_passports` or `paper_passport_fields`.
    pub async fn record_passport_feedback(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        principal: ProvenancePrincipal,
        feedback: &PassportFeedback,
    ) -> Result<FeedbackEvaluationOutcome, DbError> {
        feedback
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if principal.id().is_nil() {
            return Err(DbError::InvalidData(
                "feedback principal is invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        let passport_exists = sqlx::query_scalar::<_, bool>(
            r"
            SELECT EXISTS(
                SELECT 1
                FROM paper_passports
                WHERE id = $1 AND paper_id = $2 AND generation = $3
                  AND superseded_at IS NULL AND status <> 'failed'
            )
            ",
        )
        .bind(feedback.passport_id)
        .bind(paper_id)
        .bind(generation)
        .fetch_one(&mut *transaction)
        .await?;
        if !passport_exists {
            return Err(DbError::InvalidData(
                "feedback Passport is outside the current document".to_owned(),
            ));
        }
        if let Some(field_id) = feedback.field_id {
            let field_exists = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM paper_passport_fields WHERE id = $1 AND passport_id = $2)",
            )
            .bind(field_id)
            .bind(feedback.passport_id)
            .fetch_one(&mut *transaction)
            .await?;
            if !field_exists {
                return Err(DbError::InvalidData(
                    "feedback field is outside the Passport".to_owned(),
                ));
            }
        }
        let id = Uuid::now_v7();
        let inserted =
            insert_feedback_evaluation(&mut transaction, id, principal, feedback).await?;
        let outcome = if let Some(id) = inserted {
            FeedbackEvaluationOutcome::Inserted(id)
        } else {
            let existing =
                existing_feedback_evaluation(&mut transaction, principal, feedback.operation_id)
                    .await?;
            FeedbackEvaluationOutcome::Replayed(existing)
        };
        transaction.commit().await?;
        Ok(outcome)
    }

    pub async fn mark_enrichment_running(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        capability: EnrichmentCapability,
        artifact_version: &str,
    ) -> Result<(), DbError> {
        validate_artifact_version(artifact_version)?;
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        sqlx::query(
            r"
            INSERT INTO paper_enrichment_state (
                paper_id, generation, capability, artifact_version, status, started_at
            )
            VALUES ($1, $2, $3, $4, 'running', now())
            ON CONFLICT (paper_id, generation, capability, artifact_version) DO UPDATE
            SET status = 'running', started_at = COALESCE(paper_enrichment_state.started_at, now()),
                updated_at = now(), completed_at = NULL,
                last_error_category = NULL, last_error_code = NULL, last_error_message = NULL
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(capability.as_str())
        .bind(artifact_version)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn mark_enrichment_failed(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        capability: EnrichmentCapability,
        artifact_version: &str,
        error_category: &str,
        error_code: &str,
        safe_message: &str,
    ) -> Result<(), DbError> {
        validate_artifact_version(artifact_version)?;
        if !matches!(
            error_category,
            "external_temporary"
                | "external_permanent"
                | "parser_temporary"
                | "parser_document"
                | "model_temporary"
                | "validation"
                | "internal"
        ) || error_code.is_empty()
            || error_code.len() > 128
            || safe_message.is_empty()
            || safe_message.chars().count() > 1_000
            || error_code.contains('\0')
            || safe_message.contains('\0')
        {
            return Err(DbError::InvalidData(
                "enrichment failure detail is invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        sqlx::query(
            r"
            INSERT INTO paper_enrichment_state (
                paper_id, generation, capability, artifact_version, status,
                last_error_category, last_error_code, last_error_message,
                started_at, completed_at
            )
            VALUES ($1, $2, $3, $4, 'failed', $5, $6, $7, now(), now())
            ON CONFLICT (paper_id, generation, capability, artifact_version) DO UPDATE
            SET status = 'failed', last_error_category = EXCLUDED.last_error_category,
                last_error_code = EXCLUDED.last_error_code,
                last_error_message = EXCLUDED.last_error_message,
                updated_at = now(), completed_at = now()
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(capability.as_str())
        .bind(artifact_version)
        .bind(error_category)
        .bind(error_code)
        .bind(safe_message)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn mark_enrichment_ready(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        capability: EnrichmentCapability,
        artifact_version: &str,
    ) -> Result<(), DbError> {
        validate_artifact_version(artifact_version)?;
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        publish_enrichment_ready(
            &mut transaction,
            paper_id,
            generation,
            capability,
            artifact_version,
        )
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    /// Private provenance is only addressable through the exact principal and
    /// current paper scope. No UUID-only method exists.
    pub async fn private_provenance(
        &self,
        principal: ProvenancePrincipal,
        paper_id: PaperId,
        provenance_id: Uuid,
    ) -> Result<Option<ProvenanceRecord>, DbError> {
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        sqlx::query_as::<_, ProvenanceRow>(
            r"
            SELECT
                provenance.id, provenance.artifact_type, provenance.artifact_id,
                provenance.paper_id, provenance.generation, provenance.activity_type,
                provenance.parser_id, provenance.parser_version,
                provenance.model_provider, provenance.model_id,
                provenance.prompt_or_schema_version, provenance.input_entity_ids,
                provenance.parameters, provenance.owner_user_id,
                provenance.anonymous_session_id, provenance.created_at,
                provenance.superseded_by
            FROM provenance_records AS provenance
            JOIN paper_processing AS processing
              ON processing.paper_id = provenance.paper_id
             AND processing.generation = provenance.generation
            JOIN document_generations AS document
              ON document.paper_id = provenance.paper_id
             AND document.generation = provenance.generation
            WHERE provenance.id = $1 AND provenance.paper_id = $2
              AND provenance.owner_user_id IS NOT DISTINCT FROM $3
              AND provenance.anonymous_session_id IS NOT DISTINCT FROM $4
            ",
        )
        .bind(provenance_id)
        .bind(paper_id)
        .bind(owner_user_id)
        .bind(anonymous_session_id)
        .fetch_optional(&self.pool)
        .await?
        .map(ProvenanceRow::try_into_domain)
        .transpose()
    }

    pub async fn persist_private_provenance(
        &self,
        record: &ProvenanceRecord,
    ) -> Result<(), DbError> {
        record
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if record.principal.is_none()
            || record.artifact_type != ProvenanceArtifactType::AssistantAnswer
            || record.activity_type != ProvenanceActivityType::AssistantGeneration
        {
            return Err(DbError::InvalidData(
                "private provenance must describe an assistant answer".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, record.paper_id, record.generation).await?;
        insert_provenance(&mut transaction, record).await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn create_assistant_thread(
        &self,
        principal: ProvenancePrincipal,
        paper_id: PaperId,
        generation: ProcessingGeneration,
    ) -> Result<AssistantThread, DbError> {
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let mut transaction = self.pool.begin().await?;
        require_current_generation(&mut transaction, paper_id, generation).await?;
        let row = sqlx::query_as::<_, AssistantThreadRow>(
            r"
            INSERT INTO assistant_threads (
                owner_user_id, anonymous_session_id, paper_id, generation
            )
            VALUES ($1, $2, $3, $4)
            RETURNING id, paper_id, generation, created_at, updated_at, expires_at
            ",
        )
        .bind(owner_user_id)
        .bind(anonymous_session_id)
        .bind(paper_id)
        .bind(generation)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        row.try_into_domain()
    }

    pub async fn append_assistant_message(
        &self,
        principal: ProvenancePrincipal,
        thread_id: Uuid,
        role: AssistantHistoryRole,
        content: &str,
        provenance_id: Option<Uuid>,
    ) -> Result<AssistantMessage, DbError> {
        if thread_id.is_nil()
            || content.trim().is_empty()
            || content.chars().count() > ASSISTANT_MESSAGE_MAX_SCALARS
            || content.contains('\0')
        {
            return Err(DbError::InvalidData(
                "assistant message is invalid".to_owned(),
            ));
        }
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let mut transaction = self.pool.begin().await?;
        let scope = sqlx::query_as::<_, AssistantThreadScope>(
            r"
            SELECT thread.paper_id, thread.generation
            FROM assistant_threads AS thread
            JOIN paper_processing AS processing
              ON processing.paper_id = thread.paper_id
             AND processing.generation = thread.generation
            JOIN document_generations AS document
              ON document.paper_id = thread.paper_id
             AND document.generation = thread.generation
            WHERE thread.id = $1
              AND thread.owner_user_id IS NOT DISTINCT FROM $2
              AND thread.anonymous_session_id IS NOT DISTINCT FROM $3
              AND thread.expires_at > now()
            FOR UPDATE OF thread
            ",
        )
        .bind(thread_id)
        .bind(owner_user_id)
        .bind(anonymous_session_id)
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(DbError::InvalidChatThread)?;
        if let Some(provenance_id) = provenance_id {
            let valid = sqlx::query_scalar::<_, bool>(
                r"
                SELECT EXISTS(
                    SELECT 1 FROM provenance_records
                    WHERE id = $1 AND paper_id = $2 AND generation = $3
                      AND owner_user_id IS NOT DISTINCT FROM $4
                      AND anonymous_session_id IS NOT DISTINCT FROM $5
                      AND artifact_type = 'assistant_answer'
                )
                ",
            )
            .bind(provenance_id)
            .bind(scope.paper_id)
            .bind(scope.generation)
            .bind(owner_user_id)
            .bind(anonymous_session_id)
            .fetch_one(&mut *transaction)
            .await?;
            if !valid {
                return Err(DbError::InvalidData(
                    "assistant message provenance is outside the principal scope".to_owned(),
                ));
            }
        }
        let ordinal = sqlx::query_scalar::<_, i32>(
            "SELECT COALESCE(max(ordinal) + 1, 0) FROM assistant_messages WHERE thread_id = $1",
        )
        .bind(thread_id)
        .fetch_one(&mut *transaction)
        .await?;
        let row = sqlx::query_as::<_, AssistantMessageRow>(
            r"
            INSERT INTO assistant_messages (
                thread_id, ordinal, role, content, provenance_id
            )
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, thread_id, ordinal, role, content, provenance_id, created_at
            ",
        )
        .bind(thread_id)
        .bind(ordinal)
        .bind(role.as_str())
        .bind(content)
        .bind(provenance_id)
        .fetch_one(&mut *transaction)
        .await?;
        sqlx::query("UPDATE assistant_threads SET updated_at = now() WHERE id = $1")
            .bind(thread_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        row.try_into_domain()
    }

    pub async fn assistant_context(
        &self,
        principal: ProvenancePrincipal,
        thread_id: Uuid,
    ) -> Result<Vec<AssistantMessage>, DbError> {
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let rows = sqlx::query_as::<_, AssistantMessageRow>(
            r"
            SELECT message.id, message.thread_id, message.ordinal, message.role,
                   message.content, message.provenance_id, message.created_at
            FROM assistant_messages AS message
            JOIN assistant_threads AS thread ON thread.id = message.thread_id
            JOIN paper_processing AS processing
              ON processing.paper_id = thread.paper_id
             AND processing.generation = thread.generation
            WHERE thread.id = $1
              AND thread.owner_user_id IS NOT DISTINCT FROM $2
              AND thread.anonymous_session_id IS NOT DISTINCT FROM $3
              AND thread.expires_at > now()
            ORDER BY message.ordinal DESC
            LIMIT $4
            ",
        )
        .bind(thread_id)
        .bind(owner_user_id)
        .bind(anonymous_session_id)
        .bind(ASSISTANT_THREAD_CONTEXT_MAX)
        .fetch_all(&self.pool)
        .await?;
        let mut messages = rows
            .into_iter()
            .map(AssistantMessageRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        messages.reverse();
        Ok(messages)
    }
}

#[derive(Debug, FromRow)]
struct ExistingPassportRow {
    id: Uuid,
    provenance_id: Uuid,
    status: String,
    parser_id: String,
    model_id: Option<String>,
    prompt_version: Option<String>,
}

impl ExistingPassportRow {
    fn matches(&self, passport: &PaperPassport) -> bool {
        self.id == passport.id
            && self.provenance_id == passport.provenance_id
            && self.status == passport.status.as_str()
            && self.parser_id == passport.parser_id
            && self.model_id == passport.model_id
            && self.prompt_version == passport.prompt_version
    }
}

#[derive(Debug, Clone, FromRow)]
struct PassportHeaderRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    schema_version: String,
    status: String,
    parser_id: String,
    model_id: Option<String>,
    prompt_version: Option<String>,
    provenance_id: Uuid,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    arxiv_version: i32,
    document_parser_id: String,
    document_parser_version: String,
    document_schema_version: String,
    document_hash: String,
    document_created_at: DateTime<Utc>,
}

impl PassportHeaderRow {
    fn passport(&self, fields: Vec<PassportField>) -> Result<PaperPassport, DbError> {
        Ok(PaperPassport {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            schema_version: self.schema_version.clone(),
            status: PassportStatus::try_from(self.status.as_str()).map_err(invalid_enum)?,
            parser_id: self.parser_id.clone(),
            model_id: self.model_id.clone(),
            prompt_version: self.prompt_version.clone(),
            provenance_id: self.provenance_id,
            fields,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }

    fn document_provenance(&self) -> Result<DocumentProvenanceSummary, DbError> {
        Ok(DocumentProvenanceSummary {
            arxiv_version: required_u32(self.arxiv_version, "document arxiv version")?,
            parser_id: self.document_parser_id.clone(),
            parser_version: self.document_parser_version.clone(),
            schema_version: self.document_schema_version.clone(),
            document_hash: self.document_hash.clone(),
            generated_at: self.document_created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct PassportFieldRow {
    id: Uuid,
    field_key: String,
    value_text: Option<String>,
    value_json: Option<Value>,
    status: String,
    source_block_ids: Vec<Uuid>,
    confidence_status: String,
    provenance_id: Uuid,
    created_at: DateTime<Utc>,
}

impl PassportFieldRow {
    fn try_into_domain(self) -> Result<PassportField, DbError> {
        let key = PassportFieldKey::try_from(self.field_key.as_str()).map_err(invalid_enum)?;
        let field = PassportField {
            id: self.id,
            key,
            value_text: self.value_text,
            value_json: self.value_json,
            status: PassportFieldStatus::try_from(self.status.as_str()).map_err(invalid_enum)?,
            source_block_ids: self.source_block_ids,
            confidence_status: ArtifactConfidenceStatus::try_from(self.confidence_status.as_str())
                .map_err(invalid_enum)?,
            provenance_id: self.provenance_id,
            created_at: self.created_at,
        };
        field
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(field)
    }
}

#[derive(Debug, FromRow)]
struct SemanticSpanRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    block_id: Uuid,
    span_ordinal: i32,
    start_offset: i32,
    end_offset: i32,
    facet: String,
    minimum_density: String,
    source_kind: String,
    confidence_basis_points: i32,
    support_status: String,
    provenance_id: Uuid,
    created_at: DateTime<Utc>,
}

impl SemanticSpanRow {
    fn try_into_domain(self) -> Result<SemanticSpan, DbError> {
        Ok(SemanticSpan {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            block_id: self.block_id,
            ordinal: required_u32(self.span_ordinal, "semantic span ordinal")?,
            start_offset: required_u32(self.start_offset, "semantic span start")?,
            end_offset: required_u32(self.end_offset, "semantic span end")?,
            facet: SemanticFacet::try_from(self.facet.as_str()).map_err(invalid_enum)?,
            minimum_density: SemanticDensity::try_from(self.minimum_density.as_str())
                .map_err(invalid_enum)?,
            source_kind: SemanticSpanSourceKind::try_from(self.source_kind.as_str())
                .map_err(invalid_enum)?,
            confidence_basis_points: u16::try_from(self.confidence_basis_points)
                .map_err(|_| invalid_number())?,
            support_status: SemanticSupportStatus::try_from(self.support_status.as_str())
                .map_err(invalid_enum)?,
            provenance_id: self.provenance_id,
            created_at: self.created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct ProvenanceRow {
    id: Uuid,
    artifact_type: String,
    artifact_id: Uuid,
    paper_id: Option<Uuid>,
    generation: Option<i32>,
    activity_type: String,
    parser_id: Option<String>,
    parser_version: Option<String>,
    model_provider: Option<String>,
    model_id: Option<String>,
    prompt_or_schema_version: Option<String>,
    input_entity_ids: Vec<Uuid>,
    parameters: Value,
    owner_user_id: Option<Uuid>,
    anonymous_session_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    superseded_by: Option<Uuid>,
}

impl ProvenanceRow {
    fn try_into_domain(self) -> Result<ProvenanceRecord, DbError> {
        let principal = match (self.owner_user_id, self.anonymous_session_id) {
            (Some(user_id), None) => Some(ProvenancePrincipal::OwnerUser(user_id)),
            (None, Some(session_id)) => Some(ProvenancePrincipal::AnonymousSession(session_id)),
            (None, None) => None,
            (Some(_), Some(_)) => {
                return Err(DbError::InvalidData(
                    "provenance has multiple principals".to_owned(),
                ));
            }
        };
        let record = ProvenanceRecord {
            id: self.id,
            artifact_type: ProvenanceArtifactType::try_from(self.artifact_type.as_str())
                .map_err(invalid_enum)?,
            artifact_id: self.artifact_id,
            paper_id: self
                .paper_id
                .ok_or_else(|| DbError::InvalidData("provenance paper is missing".to_owned()))?,
            generation: self.generation.ok_or_else(|| {
                DbError::InvalidData("provenance generation is missing".to_owned())
            })?,
            activity_type: ProvenanceActivityType::try_from(self.activity_type.as_str())
                .map_err(invalid_enum)?,
            parser_id: self.parser_id,
            parser_version: self.parser_version,
            model_provider: self.model_provider,
            model_id: self.model_id,
            prompt_or_schema_version: self.prompt_or_schema_version,
            input_entity_ids: self.input_entity_ids,
            parameters: serde_json::from_value(self.parameters).map_err(|_| {
                DbError::InvalidData("provenance parameters are invalid".to_owned())
            })?,
            principal,
            created_at: self.created_at,
            superseded_by: self.superseded_by,
        };
        record
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(record)
    }
}

#[derive(Debug, FromRow)]
struct CurrentManifestRow {
    generation: i32,
    arxiv_version: i32,
    parser_id: String,
    parser_version: String,
    schema_version: String,
    document_hash: String,
    created_at: DateTime<Utc>,
}

impl CurrentManifestRow {
    fn provenance(&self) -> Result<DocumentProvenanceSummary, DbError> {
        Ok(DocumentProvenanceSummary {
            arxiv_version: required_u32(self.arxiv_version, "document arxiv version")?,
            parser_id: self.parser_id.clone(),
            parser_version: self.parser_version.clone(),
            schema_version: self.schema_version.clone(),
            document_hash: self.document_hash.clone(),
            generated_at: self.created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AssistantThreadRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
}

impl AssistantThreadRow {
    fn try_into_domain(self) -> Result<AssistantThread, DbError> {
        if self.generation <= 0
            || self.expires_at <= self.created_at
            || self.expires_at > self.created_at + Duration::days(90)
        {
            return Err(DbError::InvalidData(
                "assistant thread is invalid".to_owned(),
            ));
        }
        Ok(AssistantThread {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            created_at: self.created_at,
            updated_at: self.updated_at,
            expires_at: self.expires_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AssistantThreadScope {
    paper_id: Uuid,
    generation: i32,
}

#[derive(Debug, FromRow)]
struct AssistantMessageRow {
    id: Uuid,
    thread_id: Uuid,
    ordinal: i32,
    role: String,
    content: String,
    provenance_id: Option<Uuid>,
    created_at: DateTime<Utc>,
}

impl AssistantMessageRow {
    fn try_into_domain(self) -> Result<AssistantMessage, DbError> {
        let role = match self.role.as_str() {
            "user" => AssistantHistoryRole::User,
            "assistant" => AssistantHistoryRole::Assistant,
            _ => {
                return Err(DbError::InvalidData(
                    "assistant message role is invalid".to_owned(),
                ));
            }
        };
        if self.content.trim().is_empty()
            || self.content.chars().count() > ASSISTANT_MESSAGE_MAX_SCALARS
            || self.content.contains('\0')
        {
            return Err(DbError::InvalidData(
                "assistant message content is invalid".to_owned(),
            ));
        }
        Ok(AssistantMessage {
            id: self.id,
            thread_id: self.thread_id,
            ordinal: required_u32(self.ordinal, "assistant message ordinal")?,
            role,
            content: self.content,
            provenance_id: self.provenance_id,
            created_at: self.created_at,
        })
    }
}

async fn current_generation(
    pool: &PgPool,
    paper_id: PaperId,
) -> Result<Option<ProcessingGeneration>, DbError> {
    sqlx::query_scalar::<_, i32>(
        r"
        SELECT processing.generation
        FROM paper_processing AS processing
        JOIN document_generations AS document
          ON document.paper_id = processing.paper_id
         AND document.generation = processing.generation
        WHERE processing.paper_id = $1
        ",
    )
    .bind(paper_id)
    .fetch_optional(pool)
    .await
    .map_err(DbError::from)
}

async fn current_manifest(
    pool: &PgPool,
    paper_id: PaperId,
    capability_column: &str,
) -> Result<Option<CurrentManifestRow>, DbError> {
    if capability_column != "semantic_facets_ready" {
        return Err(DbError::InvalidData(
            "unknown enrichment capability column".to_owned(),
        ));
    }
    sqlx::query_as::<_, CurrentManifestRow>(
        r"
        SELECT
            document.generation, document.arxiv_version, document.parser_id,
            document.parser_version, document.schema_version,
            document.document_hash, document.created_at
        FROM document_generations AS document
        JOIN paper_processing AS processing
          ON processing.paper_id = document.paper_id
         AND processing.generation = document.generation
         AND processing.semantic_facets_ready
        WHERE document.paper_id = $1
        ",
    )
    .bind(paper_id)
    .fetch_optional(pool)
    .await
    .map_err(DbError::from)
}

async fn require_current_generation(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<(), DbError> {
    let current = sqlx::query_scalar::<_, i32>(
        r"
        SELECT processing.generation
        FROM paper_processing AS processing
        JOIN document_generations AS document
          ON document.paper_id = processing.paper_id
         AND document.generation = processing.generation
        WHERE processing.paper_id = $1
        FOR UPDATE OF processing
        ",
    )
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?;
    if current != Some(generation) {
        return Err(DbError::StaleGeneration);
    }
    Ok(())
}

async fn insert_provenance(
    transaction: &mut Transaction<'_, Postgres>,
    record: &ProvenanceRecord,
) -> Result<(), DbError> {
    record
        .validate()
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    let (owner_user_id, anonymous_session_id) =
        record.principal.map_or((None, None), principal_columns);
    let parameters = serde_json::to_value(&record.parameters)
        .map_err(|_| DbError::InvalidData("provenance parameters are invalid".to_owned()))?;
    sqlx::query(
        r"
        INSERT INTO provenance_records (
            id, artifact_type, artifact_id, paper_id, generation, activity_type,
            parser_id, parser_version, model_provider, model_id,
            prompt_or_schema_version, input_entity_ids, parameters,
            owner_user_id, anonymous_session_id, created_at, superseded_by
        )
        VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            $11, $12, $13, $14, $15, $16, $17
        )
        ON CONFLICT (id) DO NOTHING
        ",
    )
    .bind(record.id)
    .bind(record.artifact_type.as_str())
    .bind(record.artifact_id)
    .bind(record.paper_id)
    .bind(record.generation)
    .bind(record.activity_type.as_str())
    .bind(&record.parser_id)
    .bind(&record.parser_version)
    .bind(&record.model_provider)
    .bind(&record.model_id)
    .bind(&record.prompt_or_schema_version)
    .bind(&record.input_entity_ids)
    .bind(parameters)
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .bind(record.created_at)
    .bind(record.superseded_by)
    .execute(&mut **transaction)
    .await?;
    let scope_matches = sqlx::query_scalar::<_, bool>(
        r"
        SELECT EXISTS(
            SELECT 1 FROM provenance_records
            WHERE id = $1 AND artifact_type = $2 AND artifact_id = $3
              AND paper_id = $4 AND generation = $5 AND activity_type = $6
              AND owner_user_id IS NOT DISTINCT FROM $7
              AND anonymous_session_id IS NOT DISTINCT FROM $8
        )
        ",
    )
    .bind(record.id)
    .bind(record.artifact_type.as_str())
    .bind(record.artifact_id)
    .bind(record.paper_id)
    .bind(record.generation)
    .bind(record.activity_type.as_str())
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .fetch_one(&mut **transaction)
    .await?;
    if !scope_matches {
        return Err(DbError::InvalidData(
            "provenance UUID already belongs to another artifact".to_owned(),
        ));
    }
    Ok(())
}

async fn publish_enrichment_ready(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
    capability: EnrichmentCapability,
    artifact_version: &str,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO paper_enrichment_state (
            paper_id, generation, capability, artifact_version, status,
            started_at, completed_at
        )
        VALUES ($1, $2, $3, $4, 'ready', now(), now())
        ON CONFLICT (paper_id, generation, capability, artifact_version) DO UPDATE
        SET status = 'ready', updated_at = now(), completed_at = now(),
            last_error_category = NULL, last_error_code = NULL, last_error_message = NULL
        ",
    )
    .bind(paper_id)
    .bind(generation)
    .bind(capability.as_str())
    .bind(artifact_version)
    .execute(&mut **transaction)
    .await?;
    if let Some(column) = capability.processing_column() {
        let statement = format!(
            "UPDATE paper_processing SET {column} = true, updated_at = now() WHERE paper_id = $1 AND generation = $2"
        );
        let changed = sqlx::query(&statement)
            .bind(paper_id)
            .bind(generation)
            .execute(&mut **transaction)
            .await?
            .rows_affected();
        if changed != 1 {
            return Err(DbError::StaleGeneration);
        }
    }
    Ok(())
}

fn validate_passport_provenance<'a>(
    passport: &PaperPassport,
    records: &'a [ProvenanceRecord],
) -> Result<HashMap<Uuid, &'a ProvenanceRecord>, DbError> {
    let by_id = records
        .iter()
        .map(|record| (record.id, record))
        .collect::<HashMap<_, _>>();
    if by_id.len() != records.len() || by_id.len() != passport.fields.len() + 1 {
        return Err(DbError::InvalidData(
            "Passport provenance set is incomplete or duplicated".to_owned(),
        ));
    }
    let passport_record = by_id
        .get(&passport.provenance_id)
        .ok_or_else(|| DbError::InvalidData("Passport provenance record is missing".to_owned()))?;
    if passport_record.artifact_type != ProvenanceArtifactType::PaperPassport
        || passport_record.activity_type != ProvenanceActivityType::PassportSynthesis
        || passport_record.artifact_id != passport.id
    {
        return Err(DbError::InvalidData(
            "Passport provenance does not match the artifact".to_owned(),
        ));
    }
    for field in &passport.fields {
        let record = by_id.get(&field.provenance_id).ok_or_else(|| {
            DbError::InvalidData("Passport field provenance is missing".to_owned())
        })?;
        if record.artifact_type != ProvenanceArtifactType::PaperPassportField
            || record.activity_type != ProvenanceActivityType::PassportSynthesis
            || record.artifact_id != field.id
            || record.input_entity_ids != field.source_block_ids
        {
            return Err(DbError::InvalidData(
                "Passport field provenance does not match its exact sources".to_owned(),
            ));
        }
    }
    if records.iter().any(|record| {
        record.validate().is_err()
            || record.paper_id != passport.paper_id
            || record.generation != passport.generation
            || record.principal.is_some()
    }) {
        return Err(DbError::InvalidData(
            "Passport provenance scope is invalid".to_owned(),
        ));
    }
    Ok(by_id)
}

async fn insert_feedback_evaluation(
    transaction: &mut Transaction<'_, Postgres>,
    id: Uuid,
    principal: ProvenancePrincipal,
    feedback: &PassportFeedback,
) -> Result<Option<Uuid>, DbError> {
    let (owner_user_id, anonymous_session_id) = principal_columns(principal);
    sqlx::query_scalar::<_, Uuid>(
        r"
        INSERT INTO paper_passport_feedback_evaluations (
            id, operation_id, passport_id, field_id, owner_user_id,
            anonymous_session_id, feedback_type, detail
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT DO NOTHING
        RETURNING id
        ",
    )
    .bind(id)
    .bind(feedback.operation_id)
    .bind(feedback.passport_id)
    .bind(feedback.field_id)
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .bind(feedback.feedback_type.as_str())
    .bind(&feedback.detail)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn existing_feedback_evaluation(
    transaction: &mut Transaction<'_, Postgres>,
    principal: ProvenancePrincipal,
    operation_id: Uuid,
) -> Result<Uuid, DbError> {
    let (owner_user_id, anonymous_session_id) = principal_columns(principal);
    sqlx::query_scalar::<_, Uuid>(
        r"
        SELECT id
        FROM paper_passport_feedback_evaluations
        WHERE operation_id = $1
          AND (($2::uuid IS NOT NULL AND owner_user_id = $2)
            OR ($3::uuid IS NOT NULL AND anonymous_session_id = $3))
        ",
    )
    .bind(operation_id)
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(DbError::from)
}

fn principal_columns(principal: ProvenancePrincipal) -> (Option<Uuid>, Option<Uuid>) {
    match principal {
        ProvenancePrincipal::OwnerUser(id) => (Some(id), None),
        ProvenancePrincipal::AnonymousSession(id) => (None, Some(id)),
    }
}

fn validate_artifact_version(value: &str) -> Result<(), DbError> {
    if value.is_empty()
        || value.len() > 64
        || value.trim() != value
        || !value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
        })
    {
        return Err(DbError::InvalidData(
            "artifact version is invalid".to_owned(),
        ));
    }
    Ok(())
}

fn required_u32(value: i32, field: &str) -> Result<u32, DbError> {
    u32::try_from(value).map_err(|_| DbError::InvalidData(format!("persisted {field} is invalid")))
}

fn invalid_enum(_error: PassportValidationError) -> DbError {
    DbError::InvalidData("persisted enrichment enum is invalid".to_owned())
}

fn invalid_number() -> DbError {
    DbError::InvalidData("numeric enrichment value is out of range".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifact_versions_are_content_free_identifiers() {
        for valid in ["passport-v1", "facets_v2", "grobid.0-8"] {
            validate_artifact_version(valid).unwrap();
        }
        for invalid in ["", "contains spaces", "private/question", "UPPER"] {
            assert!(validate_artifact_version(invalid).is_err());
        }
    }

    #[test]
    fn assistant_principal_maps_to_exactly_one_column() {
        let id = Uuid::now_v7();
        assert_eq!(
            principal_columns(ProvenancePrincipal::OwnerUser(id)),
            (Some(id), None)
        );
        assert_eq!(
            principal_columns(ProvenancePrincipal::AnonymousSession(id)),
            (None, Some(id))
        );
    }
}
