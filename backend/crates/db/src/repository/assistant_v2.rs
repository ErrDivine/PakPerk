use std::collections::HashSet;

use chrono::{DateTime, Utc};
use domain::{
    AssistantAnswer, AssistantClaim, AssistantEvidenceFeedback, AssistantRequest,
    AssistantScopeKind, ChatRole, ChatTurn, PaperId, ProcessingGeneration, ProvenanceActivityType,
    ProvenanceArtifactType, ProvenanceParameters, ProvenancePrincipal, ProvenanceRecord,
    SectionKind,
};
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction};
use uuid::Uuid;

use super::DbError;

pub const ASSISTANT_RETRIEVAL_MAX_BLOCKS: i64 = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AssistantRetentionCleanup {
    pub threads: u64,
    pub provenance_records: u64,
}

#[derive(Debug, Clone)]
pub struct AssistantRetrievalContext {
    pub paper_title: String,
    pub parser_id: String,
    pub parser_version: String,
    pub blocks: Vec<RetrievedAssistantBlock>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssistantSession {
    pub thread_id: Uuid,
    pub recent_turns: Vec<ChatTurn>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantEvidenceFeedbackOutcome {
    Created { feedback_id: Uuid },
    Replayed { feedback_id: Uuid },
    IdempotencyConflict,
    TargetNotFound,
    TargetMismatch,
}

#[derive(Debug, Clone)]
pub struct RetrievedAssistantBlock {
    pub block_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub section_heading: Option<String>,
    pub page_start: Option<u32>,
    pub text: String,
}

#[derive(Clone)]
pub struct AssistantContextRepository {
    pool: PgPool,
}

impl AssistantContextRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Deletes expired private conversations in bounded batches. Assistant
    /// provenance is removed first so no anonymous principal record outlives
    /// the conversation that made it addressable.
    pub async fn cleanup_expired(
        &self,
        batch_size: u32,
    ) -> Result<AssistantRetentionCleanup, DbError> {
        if batch_size == 0 || batch_size > 10_000 {
            return Err(DbError::InvalidData(
                "assistant retention batch size is invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let thread_ids = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT id
            FROM assistant_threads
            WHERE expires_at <= now()
            ORDER BY expires_at, id
            LIMIT $1
            FOR UPDATE SKIP LOCKED
            ",
        )
        .bind(i64::from(batch_size))
        .fetch_all(&mut *transaction)
        .await?;
        if thread_ids.is_empty() {
            transaction.commit().await?;
            return Ok(AssistantRetentionCleanup {
                threads: 0,
                provenance_records: 0,
            });
        }
        let provenance_records = sqlx::query(
            r"
            DELETE FROM provenance_records
            WHERE artifact_type = 'assistant_answer'
              AND id IN (
                  SELECT provenance_id
                  FROM assistant_messages
                  WHERE thread_id = ANY($1) AND provenance_id IS NOT NULL
              )
            ",
        )
        .bind(&thread_ids)
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        let threads = sqlx::query("DELETE FROM assistant_threads WHERE id = ANY($1)")
            .bind(&thread_ids)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
        transaction.commit().await?;
        Ok(AssistantRetentionCleanup {
            threads,
            provenance_records,
        })
    }

    /// Retrieves evidence only from the exact current paper generation and
    /// validates every object/selection scope before returning any text.
    pub async fn retrieve(
        &self,
        request: &AssistantRequest,
    ) -> Result<AssistantRetrievalContext, DbError> {
        request
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let document = self.require_current_document(request).await?;
        let rows = match request.scope.kind {
            AssistantScopeKind::Paper => self.paper_blocks(request).await?,
            AssistantScopeKind::Section => self.section_blocks(request).await?,
            AssistantScopeKind::Selection => self.selection_block(request).await?,
            AssistantScopeKind::Figure
            | AssistantScopeKind::Table
            | AssistantScopeKind::Equation => self.object_blocks(request).await?,
            AssistantScopeKind::PassportField => self.passport_field_blocks(request).await?,
        };
        let blocks = rows
            .into_iter()
            .map(RetrievedAssistantBlockRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        if blocks.is_empty() {
            return Err(DbError::AssistantContextNotReady);
        }
        Ok(AssistantRetrievalContext {
            paper_title: document.paper_title,
            parser_id: document.parser_id,
            parser_version: document.parser_version,
            blocks,
        })
    }

    async fn require_current_document(
        &self,
        request: &AssistantRequest,
    ) -> Result<AssistantDocumentRow, DbError> {
        sqlx::query_as::<_, AssistantDocumentRow>(
            r"
            SELECT
                paper.title AS paper_title,
                document.parser_id,
                document.parser_version
            FROM papers AS paper
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            JOIN document_generations AS document
              ON document.paper_id = processing.paper_id
             AND document.generation = processing.generation
            WHERE paper.id = $1
              AND processing.generation = $2
            ",
        )
        .bind(request.paper_id)
        .bind(request.generation)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| DbError::AssistantContextNotReady)
    }

    /// Opens one bounded, principal-owned thread. Prior messages are context
    /// only and are never returned as evidence.
    pub async fn open_thread(
        &self,
        principal: ProvenancePrincipal,
        request: &AssistantRequest,
    ) -> Result<AssistantSession, DbError> {
        request
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if principal.id().is_nil() {
            return Err(DbError::InvalidData(
                "assistant principal is invalid".to_owned(),
            ));
        }
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let mut transaction = self.pool.begin().await?;
        let current_generation = sqlx::query_scalar::<_, i32>(
            "SELECT generation FROM paper_processing WHERE paper_id = $1 FOR SHARE",
        )
        .bind(request.paper_id)
        .fetch_optional(&mut *transaction)
        .await?;
        if current_generation != Some(request.generation) {
            return Err(DbError::AssistantContextNotReady);
        }
        let thread_id = if let Some(thread_id) = request.thread_id {
            sqlx::query_scalar::<_, Uuid>(
                r"
                SELECT id
                FROM assistant_threads
                WHERE id = $1
                  AND owner_user_id IS NOT DISTINCT FROM $2
                  AND anonymous_session_id IS NOT DISTINCT FROM $3
                  AND paper_id = $4
                  AND generation = $5
                  AND expires_at > now()
                ",
            )
            .bind(thread_id)
            .bind(owner_user_id)
            .bind(anonymous_session_id)
            .bind(request.paper_id)
            .bind(request.generation)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(DbError::InvalidAssistantThread)?
        } else {
            sqlx::query_scalar::<_, Uuid>(
                r"
                INSERT INTO assistant_threads (
                    owner_user_id,
                    anonymous_session_id,
                    paper_id,
                    generation
                )
                VALUES ($1, $2, $3, $4)
                RETURNING id
                ",
            )
            .bind(owner_user_id)
            .bind(anonymous_session_id)
            .bind(request.paper_id)
            .bind(request.generation)
            .fetch_one(&mut *transaction)
            .await?
        };
        let mut rows = sqlx::query_as::<_, AssistantTurnRow>(
            r"
            SELECT role, content
            FROM assistant_messages
            WHERE thread_id = $1
            ORDER BY ordinal DESC
            LIMIT 12
            ",
        )
        .bind(thread_id)
        .fetch_all(&mut *transaction)
        .await?;
        rows.reverse();
        let recent_turns = rows
            .into_iter()
            .map(AssistantTurnRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(AssistantSession {
            thread_id,
            recent_turns,
        })
    }

    /// Persists the user turn, validated answer, and principal-bound
    /// provenance atomically. If this fails, no answer is returned to the
    /// caller and no partial conversation becomes future context.
    #[allow(clippy::too_many_arguments)]
    pub async fn persist_exchange(
        &self,
        principal: ProvenancePrincipal,
        request: &AssistantRequest,
        thread_id: Uuid,
        context: &AssistantRetrievalContext,
        answer: &AssistantAnswer,
        model_provider: &str,
    ) -> Result<Uuid, DbError> {
        AssistantExchangePersistence::try_new(
            principal,
            request,
            thread_id,
            context,
            answer,
            model_provider,
        )?
        .persist(&self.pool)
        .await
    }

    /// Stores one evidence-specific evaluation only when its answer still
    /// belongs to the same principal, paper, and current document generation.
    pub async fn record_evidence_feedback(
        &self,
        principal: ProvenancePrincipal,
        feedback: &AssistantEvidenceFeedback,
    ) -> Result<AssistantEvidenceFeedbackOutcome, DbError> {
        feedback
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if principal.id().is_nil() {
            return Err(DbError::InvalidData(
                "assistant feedback principal is invalid".to_owned(),
            ));
        }
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let mut transaction = self.pool.begin().await?;
        let Some(claims) = load_feedback_target_claims(
            &mut transaction,
            owner_user_id,
            anonymous_session_id,
            feedback,
        )
        .await?
        else {
            transaction.rollback().await?;
            return Ok(AssistantEvidenceFeedbackOutcome::TargetNotFound);
        };
        if !feedback_target_matches(feedback, &claims) {
            transaction.rollback().await?;
            return Ok(AssistantEvidenceFeedbackOutcome::TargetMismatch);
        }

        let feedback_id = insert_evidence_feedback(
            &mut transaction,
            owner_user_id,
            anonymous_session_id,
            feedback,
        )
        .await?;
        if let Some(feedback_id) = feedback_id {
            transaction.commit().await?;
            return Ok(AssistantEvidenceFeedbackOutcome::Created { feedback_id });
        }

        let existing = load_existing_evidence_feedback(
            &mut transaction,
            owner_user_id,
            anonymous_session_id,
            feedback.operation_id,
        )
        .await?;
        transaction.commit().await?;
        let Some(existing) = existing else {
            return Err(DbError::InvalidData(
                "assistant feedback idempotency resolution failed".to_owned(),
            ));
        };
        if existing.matches(feedback) {
            Ok(AssistantEvidenceFeedbackOutcome::Replayed {
                feedback_id: existing.id,
            })
        } else {
            Ok(AssistantEvidenceFeedbackOutcome::IdempotencyConflict)
        }
    }

    /// Looks up private provenance only through the same verified principal
    /// that created it. The caller never queries by an unscoped UUID.
    pub async fn provenance(
        &self,
        principal: ProvenancePrincipal,
        provenance_id: Uuid,
    ) -> Result<Option<ProvenanceRecord>, DbError> {
        if provenance_id.is_nil() || principal.id().is_nil() {
            return Err(DbError::InvalidData(
                "assistant provenance lookup is invalid".to_owned(),
            ));
        }
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let row = sqlx::query_as::<_, AssistantProvenanceRow>(
            r"
            SELECT
                id,
                artifact_type,
                artifact_id,
                paper_id,
                generation,
                activity_type,
                parser_id,
                parser_version,
                model_provider,
                model_id,
                prompt_or_schema_version,
                input_entity_ids,
                parameters,
                created_at,
                superseded_by
            FROM provenance_records
            WHERE id = $1
              AND artifact_type = 'assistant_answer'
              AND owner_user_id IS NOT DISTINCT FROM $2
              AND anonymous_session_id IS NOT DISTINCT FROM $3
            ",
        )
        .bind(provenance_id)
        .bind(owner_user_id)
        .bind(anonymous_session_id)
        .fetch_optional(&self.pool)
        .await?;
        row.map(|row| row.try_into_domain(principal)).transpose()
    }

    async fn paper_blocks(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<RetrievedAssistantBlockRow>, DbError> {
        Ok(sqlx::query_as::<_, RetrievedAssistantBlockRow>(
            r"
            WITH query AS (
                SELECT plainto_tsquery('simple', $3) AS value
            )
            SELECT
                block.id AS block_id,
                block.paper_id,
                block.generation,
                NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                    AS section_heading,
                block.page_start,
                block.text
            FROM document_blocks AS block
            CROSS JOIN query
            WHERE block.paper_id = $1 AND block.generation = $2
            ORDER BY
                ts_rank_cd(to_tsvector('simple', block.text), query.value) DESC,
                block.ordinal
            LIMIT $4
            ",
        )
        .bind(request.paper_id)
        .bind(request.generation)
        .bind(&request.question)
        .bind(ASSISTANT_RETRIEVAL_MAX_BLOCKS)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn section_blocks(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<RetrievedAssistantBlockRow>, DbError> {
        let section_kinds = request
            .scope
            .section_kinds
            .iter()
            .copied()
            .map(section_kind_name)
            .collect::<Vec<_>>();
        Ok(sqlx::query_as::<_, RetrievedAssistantBlockRow>(
            r"
            WITH query AS (
                SELECT plainto_tsquery('simple', $4) AS value
            )
            SELECT
                block.id AS block_id,
                block.paper_id,
                block.generation,
                COALESCE(
                    section.heading,
                    NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                ) AS section_heading,
                block.page_start,
                block.text
            FROM document_blocks AS block
            JOIN paper_sections AS section
              ON section.id = block.section_id
             AND section.paper_id = block.paper_id
             AND section.generation = block.generation
            CROSS JOIN query
            WHERE block.paper_id = $1
              AND block.generation = $2
              AND section.kind = ANY($3::text[])
            ORDER BY
                ts_rank_cd(to_tsvector('simple', block.text), query.value) DESC,
                block.ordinal
            LIMIT $5
            ",
        )
        .bind(request.paper_id)
        .bind(request.generation)
        .bind(&section_kinds)
        .bind(&request.question)
        .bind(ASSISTANT_RETRIEVAL_MAX_BLOCKS)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn passport_field_blocks(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<RetrievedAssistantBlockRow>, DbError> {
        let field_key = request.scope.passport_field.as_deref().ok_or_else(|| {
            DbError::InvalidData("assistant Passport field is missing".to_owned())
        })?;
        Ok(sqlx::query_as::<_, RetrievedAssistantBlockRow>(
            r"
            SELECT
                block.id AS block_id,
                block.paper_id,
                block.generation,
                NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                    AS section_heading,
                block.page_start,
                block.text
            FROM paper_passports AS passport
            JOIN paper_passport_fields AS field
              ON field.passport_id = passport.id
             AND field.paper_id = passport.paper_id
             AND field.generation = passport.generation
            JOIN document_blocks AS block
              ON block.id = ANY(field.source_block_ids)
             AND block.paper_id = field.paper_id
             AND block.generation = field.generation
            WHERE passport.paper_id = $1
              AND passport.generation = $2
              AND passport.superseded_at IS NULL
              AND passport.status IN ('ready', 'partial')
              AND field.field_key = $3
              AND field.status IN ('supported', 'inferred', 'conflicting')
            ORDER BY array_position(field.source_block_ids, block.id), block.ordinal
            LIMIT $4
            ",
        )
        .bind(request.paper_id)
        .bind(request.generation)
        .bind(field_key)
        .bind(ASSISTANT_RETRIEVAL_MAX_BLOCKS)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn selection_block(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<RetrievedAssistantBlockRow>, DbError> {
        let selection = request
            .scope
            .selection
            .as_ref()
            .ok_or_else(|| DbError::InvalidData("assistant selection is missing".to_owned()))?;
        let row =
            sqlx::query_as::<_, RetrievedAssistantBlockRow>(
                r"
            SELECT
                block.id AS block_id,
                block.paper_id,
                block.generation,
                NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                    AS section_heading,
                block.page_start,
                block.text
            FROM document_blocks AS block
            WHERE block.id = $1
              AND block.paper_id = $2
              AND block.generation = $3
              AND $4 >= 0
              AND $5 > $4
              AND $5 <= char_length(block.text)
            ",
            )
            .bind(selection.block_id)
            .bind(request.paper_id)
            .bind(request.generation)
            .bind(i32::try_from(selection.start).map_err(|_| {
                DbError::InvalidData("assistant selection start is too large".to_owned())
            })?)
            .bind(i32::try_from(selection.end).map_err(|_| {
                DbError::InvalidData("assistant selection end is too large".to_owned())
            })?)
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(|| {
                DbError::InvalidData(
                    "assistant selection does not belong to the requested document".to_owned(),
                )
            })?;
        Ok(vec![row])
    }

    async fn object_blocks(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<RetrievedAssistantBlockRow>, DbError> {
        self.require_object_scope(request).await?;
        let object_ids = request
            .scope
            .object_ids
            .iter()
            .map(Uuid::to_string)
            .collect::<Vec<_>>();
        let mut rows = sqlx::query_as::<_, RetrievedAssistantBlockRow>(
            r"
            SELECT
                block.id AS block_id,
                block.paper_id,
                block.generation,
                NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                    AS section_heading,
                block.page_start,
                block.text
            FROM document_blocks AS block
            WHERE block.paper_id = $1
              AND block.generation = $2
              AND EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(block.inline_spans) AS span
                  WHERE span->>'target_id' = ANY($3::text[])
              )
            ORDER BY block.ordinal
            LIMIT $4
            ",
        )
        .bind(request.paper_id)
        .bind(request.generation)
        .bind(&object_ids)
        .bind(ASSISTANT_RETRIEVAL_MAX_BLOCKS)
        .fetch_all(&self.pool)
        .await?;
        if matches!(request.scope.kind, AssistantScopeKind::Equation)
            && rows.len() < usize::try_from(ASSISTANT_RETRIEVAL_MAX_BLOCKS).unwrap_or(10)
        {
            let remaining = ASSISTANT_RETRIEVAL_MAX_BLOCKS.saturating_sub(
                i64::try_from(rows.len()).unwrap_or(ASSISTANT_RETRIEVAL_MAX_BLOCKS),
            );
            let existing = rows.iter().map(|row| row.block_id).collect::<Vec<_>>();
            let equation_context = sqlx::query_as::<_, RetrievedAssistantBlockRow>(
                r"
                SELECT
                    block.id AS block_id,
                    block.paper_id,
                    block.generation,
                    NULLIF(block.section_path[array_length(block.section_path, 1)], '')
                        AS section_heading,
                    block.page_start,
                    block.text
                FROM paper_equations AS equation
                JOIN document_blocks AS block
                  ON block.id = equation.context_block_id
                 AND block.paper_id = equation.paper_id
                 AND block.generation = equation.generation
                WHERE equation.id = ANY($1::uuid[])
                  AND equation.paper_id = $2
                  AND equation.generation = $3
                  AND NOT (block.id = ANY($4::uuid[]))
                ORDER BY block.ordinal
                LIMIT $5
                ",
            )
            .bind(&request.scope.object_ids)
            .bind(request.paper_id)
            .bind(request.generation)
            .bind(&existing)
            .bind(remaining)
            .fetch_all(&self.pool)
            .await?;
            rows.extend(equation_context);
        }
        Ok(rows)
    }

    async fn require_object_scope(&self, request: &AssistantRequest) -> Result<(), DbError> {
        let table = match request.scope.kind {
            AssistantScopeKind::Figure => "paper_figures",
            AssistantScopeKind::Table => "paper_tables",
            AssistantScopeKind::Equation => "paper_equations",
            _ => {
                return Err(DbError::InvalidData(
                    "assistant object scope is invalid".to_owned(),
                ));
            }
        };
        let mut query = QueryBuilder::new("SELECT count(*) FROM ");
        query
            .push(table)
            .push(" WHERE id = ANY($1::uuid[]) AND paper_id = $2 AND generation = $3");
        let count = query
            .build_query_scalar::<i64>()
            .bind(&request.scope.object_ids)
            .bind(request.paper_id)
            .bind(request.generation)
            .fetch_one(&self.pool)
            .await?;
        if usize::try_from(count).ok() != Some(request.scope.object_ids.len()) {
            return Err(DbError::InvalidData(
                "assistant object scope is outside the requested document".to_owned(),
            ));
        }
        Ok(())
    }
}

struct AssistantExchangePersistence<'a> {
    request: &'a AssistantRequest,
    thread_id: Uuid,
    context: &'a AssistantRetrievalContext,
    answer: &'a AssistantAnswer,
    model_provider: &'a str,
    owner_user_id: Option<Uuid>,
    anonymous_session_id: Option<Uuid>,
    input_entity_ids: Vec<Uuid>,
    user_message_id: Uuid,
    answer_message_id: Uuid,
    parameters: serde_json::Value,
}

impl<'a> AssistantExchangePersistence<'a> {
    fn try_new(
        principal: ProvenancePrincipal,
        request: &'a AssistantRequest,
        thread_id: Uuid,
        context: &'a AssistantRetrievalContext,
        answer: &'a AssistantAnswer,
        model_provider: &'a str,
    ) -> Result<Self, DbError> {
        request
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let input_entity_ids = context
            .blocks
            .iter()
            .map(|block| block.block_id)
            .collect::<Vec<_>>();
        let distinct_inputs = input_entity_ids.iter().copied().collect::<HashSet<_>>();
        if principal.id().is_nil()
            || thread_id.is_nil()
            || answer.provenance_id.is_nil()
            || model_provider.trim().is_empty()
            || model_provider.len() > 64
            || context.blocks.is_empty()
            || context.blocks.len() > usize::try_from(ASSISTANT_RETRIEVAL_MAX_BLOCKS).unwrap_or(10)
            || distinct_inputs.len() != input_entity_ids.len()
            || context.blocks.iter().any(|block| {
                block.paper_id != request.paper_id || block.generation != request.generation
            })
        {
            return Err(DbError::InvalidData(
                "assistant exchange is invalid".to_owned(),
            ));
        }
        let (owner_user_id, anonymous_session_id) = principal_columns(principal);
        let parameters = serde_json::json!({
            "abstained": matches!(answer.status, domain::AssistantAnswerStatus::NotFound),
            "claim_count": i64::try_from(answer.claims.len()).unwrap_or(i64::MAX),
            "evidence_count": i64::try_from(input_entity_ids.len()).unwrap_or(i64::MAX),
        });
        Ok(Self {
            request,
            thread_id,
            context,
            answer,
            model_provider,
            owner_user_id,
            anonymous_session_id,
            input_entity_ids,
            user_message_id: Uuid::now_v7(),
            answer_message_id: Uuid::now_v7(),
            parameters,
        })
    }

    async fn persist(self, pool: &PgPool) -> Result<Uuid, DbError> {
        let mut transaction = pool.begin().await?;
        self.lock_current_thread(&mut transaction).await?;
        let next_ordinal = self.next_ordinal(&mut transaction).await?;
        self.insert_provenance(&mut transaction).await?;
        self.insert_messages(&mut transaction, next_ordinal).await?;
        sqlx::query(REFRESH_ASSISTANT_THREAD)
            .bind(self.thread_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(self.answer_message_id)
    }

    async fn lock_current_thread(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
    ) -> Result<(), DbError> {
        let valid_thread = sqlx::query_scalar::<_, Uuid>(LOCK_ASSISTANT_THREAD)
            .bind(self.thread_id)
            .bind(self.owner_user_id)
            .bind(self.anonymous_session_id)
            .bind(self.request.paper_id)
            .bind(self.request.generation)
            .fetch_optional(&mut **transaction)
            .await?;
        if valid_thread.is_some() {
            return Ok(());
        }
        let current_generation = sqlx::query_scalar::<_, i32>(
            "SELECT generation FROM paper_processing WHERE paper_id = $1",
        )
        .bind(self.request.paper_id)
        .fetch_optional(&mut **transaction)
        .await?;
        if current_generation != Some(self.request.generation) {
            return Err(DbError::AssistantContextNotReady);
        }
        Err(DbError::InvalidAssistantThread)
    }

    async fn next_ordinal(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
    ) -> Result<i32, DbError> {
        Ok(sqlx::query_scalar::<_, i32>(
            "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM assistant_messages WHERE thread_id = $1",
        )
        .bind(self.thread_id)
        .fetch_one(&mut **transaction)
        .await?)
    }

    async fn insert_provenance(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
    ) -> Result<(), DbError> {
        sqlx::query(INSERT_ASSISTANT_PROVENANCE)
            .bind(self.answer.provenance_id)
            .bind(self.answer_message_id)
            .bind(self.request.paper_id)
            .bind(self.request.generation)
            .bind(&self.context.parser_id)
            .bind(&self.context.parser_version)
            .bind(self.model_provider)
            .bind(&self.answer.model_id)
            .bind(&self.answer.prompt_version)
            .bind(&self.input_entity_ids)
            .bind(&self.parameters)
            .bind(self.owner_user_id)
            .bind(self.anonymous_session_id)
            .execute(&mut **transaction)
            .await?;
        Ok(())
    }

    async fn insert_messages(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        next_ordinal: i32,
    ) -> Result<(), DbError> {
        sqlx::query(INSERT_ASSISTANT_USER_MESSAGE)
            .bind(self.user_message_id)
            .bind(self.thread_id)
            .bind(next_ordinal)
            .bind(self.request.question.trim())
            .execute(&mut **transaction)
            .await?;
        sqlx::query(INSERT_ASSISTANT_ANSWER_MESSAGE)
            .bind(self.answer_message_id)
            .bind(self.thread_id)
            .bind(next_ordinal.checked_add(1).ok_or_else(|| {
                DbError::InvalidData("assistant thread ordinal overflowed".to_owned())
            })?)
            .bind(&self.answer.answer)
            .bind(self.answer.provenance_id)
            .bind(serde_json::to_value(&self.answer.claims).map_err(|error| {
                DbError::InvalidData(format!("assistant evidence map is invalid: {error}"))
            })?)
            .execute(&mut **transaction)
            .await?;
        Ok(())
    }
}

const LOCK_ASSISTANT_THREAD: &str = r"
    SELECT thread.id
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
      AND thread.paper_id = $4
      AND thread.generation = $5
      AND thread.expires_at > now()
    FOR UPDATE OF thread, processing
    ";

const INSERT_ASSISTANT_PROVENANCE: &str = r"
    INSERT INTO provenance_records (
        id, artifact_type, artifact_id, paper_id, generation, activity_type,
        parser_id, parser_version, model_provider, model_id,
        prompt_or_schema_version, input_entity_ids, parameters,
        owner_user_id, anonymous_session_id
    )
    VALUES (
        $1, 'assistant_answer', $2, $3, $4, 'assistant_generation',
        $5, $6, $7, $8, $9, $10, $11, $12, $13
    )
    ";

const INSERT_ASSISTANT_USER_MESSAGE: &str = r"
    INSERT INTO assistant_messages (id, thread_id, ordinal, role, content)
    VALUES ($1, $2, $3, 'user', $4)
    ";

const INSERT_ASSISTANT_ANSWER_MESSAGE: &str = r"
    INSERT INTO assistant_messages (
        id, thread_id, ordinal, role, content, provenance_id, evidence_map
    )
    VALUES ($1, $2, $3, 'assistant', $4, $5, $6)
    ";

const REFRESH_ASSISTANT_THREAD: &str = r"
    UPDATE assistant_threads
    SET updated_at = now(),
        expires_at = LEAST(created_at + interval '90 days', now() + interval '30 days')
    WHERE id = $1
    ";

const fn principal_columns(principal: ProvenancePrincipal) -> (Option<Uuid>, Option<Uuid>) {
    match principal {
        ProvenancePrincipal::OwnerUser(user_id) => (Some(user_id), None),
        ProvenancePrincipal::AnonymousSession(session_id) => (None, Some(session_id)),
    }
}

#[derive(Debug, FromRow)]
struct AssistantDocumentRow {
    paper_title: String,
    parser_id: String,
    parser_version: String,
}

#[derive(Debug, FromRow)]
struct AssistantFeedbackTargetRow {
    evidence_map: serde_json::Value,
}

async fn load_feedback_target_claims(
    transaction: &mut Transaction<'_, Postgres>,
    owner_user_id: Option<Uuid>,
    anonymous_session_id: Option<Uuid>,
    feedback: &AssistantEvidenceFeedback,
) -> Result<Option<Vec<AssistantClaim>>, DbError> {
    let target = sqlx::query_as::<_, AssistantFeedbackTargetRow>(
        r"
        SELECT message.evidence_map
        FROM assistant_messages AS message
        JOIN assistant_threads AS thread ON thread.id = message.thread_id
        JOIN paper_processing AS processing
          ON processing.paper_id = thread.paper_id
         AND processing.generation = thread.generation
        JOIN document_generations AS document
          ON document.paper_id = thread.paper_id
         AND document.generation = thread.generation
        WHERE message.id = $1
          AND message.thread_id = $2
          AND message.provenance_id = $3
          AND message.role = 'assistant'
          AND thread.paper_id = $4
          AND thread.generation = $5
          AND thread.owner_user_id IS NOT DISTINCT FROM $6
          AND thread.anonymous_session_id IS NOT DISTINCT FROM $7
          AND thread.expires_at > now()
        FOR SHARE OF message, thread, processing
        ",
    )
    .bind(feedback.response_id)
    .bind(feedback.thread_id)
    .bind(feedback.provenance_id)
    .bind(feedback.paper_id)
    .bind(feedback.generation)
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .fetch_optional(&mut **transaction)
    .await?;
    target
        .map(|target| {
            serde_json::from_value(target.evidence_map).map_err(|error| {
                DbError::InvalidData(format!("invalid assistant evidence map: {error}"))
            })
        })
        .transpose()
}

async fn insert_evidence_feedback(
    transaction: &mut Transaction<'_, Postgres>,
    owner_user_id: Option<Uuid>,
    anonymous_session_id: Option<Uuid>,
    feedback: &AssistantEvidenceFeedback,
) -> Result<Option<Uuid>, DbError> {
    sqlx::query_scalar(
        r"
        INSERT INTO assistant_evidence_feedback_evaluations (
            operation_id, thread_id, response_id, provenance_id,
            paper_id, generation, owner_user_id, anonymous_session_id,
            feedback_type, claim_index, evidence_block_id, detail
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        ON CONFLICT DO NOTHING
        RETURNING id
        ",
    )
    .bind(feedback.operation_id)
    .bind(feedback.thread_id)
    .bind(feedback.response_id)
    .bind(feedback.provenance_id)
    .bind(feedback.paper_id)
    .bind(feedback.generation)
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .bind(feedback.feedback_type.as_str())
    .bind(feedback.claim_index.map(i16::from))
    .bind(feedback.evidence_block_id)
    .bind(&feedback.detail)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(Into::into)
}

#[derive(Debug, FromRow)]
struct AssistantFeedbackIdempotencyRow {
    id: Uuid,
    thread_id: Uuid,
    response_id: Uuid,
    provenance_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    feedback_type: String,
    claim_index: Option<i16>,
    evidence_block_id: Option<Uuid>,
    detail: Option<String>,
}

async fn load_existing_evidence_feedback(
    transaction: &mut Transaction<'_, Postgres>,
    owner_user_id: Option<Uuid>,
    anonymous_session_id: Option<Uuid>,
    operation_id: Uuid,
) -> Result<Option<AssistantFeedbackIdempotencyRow>, DbError> {
    sqlx::query_as(
        r"
        SELECT
            id, thread_id, response_id, provenance_id, paper_id,
            generation, feedback_type, claim_index,
            evidence_block_id, detail
        FROM assistant_evidence_feedback_evaluations
        WHERE owner_user_id IS NOT DISTINCT FROM $1
          AND anonymous_session_id IS NOT DISTINCT FROM $2
          AND operation_id = $3
        ",
    )
    .bind(owner_user_id)
    .bind(anonymous_session_id)
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(Into::into)
}

impl AssistantFeedbackIdempotencyRow {
    fn matches(&self, feedback: &AssistantEvidenceFeedback) -> bool {
        self.thread_id == feedback.thread_id
            && self.response_id == feedback.response_id
            && self.provenance_id == feedback.provenance_id
            && self.paper_id == feedback.paper_id
            && self.generation == feedback.generation
            && self.feedback_type == feedback.feedback_type.as_str()
            && self.claim_index == feedback.claim_index.map(i16::from)
            && self.evidence_block_id == feedback.evidence_block_id
            && self.detail == feedback.detail
    }
}

fn feedback_target_matches(
    feedback: &AssistantEvidenceFeedback,
    claims: &[AssistantClaim],
) -> bool {
    let Some(claim_index) = feedback.claim_index else {
        return true;
    };
    let Some(claim) = claims.get(usize::from(claim_index)) else {
        return false;
    };
    feedback.evidence_block_id.is_none_or(|block_id| {
        claim
            .evidence
            .iter()
            .any(|evidence| evidence.block_id == block_id)
    })
}

#[derive(Debug, FromRow)]
struct AssistantTurnRow {
    role: String,
    content: String,
}

impl AssistantTurnRow {
    fn try_into_domain(self) -> Result<ChatTurn, DbError> {
        let role = match self.role.as_str() {
            "user" => ChatRole::User,
            "assistant" => ChatRole::Assistant,
            _ => {
                return Err(DbError::InvalidData(
                    "persisted assistant message role is invalid".to_owned(),
                ));
            }
        };
        if self.content.trim().is_empty() || self.content.chars().count() > 32_000 {
            return Err(DbError::InvalidData(
                "persisted assistant message content is invalid".to_owned(),
            ));
        }
        Ok(ChatTurn {
            role,
            content: self.content,
        })
    }
}

#[derive(Debug, FromRow)]
struct AssistantProvenanceRow {
    id: Uuid,
    artifact_type: String,
    artifact_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    activity_type: String,
    parser_id: Option<String>,
    parser_version: Option<String>,
    model_provider: Option<String>,
    model_id: Option<String>,
    prompt_or_schema_version: Option<String>,
    input_entity_ids: Vec<Uuid>,
    parameters: serde_json::Value,
    created_at: DateTime<Utc>,
    superseded_by: Option<Uuid>,
}

impl AssistantProvenanceRow {
    fn try_into_domain(self, principal: ProvenancePrincipal) -> Result<ProvenanceRecord, DbError> {
        let record = ProvenanceRecord {
            id: self.id,
            artifact_type: ProvenanceArtifactType::try_from(self.artifact_type.as_str())
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            artifact_id: self.artifact_id,
            paper_id: self.paper_id,
            generation: self.generation,
            activity_type: ProvenanceActivityType::try_from(self.activity_type.as_str())
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            parser_id: self.parser_id,
            parser_version: self.parser_version,
            model_provider: self.model_provider,
            model_id: self.model_id,
            prompt_or_schema_version: self.prompt_or_schema_version,
            input_entity_ids: self.input_entity_ids,
            parameters: serde_json::from_value::<ProvenanceParameters>(self.parameters)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            principal: Some(principal),
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
struct RetrievedAssistantBlockRow {
    block_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    section_heading: Option<String>,
    page_start: Option<i32>,
    text: String,
}

impl RetrievedAssistantBlockRow {
    fn try_into_domain(self) -> Result<RetrievedAssistantBlock, DbError> {
        if self.block_id.is_nil()
            || self.paper_id.is_nil()
            || self.generation <= 0
            || self.text.trim().is_empty()
            || self.text.chars().count() > 1_000_000
        {
            return Err(DbError::InvalidData(
                "persisted assistant source block is invalid".to_owned(),
            ));
        }
        Ok(RetrievedAssistantBlock {
            block_id: self.block_id,
            paper_id: self.paper_id,
            generation: self.generation,
            section_heading: self.section_heading,
            page_start: self
                .page_start
                .map(u32::try_from)
                .transpose()
                .map_err(|_| DbError::InvalidData("persisted source page is invalid".to_owned()))?,
            text: self.text,
        })
    }
}

const fn section_kind_name(value: SectionKind) -> &'static str {
    match value {
        SectionKind::Abstract => "abstract",
        SectionKind::Introduction => "introduction",
        SectionKind::Background => "background",
        SectionKind::RelatedWork => "related_work",
        SectionKind::Method => "method",
        SectionKind::Experiment => "experiment",
        SectionKind::Result => "result",
        SectionKind::Discussion => "discussion",
        SectionKind::Limitation => "limitation",
        SectionKind::Conclusion => "conclusion",
        SectionKind::Appendix => "appendix",
        SectionKind::Acknowledgment => "acknowledgment",
        SectionKind::References => "references",
        SectionKind::Other => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::{
        AssistantClaimSupport, AssistantEvidenceFeedbackType, AssistantEvidenceReference,
    };

    fn feedback(
        feedback_type: AssistantEvidenceFeedbackType,
        claim_index: Option<u8>,
        evidence_block_id: Option<Uuid>,
    ) -> AssistantEvidenceFeedback {
        AssistantEvidenceFeedback {
            operation_id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 2,
            thread_id: Uuid::now_v7(),
            response_id: Uuid::now_v7(),
            provenance_id: Uuid::now_v7(),
            feedback_type,
            claim_index,
            evidence_block_id,
            detail: Some("The source range points to a different result.".to_owned()),
        }
    }

    #[test]
    fn evidence_feedback_target_must_exist_in_the_persisted_claim_map() {
        let block_id = Uuid::now_v7();
        let claims = vec![AssistantClaim {
            text: "Supported claim".to_owned(),
            support: AssistantClaimSupport::Direct,
            evidence: vec![AssistantEvidenceReference {
                block_id,
                start: 0,
                end: 9,
                page_start: Some(2),
                section: Some("Results".to_owned()),
            }],
        }];
        assert!(feedback_target_matches(
            &feedback(
                AssistantEvidenceFeedbackType::IncorrectCitation,
                Some(0),
                Some(block_id),
            ),
            &claims,
        ));
        assert!(!feedback_target_matches(
            &feedback(
                AssistantEvidenceFeedbackType::IncorrectCitation,
                Some(0),
                Some(Uuid::now_v7()),
            ),
            &claims,
        ));
        assert!(!feedback_target_matches(
            &feedback(
                AssistantEvidenceFeedbackType::IncorrectSupportLabel,
                Some(1),
                None,
            ),
            &claims,
        ));
        assert!(feedback_target_matches(
            &feedback(AssistantEvidenceFeedbackType::MissingEvidence, None, None),
            &claims,
        ));
    }

    #[test]
    fn evidence_feedback_idempotency_compares_every_mutable_field() {
        let value = feedback(AssistantEvidenceFeedbackType::MissingEvidence, None, None);
        let row = AssistantFeedbackIdempotencyRow {
            id: Uuid::now_v7(),
            thread_id: value.thread_id,
            response_id: value.response_id,
            provenance_id: value.provenance_id,
            paper_id: value.paper_id,
            generation: value.generation,
            feedback_type: value.feedback_type.as_str().to_owned(),
            claim_index: None,
            evidence_block_id: None,
            detail: value.detail.clone(),
        };
        assert!(row.matches(&value));
        let mut changed = value;
        changed.detail = Some("Different private correction.".to_owned());
        assert!(!row.matches(&changed));
    }
}
