use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, Annotation, AnnotationAnchorStatus, AnnotationColorRole, AnnotationConflict,
    AnnotationConflictResolution, AnnotationKind, AnnotationWrite, AuthenticatedUserId,
    EvidenceCard, EvidenceCardWrite, EvidenceVerificationStatus, MemoryItem, MemoryItemWrite,
    MemorySourceType, MemoryStatus, PaperId, ReaderMode, ReaderStage, ReadingCheckpoint,
    ReadingCheckpointWrite, ReanchorBlock, ReanchorStrategy, TextQuotePositionSelector,
    reanchor_annotation,
};
use opaque_cursor::OpaqueCursorCodec;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::{
    DbError,
    library::{advisory_lock, begin_consistent_read, lock_account_status},
};

const ANNOTATION_PAGE_MAX: u32 = 500;
const RESEARCH_PAGE_DEFAULT: u32 = 50;
const RESEARCH_PAGE_MAX: u32 = 200;
const RESEARCH_CURSOR_MAX_BYTES: usize = 2_048;
const EVIDENCE_CURSOR_PURPOSE: &str = "research.evidence.v1";
const MEMORY_CURSOR_PURPOSE: &str = "research.memory.v1";
const ANNOTATION_CONFLICT_CURSOR_PURPOSE: &str = "research.annotation-conflict.v1";
const RESEARCH_EXPORT_CURSOR_PURPOSE: &str = "research.export.v1";
const REANCHOR_BLOCK_MAX: i64 = 20_000;
const REANCHOR_DOCUMENT_SCALAR_MAX: i64 = 8_000_000;
const REANCHOR_TARGET_PAGE_MAX: u32 = 500;
const EXPORT_ARTIFACT_MAX: i64 = 5_000;
const EXPORT_PRIVATE_SCALAR_MAX: i64 = 2_000_000;
const EXPORT_SOURCE_QUOTE_SCALAR_MAX: i64 = 250_000;
const EXPORT_PRIVATE_BYTE_MAX: i64 = 2_000_000;
const EXPORT_SOURCE_QUOTE_BYTE_MAX: i64 = 250_000;
const EXPORT_MANIFEST_PAPER_MAX: i64 = 5_000;
const ANNOTATION_IMPORT_MAX: usize = 5_000;
const ANNOTATION_IMPORT_CONFLICT_MAX: usize = 10_000;
const ANNOTATION_IMPORT_REANCHOR_MAX: usize = 20_000;

#[derive(Clone)]
pub struct ResearchMemoryRepository {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

#[derive(Clone, PartialEq)]
pub enum ResearchMutationOutcome<T> {
    Applied { value: T, replayed: bool },
    AnnotationConflict(AnnotationConflict),
    AccountNotFound,
    Inactive(AccountStatus),
    PaperNotFound,
    ArtifactNotFound,
    StaleGeneration,
    RevisionConflict { current_revision: i64 },
    IdempotencyConflict,
}

#[derive(Clone, PartialEq)]
pub enum ResearchReadOutcome<T> {
    Found(T),
    AccountNotFound,
    Inactive(AccountStatus),
    InvalidRevision,
    InvalidCursor,
    ExportTooLarge {
        artifact_count: i64,
        private_scalar_count: i64,
        source_quote_scalar_count: i64,
        private_byte_count: i64,
        source_quote_byte_count: i64,
    },
}

#[derive(Clone, PartialEq)]
pub enum ResearchAnnotationImportOutcome {
    Applied {
        result: ResearchAnnotationImportResult,
        replayed: bool,
    },
    AccountNotFound,
    Inactive(AccountStatus),
    IdempotencyConflict,
    ArtifactCollision,
    SourceUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ResearchAnnotationImportResult {
    pub imported_annotations: i32,
    pub imported_conflicts: i32,
    pub imported_reanchor_attempts: i32,
    pub skipped_annotations: i32,
}

/// The annotation-bearing subset of `pakperk.research-export.v1`.
///
/// Serde deliberately ignores the export's unrelated research sections: the
/// `/v1/annotations/import` surface restores only annotations and their exact
/// private conflict/re-anchor history and reports that scope explicitly.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResearchAnnotationImport {
    pub schema_version: String,
    #[serde(default)]
    pub annotations: Vec<Annotation>,
    #[serde(default)]
    pub annotation_conflicts: Vec<AnnotationConflict>,
    #[serde(default)]
    pub annotation_reanchor_attempts: Vec<StoredReanchorAttempt>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct StoredAnnotationPage {
    pub items: Vec<Annotation>,
    pub next_after_revision: i64,
    pub has_more: bool,
    pub sync_revision: i64,
    pub purged_through_revision: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub struct StoredAnnotationConflict {
    pub conflict: AnnotationConflict,
    pub paper_id: PaperId,
    pub current_annotation_revision: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub struct StoredAnnotationConflictPage {
    pub items: Vec<StoredAnnotationConflict>,
    pub next_cursor: Option<String>,
    pub sync_revision: i64,
}

#[derive(Clone, PartialEq)]
pub struct StoredCheckpoints {
    pub items: Vec<ReadingCheckpoint>,
    pub sync_revision: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub struct StoredEvidenceCardPage {
    pub items: Vec<EvidenceCard>,
    pub next_cursor: Option<String>,
    pub sync_revision: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub struct StoredMemoryPage {
    pub items: Vec<MemoryItem>,
    pub next_cursor: Option<String>,
    pub sync_revision: i64,
}

/// One principal-scoped annotation that has not yet been considered for a
/// published document generation. The worker receives only identifiers and a
/// revision; private annotation text remains inside the transactional
/// re-anchoring boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, FromRow)]
pub struct PendingAnnotationReanchor {
    pub user_id: Uuid,
    pub annotation_id: Uuid,
    pub base_revision: i64,
}

/// Re-anchor mutation plus content-free worker-observability dimensions. The
/// annotation remains the private mutation result and must never become a
/// label; only the closed strategy/result fields are safe metric dimensions.
#[derive(Clone, PartialEq)]
pub struct ObservedAnnotationReanchor {
    pub annotation: Annotation,
    pub strategy: Option<ReanchorStrategy>,
    pub result: AnnotationAnchorStatus,
}

#[derive(Clone, PartialEq, Serialize)]
pub struct ResearchArtifactExport {
    pub schema_version: &'static str,
    pub exported_at: DateTime<Utc>,
    pub annotations: Vec<Annotation>,
    pub annotation_conflicts: Vec<AnnotationConflict>,
    pub annotation_reanchor_attempts: Vec<StoredReanchorAttempt>,
    pub evidence_cards: Vec<EvidenceCard>,
    pub reading_checkpoints: Vec<ReadingCheckpoint>,
    pub memory_items: Vec<MemoryItem>,
    pub assistant_threads: Vec<ResearchExportAssistantThread>,
    pub assistant_messages: Vec<ResearchExportAssistantMessage>,
    pub assistant_evidence_feedback: Vec<ResearchExportAssistantEvidenceFeedback>,
    pub private_provenance: Vec<ResearchExportPrivateProvenance>,
    pub library_items: Vec<ResearchExportLibraryItem>,
    pub papers: Vec<ResearchExportPaper>,
}

#[derive(Clone, PartialEq)]
pub struct ResearchArtifactExportPage {
    pub export: ResearchArtifactExport,
    pub artifact_kind: Option<&'static str>,
    pub page_number: u32,
    pub next_cursor: Option<String>,
    pub snapshot_at: DateTime<Utc>,
}

#[derive(Clone, PartialEq, Eq, Serialize, FromRow)]
pub struct ResearchExportAssistantThread {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, PartialEq, Eq, Serialize, FromRow)]
pub struct ResearchExportAssistantMessage {
    pub id: Uuid,
    pub thread_id: Uuid,
    pub ordinal: i32,
    pub role: String,
    pub content: String,
    pub provenance_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, PartialEq, Eq, Serialize, FromRow)]
pub struct ResearchExportAssistantEvidenceFeedback {
    pub id: Uuid,
    pub operation_id: Uuid,
    pub thread_id: Uuid,
    pub response_id: Uuid,
    pub provenance_id: Uuid,
    pub paper_id: PaperId,
    pub generation: i32,
    pub feedback_type: String,
    pub claim_index: Option<i16>,
    pub evidence_block_id: Option<Uuid>,
    pub detail: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, PartialEq, Serialize, FromRow)]
pub struct ResearchExportPrivateProvenance {
    pub id: Uuid,
    pub artifact_type: String,
    pub artifact_id: Uuid,
    pub paper_id: Option<PaperId>,
    pub generation: Option<i32>,
    pub activity_type: String,
    pub parser_id: Option<String>,
    pub parser_version: Option<String>,
    pub model_provider: Option<String>,
    pub model_id: Option<String>,
    pub prompt_or_schema_version: Option<String>,
    pub input_entity_ids: Vec<Uuid>,
    pub parameters: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub superseded_by: Option<Uuid>,
}

#[derive(Clone, PartialEq, Eq, Serialize, FromRow)]
pub struct ResearchExportLibraryItem {
    pub paper_id: PaperId,
    pub state: String,
    pub private_note: Option<String>,
    pub save_source_kind: Option<String>,
    pub reminder_at: Option<DateTime<Utc>>,
    pub reviewed_at: Option<DateTime<Utc>>,
    pub archived_at: Option<DateTime<Utc>>,
    pub saved_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub removed_at: Option<DateTime<Utc>>,
    pub revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResearchExportManifest {
    pub schema_version: &'static str,
    pub generated_at: DateTime<Utc>,
    pub papers: Vec<ResearchExportManifestPaper>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, FromRow)]
pub struct ResearchExportManifestPaper {
    pub paper_id: PaperId,
    pub title: String,
    pub arxiv_base_id: String,
    pub artifact_count: i64,
    pub private_scalar_count: i64,
    pub source_quote_scalar_count: i64,
    pub private_byte_count: i64,
    pub source_quote_byte_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResearchExportPaper {
    pub paper_id: PaperId,
    pub arxiv_base_id: String,
    pub arxiv_version: i32,
    pub title: String,
    pub authors: serde_json::Value,
    pub doi: Option<String>,
    pub journal_reference: Option<String>,
    pub original_url: String,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StoredReanchorAttempt {
    pub id: Uuid,
    pub annotation_id: Uuid,
    pub operation_id: Uuid,
    pub paper_id: PaperId,
    pub from_generation: i32,
    pub to_generation: i32,
    pub source_block_id: Option<Uuid>,
    pub source_stable_key: Option<String>,
    pub source_selector: TextQuotePositionSelector,
    pub strategy: Option<ReanchorStrategy>,
    pub result: AnnotationAnchorStatus,
    pub target_block_id: Option<Uuid>,
    pub target_start: Option<u32>,
    pub target_end: Option<u32>,
    pub similarity: Option<f32>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResearchPageCursor {
    sort_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
    id: Uuid,
    sync_revision: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AnnotationConflictPageCursor {
    after_created_at: DateTime<Utc>,
    after_id: Uuid,
    snapshot_created_at: DateTime<Utc>,
    snapshot_id: Uuid,
    sync_revision: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResearchExportPageCursor {
    kind: i16,
    sort_at: DateTime<Utc>,
    id: Uuid,
    snapshot_at: DateTime<Utc>,
    page_number: u32,
}

impl ResearchMemoryRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    /// Lists a bounded, stable page of active-principal annotations that still
    /// need one conservative re-anchoring attempt for `to_generation`.
    ///
    /// Attempts already recorded for that target generation are excluded so a
    /// fuzzy/uncertain result is never retried into a silent move by a worker
    /// replay. The actual private selector is loaded only by
    /// [`Self::reanchor_annotation`] under the principal lock.
    pub async fn pending_annotation_reanchors(
        &self,
        paper_id: PaperId,
        to_generation: i32,
        after: Option<(Uuid, Uuid)>,
        limit: u32,
    ) -> Result<Vec<PendingAnnotationReanchor>, DbError> {
        if paper_id.is_nil()
            || to_generation <= 1
            || !(1..=REANCHOR_TARGET_PAGE_MAX).contains(&limit)
            || after
                .is_some_and(|(user_id, annotation_id)| user_id.is_nil() || annotation_id.is_nil())
        {
            return Err(DbError::InvalidData(
                "annotation reanchor page scope is invalid".to_owned(),
            ));
        }
        let (after_user_id, after_annotation_id) = after.unzip();
        sqlx::query_as::<_, PendingAnnotationReanchor>(
            r"
            SELECT annotation.user_id,
                   annotation.id AS annotation_id,
                   annotation.revision AS base_revision
            FROM annotations AS annotation
            INNER JOIN users AS principal
                    ON principal.id = annotation.user_id
                   AND principal.status = 'active'
            WHERE annotation.paper_id = $1
              AND annotation.generation < $2
              AND annotation.deleted_at IS NULL
              AND annotation.quote_exact IS NOT NULL
              AND (
                    $3::uuid IS NULL
                    OR (annotation.user_id, annotation.id) > ($3, $4)
                  )
              AND NOT EXISTS (
                    SELECT 1
                    FROM annotation_reanchor_attempts AS attempt
                    WHERE attempt.user_id = annotation.user_id
                      AND attempt.annotation_id = annotation.id
                      AND attempt.to_generation = $2
                  )
            ORDER BY annotation.user_id, annotation.id
            LIMIT $5
            ",
        )
        .bind(paper_id)
        .bind(to_generation)
        .bind(after_user_id)
        .bind(after_annotation_id)
        .bind(i64::from(limit))
        .fetch_all(&self.pool)
        .await
        .map_err(Into::into)
    }

    pub(super) const fn with_cursor_codec(
        pool: PgPool,
        cursor_codec: Option<OpaqueCursorCodec>,
    ) -> Self {
        Self { pool, cursor_codec }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Idempotent optimistic annotation upsert. A stale body edit is written
    /// to `annotation_conflicts` before returning; it is never collapsed into
    /// last-write-wins behavior.
    pub async fn put_annotation(
        &self,
        user_id: AuthenticatedUserId,
        write: &AnnotationWrite,
    ) -> Result<ResearchMutationOutcome<Annotation>, DbError> {
        self.put_annotation_resolving(user_id, write, None).await
    }

    /// Applies an annotation write and optionally resolves one retained body
    /// conflict in the same transaction. The conflict must belong to this
    /// principal and annotation, while the write must target the annotation's
    /// current optimistic revision. A conflict's server revision is retained
    /// as historical archive metadata and can differ after an import.
    #[allow(clippy::too_many_lines)]
    pub async fn put_annotation_resolving(
        &self,
        user_id: AuthenticatedUserId,
        write: &AnnotationWrite,
        resolves_conflict_id: Option<Uuid>,
    ) -> Result<ResearchMutationOutcome<Annotation>, DbError> {
        write
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if resolves_conflict_id == Some(Uuid::nil()) {
            return Err(DbError::InvalidData(
                "resolved conflict ID must not be nil".to_owned(),
            ));
        }
        let Some(block_id) = write.block_id else {
            return Err(DbError::InvalidData(
                "a new annotation write requires a trusted block anchor".to_owned(),
            ));
        };
        let request_hash = if let Some(conflict_id) = resolves_conflict_id {
            canonical_request_hash("put_annotation_resolving", &(write, conflict_id))?
        } else {
            canonical_request_hash("put_annotation", write)?
        };
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            write.operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-annotation", user_id, write.id).await?;

        if let Some(operation) =
            load_operation(&mut transaction, user_id, write.operation_id).await?
        {
            if !operation.matches("annotation", write.id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let annotation = load_annotation(&mut transaction, user_id, write.id, false)
                .await?
                .ok_or_else(|| invalid_replay("annotation"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: annotation,
                replayed: true,
            });
        }
        if let Some(conflict) =
            load_conflict_by_operation(&mut transaction, user_id, write.operation_id).await?
        {
            if conflict.annotation_id != write.id || conflict.request_hash != request_hash {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::AnnotationConflict(
                AnnotationConflict::try_from(conflict)?,
            ));
        }

        let existing = load_annotation(&mut transaction, user_id, write.id, true).await?;
        if existing.is_none() && write.base_revision != 0 {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        let mut manual_reanchor_source = None;
        if let Some(existing) = &existing {
            if existing.deleted_at.is_some() {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            }
            if existing.revision != write.base_revision {
                // Preserve an edited private body even when a concurrent
                // re-anchor changed the canonical source scope. The attempted
                // selector is never trusted or applied on this path; only the
                // two bodies are retained for explicit user resolution.
                if annotation_has_body_conflict(existing, write) {
                    let conflict = persist_annotation_conflict(
                        &mut transaction,
                        user_id,
                        existing,
                        write,
                        &request_hash,
                    )
                    .await?;
                    transaction.commit().await?;
                    return Ok(ResearchMutationOutcome::AnnotationConflict(conflict));
                }
                if !annotation_scope_matches(existing, write)
                    || !annotation_stale_highlight_merge_allowed(existing, write)
                {
                    return Ok(ResearchMutationOutcome::RevisionConflict {
                        current_revision: existing.revision,
                    });
                }
            } else if !annotation_scope_matches(existing, write) {
                if manual_reanchor_allowed(existing, write) {
                    manual_reanchor_source = Some(existing.clone());
                } else {
                    return Ok(ResearchMutationOutcome::ArtifactNotFound);
                }
            }
        }

        let conflict_resolution = if let Some(conflict_id) = resolves_conflict_id {
            let conflict = sqlx::query_as::<_, (Option<String>, Option<String>)>(
                r"
                SELECT attempted_body, server_body
                FROM annotation_conflicts
                WHERE user_id = $1
                  AND id = $2
                  AND annotation_id = $3
                  AND resolved_at IS NULL
                FOR UPDATE
                ",
            )
            .bind(user_id.into_inner())
            .bind(conflict_id)
            .bind(write.id)
            .fetch_optional(&mut *transaction)
            .await?;
            let Some((attempted_body, server_body)) = conflict else {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            };
            let resolution = if write.body == server_body {
                AnnotationConflictResolution::KeepServer
            } else if write.body == attempted_body {
                AnnotationConflictResolution::KeepAttempted
            } else {
                AnnotationConflictResolution::Merged
            };
            Some((conflict_id, resolution))
        } else {
            None
        };

        let Some(block_text) =
            current_block_text(&mut transaction, write.paper_id, write.generation, block_id)
                .await?
        else {
            return classify_missing_paper_or_generation(
                &mut transaction,
                write.paper_id,
                write.generation,
            )
            .await;
        };
        write
            .selector
            .validate_against(&block_text)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if manual_reanchor_source.is_some()
            && !matches!(
                (write.selector.start, write.selector.end),
                (Some(_), Some(_))
            )
        {
            return Err(DbError::InvalidData(
                "a manual annotation reanchor requires exact target offsets".to_owned(),
            ));
        }

        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            write.operation_id,
            revision,
            "annotation",
            write.id,
            &request_hash,
        )
        .await?;
        if let Some(source) = &manual_reanchor_source {
            insert_manual_reanchor_attempt(
                &mut transaction,
                user_id,
                source,
                write.operation_id,
                write.generation,
                block_id,
                &write.selector,
            )
            .await?;
        }
        let row = sqlx::query_as::<_, AnnotationRow>(
            r"
            INSERT INTO annotations (
                id, user_id, paper_id, generation, block_id, kind, body, color_role,
                quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                section_hint, page_hint, anchor_status, revision, last_operation_id,
                deleted_at, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8,
                $9, $10, $11, $12, $13, $14, $15, 'anchored', $16, $17,
                NULL, statement_timestamp(), statement_timestamp()
            )
            ON CONFLICT (user_id, id) DO UPDATE
            SET paper_id = EXCLUDED.paper_id,
                generation = EXCLUDED.generation,
                block_id = EXCLUDED.block_id,
                kind = EXCLUDED.kind,
                body = EXCLUDED.body,
                color_role = EXCLUDED.color_role,
                quote_exact = EXCLUDED.quote_exact,
                quote_prefix = EXCLUDED.quote_prefix,
                quote_suffix = EXCLUDED.quote_suffix,
                start_offset = EXCLUDED.start_offset,
                end_offset = EXCLUDED.end_offset,
                section_hint = EXCLUDED.section_hint,
                page_hint = EXCLUDED.page_hint,
                anchor_status = 'anchored',
                revision = EXCLUDED.revision,
                last_operation_id = EXCLUDED.last_operation_id,
                deleted_at = NULL,
                updated_at = statement_timestamp()
            RETURNING
                id, paper_id, generation, block_id, kind, body, color_role,
                quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                section_hint, page_hint, anchor_status, revision, deleted_at,
                created_at, updated_at
            ",
        )
        .bind(write.id)
        .bind(user_id.into_inner())
        .bind(write.paper_id)
        .bind(write.generation)
        .bind(block_id)
        .bind(annotation_kind_name(write.kind))
        .bind(write.body.as_deref())
        .bind(write.color_role.map(annotation_color_name))
        .bind(&write.selector.exact)
        .bind(write.selector.prefix.as_deref())
        .bind(write.selector.suffix.as_deref())
        .bind(write.selector.start.map(u32_to_i32).transpose()?)
        .bind(write.selector.end.map(u32_to_i32).transpose()?)
        .bind(&write.section_hint)
        .bind(write.page_hint.map(u32_to_i32).transpose()?)
        .bind(revision)
        .bind(write.operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        if let Some((conflict_id, resolution)) = conflict_resolution {
            let updated = sqlx::query(
                r"
                UPDATE annotation_conflicts
                SET resolution = $4,
                    merged_body = $5,
                    resolved_at = statement_timestamp()
                WHERE user_id = $1
                  AND id = $2
                  AND annotation_id = $3
                  AND resolved_at IS NULL
                ",
            )
            .bind(user_id.into_inner())
            .bind(conflict_id)
            .bind(write.id)
            .bind(annotation_conflict_resolution_name(resolution))
            .bind(
                (resolution == AnnotationConflictResolution::Merged)
                    .then_some(write.body.as_deref())
                    .flatten(),
            )
            .execute(&mut *transaction)
            .await?;
            if updated.rows_affected() != 1 {
                return Err(invalid_persisted("annotation conflict resolution race"));
            }
        }
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: Annotation::try_from(row)?,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_lines)]
    pub async fn delete_annotation(
        &self,
        user_id: AuthenticatedUserId,
        annotation_id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
    ) -> Result<ResearchMutationOutcome<Annotation>, DbError> {
        if annotation_id.is_nil() || operation_id.is_nil() || base_revision <= 0 {
            return Err(DbError::InvalidData(
                "annotation delete identifiers and revision are invalid".to_owned(),
            ));
        }
        let request_hash = canonical_request_hash(
            "delete_annotation",
            &(annotation_id, operation_id, base_revision),
        )?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            operation_id,
        )
        .await?;
        advisory_lock(
            &mut transaction,
            "research-annotation",
            user_id,
            annotation_id,
        )
        .await?;
        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if !operation.matches("annotation", annotation_id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let annotation = load_annotation(&mut transaction, user_id, annotation_id, false)
                .await?
                .ok_or_else(|| invalid_replay("annotation delete"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: annotation,
                replayed: true,
            });
        }
        let Some(existing) =
            load_annotation(&mut transaction, user_id, annotation_id, true).await?
        else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        if existing.deleted_at.is_some() {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if existing.revision != base_revision {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            revision,
            "annotation",
            annotation_id,
            &request_hash,
        )
        .await?;
        // A tombstoned annotation can no longer be merged, so its rejected
        // private note variants must not outlive the user-visible artifact.
        sqlx::query("DELETE FROM annotation_conflicts WHERE user_id = $1 AND annotation_id = $2")
            .bind(user_id.into_inner())
            .bind(annotation_id)
            .execute(&mut *transaction)
            .await?;
        let row = sqlx::query_as::<_, AnnotationRow>(
            r"
            UPDATE annotations
            SET block_id = NULL,
                body = NULL,
                color_role = NULL,
                quote_exact = NULL,
                quote_prefix = NULL,
                quote_suffix = NULL,
                start_offset = NULL,
                end_offset = NULL,
                section_hint = '{}'::text[],
                page_hint = NULL,
                anchor_status = 'orphaned',
                revision = $3,
                last_operation_id = $4,
                deleted_at = statement_timestamp(),
                updated_at = statement_timestamp()
            WHERE user_id = $1 AND id = $2
            RETURNING
                id, paper_id, generation, block_id, kind, body, color_role,
                quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                section_hint, page_hint, anchor_status, revision, deleted_at,
                created_at, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(annotation_id)
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: Annotation::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn annotations(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
        after_revision: i64,
        limit: u32,
    ) -> Result<ResearchReadOutcome<StoredAnnotationPage>, DbError> {
        if after_revision < 0 || paper_id == Some(Uuid::nil()) {
            return Ok(ResearchReadOutcome::InvalidRevision);
        }
        let limit = limit.clamp(1, ANNOTATION_PAGE_MAX);
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let (sync_revision, purged_through_revision) =
            revision_metadata(&mut transaction, user_id).await?;
        if after_revision > sync_revision || after_revision < purged_through_revision {
            return Ok(ResearchReadOutcome::InvalidRevision);
        }
        let mut rows = sqlx::query_as::<_, AnnotationRow>(
            r"
            SELECT
                id, paper_id, generation, block_id, kind, body, color_role,
                quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                section_hint, page_hint, anchor_status, revision, deleted_at,
                created_at, updated_at
            FROM annotations
            WHERE user_id = $1
              AND revision > $2
              AND ($3::uuid IS NULL OR paper_id = $3)
            ORDER BY revision, id
            LIMIT $4
            ",
        )
        .bind(user_id.into_inner())
        .bind(after_revision)
        .bind(paper_id)
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let items = rows
            .into_iter()
            .map(Annotation::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let next_after_revision = items.last().map_or(after_revision, |item| item.revision);
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(StoredAnnotationPage {
            items,
            next_after_revision,
            has_more,
            sync_revision,
            purged_through_revision,
        }))
    }

    /// Returns an account-wide, bounded snapshot of unresolved annotation
    /// conflicts. The retained conflict revision is immutable history; each
    /// item separately carries the annotation's current revision so an
    /// imported conflict can be resolved after a client cache loss.
    #[allow(clippy::too_many_lines)] // Keep one consistent snapshot transaction visible end-to-end.
    pub async fn unresolved_annotation_conflicts(
        &self,
        user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<ResearchReadOutcome<StoredAnnotationConflictPage>, DbError> {
        let limit = normalize_page_limit(limit);
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        if cursor.is_some_and(|value| value.is_empty() || value.len() > RESEARCH_CURSOR_MAX_BYTES) {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let current_revision = revision_metadata(&mut transaction, user_id).await?.0;
        let scope = annotation_conflict_cursor_scope(user_id);
        let decoded = match cursor {
            Some(value) => {
                let Some(codec) = self.cursor_codec.as_ref() else {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                };
                let Ok(decoded) = codec.open::<AnnotationConflictPageCursor>(
                    ANNOTATION_CONFLICT_CURSOR_PURPOSE,
                    &scope,
                    value,
                ) else {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                };
                if decoded.sync_revision < 0
                    || decoded.sync_revision != current_revision
                    || (decoded.after_created_at, decoded.after_id)
                        > (decoded.snapshot_created_at, decoded.snapshot_id)
                {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                }
                Some(decoded)
            }
            None => None,
        };
        let snapshot = match decoded {
            Some(value) => Some((value.snapshot_created_at, value.snapshot_id)),
            None => {
                sqlx::query_as::<_, (DateTime<Utc>, Uuid)>(
                    r"
                SELECT conflict.created_at, conflict.id
                FROM annotation_conflicts AS conflict
                JOIN annotations AS annotation
                  ON annotation.user_id = conflict.user_id
                 AND annotation.id = conflict.annotation_id
                WHERE conflict.user_id = $1 AND conflict.resolved_at IS NULL
                ORDER BY conflict.created_at DESC, conflict.id DESC
                LIMIT 1
                ",
                )
                .bind(user_id.into_inner())
                .fetch_optional(&mut *transaction)
                .await?
            }
        };
        let Some((snapshot_created_at, snapshot_id)) = snapshot else {
            transaction.commit().await?;
            return Ok(ResearchReadOutcome::Found(StoredAnnotationConflictPage {
                items: Vec::new(),
                next_cursor: None,
                sync_revision: current_revision,
            }));
        };
        let mut rows = sqlx::query_as::<_, AnnotationConflictSyncRow>(
            r"
            SELECT conflict.id, conflict.annotation_id,
                   conflict.attempted_operation_id, conflict.request_hash,
                   conflict.base_revision, conflict.server_revision,
                   conflict.attempted_body, conflict.server_body,
                   conflict.created_at, conflict.resolution,
                   conflict.merged_body, conflict.resolved_at,
                   annotation.paper_id,
                   annotation.revision AS current_annotation_revision
            FROM annotation_conflicts AS conflict
            JOIN annotations AS annotation
              ON annotation.user_id = conflict.user_id
             AND annotation.id = conflict.annotation_id
            WHERE conflict.user_id = $1
              AND conflict.resolved_at IS NULL
              AND (conflict.created_at, conflict.id) <= ($2, $3)
              AND (
                    $4::timestamptz IS NULL
                    OR (conflict.created_at, conflict.id) > ($4, $5)
                  )
            ORDER BY conflict.created_at, conflict.id
            LIMIT $6
            ",
        )
        .bind(user_id.into_inner())
        .bind(snapshot_created_at)
        .bind(snapshot_id)
        .bind(decoded.map(|value| value.after_created_at))
        .bind(decoded.map(|value| value.after_id))
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let next_cursor = if has_more {
            let row = rows
                .last()
                .ok_or_else(|| invalid_persisted("annotation conflict page"))?;
            let codec = self
                .cursor_codec
                .as_ref()
                .ok_or(crate::CursorError::Unavailable)?;
            Some(
                codec
                    .seal(
                        ANNOTATION_CONFLICT_CURSOR_PURPOSE,
                        &scope,
                        &AnnotationConflictPageCursor {
                            after_created_at: row.created_at,
                            after_id: row.id,
                            snapshot_created_at,
                            snapshot_id,
                            sync_revision: current_revision,
                        },
                    )
                    .map_err(|_| crate::CursorError::Unavailable)?,
            )
        } else {
            None
        };
        let items = rows
            .into_iter()
            .map(StoredAnnotationConflict::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(StoredAnnotationConflictPage {
            items,
            next_cursor,
            sync_revision: current_revision,
        }))
    }

    /// Attempts a conservative move to the current target generation. Only a
    /// unique exact match is committed. A fuzzy candidate is recorded and the
    /// annotation is marked uncertain without moving its source anchor.
    pub async fn reanchor_annotation(
        &self,
        user_id: AuthenticatedUserId,
        annotation_id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
        to_generation: i32,
    ) -> Result<ResearchMutationOutcome<Annotation>, DbError> {
        Ok(strip_reanchor_observation(
            self.reanchor_annotation_observed(
                user_id,
                annotation_id,
                operation_id,
                base_revision,
                to_generation,
            )
            .await?,
        ))
    }

    /// Worker-facing variant of [`Self::reanchor_annotation`] which exposes
    /// only the closed strategy/result dimensions persisted with the attempt.
    #[allow(clippy::too_many_lines)]
    pub async fn reanchor_annotation_observed(
        &self,
        user_id: AuthenticatedUserId,
        annotation_id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
        to_generation: i32,
    ) -> Result<ResearchMutationOutcome<ObservedAnnotationReanchor>, DbError> {
        if annotation_id.is_nil()
            || operation_id.is_nil()
            || base_revision <= 0
            || to_generation <= 0
        {
            return Err(DbError::InvalidData(
                "reanchor identifiers, generation, and revision are invalid".to_owned(),
            ));
        }
        let request_hash = canonical_request_hash(
            "reanchor_annotation",
            &(annotation_id, operation_id, base_revision, to_generation),
        )?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            operation_id,
        )
        .await?;
        advisory_lock(
            &mut transaction,
            "research-annotation",
            user_id,
            annotation_id,
        )
        .await?;
        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if !operation.matches("annotation", annotation_id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let annotation = load_annotation(&mut transaction, user_id, annotation_id, false)
                .await?
                .ok_or_else(|| invalid_replay("annotation reanchor"))?;
            let observation =
                load_reanchor_observation(&mut transaction, user_id, annotation_id, operation_id)
                    .await?
                    .ok_or_else(|| invalid_replay("annotation reanchor history"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: ObservedAnnotationReanchor {
                    annotation,
                    strategy: observation.strategy,
                    result: observation.result,
                },
                replayed: true,
            });
        }
        let Some(existing) =
            load_annotation(&mut transaction, user_id, annotation_id, true).await?
        else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        let Some(source_selector) = existing.selector.clone() else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        if existing.deleted_at.is_some() {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if existing.revision != base_revision {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        if to_generation <= existing.generation {
            // A foreground manual reattach may win after a worker selected
            // this row but before its optimistic mutation. Treat the now
            // current/newer source as a safe stale-generation outcome, not a
            // malformed request or a reason to overwrite the user action.
            return Ok(ResearchMutationOutcome::StaleGeneration);
        }
        if !current_paper_generation(&mut transaction, existing.paper_id, to_generation).await? {
            return classify_missing_paper_or_generation(
                &mut transaction,
                existing.paper_id,
                to_generation,
            )
            .await;
        }
        let source_stable_key: Option<String> = match existing.block_id {
            Some(block_id) => {
                sqlx::query_scalar(
                    r"
                    SELECT stable_key
                    FROM document_blocks
                    WHERE id = $1 AND paper_id = $2 AND generation = $3
                    ",
                )
                .bind(block_id)
                .bind(existing.paper_id)
                .bind(existing.generation)
                .fetch_optional(&mut *transaction)
                .await?
            }
            None => None,
        };
        let (candidate_count, candidate_scalars): (i64, i64) = sqlx::query_as(
            r"
            SELECT count(*)::bigint,
                   COALESCE(sum(char_length(text)), 0)::bigint
            FROM document_blocks
            WHERE paper_id = $1 AND generation = $2
            ",
        )
        .bind(existing.paper_id)
        .bind(to_generation)
        .fetch_one(&mut *transaction)
        .await?;
        // Exact matching over the complete candidate set is allowed only
        // inside a hard memory/CPU envelope. For an unusually large document,
        // inspect the unique equivalent stable block alone; failure to match
        // becomes an explicit orphan/uncertain result and never a guessed move.
        let candidate_rows = if candidate_count <= REANCHOR_BLOCK_MAX
            && candidate_scalars <= REANCHOR_DOCUMENT_SCALAR_MAX
        {
            sqlx::query_as::<_, ReanchorCandidateRow>(
                r"
                SELECT id, stable_key, section_path, text, page_start
                FROM document_blocks
                WHERE paper_id = $1 AND generation = $2
                ORDER BY ordinal
                ",
            )
            .bind(existing.paper_id)
            .bind(to_generation)
            .fetch_all(&mut *transaction)
            .await?
        } else if let Some(stable_key) = source_stable_key.as_deref() {
            sqlx::query_as::<_, ReanchorCandidateRow>(
                r"
                SELECT id, stable_key, section_path, text, page_start
                FROM document_blocks
                WHERE paper_id = $1 AND generation = $2 AND stable_key = $3
                ",
            )
            .bind(existing.paper_id)
            .bind(to_generation)
            .bind(stable_key)
            .fetch_all(&mut *transaction)
            .await?
        } else {
            Vec::new()
        };
        let candidates = candidate_rows
            .iter()
            .map(|row| ReanchorBlock {
                id: row.id,
                stable_key: &row.stable_key,
                section_path: &row.section_path,
                text: &row.text,
            })
            .collect::<Vec<_>>();
        let result = reanchor_annotation(
            &source_selector,
            source_stable_key.as_deref(),
            &existing.section_hint,
            &candidates,
        );
        let target = result
            .target_block_id
            .and_then(|target_id| candidate_rows.iter().find(|row| row.id == target_id));
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            revision,
            "annotation",
            annotation_id,
            &request_hash,
        )
        .await?;
        sqlx::query(
            r"
            INSERT INTO annotation_reanchor_attempts (
                user_id, annotation_id, operation_id, paper_id,
                from_generation, to_generation, source_block_id,
                source_stable_key, source_quote_exact, source_quote_prefix,
                source_quote_suffix, source_start_offset, source_end_offset,
                strategy, result, target_block_id, target_start_offset,
                target_end_offset, similarity, created_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                $11, $12, $13, $14, $15, $16, $17, $18, $19,
                statement_timestamp()
            )
            ",
        )
        .bind(user_id.into_inner())
        .bind(annotation_id)
        .bind(operation_id)
        .bind(existing.paper_id)
        .bind(existing.generation)
        .bind(to_generation)
        .bind(existing.block_id)
        .bind(source_stable_key.as_deref())
        .bind(&source_selector.exact)
        .bind(source_selector.prefix.as_deref())
        .bind(source_selector.suffix.as_deref())
        .bind(source_selector.start.map(u32_to_i32).transpose()?)
        .bind(source_selector.end.map(u32_to_i32).transpose()?)
        .bind(result.strategy.map(reanchor_strategy_name))
        .bind(anchor_status_name(result.status))
        .bind(result.target_block_id)
        .bind(result.start.map(u32_to_i32).transpose()?)
        .bind(result.end.map(u32_to_i32).transpose()?)
        .bind(result.similarity)
        .execute(&mut *transaction)
        .await?;

        let (generation, block_id, quote_prefix, quote_suffix, section_hint, page_hint) =
            if matches!(result.status, AnnotationAnchorStatus::Anchored) {
                let target = target.ok_or_else(|| invalid_persisted("reanchor target"))?;
                let (quote_prefix, quote_suffix) = reanchored_context(
                    &target.text,
                    result.start,
                    result.end,
                    source_selector.prefix.as_deref(),
                    source_selector.suffix.as_deref(),
                )?;
                (
                    to_generation,
                    Some(target.id),
                    quote_prefix,
                    quote_suffix,
                    target.section_path.clone(),
                    target.page_start,
                )
            } else {
                (
                    existing.generation,
                    existing.block_id,
                    source_selector.prefix.clone(),
                    source_selector.suffix.clone(),
                    existing.section_hint.clone(),
                    existing.page_hint.map(u32_to_i32).transpose()?,
                )
            };
        let start_offset = if matches!(result.status, AnnotationAnchorStatus::Anchored) {
            result.start.map(u32_to_i32).transpose()?
        } else {
            source_selector.start.map(u32_to_i32).transpose()?
        };
        let end_offset = if matches!(result.status, AnnotationAnchorStatus::Anchored) {
            result.end.map(u32_to_i32).transpose()?
        } else {
            source_selector.end.map(u32_to_i32).transpose()?
        };
        let row = sqlx::query_as::<_, AnnotationRow>(
            r"
            UPDATE annotations
            SET generation = $3,
                block_id = $4,
                start_offset = $5,
                end_offset = $6,
                quote_prefix = $7,
                quote_suffix = $8,
                section_hint = $9,
                page_hint = $10,
                anchor_status = $11,
                revision = $12,
                last_operation_id = $13,
                updated_at = statement_timestamp()
            WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
            RETURNING id, paper_id, generation, block_id, kind, body, color_role,
                      quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                      section_hint, page_hint, anchor_status, revision, deleted_at,
                      created_at, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(annotation_id)
        .bind(generation)
        .bind(block_id)
        .bind(start_offset)
        .bind(end_offset)
        .bind(quote_prefix.as_deref())
        .bind(quote_suffix.as_deref())
        .bind(section_hint)
        .bind(page_hint)
        .bind(anchor_status_name(result.status))
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: ObservedAnnotationReanchor {
                annotation: Annotation::try_from(row)?,
                strategy: result.strategy,
                result: result.status,
            },
            replayed: false,
        })
    }

    /// Writes only position/presentation data. This repository has no Library
    /// service dependency and the schema has no Library-state column.
    #[allow(clippy::too_many_lines)]
    pub async fn put_checkpoint(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: PaperId,
        write: &ReadingCheckpointWrite,
    ) -> Result<ResearchMutationOutcome<ReadingCheckpoint>, DbError> {
        write
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        if paper_id.is_nil() {
            return Err(DbError::InvalidData(
                "checkpoint paper ID must not be nil".to_owned(),
            ));
        }
        let request_hash = canonical_request_hash("put_checkpoint", &(paper_id, write))?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            write.operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-checkpoint", user_id, paper_id).await?;
        if let Some(operation) =
            load_operation(&mut transaction, user_id, write.operation_id).await?
        {
            if !operation.matches("checkpoint", paper_id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let checkpoint = load_checkpoint(&mut transaction, user_id, paper_id, false)
                .await?
                .ok_or_else(|| invalid_replay("checkpoint"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: checkpoint,
                replayed: true,
            });
        }
        let existing = load_checkpoint(&mut transaction, user_id, paper_id, true).await?;
        if existing.is_none() && write.base_revision != 0 {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if let Some(existing) = &existing
            && existing.revision != write.base_revision
        {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        if !current_paper_generation(&mut transaction, paper_id, write.generation).await? {
            return classify_missing_paper_or_generation(
                &mut transaction,
                paper_id,
                write.generation,
            )
            .await;
        }
        if let Some(block_id) = write.block_id
            && current_block_text(&mut transaction, paper_id, write.generation, block_id)
                .await?
                .is_none()
        {
            return classify_missing_paper_or_generation(
                &mut transaction,
                paper_id,
                write.generation,
            )
            .await;
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            write.operation_id,
            revision,
            "checkpoint",
            paper_id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, CheckpointRow>(
            r"
            INSERT INTO reading_checkpoints (
                user_id, paper_id, generation, mode, stage, block_id,
                scroll_fraction, last_read_at, revision, last_operation_id, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, statement_timestamp()
            )
            ON CONFLICT (user_id, paper_id) DO UPDATE
            SET generation = EXCLUDED.generation,
                mode = EXCLUDED.mode,
                stage = EXCLUDED.stage,
                block_id = EXCLUDED.block_id,
                scroll_fraction = EXCLUDED.scroll_fraction,
                last_read_at = EXCLUDED.last_read_at,
                revision = EXCLUDED.revision,
                last_operation_id = EXCLUDED.last_operation_id,
                updated_at = statement_timestamp()
            RETURNING paper_id, generation, mode, stage, block_id,
                      scroll_fraction, last_read_at, revision
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .bind(write.generation)
        .bind(reader_mode_name(write.mode))
        .bind(reader_stage_name(write.stage))
        .bind(write.block_id)
        .bind(write.scroll_fraction)
        .bind(write.last_read_at)
        .bind(revision)
        .bind(write.operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: ReadingCheckpoint::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn checkpoints(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
    ) -> Result<ResearchReadOutcome<StoredCheckpoints>, DbError> {
        if paper_id == Some(Uuid::nil()) {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let (sync_revision, _) = revision_metadata(&mut transaction, user_id).await?;
        let rows = if let Some(paper_id) = paper_id {
            sqlx::query_as::<_, CheckpointRow>(
                r"
                SELECT paper_id, generation, mode, stage, block_id,
                       scroll_fraction, last_read_at, revision
                FROM reading_checkpoints
                WHERE user_id = $1 AND paper_id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(paper_id)
            .fetch_all(&mut *transaction)
            .await?
        } else {
            sqlx::query_as::<_, CheckpointRow>(
                r"
                SELECT paper_id, generation, mode, stage, block_id,
                       scroll_fraction, last_read_at, revision
                FROM reading_checkpoints
                WHERE user_id = $1
                ORDER BY last_read_at DESC, paper_id
                LIMIT 1000
                ",
            )
            .bind(user_id.into_inner())
            .fetch_all(&mut *transaction)
            .await?
        };
        let items = rows
            .into_iter()
            .map(ReadingCheckpoint::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(StoredCheckpoints {
            items,
            sync_revision,
        }))
    }

    #[allow(clippy::too_many_lines)]
    pub async fn put_evidence_card(
        &self,
        user_id: AuthenticatedUserId,
        write: &EvidenceCardWrite,
    ) -> Result<ResearchMutationOutcome<EvidenceCard>, DbError> {
        write
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let request_hash = canonical_request_hash("put_evidence_card", write)?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            write.operation_id,
        )
        .await?;
        advisory_lock(
            &mut transaction,
            "research-evidence-card",
            user_id,
            write.id,
        )
        .await?;

        if let Some(operation) =
            load_operation(&mut transaction, user_id, write.operation_id).await?
        {
            if !operation.matches("evidence_card", write.id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let card = load_evidence_card(&mut transaction, user_id, write.id, false)
                .await?
                .ok_or_else(|| invalid_replay("evidence card"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: card,
                replayed: true,
            });
        }

        let existing = load_evidence_card(&mut transaction, user_id, write.id, true).await?;
        if existing.is_none() && write.base_revision != 0 {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if let Some(existing) = &existing {
            if existing.deleted_at.is_some()
                || existing.paper_id != write.paper_id
                || existing.generation != write.generation
            {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            }
            if existing.revision != write.base_revision {
                return Ok(ResearchMutationOutcome::RevisionConflict {
                    current_revision: existing.revision,
                });
            }
        }
        match validate_evidence_scope(&mut transaction, write).await? {
            ScopeValidation::Valid => {}
            ScopeValidation::PaperNotFound => {
                return Ok(ResearchMutationOutcome::PaperNotFound);
            }
            ScopeValidation::StaleGeneration => {
                return Ok(ResearchMutationOutcome::StaleGeneration);
            }
            ScopeValidation::ArtifactNotFound => {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            }
        }

        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            write.operation_id,
            revision,
            "evidence_card",
            write.id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, EvidenceCardRow>(
            r"
            INSERT INTO evidence_cards (
                id, user_id, paper_id, generation, title, claim_or_question,
                user_note, source_block_ids, figure_ids, table_ids,
                citation_context_ids, verification_status, revision,
                last_operation_id, deleted_at, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                $13, $14, NULL, statement_timestamp(), statement_timestamp()
            )
            ON CONFLICT (user_id, id) DO UPDATE
            SET title = EXCLUDED.title,
                claim_or_question = EXCLUDED.claim_or_question,
                user_note = EXCLUDED.user_note,
                source_block_ids = EXCLUDED.source_block_ids,
                figure_ids = EXCLUDED.figure_ids,
                table_ids = EXCLUDED.table_ids,
                citation_context_ids = EXCLUDED.citation_context_ids,
                verification_status = EXCLUDED.verification_status,
                revision = EXCLUDED.revision,
                last_operation_id = EXCLUDED.last_operation_id,
                updated_at = statement_timestamp()
            RETURNING id, paper_id, generation, title, claim_or_question,
                      user_note, source_block_ids, figure_ids, table_ids,
                      citation_context_ids, verification_status, revision,
                      deleted_at, created_at, updated_at
            ",
        )
        .bind(write.id)
        .bind(user_id.into_inner())
        .bind(write.paper_id)
        .bind(write.generation)
        .bind(&write.title)
        .bind(write.claim_or_question.as_deref())
        .bind(write.user_note.as_deref())
        .bind(&write.source_block_ids)
        .bind(&write.figure_ids)
        .bind(&write.table_ids)
        .bind(&write.citation_context_ids)
        .bind(evidence_verification_name(write.verification_status))
        .bind(revision)
        .bind(write.operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: EvidenceCard::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn delete_evidence_card(
        &self,
        user_id: AuthenticatedUserId,
        id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
    ) -> Result<ResearchMutationOutcome<EvidenceCard>, DbError> {
        validate_delete_preconditions(id, operation_id, base_revision, "evidence card")?;
        let request_hash =
            canonical_request_hash("delete_evidence_card", &(id, operation_id, base_revision))?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-evidence-card", user_id, id).await?;
        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if !operation.matches("evidence_card", id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let card = load_evidence_card(&mut transaction, user_id, id, false)
                .await?
                .ok_or_else(|| invalid_replay("evidence card delete"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: card,
                replayed: true,
            });
        }
        let Some(existing) = load_evidence_card(&mut transaction, user_id, id, true).await? else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        if existing.deleted_at.is_some() {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if existing.revision != base_revision {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            revision,
            "evidence_card",
            id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, EvidenceCardRow>(
            r"
            UPDATE evidence_cards
            SET title = NULL,
                claim_or_question = NULL,
                user_note = NULL,
                source_block_ids = '{}'::uuid[],
                figure_ids = '{}'::uuid[],
                table_ids = '{}'::uuid[],
                citation_context_ids = '{}'::uuid[],
                verification_status = 'superseded',
                revision = $3,
                last_operation_id = $4,
                deleted_at = statement_timestamp(),
                updated_at = statement_timestamp()
            WHERE user_id = $1 AND id = $2
            RETURNING id, paper_id, generation, title, claim_or_question,
                      user_note, source_block_ids, figure_ids, table_ids,
                      citation_context_ids, verification_status, revision,
                      deleted_at, created_at, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(id)
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: EvidenceCard::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn evidence_cards(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<ResearchReadOutcome<StoredEvidenceCardPage>, DbError> {
        if paper_id == Some(Uuid::nil()) {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let limit = normalize_page_limit(limit);
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let current_revision = revision_metadata(&mut transaction, user_id).await?.0;
        let scope = evidence_cursor_scope(user_id, paper_id);
        let Ok(decoded) = self.decode_cursor(EVIDENCE_CURSOR_PURPOSE, &scope, cursor) else {
            return Ok(ResearchReadOutcome::InvalidCursor);
        };
        let sync_revision = decoded.map_or(current_revision, |value| value.sync_revision);
        if sync_revision < 0 || sync_revision > current_revision {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let mut rows = sqlx::query_as::<_, EvidenceCardRow>(
            r"
            SELECT id, paper_id, generation, title, claim_or_question,
                   user_note, source_block_ids, figure_ids, table_ids,
                   citation_context_ids, verification_status, revision,
                   deleted_at, created_at, updated_at
            FROM evidence_cards
            WHERE user_id = $1
              AND deleted_at IS NULL
              AND revision <= $2
              AND ($3::uuid IS NULL OR paper_id = $3)
              AND ($4::timestamptz IS NULL OR (updated_at, id) < ($4, $5))
            ORDER BY updated_at DESC, id DESC
            LIMIT $6
            ",
        )
        .bind(user_id.into_inner())
        .bind(sync_revision)
        .bind(paper_id)
        .bind(decoded.map(|value| value.sort_at))
        .bind(decoded.map(|value| value.id))
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let next_cursor = self.encode_cursor(
            EVIDENCE_CURSOR_PURPOSE,
            &scope,
            has_more
                .then(|| rows.last())
                .flatten()
                .map(|row| ResearchPageCursor {
                    sort_at: row.updated_at,
                    created_at: row.created_at,
                    id: row.id,
                    sync_revision,
                }),
        )?;
        let items = rows
            .into_iter()
            .map(EvidenceCard::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(StoredEvidenceCardPage {
            items,
            next_cursor,
            sync_revision,
        }))
    }

    #[allow(clippy::too_many_lines)]
    pub async fn put_memory_item(
        &self,
        user_id: AuthenticatedUserId,
        write: &MemoryItemWrite,
    ) -> Result<ResearchMutationOutcome<MemoryItem>, DbError> {
        write
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let request_hash = canonical_request_hash("put_memory_item", write)?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            write.operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-memory-item", user_id, write.id).await?;
        if let Some(operation) =
            load_operation(&mut transaction, user_id, write.operation_id).await?
        {
            if !operation.matches("memory_item", write.id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let item = load_memory_item(&mut transaction, user_id, write.id, false)
                .await?
                .ok_or_else(|| invalid_replay("memory item"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: item,
                replayed: true,
            });
        }
        let existing = load_memory_item(&mut transaction, user_id, write.id, true).await?;
        if existing.is_none() && write.base_revision != 0 {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if let Some(existing) = &existing {
            if existing.deleted_at.is_some()
                || existing.paper_id != write.paper_id
                || existing.generation != write.generation
                || existing.source_type != write.source_type
                || existing.source_id != write.source_id
            {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            }
            if existing.revision != write.base_revision {
                return Ok(ResearchMutationOutcome::RevisionConflict {
                    current_revision: existing.revision,
                });
            }
        }
        match validate_memory_source(&mut transaction, user_id, write).await? {
            ScopeValidation::Valid => {}
            ScopeValidation::PaperNotFound => {
                return Ok(ResearchMutationOutcome::PaperNotFound);
            }
            ScopeValidation::StaleGeneration => {
                return Ok(ResearchMutationOutcome::StaleGeneration);
            }
            ScopeValidation::ArtifactNotFound => {
                return Ok(ResearchMutationOutcome::ArtifactNotFound);
            }
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            write.operation_id,
            revision,
            "memory_item",
            write.id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, MemoryItemRow>(
            r"
            INSERT INTO memory_items (
                id, user_id, paper_id, generation, source_type, source_id,
                prompt_text, answer_text, status, next_review_at, review_count,
                revision, last_operation_id, deleted_at, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 0,
                $11, $12, NULL, statement_timestamp(), statement_timestamp()
            )
            ON CONFLICT (user_id, id) DO UPDATE
            SET prompt_text = EXCLUDED.prompt_text,
                answer_text = EXCLUDED.answer_text,
                status = EXCLUDED.status,
                next_review_at = EXCLUDED.next_review_at,
                revision = EXCLUDED.revision,
                last_operation_id = EXCLUDED.last_operation_id,
                updated_at = statement_timestamp()
            RETURNING id, paper_id, generation, source_type, source_id,
                      prompt_text, answer_text, status, next_review_at,
                      review_count, revision, deleted_at, created_at, updated_at
            ",
        )
        .bind(write.id)
        .bind(user_id.into_inner())
        .bind(write.paper_id)
        .bind(write.generation)
        .bind(memory_source_name(write.source_type))
        .bind(write.source_id)
        .bind(write.prompt_text.as_deref())
        .bind(write.answer_text.as_deref())
        .bind(memory_status_name(write.status))
        .bind(write.next_review_at)
        .bind(revision)
        .bind(write.operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: MemoryItem::try_from(row)?,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_arguments, clippy::too_many_lines)]
    pub async fn review_memory_item(
        &self,
        user_id: AuthenticatedUserId,
        id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
        status: MemoryStatus,
        next_review_at: Option<DateTime<Utc>>,
        reviewed_at: DateTime<Utc>,
    ) -> Result<ResearchMutationOutcome<MemoryItem>, DbError> {
        validate_memory_schedule(status, next_review_at)?;
        if id.is_nil() || operation_id.is_nil() || base_revision <= 0 {
            return Err(DbError::InvalidData(
                "memory review identifiers and revision are invalid".to_owned(),
            ));
        }
        let request_hash = canonical_request_hash(
            "review_memory_item",
            &(
                id,
                operation_id,
                base_revision,
                status,
                next_review_at,
                reviewed_at,
            ),
        )?;
        let mut transaction = self.pool.begin().await?;
        let Some(account_status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !account_status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(account_status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-memory-item", user_id, id).await?;
        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if !operation.matches("memory_item", id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let item = load_memory_item(&mut transaction, user_id, id, false)
                .await?
                .ok_or_else(|| invalid_replay("memory review"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: item,
                replayed: true,
            });
        }
        let Some(existing) = load_memory_item(&mut transaction, user_id, id, true).await? else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        if existing.deleted_at.is_some() {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if existing.revision != base_revision {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            revision,
            "memory_item",
            id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, MemoryItemRow>(
            r"
            UPDATE memory_items
            SET status = $3,
                next_review_at = $4,
                review_count = review_count + 1,
                revision = $5,
                last_operation_id = $6,
                updated_at = statement_timestamp()
            WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
            RETURNING id, paper_id, generation, source_type, source_id,
                      prompt_text, answer_text, status, next_review_at,
                      review_count, revision, deleted_at, created_at, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(id)
        .bind(memory_status_name(status))
        .bind(next_review_at)
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: MemoryItem::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn delete_memory_item(
        &self,
        user_id: AuthenticatedUserId,
        id: Uuid,
        operation_id: Uuid,
        base_revision: i64,
    ) -> Result<ResearchMutationOutcome<MemoryItem>, DbError> {
        validate_delete_preconditions(id, operation_id, base_revision, "memory item")?;
        let request_hash =
            canonical_request_hash("delete_memory_item", &(id, operation_id, base_revision))?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchMutationOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchMutationOutcome::Inactive(status));
        }
        advisory_lock(
            &mut transaction,
            "research-operation",
            user_id,
            operation_id,
        )
        .await?;
        advisory_lock(&mut transaction, "research-memory-item", user_id, id).await?;
        if let Some(operation) = load_operation(&mut transaction, user_id, operation_id).await? {
            if !operation.matches("memory_item", id, &request_hash) {
                return Ok(ResearchMutationOutcome::IdempotencyConflict);
            }
            let item = load_memory_item(&mut transaction, user_id, id, false)
                .await?
                .ok_or_else(|| invalid_replay("memory item delete"))?;
            transaction.commit().await?;
            return Ok(ResearchMutationOutcome::Applied {
                value: item,
                replayed: true,
            });
        }
        let Some(existing) = load_memory_item(&mut transaction, user_id, id, true).await? else {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        };
        if existing.deleted_at.is_some() {
            return Ok(ResearchMutationOutcome::ArtifactNotFound);
        }
        if existing.revision != base_revision {
            return Ok(ResearchMutationOutcome::RevisionConflict {
                current_revision: existing.revision,
            });
        }
        let revision = allocate_revision(&mut transaction, user_id).await?;
        insert_operation(
            &mut transaction,
            user_id,
            operation_id,
            revision,
            "memory_item",
            id,
            &request_hash,
        )
        .await?;
        let row = sqlx::query_as::<_, MemoryItemRow>(
            r"
            UPDATE memory_items
            SET prompt_text = NULL,
                answer_text = NULL,
                status = 'retired',
                next_review_at = NULL,
                revision = $3,
                last_operation_id = $4,
                deleted_at = statement_timestamp(),
                updated_at = statement_timestamp()
            WHERE user_id = $1 AND id = $2
            RETURNING id, paper_id, generation, source_type, source_id,
                      prompt_text, answer_text, status, next_review_at,
                      review_count, revision, deleted_at, created_at, updated_at
            ",
        )
        .bind(user_id.into_inner())
        .bind(id)
        .bind(revision)
        .bind(operation_id)
        .fetch_one(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchMutationOutcome::Applied {
            value: MemoryItem::try_from(row)?,
            replayed: false,
        })
    }

    pub async fn memory_review(
        &self,
        user_id: AuthenticatedUserId,
        cursor: Option<&str>,
        limit: u32,
        now: DateTime<Utc>,
    ) -> Result<ResearchReadOutcome<StoredMemoryPage>, DbError> {
        let limit = normalize_page_limit(limit);
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let current_revision = revision_metadata(&mut transaction, user_id).await?.0;
        let scope = memory_cursor_scope(user_id);
        let Ok(decoded) = self.decode_cursor(MEMORY_CURSOR_PURPOSE, &scope, cursor) else {
            return Ok(ResearchReadOutcome::InvalidCursor);
        };
        let sync_revision = decoded.map_or(current_revision, |value| value.sync_revision);
        if sync_revision < 0 || sync_revision > current_revision {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let mut rows = sqlx::query_as::<_, MemoryItemRow>(
            r"
            SELECT id, paper_id, generation, source_type, source_id,
                   prompt_text, answer_text, status, next_review_at,
                   review_count, revision, deleted_at, created_at, updated_at
            FROM memory_items
            WHERE user_id = $1
              AND deleted_at IS NULL
              AND revision <= $2
              AND (
                    status = 'active'
                    OR (status = 'snoozed' AND next_review_at <= $3)
              )
              AND (
                    $4::timestamptz IS NULL
                    OR (COALESCE(next_review_at, created_at), created_at, id) > ($4, $5, $6)
              )
            ORDER BY COALESCE(next_review_at, created_at), created_at, id
            LIMIT $7
            ",
        )
        .bind(user_id.into_inner())
        .bind(sync_revision)
        .bind(now)
        .bind(decoded.map(|value| value.sort_at))
        .bind(decoded.map(|value| value.created_at))
        .bind(decoded.map(|value| value.id))
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *transaction)
        .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let next_cursor = self.encode_cursor(
            MEMORY_CURSOR_PURPOSE,
            &scope,
            has_more
                .then(|| rows.last())
                .flatten()
                .map(|row| ResearchPageCursor {
                    sort_at: row.next_review_at.unwrap_or(row.created_at),
                    created_at: row.created_at,
                    id: row.id,
                    sync_revision,
                }),
        )?;
        let items = rows
            .into_iter()
            .map(MemoryItem::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(StoredMemoryPage {
            items,
            next_cursor,
            sync_revision,
        }))
    }

    /// Restores the annotation-bearing subset of a bounded JSON research
    /// export. The operation is all-or-nothing and principal-scoped. Existing
    /// equivalent annotations are skipped; any same-ID semantic mismatch or
    /// missing retained source fails the entire batch without overwriting.
    #[allow(clippy::too_many_lines)]
    pub async fn import_annotations(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        archive: &ResearchAnnotationImport,
    ) -> Result<ResearchAnnotationImportOutcome, DbError> {
        if operation_id.is_nil() {
            return Err(DbError::InvalidData(
                "annotation import operation ID must not be nil".to_owned(),
            ));
        }
        validate_annotation_import(archive)?;
        let request_hash = canonical_request_hash("import_annotations", archive)?;
        let mut transaction = self.pool.begin().await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchAnnotationImportOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchAnnotationImportOutcome::Inactive(status));
        }
        advisory_lock(&mut transaction, "annotation-import", user_id, operation_id).await?;
        if let Some((
            stored_hash,
            imported_annotations,
            imported_conflicts,
            imported_reanchor_attempts,
            skipped_annotations,
        )) = sqlx::query_as::<_, (String, i32, i32, i32, i32)>(
            r"
            SELECT request_hash, imported_annotations, imported_conflicts,
                   imported_reanchor_attempts, skipped_annotations
            FROM annotation_imports
            WHERE user_id = $1 AND operation_id = $2
            FOR UPDATE
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            if stored_hash != request_hash {
                return Ok(ResearchAnnotationImportOutcome::IdempotencyConflict);
            }
            let result = ResearchAnnotationImportResult {
                imported_annotations,
                imported_conflicts,
                imported_reanchor_attempts,
                skipped_annotations,
            };
            transaction.commit().await?;
            return Ok(ResearchAnnotationImportOutcome::Applied {
                result,
                replayed: true,
            });
        }

        let mut annotation_ids = archive
            .annotations
            .iter()
            .map(|annotation| annotation.id)
            .collect::<Vec<_>>();
        annotation_ids.sort_unstable();
        for annotation_id in annotation_ids {
            advisory_lock(
                &mut transaction,
                "research-annotation",
                user_id,
                annotation_id,
            )
            .await?;
        }
        for attempt in &archive.annotation_reanchor_attempts {
            if !reanchor_import_blocks_available(&mut transaction, attempt).await? {
                return Ok(ResearchAnnotationImportOutcome::SourceUnavailable);
            }
        }

        let mut imported_annotations = 0_i32;
        let mut skipped_annotations = 0_i32;
        for source in &archive.annotations {
            if let Some(existing) =
                load_annotation(&mut transaction, user_id, source.id, true).await?
            {
                if annotation_archive_equivalent(&existing, source) {
                    skipped_annotations += 1;
                    continue;
                }
                return Ok(ResearchAnnotationImportOutcome::ArtifactCollision);
            }
            if !annotation_import_source_available(&mut transaction, source).await? {
                return Ok(ResearchAnnotationImportOutcome::SourceUnavailable);
            }
            let revision = allocate_revision(&mut transaction, user_id).await?;
            let item_operation_id = Uuid::now_v7();
            let item_hash = canonical_request_hash(
                "imported_annotation",
                &(operation_id, source.id, source.revision),
            )?;
            insert_operation(
                &mut transaction,
                user_id,
                item_operation_id,
                revision,
                "annotation",
                source.id,
                &item_hash,
            )
            .await?;
            let selector = source.selector.as_ref();
            sqlx::query(
                r"
                INSERT INTO annotations (
                    id, user_id, paper_id, generation, block_id, kind, body,
                    color_role, quote_exact, quote_prefix, quote_suffix,
                    start_offset, end_offset, section_hint, page_hint,
                    anchor_status, revision, last_operation_id, deleted_at,
                    created_at, updated_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7,
                    $8, $9, $10, $11, $12, $13, $14, $15,
                    $16, $17, $18, $19, $20, $21
                )
                ",
            )
            .bind(source.id)
            .bind(user_id.into_inner())
            .bind(source.paper_id)
            .bind(source.generation)
            .bind(source.block_id)
            .bind(annotation_kind_name(source.kind))
            .bind(source.body.as_deref())
            .bind(source.color_role.map(annotation_color_name))
            .bind(selector.map(|value| value.exact.as_str()))
            .bind(selector.and_then(|value| value.prefix.as_deref()))
            .bind(selector.and_then(|value| value.suffix.as_deref()))
            .bind(
                selector
                    .and_then(|value| value.start)
                    .map(u32_to_i32)
                    .transpose()?,
            )
            .bind(
                selector
                    .and_then(|value| value.end)
                    .map(u32_to_i32)
                    .transpose()?,
            )
            .bind(&source.section_hint)
            .bind(source.page_hint.map(u32_to_i32).transpose()?)
            .bind(anchor_status_name(source.anchor_status))
            .bind(revision)
            .bind(item_operation_id)
            .bind(source.deleted_at)
            .bind(source.created_at)
            .bind(source.updated_at)
            .execute(&mut *transaction)
            .await?;
            imported_annotations += 1;
        }

        let mut imported_conflicts = 0_i32;
        for source in &archive.annotation_conflicts {
            if let Some(existing) =
                load_annotation_conflict_by_id(&mut transaction, user_id, source.conflict_id)
                    .await?
            {
                if existing == *source {
                    continue;
                }
                return Ok(ResearchAnnotationImportOutcome::ArtifactCollision);
            }
            if annotation_conflict_operation_exists(
                &mut transaction,
                user_id,
                source.attempted_operation_id,
            )
            .await?
            {
                return Ok(ResearchAnnotationImportOutcome::ArtifactCollision);
            }
            let conflict_hash = canonical_request_hash("imported_annotation_conflict", source)?;
            sqlx::query(
                r"
                INSERT INTO annotation_conflicts (
                    id, user_id, annotation_id, attempted_operation_id,
                    request_hash, base_revision, server_revision,
                    attempted_body, server_body, created_at, resolved_at,
                    resolution, merged_body
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7,
                    $8, $9, $10, $11, $12, $13
                )
                ",
            )
            .bind(source.conflict_id)
            .bind(user_id.into_inner())
            .bind(source.annotation_id)
            .bind(source.attempted_operation_id)
            .bind(conflict_hash)
            .bind(source.base_revision)
            .bind(source.server_revision)
            .bind(source.attempted_body.as_deref())
            .bind(source.server_body.as_deref())
            .bind(source.created_at)
            .bind(source.resolved_at)
            .bind(source.resolution.map(annotation_conflict_resolution_name))
            .bind(source.merged_body.as_deref())
            .execute(&mut *transaction)
            .await?;
            imported_conflicts += 1;
        }

        let mut imported_reanchor_attempts = 0_i32;
        for source in &archive.annotation_reanchor_attempts {
            if let Some(existing) =
                load_reanchor_attempt_by_id(&mut transaction, user_id, source.id).await?
            {
                if existing == *source {
                    continue;
                }
                return Ok(ResearchAnnotationImportOutcome::ArtifactCollision);
            }
            if reanchor_operation_exists(&mut transaction, user_id, source.operation_id).await? {
                return Ok(ResearchAnnotationImportOutcome::ArtifactCollision);
            }
            sqlx::query(
                r"
                INSERT INTO annotation_reanchor_attempts (
                    id, user_id, annotation_id, operation_id, paper_id,
                    from_generation, to_generation, source_block_id,
                    source_stable_key, source_quote_exact,
                    source_quote_prefix, source_quote_suffix,
                    source_start_offset, source_end_offset, strategy, result,
                    target_block_id, target_start_offset, target_end_offset,
                    similarity, created_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                    $11, $12, $13, $14, $15, $16, $17, $18, $19,
                    $20, $21
                )
                ",
            )
            .bind(source.id)
            .bind(user_id.into_inner())
            .bind(source.annotation_id)
            .bind(source.operation_id)
            .bind(source.paper_id)
            .bind(source.from_generation)
            .bind(source.to_generation)
            .bind(source.source_block_id)
            .bind(source.source_stable_key.as_deref())
            .bind(&source.source_selector.exact)
            .bind(source.source_selector.prefix.as_deref())
            .bind(source.source_selector.suffix.as_deref())
            .bind(source.source_selector.start.map(u32_to_i32).transpose()?)
            .bind(source.source_selector.end.map(u32_to_i32).transpose()?)
            .bind(source.strategy.map(reanchor_strategy_name))
            .bind(anchor_status_name(source.result))
            .bind(source.target_block_id)
            .bind(source.target_start.map(u32_to_i32).transpose()?)
            .bind(source.target_end.map(u32_to_i32).transpose()?)
            .bind(source.similarity)
            .bind(source.created_at)
            .execute(&mut *transaction)
            .await?;
            imported_reanchor_attempts += 1;
        }

        let result = ResearchAnnotationImportResult {
            imported_annotations,
            imported_conflicts,
            imported_reanchor_attempts,
            skipped_annotations,
        };
        sqlx::query(
            r"
            INSERT INTO annotation_imports (
                user_id, operation_id, request_hash, schema_version,
                imported_annotations, imported_conflicts,
                imported_reanchor_attempts, skipped_annotations, created_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, statement_timestamp())
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(request_hash)
        .bind(&archive.schema_version)
        .bind(result.imported_annotations)
        .bind(result.imported_conflicts)
        .bind(result.imported_reanchor_attempts)
        .bind(result.skipped_annotations)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(ResearchAnnotationImportOutcome::Applied {
            result,
            replayed: false,
        })
    }

    #[allow(clippy::too_many_lines)]
    pub async fn export_research_artifacts(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
        exported_at: DateTime<Utc>,
    ) -> Result<ResearchReadOutcome<ResearchArtifactExport>, DbError> {
        if paper_id == Some(Uuid::nil()) {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let bounds = export_bounds(&mut transaction, user_id, paper_id).await?;
        if bounds.artifacts > EXPORT_ARTIFACT_MAX
            || bounds.private_scalars > EXPORT_PRIVATE_SCALAR_MAX
            || bounds.source_quote_scalars > EXPORT_SOURCE_QUOTE_SCALAR_MAX
            || bounds.private_bytes > EXPORT_PRIVATE_BYTE_MAX
            || bounds.source_quote_bytes > EXPORT_SOURCE_QUOTE_BYTE_MAX
        {
            return Ok(ResearchReadOutcome::ExportTooLarge {
                artifact_count: bounds.artifacts,
                private_scalar_count: bounds.private_scalars,
                source_quote_scalar_count: bounds.source_quote_scalars,
                private_byte_count: bounds.private_bytes,
                source_quote_byte_count: bounds.source_quote_bytes,
            });
        }
        let annotation_rows = sqlx::query_as::<_, AnnotationRow>(
            r"
            SELECT id, paper_id, generation, block_id, kind, body, color_role,
                   quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
                   section_hint, page_hint, anchor_status, revision, deleted_at,
                   created_at, updated_at
            FROM annotations
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let conflict_rows = sqlx::query_as::<_, AnnotationConflictRow>(
            r"
            SELECT conflict.id, conflict.annotation_id,
                   conflict.attempted_operation_id, conflict.request_hash,
                   conflict.base_revision, conflict.server_revision,
                   conflict.attempted_body, conflict.server_body,
                   conflict.created_at, conflict.resolution,
                   conflict.merged_body, conflict.resolved_at
            FROM annotation_conflicts AS conflict
            JOIN annotations AS annotation
              ON annotation.user_id = conflict.user_id
             AND annotation.id = conflict.annotation_id
            WHERE conflict.user_id = $1
              AND ($2::uuid IS NULL OR annotation.paper_id = $2)
            ORDER BY conflict.created_at, conflict.id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let reanchor_rows = sqlx::query_as::<_, ReanchorAttemptRow>(
            r"
            SELECT id, annotation_id, operation_id, paper_id,
                   from_generation, to_generation, source_block_id,
                   source_stable_key, source_quote_exact, source_quote_prefix,
                   source_quote_suffix, source_start_offset, source_end_offset,
                   strategy, result, target_block_id, target_start_offset,
                   target_end_offset, similarity, created_at
            FROM annotation_reanchor_attempts
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let evidence_rows = sqlx::query_as::<_, EvidenceCardRow>(
            r"
            SELECT id, paper_id, generation, title, claim_or_question,
                   user_note, source_block_ids, figure_ids, table_ids,
                   citation_context_ids, verification_status, revision,
                   deleted_at, created_at, updated_at
            FROM evidence_cards
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let checkpoint_rows = sqlx::query_as::<_, CheckpointRow>(
            r"
            SELECT paper_id, generation, mode, stage, block_id,
                   scroll_fraction, last_read_at, revision
            FROM reading_checkpoints
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY last_read_at, paper_id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let memory_rows = sqlx::query_as::<_, MemoryItemRow>(
            r"
            SELECT id, paper_id, generation, source_type, source_id,
                   prompt_text, answer_text, status, next_review_at,
                   review_count, revision, deleted_at, created_at, updated_at
            FROM memory_items
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let assistant_threads = sqlx::query_as::<_, ResearchExportAssistantThread>(
            r"
            SELECT id, paper_id, generation, created_at, updated_at, expires_at
            FROM assistant_threads
            WHERE owner_user_id = $1
              AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let assistant_messages = sqlx::query_as::<_, ResearchExportAssistantMessage>(
            r"
            SELECT message.id, message.thread_id, message.ordinal, message.role,
                   message.content, message.provenance_id, message.created_at
            FROM assistant_messages AS message
            JOIN assistant_threads AS thread ON thread.id = message.thread_id
            WHERE thread.owner_user_id = $1
              AND ($2::uuid IS NULL OR thread.paper_id = $2)
            ORDER BY thread.created_at, thread.id, message.ordinal, message.id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let assistant_evidence_feedback =
            sqlx::query_as::<_, ResearchExportAssistantEvidenceFeedback>(
                r"
                SELECT id, operation_id, thread_id, response_id, provenance_id,
                       paper_id, generation, feedback_type, claim_index,
                       evidence_block_id, detail, created_at
                FROM assistant_evidence_feedback_evaluations
                WHERE owner_user_id = $1
                  AND ($2::uuid IS NULL OR paper_id = $2)
                ORDER BY created_at, id
                ",
            )
            .bind(user_id.into_inner())
            .bind(paper_id)
            .fetch_all(&mut *transaction)
            .await?;
        let private_provenance = sqlx::query_as::<_, ResearchExportPrivateProvenance>(
            r"
            SELECT id, artifact_type, artifact_id, paper_id, generation,
                   activity_type, parser_id, parser_version, model_provider,
                   model_id, prompt_or_schema_version, input_entity_ids,
                   parameters, created_at, superseded_by
            FROM provenance_records
            WHERE owner_user_id = $1
              AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY created_at, id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let library_items = sqlx::query_as::<_, ResearchExportLibraryItem>(
            r"
            SELECT paper_id, state, private_note, save_source_kind, reminder_at,
                   reviewed_at, archived_at, saved_at, updated_at, removed_at,
                   revision
            FROM user_paper_library
            WHERE user_id = $1
              AND ($2::uuid IS NULL OR paper_id = $2)
            ORDER BY saved_at, paper_id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;
        let paper_rows = sqlx::query_as::<_, ResearchExportPaperRow>(
            r"
            WITH scoped_papers AS (
                SELECT paper_id FROM annotations
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM evidence_cards
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM reading_checkpoints
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM memory_items
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM assistant_threads
                WHERE owner_user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM provenance_records
                WHERE owner_user_id = $1 AND paper_id IS NOT NULL
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION SELECT paper_id FROM user_paper_library
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            )
            SELECT paper.id AS paper_id, paper.arxiv_base_id, paper.arxiv_version,
                   paper.title, paper.authors, paper.doi, paper.journal_reference,
                   paper.abs_url AS original_url
            FROM papers AS paper
            JOIN scoped_papers AS scoped ON scoped.paper_id = paper.id
            ORDER BY paper.arxiv_base_id, paper.arxiv_version, paper.id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .fetch_all(&mut *transaction)
        .await?;

        let export = ResearchArtifactExport {
            schema_version: "pakperk.research-export.v1",
            exported_at,
            annotations: annotation_rows
                .into_iter()
                .map(Annotation::try_from)
                .collect::<Result<_, _>>()?,
            annotation_conflicts: conflict_rows
                .into_iter()
                .map(AnnotationConflict::try_from)
                .collect::<Result<_, _>>()?,
            annotation_reanchor_attempts: reanchor_rows
                .into_iter()
                .map(StoredReanchorAttempt::try_from)
                .collect::<Result<_, _>>()?,
            evidence_cards: evidence_rows
                .into_iter()
                .map(EvidenceCard::try_from)
                .collect::<Result<_, _>>()?,
            reading_checkpoints: checkpoint_rows
                .into_iter()
                .map(ReadingCheckpoint::try_from)
                .collect::<Result<_, _>>()?,
            memory_items: memory_rows
                .into_iter()
                .map(MemoryItem::try_from)
                .collect::<Result<_, _>>()?,
            assistant_threads,
            assistant_messages,
            assistant_evidence_feedback,
            private_provenance,
            library_items,
            papers: paper_rows.into_iter().map(Into::into).collect(),
        };
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(export))
    }

    /// Returns one lossless, account-bound export artifact at a time.
    ///
    /// The opaque cursor is bound to both the principal and optional paper
    /// scope. Ordering uses immutable creation keys (or the paper key for the
    /// two singleton-per-paper records), and a start-time ceiling excludes
    /// later inserts. A single persisted artifact is always well below the
    /// HTTP export ceiling, so callers never have to delete valid private text
    /// merely to retrieve it.
    #[allow(clippy::too_many_lines)]
    pub async fn export_research_artifact_page(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
        cursor: Option<&str>,
    ) -> Result<ResearchReadOutcome<ResearchArtifactExportPage>, DbError> {
        if paper_id == Some(Uuid::nil())
            || cursor
                .is_some_and(|value| value.is_empty() || value.len() > RESEARCH_CURSOR_MAX_BYTES)
        {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let scope = research_export_cursor_scope(user_id, paper_id);
        let decoded = match cursor {
            Some(value) => {
                let Some(codec) = self.cursor_codec.as_ref() else {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                };
                let Ok(value) = codec.open::<ResearchExportPageCursor>(
                    RESEARCH_EXPORT_CURSOR_PURPOSE,
                    &scope,
                    value,
                ) else {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                };
                if !(0..=10).contains(&value.kind)
                    || value.id.is_nil()
                    || value.page_number < 2
                    || value.sort_at > value.snapshot_at
                {
                    return Ok(ResearchReadOutcome::InvalidCursor);
                }
                Some(value)
            }
            None => None,
        };
        let page_number = decoded.map_or(1, |value| value.page_number);

        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let snapshot_at = match decoded {
            Some(value) => value.snapshot_at,
            None => {
                sqlx::query_scalar::<_, DateTime<Utc>>("SELECT transaction_timestamp()")
                    .fetch_one(&mut *transaction)
                    .await?
            }
        };
        let (after_kind, after_sort_at, after_id) = decoded.map_or(
            (-1_i16, DateTime::<Utc>::UNIX_EPOCH, Uuid::nil()),
            |value| (value.kind, value.sort_at, value.id),
        );
        let index_rows = sqlx::query_as::<_, ResearchExportIndexRow>(
            r"
            WITH export_index AS (
                SELECT 0::smallint AS kind, created_at AS sort_at, id, paper_id
                FROM annotations
                WHERE user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 1::smallint, conflict.created_at, conflict.id, annotation.paper_id
                FROM annotation_conflicts AS conflict
                JOIN annotations AS annotation
                  ON annotation.user_id = conflict.user_id
                 AND annotation.id = conflict.annotation_id
                WHERE conflict.user_id = $1 AND conflict.created_at <= $3
                  AND ($2::uuid IS NULL OR annotation.paper_id = $2)
                UNION ALL
                SELECT 2::smallint, created_at, id, paper_id
                FROM annotation_reanchor_attempts
                WHERE user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 3::smallint, created_at, id, paper_id
                FROM evidence_cards
                WHERE user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 4::smallint, TIMESTAMPTZ '1970-01-01 00:00:00+00', paper_id, paper_id
                FROM reading_checkpoints
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 5::smallint, created_at, id, paper_id
                FROM memory_items
                WHERE user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 6::smallint, created_at, id, paper_id
                FROM assistant_threads
                WHERE owner_user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 7::smallint, message.created_at, message.id, thread.paper_id
                FROM assistant_messages AS message
                JOIN assistant_threads AS thread ON thread.id = message.thread_id
                WHERE thread.owner_user_id = $1 AND message.created_at <= $3
                  AND ($2::uuid IS NULL OR thread.paper_id = $2)
                UNION ALL
                SELECT 8::smallint, created_at, id, paper_id
                FROM assistant_evidence_feedback_evaluations
                WHERE owner_user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 9::smallint, created_at, id, paper_id
                FROM provenance_records
                WHERE owner_user_id = $1 AND created_at <= $3
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT 10::smallint, TIMESTAMPTZ '1970-01-01 00:00:00+00', paper_id, paper_id
                FROM user_paper_library
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            )
            SELECT kind, sort_at, id, paper_id
            FROM export_index
            WHERE (kind, sort_at, id) > ($4, $5, $6)
            ORDER BY kind, sort_at, id
            LIMIT 2
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .bind(snapshot_at)
        .bind(after_kind)
        .bind(after_sort_at)
        .bind(after_id)
        .fetch_all(&mut *transaction)
        .await?;

        let Some(index) = index_rows.first().copied() else {
            transaction.commit().await?;
            return Ok(ResearchReadOutcome::Found(ResearchArtifactExportPage {
                export: empty_research_export(snapshot_at),
                artifact_kind: None,
                page_number,
                next_cursor: None,
                snapshot_at,
            }));
        };
        let mut export = empty_research_export(snapshot_at);
        load_export_page_item(&mut transaction, user_id, index, &mut export).await?;
        if let Some(scoped_paper_id) = index.paper_id {
            let paper = load_export_paper(&mut transaction, scoped_paper_id).await?;
            export.papers.push(paper);
        }
        let next_cursor = if index_rows.len() > 1 {
            let next_page_number = page_number.checked_add(1).ok_or_else(|| {
                DbError::InvalidData("research export page number overflowed".to_owned())
            })?;
            let codec = self
                .cursor_codec
                .as_ref()
                .ok_or(crate::CursorError::Unavailable)?;
            Some(
                codec
                    .seal(
                        RESEARCH_EXPORT_CURSOR_PURPOSE,
                        &scope,
                        &ResearchExportPageCursor {
                            kind: index.kind,
                            sort_at: index.sort_at,
                            id: index.id,
                            snapshot_at,
                            page_number: next_page_number,
                        },
                    )
                    .map_err(|_| crate::CursorError::Unavailable)?,
            )
        } else {
            None
        };
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(ResearchArtifactExportPage {
            export,
            artifact_kind: Some(export_artifact_kind(index.kind)?),
            page_number,
            next_cursor,
            snapshot_at,
        }))
    }

    #[allow(clippy::too_many_lines)]
    pub async fn research_export_manifest(
        &self,
        user_id: AuthenticatedUserId,
        paper_id: Option<PaperId>,
        generated_at: DateTime<Utc>,
    ) -> Result<ResearchReadOutcome<ResearchExportManifest>, DbError> {
        if paper_id == Some(Uuid::nil()) {
            return Ok(ResearchReadOutcome::InvalidCursor);
        }
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(status) = lock_account_status(&mut transaction, user_id).await? else {
            return Ok(ResearchReadOutcome::AccountNotFound);
        };
        if !status.is_active() {
            return Ok(ResearchReadOutcome::Inactive(status));
        }
        let papers = sqlx::query_as::<_, ResearchExportManifestPaper>(
            r"
            WITH artifact_rows AS (
                SELECT paper_id, 1::bigint AS artifacts,
                       (COALESCE(char_length(body), 0)
                        + COALESCE(char_length(quote_prefix), 0)
                        + COALESCE(char_length(quote_suffix), 0))::bigint AS private_scalars,
                       COALESCE(char_length(quote_exact), 0)::bigint AS source_quote_scalars,
                       (COALESCE(octet_length(body), 0)
                        + COALESCE(octet_length(quote_prefix), 0)
                        + COALESCE(octet_length(quote_suffix), 0))::bigint AS private_bytes,
                       COALESCE(octet_length(quote_exact), 0)::bigint AS source_quote_bytes
                FROM annotations
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT annotation.paper_id, 1,
                       (COALESCE(char_length(conflict.attempted_body), 0)
                        + COALESCE(char_length(conflict.server_body), 0)
                        + COALESCE(char_length(conflict.merged_body), 0))::bigint,
                       0,
                       (COALESCE(octet_length(conflict.attempted_body), 0)
                        + COALESCE(octet_length(conflict.server_body), 0)
                        + COALESCE(octet_length(conflict.merged_body), 0))::bigint,
                       0
                FROM annotation_conflicts AS conflict
                JOIN annotations AS annotation
                  ON annotation.user_id = conflict.user_id
                 AND annotation.id = conflict.annotation_id
                WHERE conflict.user_id = $1
                  AND ($2::uuid IS NULL OR annotation.paper_id = $2)
                UNION ALL
                SELECT paper_id, 1,
                       (COALESCE(char_length(source_quote_prefix), 0)
                        + COALESCE(char_length(source_quote_suffix), 0))::bigint,
                       char_length(source_quote_exact)::bigint,
                       (COALESCE(octet_length(source_quote_prefix), 0)
                        + COALESCE(octet_length(source_quote_suffix), 0))::bigint,
                       octet_length(source_quote_exact)::bigint
                FROM annotation_reanchor_attempts
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1,
                       (COALESCE(char_length(title), 0)
                        + COALESCE(char_length(claim_or_question), 0)
                        + COALESCE(char_length(user_note), 0))::bigint,
                       0,
                       (COALESCE(octet_length(title), 0)
                        + COALESCE(octet_length(claim_or_question), 0)
                        + COALESCE(octet_length(user_note), 0))::bigint,
                       0
                FROM evidence_cards
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1, 0, 0, 0, 0
                FROM reading_checkpoints
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1,
                       (COALESCE(char_length(prompt_text), 0)
                        + COALESCE(char_length(answer_text), 0))::bigint,
                       0,
                       (COALESCE(octet_length(prompt_text), 0)
                        + COALESCE(octet_length(answer_text), 0))::bigint,
                       0
                FROM memory_items
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1, 0, 0, 0, 0
                FROM assistant_threads
                WHERE owner_user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT thread.paper_id, 1, char_length(message.content)::bigint, 0,
                       octet_length(message.content)::bigint, 0
                FROM assistant_messages AS message
                JOIN assistant_threads AS thread ON thread.id = message.thread_id
                WHERE thread.owner_user_id = $1
                  AND ($2::uuid IS NULL OR thread.paper_id = $2)
                UNION ALL
                SELECT paper_id, 1,
                       COALESCE(char_length(detail), 0)::bigint, 0,
                       COALESCE(octet_length(detail), 0)::bigint, 0
                FROM assistant_evidence_feedback_evaluations
                WHERE owner_user_id = $1
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1, 0, 0, 0, 0
                FROM provenance_records
                WHERE owner_user_id = $1 AND paper_id IS NOT NULL
                  AND ($2::uuid IS NULL OR paper_id = $2)
                UNION ALL
                SELECT paper_id, 1,
                       COALESCE(char_length(private_note), 0)::bigint, 0,
                       COALESCE(octet_length(private_note), 0)::bigint, 0
                FROM user_paper_library
                WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            ), totals AS (
                SELECT paper_id, sum(artifacts)::bigint AS artifact_count,
                       sum(private_scalars)::bigint AS private_scalar_count,
                       sum(source_quote_scalars)::bigint AS source_quote_scalar_count,
                       sum(private_bytes)::bigint AS private_byte_count,
                       sum(source_quote_bytes)::bigint AS source_quote_byte_count
                FROM artifact_rows GROUP BY paper_id
            )
            SELECT paper.id AS paper_id, paper.title, paper.arxiv_base_id,
                   totals.artifact_count, totals.private_scalar_count,
                   totals.source_quote_scalar_count, totals.private_byte_count,
                   totals.source_quote_byte_count
            FROM totals
            JOIN papers AS paper ON paper.id = totals.paper_id
            ORDER BY paper.arxiv_base_id, paper.id
            LIMIT $3
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_id)
        .bind(EXPORT_MANIFEST_PAPER_MAX + 1)
        .fetch_all(&mut *transaction)
        .await?;
        if i64::try_from(papers.len()).unwrap_or(i64::MAX) > EXPORT_MANIFEST_PAPER_MAX {
            let artifact_count = papers.iter().map(|paper| paper.artifact_count).sum();
            let private_scalar_count = papers.iter().map(|paper| paper.private_scalar_count).sum();
            let source_quote_scalar_count = papers
                .iter()
                .map(|paper| paper.source_quote_scalar_count)
                .sum();
            let private_byte_count = papers.iter().map(|paper| paper.private_byte_count).sum();
            let source_quote_byte_count = papers
                .iter()
                .map(|paper| paper.source_quote_byte_count)
                .sum();
            return Ok(ResearchReadOutcome::ExportTooLarge {
                artifact_count,
                private_scalar_count,
                source_quote_scalar_count,
                private_byte_count,
                source_quote_byte_count,
            });
        }
        transaction.commit().await?;
        Ok(ResearchReadOutcome::Found(ResearchExportManifest {
            schema_version: "pakperk.research-export-manifest.v1",
            generated_at,
            papers,
        }))
    }

    fn decode_cursor(
        &self,
        purpose: &str,
        scope: &[u8],
        cursor: Option<&str>,
    ) -> Result<Option<ResearchPageCursor>, ()> {
        cursor
            .map(|value| {
                self.cursor_codec
                    .as_ref()
                    .ok_or(())?
                    .open(purpose, scope, value)
                    .map_err(|_| ())
            })
            .transpose()
    }

    fn encode_cursor(
        &self,
        purpose: &str,
        scope: &[u8],
        cursor: Option<ResearchPageCursor>,
    ) -> Result<Option<String>, DbError> {
        cursor
            .map(|value| {
                self.cursor_codec
                    .as_ref()
                    .ok_or(crate::CursorError::Unavailable)?
                    .seal(purpose, scope, &value)
                    .map_err(|_| crate::CursorError::Unavailable.into())
            })
            .transpose()
    }
}

fn strip_reanchor_observation(
    outcome: ResearchMutationOutcome<ObservedAnnotationReanchor>,
) -> ResearchMutationOutcome<Annotation> {
    match outcome {
        ResearchMutationOutcome::Applied { value, replayed } => ResearchMutationOutcome::Applied {
            value: value.annotation,
            replayed,
        },
        ResearchMutationOutcome::AnnotationConflict(conflict) => {
            ResearchMutationOutcome::AnnotationConflict(conflict)
        }
        ResearchMutationOutcome::AccountNotFound => ResearchMutationOutcome::AccountNotFound,
        ResearchMutationOutcome::Inactive(status) => ResearchMutationOutcome::Inactive(status),
        ResearchMutationOutcome::PaperNotFound => ResearchMutationOutcome::PaperNotFound,
        ResearchMutationOutcome::ArtifactNotFound => ResearchMutationOutcome::ArtifactNotFound,
        ResearchMutationOutcome::StaleGeneration => ResearchMutationOutcome::StaleGeneration,
        ResearchMutationOutcome::RevisionConflict { current_revision } => {
            ResearchMutationOutcome::RevisionConflict { current_revision }
        }
        ResearchMutationOutcome::IdempotencyConflict => {
            ResearchMutationOutcome::IdempotencyConflict
        }
    }
}

#[derive(FromRow)]
struct AnnotationRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    block_id: Option<Uuid>,
    kind: String,
    body: Option<String>,
    color_role: Option<String>,
    quote_exact: Option<String>,
    quote_prefix: Option<String>,
    quote_suffix: Option<String>,
    start_offset: Option<i32>,
    end_offset: Option<i32>,
    section_hint: Vec<String>,
    page_hint: Option<i32>,
    anchor_status: String,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(FromRow)]
struct ReanchorObservationRow {
    strategy: Option<String>,
    result: String,
}

struct ReanchorObservation {
    strategy: Option<ReanchorStrategy>,
    result: AnnotationAnchorStatus,
}

impl TryFrom<AnnotationRow> for Annotation {
    type Error = DbError;

    fn try_from(row: AnnotationRow) -> Result<Self, Self::Error> {
        let selector = match row.quote_exact {
            Some(exact) => Some(TextQuotePositionSelector {
                exact,
                prefix: row.quote_prefix,
                suffix: row.quote_suffix,
                start: row.start_offset.map(nonnegative_i32_to_u32).transpose()?,
                end: row.end_offset.map(nonnegative_i32_to_u32).transpose()?,
            }),
            None => None,
        };
        Ok(Self {
            id: row.id,
            paper_id: row.paper_id,
            generation: row.generation,
            block_id: row.block_id,
            kind: parse_annotation_kind(&row.kind)?,
            body: row.body,
            color_role: row
                .color_role
                .as_deref()
                .map(parse_annotation_color)
                .transpose()?,
            selector,
            section_hint: row.section_hint,
            page_hint: row.page_hint.map(positive_i32_to_u32).transpose()?,
            anchor_status: parse_anchor_status(&row.anchor_status)?,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(FromRow)]
struct AnnotationConflictRow {
    id: Uuid,
    annotation_id: Uuid,
    attempted_operation_id: Uuid,
    request_hash: String,
    base_revision: i64,
    server_revision: i64,
    attempted_body: Option<String>,
    server_body: Option<String>,
    created_at: DateTime<Utc>,
    resolution: Option<String>,
    merged_body: Option<String>,
    resolved_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct AnnotationConflictSyncRow {
    id: Uuid,
    annotation_id: Uuid,
    attempted_operation_id: Uuid,
    request_hash: String,
    base_revision: i64,
    server_revision: i64,
    attempted_body: Option<String>,
    server_body: Option<String>,
    created_at: DateTime<Utc>,
    resolution: Option<String>,
    merged_body: Option<String>,
    resolved_at: Option<DateTime<Utc>>,
    paper_id: Uuid,
    current_annotation_revision: i64,
}

impl TryFrom<AnnotationConflictRow> for AnnotationConflict {
    type Error = DbError;

    fn try_from(row: AnnotationConflictRow) -> Result<Self, Self::Error> {
        let resolution = row
            .resolution
            .as_deref()
            .map(parse_annotation_conflict_resolution)
            .transpose()?;
        let conflict = Self {
            conflict_id: row.id,
            annotation_id: row.annotation_id,
            attempted_operation_id: row.attempted_operation_id,
            base_revision: row.base_revision,
            server_revision: row.server_revision,
            attempted_body: row.attempted_body,
            server_body: row.server_body,
            created_at: row.created_at,
            resolution,
            merged_body: row.merged_body,
            resolved_at: row.resolved_at,
        };
        conflict
            .validate()
            .map_err(|_| invalid_persisted("annotation conflict"))?;
        Ok(conflict)
    }
}

impl TryFrom<AnnotationConflictSyncRow> for StoredAnnotationConflict {
    type Error = DbError;

    fn try_from(row: AnnotationConflictSyncRow) -> Result<Self, Self::Error> {
        if row.paper_id.is_nil() || row.current_annotation_revision <= 0 {
            return Err(invalid_persisted("annotation conflict sync scope"));
        }
        let conflict = AnnotationConflict::try_from(AnnotationConflictRow {
            id: row.id,
            annotation_id: row.annotation_id,
            attempted_operation_id: row.attempted_operation_id,
            request_hash: row.request_hash,
            base_revision: row.base_revision,
            server_revision: row.server_revision,
            attempted_body: row.attempted_body,
            server_body: row.server_body,
            created_at: row.created_at,
            resolution: row.resolution,
            merged_body: row.merged_body,
            resolved_at: row.resolved_at,
        })?;
        Ok(Self {
            conflict,
            paper_id: row.paper_id,
            current_annotation_revision: row.current_annotation_revision,
        })
    }
}

#[derive(Debug, FromRow)]
struct CheckpointRow {
    paper_id: Uuid,
    generation: i32,
    mode: String,
    stage: String,
    block_id: Option<Uuid>,
    scroll_fraction: Option<f32>,
    last_read_at: DateTime<Utc>,
    revision: i64,
}

#[derive(FromRow)]
struct ReanchorCandidateRow {
    id: Uuid,
    stable_key: String,
    section_path: Vec<String>,
    text: String,
    page_start: Option<i32>,
}

impl TryFrom<CheckpointRow> for ReadingCheckpoint {
    type Error = DbError;

    fn try_from(row: CheckpointRow) -> Result<Self, Self::Error> {
        Ok(Self {
            paper_id: row.paper_id,
            generation: row.generation,
            mode: parse_reader_mode(&row.mode)?,
            stage: parse_reader_stage(&row.stage)?,
            block_id: row.block_id,
            scroll_fraction: row.scroll_fraction,
            last_read_at: row.last_read_at,
            revision: row.revision,
        })
    }
}

#[derive(FromRow)]
struct EvidenceCardRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    title: Option<String>,
    claim_or_question: Option<String>,
    user_note: Option<String>,
    source_block_ids: Vec<Uuid>,
    figure_ids: Vec<Uuid>,
    table_ids: Vec<Uuid>,
    citation_context_ids: Vec<Uuid>,
    verification_status: String,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<EvidenceCardRow> for EvidenceCard {
    type Error = DbError;

    fn try_from(row: EvidenceCardRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            paper_id: row.paper_id,
            generation: row.generation,
            title: row.title,
            claim_or_question: row.claim_or_question,
            user_note: row.user_note,
            source_block_ids: row.source_block_ids,
            figure_ids: row.figure_ids,
            table_ids: row.table_ids,
            citation_context_ids: row.citation_context_ids,
            verification_status: parse_evidence_verification(&row.verification_status)?,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(FromRow)]
struct MemoryItemRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    source_type: String,
    source_id: Uuid,
    prompt_text: Option<String>,
    answer_text: Option<String>,
    status: String,
    next_review_at: Option<DateTime<Utc>>,
    review_count: i32,
    revision: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<MemoryItemRow> for MemoryItem {
    type Error = DbError;

    fn try_from(row: MemoryItemRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            paper_id: row.paper_id,
            generation: row.generation,
            source_type: parse_memory_source(&row.source_type)?,
            source_id: row.source_id,
            prompt_text: row.prompt_text,
            answer_text: row.answer_text,
            status: parse_memory_status(&row.status)?,
            next_review_at: row.next_review_at,
            review_count: u32::try_from(row.review_count)
                .map_err(|_| invalid_persisted("memory review count"))?,
            revision: row.revision,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(FromRow)]
struct ReanchorAttemptRow {
    id: Uuid,
    annotation_id: Uuid,
    operation_id: Uuid,
    paper_id: Uuid,
    from_generation: i32,
    to_generation: i32,
    source_block_id: Option<Uuid>,
    source_stable_key: Option<String>,
    source_quote_exact: String,
    source_quote_prefix: Option<String>,
    source_quote_suffix: Option<String>,
    source_start_offset: Option<i32>,
    source_end_offset: Option<i32>,
    strategy: Option<String>,
    result: String,
    target_block_id: Option<Uuid>,
    target_start_offset: Option<i32>,
    target_end_offset: Option<i32>,
    similarity: Option<f32>,
    created_at: DateTime<Utc>,
}

impl TryFrom<ReanchorAttemptRow> for StoredReanchorAttempt {
    type Error = DbError;

    fn try_from(row: ReanchorAttemptRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            annotation_id: row.annotation_id,
            operation_id: row.operation_id,
            paper_id: row.paper_id,
            from_generation: row.from_generation,
            to_generation: row.to_generation,
            source_block_id: row.source_block_id,
            source_stable_key: row.source_stable_key,
            source_selector: TextQuotePositionSelector {
                exact: row.source_quote_exact,
                prefix: row.source_quote_prefix,
                suffix: row.source_quote_suffix,
                start: row
                    .source_start_offset
                    .map(nonnegative_i32_to_u32)
                    .transpose()?,
                end: row
                    .source_end_offset
                    .map(nonnegative_i32_to_u32)
                    .transpose()?,
            },
            strategy: row
                .strategy
                .as_deref()
                .map(parse_reanchor_strategy)
                .transpose()?,
            result: parse_anchor_status(&row.result)?,
            target_block_id: row.target_block_id,
            target_start: row
                .target_start_offset
                .map(nonnegative_i32_to_u32)
                .transpose()?,
            target_end: row
                .target_end_offset
                .map(nonnegative_i32_to_u32)
                .transpose()?,
            similarity: row.similarity,
            created_at: row.created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct ResearchExportPaperRow {
    paper_id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    authors: serde_json::Value,
    doi: Option<String>,
    journal_reference: Option<String>,
    original_url: String,
}

#[derive(Debug, Clone, Copy, FromRow)]
struct ResearchExportIndexRow {
    kind: i16,
    sort_at: DateTime<Utc>,
    id: Uuid,
    paper_id: Option<Uuid>,
}

impl From<ResearchExportPaperRow> for ResearchExportPaper {
    fn from(row: ResearchExportPaperRow) -> Self {
        Self {
            paper_id: row.paper_id,
            arxiv_base_id: row.arxiv_base_id,
            arxiv_version: row.arxiv_version,
            title: row.title,
            authors: row.authors,
            doi: row.doi,
            journal_reference: row.journal_reference,
            original_url: row.original_url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeValidation {
    Valid,
    PaperNotFound,
    StaleGeneration,
    ArtifactNotFound,
}

#[derive(Debug, Clone, Copy, FromRow)]
struct ExportBounds {
    #[sqlx(rename = "artifact_count")]
    artifacts: i64,
    #[sqlx(rename = "private_scalar_count")]
    private_scalars: i64,
    #[sqlx(rename = "source_quote_scalar_count")]
    source_quote_scalars: i64,
    #[sqlx(rename = "private_byte_count")]
    private_bytes: i64,
    #[sqlx(rename = "source_quote_byte_count")]
    source_quote_bytes: i64,
}

fn empty_research_export(exported_at: DateTime<Utc>) -> ResearchArtifactExport {
    ResearchArtifactExport {
        schema_version: "pakperk.research-export.v1",
        exported_at,
        annotations: Vec::new(),
        annotation_conflicts: Vec::new(),
        annotation_reanchor_attempts: Vec::new(),
        evidence_cards: Vec::new(),
        reading_checkpoints: Vec::new(),
        memory_items: Vec::new(),
        assistant_threads: Vec::new(),
        assistant_messages: Vec::new(),
        assistant_evidence_feedback: Vec::new(),
        private_provenance: Vec::new(),
        library_items: Vec::new(),
        papers: Vec::new(),
    }
}

fn research_export_cursor_scope(
    user_id: AuthenticatedUserId,
    paper_id: Option<PaperId>,
) -> Vec<u8> {
    let mut scope = Vec::with_capacity(49);
    scope.extend_from_slice(user_id.into_inner().as_bytes());
    scope.push(u8::from(paper_id.is_some()));
    scope.extend_from_slice(paper_id.unwrap_or(Uuid::nil()).as_bytes());
    scope
}

fn export_artifact_kind(kind: i16) -> Result<&'static str, DbError> {
    match kind {
        0 => Ok("annotation"),
        1 => Ok("annotation_conflict"),
        2 => Ok("annotation_reanchor_attempt"),
        3 => Ok("evidence_card"),
        4 => Ok("reading_checkpoint"),
        5 => Ok("memory_item"),
        6 => Ok("assistant_thread"),
        7 => Ok("assistant_message"),
        8 => Ok("assistant_evidence_feedback"),
        9 => Ok("private_provenance"),
        10 => Ok("library_item"),
        _ => Err(invalid_persisted("research export artifact kind")),
    }
}

async fn load_export_paper(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
) -> Result<ResearchExportPaper, DbError> {
    let row = sqlx::query_as::<_, ResearchExportPaperRow>(
        r"
        SELECT id AS paper_id, arxiv_base_id, arxiv_version, title, authors,
               doi, journal_reference, abs_url AS original_url
        FROM papers WHERE id = $1
        ",
    )
    .bind(paper_id)
    .fetch_one(&mut **transaction)
    .await?;
    Ok(row.into())
}

async fn load_export_annotation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    annotation_id: Uuid,
) -> Result<Annotation, DbError> {
    let row = sqlx::query_as::<_, AnnotationRow>(
        r"
        SELECT id, paper_id, generation, block_id, kind, body, color_role,
               quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
               section_hint, page_hint, anchor_status, revision, deleted_at,
               created_at, updated_at
        FROM annotations WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(annotation_id)
    .fetch_one(&mut **transaction)
    .await?;
    Annotation::try_from(row)
}

async fn load_export_thread(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    thread_id: Uuid,
) -> Result<ResearchExportAssistantThread, DbError> {
    sqlx::query_as(
        r"
        SELECT id, paper_id, generation, created_at, updated_at, expires_at
        FROM assistant_threads WHERE owner_user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(thread_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn load_export_message(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    message_id: Uuid,
) -> Result<ResearchExportAssistantMessage, DbError> {
    sqlx::query_as(
        r"
        SELECT message.id, message.thread_id, message.ordinal, message.role,
               message.content, message.provenance_id, message.created_at
        FROM assistant_messages AS message
        JOIN assistant_threads AS thread ON thread.id = message.thread_id
        WHERE thread.owner_user_id = $1 AND message.id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(message_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn load_export_provenance(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    provenance_id: Uuid,
) -> Result<ResearchExportPrivateProvenance, DbError> {
    sqlx::query_as(
        r"
        SELECT id, artifact_type, artifact_id, paper_id, generation,
               activity_type, parser_id, parser_version, model_provider,
               model_id, prompt_or_schema_version, input_entity_ids,
               parameters, created_at, superseded_by
        FROM provenance_records WHERE owner_user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(provenance_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

#[allow(clippy::too_many_lines)]
async fn load_export_page_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    index: ResearchExportIndexRow,
    export: &mut ResearchArtifactExport,
) -> Result<(), DbError> {
    match index.kind {
        0 => {
            export
                .annotations
                .push(load_export_annotation(transaction, user_id, index.id).await?);
        }
        1 => {
            let row = sqlx::query_as::<_, AnnotationConflictRow>(
                r"
                SELECT id, annotation_id, attempted_operation_id, request_hash,
                       base_revision, server_revision, attempted_body, server_body,
                       created_at, resolution, merged_body, resolved_at
                FROM annotation_conflicts WHERE user_id = $1 AND id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            let annotation_id = row.annotation_id;
            export
                .annotation_conflicts
                .push(AnnotationConflict::try_from(row)?);
            export
                .annotations
                .push(load_export_annotation(transaction, user_id, annotation_id).await?);
        }
        2 => {
            let row = sqlx::query_as::<_, ReanchorAttemptRow>(
                r"
                SELECT id, annotation_id, operation_id, paper_id, from_generation,
                       to_generation, source_block_id, source_stable_key,
                       source_quote_exact, source_quote_prefix, source_quote_suffix,
                       source_start_offset, source_end_offset, strategy, result,
                       target_block_id, target_start_offset, target_end_offset,
                       similarity, created_at
                FROM annotation_reanchor_attempts WHERE user_id = $1 AND id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            let annotation_id = row.annotation_id;
            export
                .annotation_reanchor_attempts
                .push(StoredReanchorAttempt::try_from(row)?);
            export
                .annotations
                .push(load_export_annotation(transaction, user_id, annotation_id).await?);
        }
        3 => {
            let row = sqlx::query_as::<_, EvidenceCardRow>(
                r"
                SELECT id, paper_id, generation, title, claim_or_question,
                       user_note, source_block_ids, figure_ids, table_ids,
                       citation_context_ids, verification_status, revision,
                       deleted_at, created_at, updated_at
                FROM evidence_cards WHERE user_id = $1 AND id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            export.evidence_cards.push(EvidenceCard::try_from(row)?);
        }
        4 => {
            let row = sqlx::query_as::<_, CheckpointRow>(
                r"
                SELECT paper_id, generation, mode, stage, block_id,
                       scroll_fraction, last_read_at, revision
                FROM reading_checkpoints WHERE user_id = $1 AND paper_id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            export
                .reading_checkpoints
                .push(ReadingCheckpoint::try_from(row)?);
        }
        5 => {
            let row = sqlx::query_as::<_, MemoryItemRow>(
                r"
                SELECT id, paper_id, generation, source_type, source_id,
                       prompt_text, answer_text, status, next_review_at,
                       review_count, revision, deleted_at, created_at, updated_at
                FROM memory_items WHERE user_id = $1 AND id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            export.memory_items.push(MemoryItem::try_from(row)?);
        }
        6 => {
            export
                .assistant_threads
                .push(load_export_thread(transaction, user_id, index.id).await?);
        }
        7 => {
            let message = load_export_message(transaction, user_id, index.id).await?;
            export
                .assistant_threads
                .push(load_export_thread(transaction, user_id, message.thread_id).await?);
            if let Some(provenance_id) = message.provenance_id {
                export
                    .private_provenance
                    .push(load_export_provenance(transaction, user_id, provenance_id).await?);
            }
            export.assistant_messages.push(message);
        }
        8 => {
            let feedback = sqlx::query_as::<_, ResearchExportAssistantEvidenceFeedback>(
                r"
                SELECT id, operation_id, thread_id, response_id, provenance_id,
                       paper_id, generation, feedback_type, claim_index,
                       evidence_block_id, detail, created_at
                FROM assistant_evidence_feedback_evaluations
                WHERE owner_user_id = $1 AND id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            export
                .assistant_threads
                .push(load_export_thread(transaction, user_id, feedback.thread_id).await?);
            export
                .assistant_messages
                .push(load_export_message(transaction, user_id, feedback.response_id).await?);
            export
                .private_provenance
                .push(load_export_provenance(transaction, user_id, feedback.provenance_id).await?);
            export.assistant_evidence_feedback.push(feedback);
        }
        9 => {
            export
                .private_provenance
                .push(load_export_provenance(transaction, user_id, index.id).await?);
        }
        10 => {
            let library_item = sqlx::query_as::<_, ResearchExportLibraryItem>(
                r"
                SELECT paper_id, state, private_note, save_source_kind, reminder_at,
                       reviewed_at, archived_at, saved_at, updated_at, removed_at,
                       revision
                FROM user_paper_library WHERE user_id = $1 AND paper_id = $2
                ",
            )
            .bind(user_id.into_inner())
            .bind(index.id)
            .fetch_one(&mut **transaction)
            .await?;
            export.library_items.push(library_item);
        }
        _ => return Err(invalid_persisted("research export artifact kind")),
    }
    Ok(())
}

#[derive(Debug, FromRow)]
struct OperationRow {
    artifact_kind: String,
    artifact_id: Uuid,
    request_hash: String,
}

impl OperationRow {
    fn matches(&self, kind: &str, id: Uuid, request_hash: &str) -> bool {
        self.artifact_kind == kind && self.artifact_id == id && self.request_hash == request_hash
    }
}

async fn load_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<Option<OperationRow>, DbError> {
    sqlx::query_as(
        r"
        SELECT artifact_kind, artifact_id, request_hash
        FROM research_artifact_operations
        WHERE user_id = $1 AND operation_id = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn insert_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    revision: i64,
    artifact_kind: &str,
    artifact_id: Uuid,
    request_hash: &str,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO research_artifact_operations (
            user_id, operation_id, accepted_revision, artifact_kind,
            artifact_id, request_hash, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, statement_timestamp())
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(revision)
    .bind(artifact_kind)
    .bind(artifact_id)
    .bind(request_hash)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn allocate_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, DbError> {
    sqlx::query(
        r"
        INSERT INTO research_artifact_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        ) VALUES ($1, 0, 0, statement_timestamp())
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    let revision: i64 = sqlx::query_scalar(
        r"
        UPDATE research_artifact_sync_metadata
        SET current_revision = current_revision + 1,
            updated_at = statement_timestamp()
        WHERE user_id = $1
        RETURNING current_revision
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision <= 0 {
        return Err(DbError::InvalidData(
            "research artifact revision is non-positive".to_owned(),
        ));
    }
    Ok(revision)
}

async fn revision_metadata(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<(i64, i64), DbError> {
    Ok(sqlx::query_as(
        r"
        SELECT current_revision, purged_through_revision
        FROM research_artifact_sync_metadata
        WHERE user_id = $1
        ",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?
    .unwrap_or((0, 0)))
}

#[allow(clippy::too_many_lines)] // One SQL union makes every exported private source auditable.
async fn export_bounds(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: Option<PaperId>,
) -> Result<ExportBounds, DbError> {
    sqlx::query_as(
        r"
        WITH artifact_rows AS (
            SELECT 1::bigint AS artifacts,
                   (COALESCE(char_length(body), 0)
                    + COALESCE(char_length(quote_prefix), 0)
                    + COALESCE(char_length(quote_suffix), 0))::bigint AS private_scalars,
                   COALESCE(char_length(quote_exact), 0)::bigint AS source_quote_scalars,
                   (COALESCE(octet_length(body), 0)
                    + COALESCE(octet_length(quote_prefix), 0)
                    + COALESCE(octet_length(quote_suffix), 0))::bigint AS private_bytes,
                   COALESCE(octet_length(quote_exact), 0)::bigint AS source_quote_bytes
            FROM annotations
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1,
                   (COALESCE(char_length(conflict.attempted_body), 0)
                    + COALESCE(char_length(conflict.server_body), 0)
                    + COALESCE(char_length(conflict.merged_body), 0))::bigint,
                   0,
                   (COALESCE(octet_length(conflict.attempted_body), 0)
                    + COALESCE(octet_length(conflict.server_body), 0)
                    + COALESCE(octet_length(conflict.merged_body), 0))::bigint,
                   0
            FROM annotation_conflicts AS conflict
            JOIN annotations AS annotation
              ON annotation.user_id = conflict.user_id
             AND annotation.id = conflict.annotation_id
            WHERE conflict.user_id = $1
              AND ($2::uuid IS NULL OR annotation.paper_id = $2)
            UNION ALL
            SELECT 1,
                   (COALESCE(char_length(source_quote_prefix), 0)
                    + COALESCE(char_length(source_quote_suffix), 0))::bigint,
                   char_length(source_quote_exact)::bigint,
                   (COALESCE(octet_length(source_quote_prefix), 0)
                    + COALESCE(octet_length(source_quote_suffix), 0))::bigint,
                   octet_length(source_quote_exact)::bigint
            FROM annotation_reanchor_attempts
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1,
                   (COALESCE(char_length(title), 0)
                    + COALESCE(char_length(claim_or_question), 0)
                    + COALESCE(char_length(user_note), 0))::bigint,
                   0,
                   (COALESCE(octet_length(title), 0)
                    + COALESCE(octet_length(claim_or_question), 0)
                    + COALESCE(octet_length(user_note), 0))::bigint,
                   0
            FROM evidence_cards
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1, 0, 0, 0, 0 FROM reading_checkpoints
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1,
                   (COALESCE(char_length(prompt_text), 0)
                    + COALESCE(char_length(answer_text), 0))::bigint,
                   0,
                   (COALESCE(octet_length(prompt_text), 0)
                    + COALESCE(octet_length(answer_text), 0))::bigint,
                   0
            FROM memory_items
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1, 0, 0, 0, 0
            FROM assistant_threads
            WHERE owner_user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1, char_length(message.content)::bigint, 0,
                   octet_length(message.content)::bigint, 0
            FROM assistant_messages AS message
            JOIN assistant_threads AS thread ON thread.id = message.thread_id
            WHERE thread.owner_user_id = $1
              AND ($2::uuid IS NULL OR thread.paper_id = $2)
            UNION ALL
            SELECT 1, COALESCE(char_length(detail), 0)::bigint, 0,
                   COALESCE(octet_length(detail), 0)::bigint, 0
            FROM assistant_evidence_feedback_evaluations
            WHERE owner_user_id = $1
              AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1, 0, 0, 0, 0
            FROM provenance_records
            WHERE owner_user_id = $1
              AND ($2::uuid IS NULL OR paper_id = $2)
            UNION ALL
            SELECT 1, COALESCE(char_length(private_note), 0)::bigint, 0,
                   COALESCE(octet_length(private_note), 0)::bigint, 0
            FROM user_paper_library
            WHERE user_id = $1 AND ($2::uuid IS NULL OR paper_id = $2)
        )
        SELECT COALESCE(sum(artifacts), 0)::bigint AS artifact_count,
               COALESCE(sum(private_scalars), 0)::bigint AS private_scalar_count,
               COALESCE(sum(source_quote_scalars), 0)::bigint AS source_quote_scalar_count,
               COALESCE(sum(private_bytes), 0)::bigint AS private_byte_count,
               COALESCE(sum(source_quote_bytes), 0)::bigint AS source_quote_byte_count
        FROM artifact_rows
        ",
    )
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn load_annotation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    annotation_id: Uuid,
    lock: bool,
) -> Result<Option<Annotation>, DbError> {
    let lock_clause = if lock { " FOR UPDATE" } else { "" };
    let row = sqlx::query_as::<_, AnnotationRow>(&format!(
        r"
        SELECT
            id, paper_id, generation, block_id, kind, body, color_role,
            quote_exact, quote_prefix, quote_suffix, start_offset, end_offset,
            section_hint, page_hint, anchor_status, revision, deleted_at,
            created_at, updated_at
        FROM annotations
        WHERE user_id = $1 AND id = $2{lock_clause}
        "
    ))
    .bind(user_id.into_inner())
    .bind(annotation_id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(Annotation::try_from).transpose()
}

async fn load_reanchor_observation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    annotation_id: Uuid,
    operation_id: Uuid,
) -> Result<Option<ReanchorObservation>, DbError> {
    let row = sqlx::query_as::<_, ReanchorObservationRow>(
        r"
        SELECT strategy, result
        FROM annotation_reanchor_attempts
        WHERE user_id = $1 AND annotation_id = $2 AND operation_id = $3
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(annotation_id)
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(|row| {
        let observation = ReanchorObservation {
            strategy: row
                .strategy
                .as_deref()
                .map(parse_reanchor_strategy)
                .transpose()?,
            result: parse_anchor_status(&row.result)?,
        };
        if !valid_reanchor_observation(&observation) {
            return Err(invalid_persisted("reanchor observation"));
        }
        Ok(observation)
    })
    .transpose()
}

async fn load_conflict_by_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<Option<AnnotationConflictRow>, DbError> {
    sqlx::query_as(
        r"
        SELECT id, annotation_id, attempted_operation_id, request_hash,
               base_revision, server_revision, attempted_body, server_body,
               created_at, resolution, merged_body, resolved_at
        FROM annotation_conflicts
        WHERE user_id = $1 AND attempted_operation_id = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn persist_annotation_conflict(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    existing: &Annotation,
    write: &AnnotationWrite,
    request_hash: &str,
) -> Result<AnnotationConflict, DbError> {
    let row = sqlx::query_as::<_, AnnotationConflictRow>(
        r"
        INSERT INTO annotation_conflicts (
            user_id, annotation_id, attempted_operation_id, request_hash,
            base_revision, server_revision, attempted_body, server_body, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, statement_timestamp())
        RETURNING id, annotation_id, attempted_operation_id, request_hash,
                  base_revision, server_revision, attempted_body, server_body,
                  created_at, resolution, merged_body, resolved_at
        ",
    )
    .bind(user_id.into_inner())
    .bind(existing.id)
    .bind(write.operation_id)
    .bind(request_hash)
    .bind(write.base_revision)
    .bind(existing.revision)
    .bind(write.body.as_deref())
    .bind(existing.body.as_deref())
    .fetch_one(&mut **transaction)
    .await?;
    AnnotationConflict::try_from(row)
}

fn annotation_has_body_conflict(existing: &Annotation, write: &AnnotationWrite) -> bool {
    existing.body != write.body
}

fn annotation_scope_matches(existing: &Annotation, write: &AnnotationWrite) -> bool {
    existing.paper_id == write.paper_id
        && existing.generation == write.generation
        && existing.block_id == write.block_id
        && existing.kind == write.kind
        && existing.selector.as_ref() == Some(&write.selector)
}

/// A user may explicitly move an existing annotation onto a trusted block in
/// a newer retained source generation. This is deliberately narrower than a
/// general scope edit: paper identity and annotation semantics cannot change,
/// the optimistic revision must already have matched, and the target block is
/// subsequently verified against the current generation before persistence.
fn manual_reanchor_allowed(existing: &Annotation, write: &AnnotationWrite) -> bool {
    existing.paper_id == write.paper_id
        && existing.kind == write.kind
        && write.generation > existing.generation
        && existing.selector.is_some()
        && existing.block_id.is_some()
}

#[allow(clippy::too_many_arguments)]
async fn insert_manual_reanchor_attempt(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    source: &Annotation,
    operation_id: Uuid,
    to_generation: i32,
    target_block_id: Uuid,
    target_selector: &TextQuotePositionSelector,
) -> Result<(), DbError> {
    let source_selector = source
        .selector
        .as_ref()
        .ok_or_else(|| invalid_persisted("manual reanchor source selector"))?;
    let source_stable_key: Option<String> = match source.block_id {
        Some(block_id) => {
            sqlx::query_scalar(
                r"
                SELECT stable_key
                FROM document_blocks
                WHERE id = $1 AND paper_id = $2 AND generation = $3
                ",
            )
            .bind(block_id)
            .bind(source.paper_id)
            .bind(source.generation)
            .fetch_optional(&mut **transaction)
            .await?
        }
        None => None,
    };
    sqlx::query(
        r"
        INSERT INTO annotation_reanchor_attempts (
            user_id, annotation_id, operation_id, paper_id,
            from_generation, to_generation, source_block_id,
            source_stable_key, source_quote_exact, source_quote_prefix,
            source_quote_suffix, source_start_offset, source_end_offset,
            strategy, result, target_block_id, target_start_offset,
            target_end_offset, similarity, created_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            $11, $12, $13, 'manual', 'anchored', $14, $15, $16,
            NULL, statement_timestamp()
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(source.id)
    .bind(operation_id)
    .bind(source.paper_id)
    .bind(source.generation)
    .bind(to_generation)
    .bind(source.block_id)
    .bind(source_stable_key.as_deref())
    .bind(&source_selector.exact)
    .bind(source_selector.prefix.as_deref())
    .bind(source_selector.suffix.as_deref())
    .bind(source_selector.start.map(u32_to_i32).transpose()?)
    .bind(source_selector.end.map(u32_to_i32).transpose()?)
    .bind(target_block_id)
    .bind(target_selector.start.map(u32_to_i32).transpose()?)
    .bind(target_selector.end.map(u32_to_i32).transpose()?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

/// The only automatic stale merge is a presentation-only highlight update.
/// Source identity, selector, and the absence of a private note body must all
/// still match the accepted revision.
fn annotation_stale_highlight_merge_allowed(
    existing: &Annotation,
    write: &AnnotationWrite,
) -> bool {
    matches!(existing.kind, AnnotationKind::Highlight)
        && matches!(write.kind, AnnotationKind::Highlight)
        && matches!(existing.anchor_status, AnnotationAnchorStatus::Anchored)
        && existing.body.is_none()
        && write.body.is_none()
        && existing.section_hint == write.section_hint
        && existing.page_hint == write.page_hint
        && annotation_scope_matches(existing, write)
}

async fn current_block_text(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: i32,
    block_id: Uuid,
) -> Result<Option<String>, DbError> {
    sqlx::query_scalar(
        r"
        SELECT block.text
        FROM document_blocks AS block
        JOIN paper_processing AS processing
          ON processing.paper_id = block.paper_id
         AND processing.generation = block.generation
        WHERE block.id = $1
          AND block.paper_id = $2
          AND block.generation = $3
        ",
    )
    .bind(block_id)
    .bind(paper_id)
    .bind(generation)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn current_paper_generation(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: i32,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        r"
        SELECT EXISTS (
            SELECT 1 FROM paper_processing
            WHERE paper_id = $1 AND generation = $2
        )
        ",
    )
    .bind(paper_id)
    .bind(generation)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn classify_missing_paper_or_generation<T>(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: i32,
) -> Result<ResearchMutationOutcome<T>, DbError> {
    let current: Option<i32> =
        sqlx::query_scalar("SELECT generation FROM paper_processing WHERE paper_id = $1")
            .bind(paper_id)
            .fetch_optional(&mut **transaction)
            .await?;
    Ok(match current {
        None => ResearchMutationOutcome::PaperNotFound,
        Some(current) if current != generation => ResearchMutationOutcome::StaleGeneration,
        Some(_) => ResearchMutationOutcome::ArtifactNotFound,
    })
}

async fn load_checkpoint(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    paper_id: PaperId,
    lock: bool,
) -> Result<Option<ReadingCheckpoint>, DbError> {
    let lock_clause = if lock { " FOR UPDATE" } else { "" };
    let row = sqlx::query_as::<_, CheckpointRow>(&format!(
        r"
        SELECT paper_id, generation, mode, stage, block_id,
               scroll_fraction, last_read_at, revision
        FROM reading_checkpoints
        WHERE user_id = $1 AND paper_id = $2{lock_clause}
        "
    ))
    .bind(user_id.into_inner())
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(ReadingCheckpoint::try_from).transpose()
}

async fn load_evidence_card(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
    lock: bool,
) -> Result<Option<EvidenceCard>, DbError> {
    let lock_clause = if lock { " FOR UPDATE" } else { "" };
    let row = sqlx::query_as::<_, EvidenceCardRow>(&format!(
        r"
        SELECT id, paper_id, generation, title, claim_or_question,
               user_note, source_block_ids, figure_ids, table_ids,
               citation_context_ids, verification_status, revision,
               deleted_at, created_at, updated_at
        FROM evidence_cards
        WHERE user_id = $1 AND id = $2{lock_clause}
        "
    ))
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(EvidenceCard::try_from).transpose()
}

async fn load_memory_item(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    id: Uuid,
    lock: bool,
) -> Result<Option<MemoryItem>, DbError> {
    let lock_clause = if lock { " FOR UPDATE" } else { "" };
    let row = sqlx::query_as::<_, MemoryItemRow>(&format!(
        r"
        SELECT id, paper_id, generation, source_type, source_id,
               prompt_text, answer_text, status, next_review_at,
               review_count, revision, deleted_at, created_at, updated_at
        FROM memory_items
        WHERE user_id = $1 AND id = $2{lock_clause}
        "
    ))
    .bind(user_id.into_inner())
    .bind(id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(MemoryItem::try_from).transpose()
}

async fn validate_evidence_scope(
    transaction: &mut Transaction<'_, Postgres>,
    write: &EvidenceCardWrite,
) -> Result<ScopeValidation, DbError> {
    let scope = classify_paper_generation(transaction, write.paper_id, write.generation).await?;
    if scope != ScopeValidation::Valid {
        return Ok(scope);
    }
    if !ids_match_scope(
        transaction,
        "document_blocks",
        write.paper_id,
        write.generation,
        &write.source_block_ids,
    )
    .await?
        || !ids_match_scope(
            transaction,
            "paper_figures",
            write.paper_id,
            write.generation,
            &write.figure_ids,
        )
        .await?
        || !ids_match_scope(
            transaction,
            "paper_tables",
            write.paper_id,
            write.generation,
            &write.table_ids,
        )
        .await?
        || !citation_contexts_match_scope(
            transaction,
            write.paper_id,
            write.generation,
            &write.citation_context_ids,
        )
        .await?
    {
        return Ok(ScopeValidation::ArtifactNotFound);
    }
    Ok(ScopeValidation::Valid)
}

async fn classify_paper_generation(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: i32,
) -> Result<ScopeValidation, DbError> {
    let current: Option<i32> =
        sqlx::query_scalar("SELECT generation FROM paper_processing WHERE paper_id = $1")
            .bind(paper_id)
            .fetch_optional(&mut **transaction)
            .await?;
    Ok(match current {
        None => ScopeValidation::PaperNotFound,
        Some(current) if current != generation => ScopeValidation::StaleGeneration,
        Some(_) => ScopeValidation::Valid,
    })
}

async fn ids_match_scope(
    transaction: &mut Transaction<'_, Postgres>,
    table: &str,
    paper_id: PaperId,
    generation: i32,
    ids: &[Uuid],
) -> Result<bool, DbError> {
    if ids.is_empty() {
        return Ok(true);
    }
    let sql = match table {
        "document_blocks" => {
            "SELECT count(*) FROM document_blocks WHERE paper_id = $1 AND generation = $2 AND id = ANY($3)"
        }
        "paper_figures" => {
            "SELECT count(*) FROM paper_figures WHERE paper_id = $1 AND generation = $2 AND id = ANY($3)"
        }
        "paper_tables" => {
            "SELECT count(*) FROM paper_tables WHERE paper_id = $1 AND generation = $2 AND id = ANY($3)"
        }
        _ => {
            return Err(DbError::InvalidData(
                "invalid research source table".to_owned(),
            ));
        }
    };
    let count: i64 = sqlx::query_scalar(sql)
        .bind(paper_id)
        .bind(generation)
        .bind(ids)
        .fetch_one(&mut **transaction)
        .await?;
    Ok(usize::try_from(count).ok() == Some(ids.len()))
}

async fn citation_contexts_match_scope(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: i32,
    ids: &[Uuid],
) -> Result<bool, DbError> {
    if ids.is_empty() {
        return Ok(true);
    }
    let count: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM citation_contexts AS context
        JOIN paper_references AS reference ON reference.id = context.reference_id
        WHERE reference.citing_paper_id = $1
          AND reference.generation = $2
          AND context.id = ANY($3)
        ",
    )
    .bind(paper_id)
    .bind(generation)
    .bind(ids)
    .fetch_one(&mut **transaction)
    .await?;
    Ok(usize::try_from(count).ok() == Some(ids.len()))
}

async fn validate_memory_source(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    write: &MemoryItemWrite,
) -> Result<ScopeValidation, DbError> {
    let scope = classify_paper_generation(transaction, write.paper_id, write.generation).await?;
    if scope != ScopeValidation::Valid {
        return Ok(scope);
    }
    let exists: bool = match write.source_type {
        MemorySourceType::Annotation => {
            sqlx::query_scalar(
                r"
            SELECT EXISTS (
                SELECT 1 FROM annotations
                WHERE user_id = $1 AND id = $2 AND paper_id = $3
                  AND generation = $4 AND deleted_at IS NULL
            )
            ",
            )
            .bind(user_id.into_inner())
            .bind(write.source_id)
            .bind(write.paper_id)
            .bind(write.generation)
            .fetch_one(&mut **transaction)
            .await?
        }
        MemorySourceType::EvidenceCard => {
            sqlx::query_scalar(
                r"
            SELECT EXISTS (
                SELECT 1 FROM evidence_cards
                WHERE user_id = $1 AND id = $2 AND paper_id = $3
                  AND generation = $4 AND deleted_at IS NULL
                  AND verification_status = 'user_reviewed'
            )
            ",
            )
            .bind(user_id.into_inner())
            .bind(write.source_id)
            .bind(write.paper_id)
            .bind(write.generation)
            .fetch_one(&mut **transaction)
            .await?
        }
        MemorySourceType::PassportField => {
            sqlx::query_scalar(
                r"
            SELECT EXISTS (
                SELECT 1
                FROM paper_passport_fields AS field
                JOIN paper_passports AS passport ON passport.id = field.passport_id
                WHERE field.id = $1 AND passport.paper_id = $2
                  AND passport.generation = $3
                  AND field.status IN ('supported', 'inferred')
            )
            ",
            )
            .bind(write.source_id)
            .bind(write.paper_id)
            .bind(write.generation)
            .fetch_one(&mut **transaction)
            .await?
        }
        MemorySourceType::UserQuestion => {
            sqlx::query_scalar(
                r"
            SELECT EXISTS (
                SELECT 1 FROM annotations
                WHERE user_id = $1 AND id = $2 AND paper_id = $3
                  AND generation = $4 AND kind = 'question' AND deleted_at IS NULL
            )
            ",
            )
            .bind(user_id.into_inner())
            .bind(write.source_id)
            .bind(write.paper_id)
            .bind(write.generation)
            .fetch_one(&mut **transaction)
            .await?
        }
    };
    Ok(if exists {
        ScopeValidation::Valid
    } else {
        ScopeValidation::ArtifactNotFound
    })
}

fn validate_delete_preconditions(
    id: Uuid,
    operation_id: Uuid,
    base_revision: i64,
    kind: &str,
) -> Result<(), DbError> {
    if id.is_nil() || operation_id.is_nil() || base_revision <= 0 {
        return Err(DbError::InvalidData(format!(
            "{kind} delete identifiers and revision are invalid"
        )));
    }
    Ok(())
}

fn validate_memory_schedule(
    status: MemoryStatus,
    next_review_at: Option<DateTime<Utc>>,
) -> Result<(), DbError> {
    if matches!(status, MemoryStatus::Snoozed) != next_review_at.is_some() {
        return Err(DbError::InvalidData(
            "memory review schedule is invalid".to_owned(),
        ));
    }
    Ok(())
}

fn normalize_page_limit(limit: u32) -> u32 {
    if limit == 0 {
        RESEARCH_PAGE_DEFAULT
    } else {
        limit.min(RESEARCH_PAGE_MAX)
    }
}

fn evidence_cursor_scope(user_id: AuthenticatedUserId, paper_id: Option<PaperId>) -> Vec<u8> {
    let mut scope = Vec::with_capacity(33);
    scope.extend_from_slice(user_id.as_uuid().as_bytes());
    if let Some(paper_id) = paper_id {
        scope.push(1);
        scope.extend_from_slice(paper_id.as_bytes());
    } else {
        scope.push(0);
    }
    scope
}

fn memory_cursor_scope(user_id: AuthenticatedUserId) -> Vec<u8> {
    user_id.as_uuid().as_bytes().to_vec()
}

fn annotation_conflict_cursor_scope(user_id: AuthenticatedUserId) -> Vec<u8> {
    user_id.as_uuid().as_bytes().to_vec()
}

#[allow(clippy::too_many_lines)] // One fail-closed pass accounts for the archive's aggregate bounds.
fn validate_annotation_import(archive: &ResearchAnnotationImport) -> Result<(), DbError> {
    if archive.schema_version != "pakperk.research-export.v1"
        || archive.annotations.len() > ANNOTATION_IMPORT_MAX
        || archive.annotation_conflicts.len() > ANNOTATION_IMPORT_CONFLICT_MAX
        || archive.annotation_reanchor_attempts.len() > ANNOTATION_IMPORT_REANCHOR_MAX
    {
        return Err(DbError::InvalidData(
            "annotation import schema or item count is invalid".to_owned(),
        ));
    }
    let annotations = archive
        .annotations
        .iter()
        .map(|annotation| (annotation.id, annotation))
        .collect::<HashMap<_, _>>();
    if annotations.len() != archive.annotations.len() {
        return Err(DbError::InvalidData(
            "annotation import contains duplicate annotation IDs".to_owned(),
        ));
    }
    let mut private_scalars = 0_usize;
    let mut source_quote_scalars = 0_usize;
    for annotation in &archive.annotations {
        if annotation.id.is_nil()
            || annotation.paper_id.is_nil()
            || annotation.generation <= 0
            || annotation.revision <= 0
            || annotation.created_at > annotation.updated_at
            || annotation
                .deleted_at
                .is_some_and(|deleted_at| deleted_at < annotation.created_at)
        {
            return Err(DbError::InvalidData(
                "annotation import contains an invalid annotation".to_owned(),
            ));
        }
        if annotation.deleted_at.is_some() {
            if annotation.block_id.is_some()
                || annotation.body.is_some()
                || annotation.color_role.is_some()
                || annotation.selector.is_some()
                || !annotation.section_hint.is_empty()
                || annotation.page_hint.is_some()
                || !matches!(annotation.anchor_status, AnnotationAnchorStatus::Orphaned)
            {
                return Err(DbError::InvalidData(
                    "annotation import contains an invalid tombstone".to_owned(),
                ));
            }
            continue;
        }
        let Some(block_id) = annotation.block_id else {
            return Err(DbError::InvalidData(
                "annotation import live anchor has no block".to_owned(),
            ));
        };
        let Some(selector) = annotation.selector.clone() else {
            return Err(DbError::InvalidData(
                "annotation import live anchor has no selector".to_owned(),
            ));
        };
        AnnotationWrite {
            id: annotation.id,
            operation_id: Uuid::from_u128(1),
            paper_id: annotation.paper_id,
            generation: annotation.generation,
            block_id: Some(block_id),
            kind: annotation.kind,
            body: annotation.body.clone(),
            color_role: annotation.color_role,
            selector,
            section_hint: annotation.section_hint.clone(),
            page_hint: annotation.page_hint,
            base_revision: 0,
        }
        .validate()
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
        private_scalars = private_scalars.saturating_add(
            annotation
                .body
                .as_deref()
                .map_or(0, |value| value.chars().count()),
        );
        if let Some(selector) = &annotation.selector {
            private_scalars = private_scalars
                .saturating_add(
                    selector
                        .prefix
                        .as_deref()
                        .map_or(0, |value| value.chars().count()),
                )
                .saturating_add(
                    selector
                        .suffix
                        .as_deref()
                        .map_or(0, |value| value.chars().count()),
                );
            source_quote_scalars =
                source_quote_scalars.saturating_add(selector.exact.chars().count());
        }
    }

    let mut conflict_ids = HashSet::new();
    let mut conflict_operations = HashSet::new();
    for conflict in &archive.annotation_conflicts {
        if !annotations.contains_key(&conflict.annotation_id)
            || !conflict_ids.insert(conflict.conflict_id)
            || !conflict_operations.insert(conflict.attempted_operation_id)
            || conflict.validate().is_err()
        {
            return Err(DbError::InvalidData(
                "annotation import contains an invalid conflict".to_owned(),
            ));
        }
        for body in [
            conflict.attempted_body.as_deref(),
            conflict.server_body.as_deref(),
            conflict.merged_body.as_deref(),
        ] {
            private_scalars =
                private_scalars.saturating_add(body.map_or(0, |value| value.chars().count()));
        }
    }

    let mut reanchor_ids = HashSet::new();
    let mut reanchor_operations = HashSet::new();
    for attempt in &archive.annotation_reanchor_attempts {
        let annotation = annotations.get(&attempt.annotation_id);
        let valid_result = matches!(
            (attempt.result, attempt.strategy),
            (
                AnnotationAnchorStatus::Anchored,
                Some(
                    ReanchorStrategy::StableBlockExact
                        | ReanchorStrategy::QuoteContext
                        | ReanchorStrategy::Manual
                )
            ) | (
                AnnotationAnchorStatus::Uncertain,
                Some(ReanchorStrategy::FuzzyHighThreshold)
            ) | (AnnotationAnchorStatus::Orphaned, None)
        );
        let valid_target = match attempt.result {
            AnnotationAnchorStatus::Anchored => {
                attempt.target_block_id.is_some()
                    && attempt.target_start.is_some()
                    && attempt.target_end.is_some()
                    && attempt.target_start < attempt.target_end
            }
            AnnotationAnchorStatus::Uncertain => {
                attempt.target_block_id.is_some()
                    && attempt.target_start.is_none()
                    && attempt.target_end.is_none()
            }
            AnnotationAnchorStatus::Orphaned => {
                attempt.target_block_id.is_none()
                    && attempt.target_start.is_none()
                    && attempt.target_end.is_none()
            }
        };
        if attempt.id.is_nil()
            || attempt.annotation_id.is_nil()
            || attempt.operation_id.is_nil()
            || attempt.paper_id.is_nil()
            || annotation.is_none_or(|value| value.paper_id != attempt.paper_id)
            || !reanchor_ids.insert(attempt.id)
            || !reanchor_operations.insert(attempt.operation_id)
            || attempt.from_generation <= 0
            || attempt.to_generation <= attempt.from_generation
            || attempt.source_block_id.is_none_or(|value| value.is_nil())
            || attempt.target_block_id == Some(Uuid::nil())
            || !valid_result
            || !valid_target
            || attempt
                .similarity
                .is_some_and(|value| !value.is_finite() || !(0.0..=1.0).contains(&value))
        {
            return Err(DbError::InvalidData(
                "annotation import contains invalid re-anchor history".to_owned(),
            ));
        }
        attempt
            .source_selector
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        private_scalars = private_scalars
            .saturating_add(
                attempt
                    .source_selector
                    .prefix
                    .as_deref()
                    .map_or(0, |value| value.chars().count()),
            )
            .saturating_add(
                attempt
                    .source_selector
                    .suffix
                    .as_deref()
                    .map_or(0, |value| value.chars().count()),
            );
        source_quote_scalars =
            source_quote_scalars.saturating_add(attempt.source_selector.exact.chars().count());
    }
    if private_scalars > usize::try_from(EXPORT_PRIVATE_SCALAR_MAX).unwrap_or(usize::MAX)
        || source_quote_scalars
            > usize::try_from(EXPORT_SOURCE_QUOTE_SCALAR_MAX).unwrap_or(usize::MAX)
    {
        return Err(DbError::InvalidData(
            "annotation import private content exceeds the safe bound".to_owned(),
        ));
    }
    Ok(())
}

fn annotation_archive_equivalent(left: &Annotation, right: &Annotation) -> bool {
    left.id == right.id
        && left.paper_id == right.paper_id
        && left.generation == right.generation
        && left.block_id == right.block_id
        && left.kind == right.kind
        && left.body == right.body
        && left.color_role == right.color_role
        && left.selector == right.selector
        && left.section_hint == right.section_hint
        && left.page_hint == right.page_hint
        && left.anchor_status == right.anchor_status
        && left.deleted_at == right.deleted_at
}

async fn annotation_import_source_available(
    transaction: &mut Transaction<'_, Postgres>,
    annotation: &Annotation,
) -> Result<bool, DbError> {
    if annotation.deleted_at.is_some() {
        return sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM papers WHERE id = $1)")
            .bind(annotation.paper_id)
            .fetch_one(&mut **transaction)
            .await
            .map_err(Into::into);
    }
    let Some(block_id) = annotation.block_id else {
        return Ok(false);
    };
    let text: Option<String> = sqlx::query_scalar(
        r"
        SELECT text FROM document_blocks
        WHERE id = $1 AND paper_id = $2 AND generation = $3
        ",
    )
    .bind(block_id)
    .bind(annotation.paper_id)
    .bind(annotation.generation)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(text) = text else {
        return Ok(false);
    };
    Ok(annotation
        .selector
        .as_ref()
        .is_some_and(|selector| selector.validate_against(&text).is_ok()))
}

async fn reanchor_import_blocks_available(
    transaction: &mut Transaction<'_, Postgres>,
    attempt: &StoredReanchorAttempt,
) -> Result<bool, DbError> {
    let Some(source_block_id) = attempt.source_block_id else {
        return Ok(false);
    };
    let source: Option<(String, String)> = sqlx::query_as(
        r"
        SELECT text, stable_key
        FROM document_blocks
        WHERE id = $1 AND paper_id = $2 AND generation = $3
        ",
    )
    .bind(source_block_id)
    .bind(attempt.paper_id)
    .bind(attempt.from_generation)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some((text, stable_key)) = source else {
        return Ok(false);
    };
    if attempt
        .source_stable_key
        .as_deref()
        .is_some_and(|claimed| claimed != stable_key)
        || attempt.source_selector.validate_against(&text).is_err()
    {
        return Ok(false);
    }

    let Some(target_block_id) = attempt.target_block_id else {
        return Ok(true);
    };
    let target_text: Option<String> = sqlx::query_scalar(
        r"
        SELECT text
        FROM document_blocks
        WHERE id = $1 AND paper_id = $2 AND generation = $3
        ",
    )
    .bind(target_block_id)
    .bind(attempt.paper_id)
    .bind(attempt.to_generation)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(target_text) = target_text else {
        return Ok(false);
    };
    if attempt.result == AnnotationAnchorStatus::Uncertain {
        return Ok(true);
    }
    let target_selector = TextQuotePositionSelector {
        exact: attempt.source_selector.exact.clone(),
        prefix: None,
        suffix: None,
        start: attempt.target_start,
        end: attempt.target_end,
    };
    Ok(target_selector.validate_against(&target_text).is_ok())
}

async fn load_annotation_conflict_by_id(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    conflict_id: Uuid,
) -> Result<Option<AnnotationConflict>, DbError> {
    let row = sqlx::query_as::<_, AnnotationConflictRow>(
        r"
        SELECT id, annotation_id, attempted_operation_id, request_hash,
               base_revision, server_revision, attempted_body, server_body,
               created_at, resolution, merged_body, resolved_at
        FROM annotation_conflicts
        WHERE user_id = $1 AND id = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(conflict_id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(AnnotationConflict::try_from).transpose()
}

async fn annotation_conflict_operation_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM annotation_conflicts WHERE user_id = $1 AND attempted_operation_id = $2)",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

async fn load_reanchor_attempt_by_id(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    attempt_id: Uuid,
) -> Result<Option<StoredReanchorAttempt>, DbError> {
    let row = sqlx::query_as::<_, ReanchorAttemptRow>(
        r"
        SELECT id, annotation_id, operation_id, paper_id,
               from_generation, to_generation, source_block_id,
               source_stable_key, source_quote_exact, source_quote_prefix,
               source_quote_suffix, source_start_offset, source_end_offset,
               strategy, result, target_block_id, target_start_offset,
               target_end_offset, similarity, created_at
        FROM annotation_reanchor_attempts
        WHERE user_id = $1 AND id = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(attempt_id)
    .fetch_optional(&mut **transaction)
    .await?;
    row.map(StoredReanchorAttempt::try_from).transpose()
}

async fn reanchor_operation_exists(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
) -> Result<bool, DbError> {
    sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM annotation_reanchor_attempts WHERE user_id = $1 AND operation_id = $2)",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(Into::into)
}

fn canonical_request_hash<T: Serialize>(intent: &str, value: &T) -> Result<String, DbError> {
    let payload = serde_json::to_vec(&(intent, value))
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    Ok(format!("{:x}", Sha256::digest(payload)))
}

fn annotation_kind_name(kind: AnnotationKind) -> &'static str {
    match kind {
        AnnotationKind::Highlight => "highlight",
        AnnotationKind::Note => "note",
        AnnotationKind::Question => "question",
        AnnotationKind::Evidence => "evidence",
    }
}

fn parse_annotation_kind(value: &str) -> Result<AnnotationKind, DbError> {
    match value {
        "highlight" => Ok(AnnotationKind::Highlight),
        "note" => Ok(AnnotationKind::Note),
        "question" => Ok(AnnotationKind::Question),
        "evidence" => Ok(AnnotationKind::Evidence),
        _ => Err(invalid_persisted("annotation kind")),
    }
}

fn annotation_color_name(color: AnnotationColorRole) -> &'static str {
    match color {
        AnnotationColorRole::Yellow => "yellow",
        AnnotationColorRole::Blue => "blue",
        AnnotationColorRole::Green => "green",
        AnnotationColorRole::Pink => "pink",
        AnnotationColorRole::Purple => "purple",
    }
}

fn parse_annotation_color(value: &str) -> Result<AnnotationColorRole, DbError> {
    match value {
        "yellow" => Ok(AnnotationColorRole::Yellow),
        "blue" => Ok(AnnotationColorRole::Blue),
        "green" => Ok(AnnotationColorRole::Green),
        "pink" => Ok(AnnotationColorRole::Pink),
        "purple" => Ok(AnnotationColorRole::Purple),
        _ => Err(invalid_persisted("annotation color")),
    }
}

fn parse_anchor_status(value: &str) -> Result<AnnotationAnchorStatus, DbError> {
    match value {
        "anchored" => Ok(AnnotationAnchorStatus::Anchored),
        "uncertain" => Ok(AnnotationAnchorStatus::Uncertain),
        "orphaned" => Ok(AnnotationAnchorStatus::Orphaned),
        _ => Err(invalid_persisted("annotation anchor status")),
    }
}

fn anchor_status_name(status: AnnotationAnchorStatus) -> &'static str {
    match status {
        AnnotationAnchorStatus::Anchored => "anchored",
        AnnotationAnchorStatus::Uncertain => "uncertain",
        AnnotationAnchorStatus::Orphaned => "orphaned",
    }
}

fn annotation_conflict_resolution_name(resolution: AnnotationConflictResolution) -> &'static str {
    match resolution {
        AnnotationConflictResolution::KeepServer => "keep_server",
        AnnotationConflictResolution::KeepAttempted => "keep_attempted",
        AnnotationConflictResolution::Merged => "merged",
        AnnotationConflictResolution::Dismissed => "dismissed",
    }
}

fn parse_annotation_conflict_resolution(
    value: &str,
) -> Result<AnnotationConflictResolution, DbError> {
    match value {
        "keep_server" => Ok(AnnotationConflictResolution::KeepServer),
        "keep_attempted" => Ok(AnnotationConflictResolution::KeepAttempted),
        "merged" => Ok(AnnotationConflictResolution::Merged),
        "dismissed" => Ok(AnnotationConflictResolution::Dismissed),
        _ => Err(invalid_persisted("annotation conflict resolution")),
    }
}

fn evidence_verification_name(status: EvidenceVerificationStatus) -> &'static str {
    match status {
        EvidenceVerificationStatus::UserSelected => "user_selected",
        EvidenceVerificationStatus::UserReviewed => "user_reviewed",
        EvidenceVerificationStatus::Superseded => "superseded",
    }
}

fn parse_evidence_verification(value: &str) -> Result<EvidenceVerificationStatus, DbError> {
    match value {
        "user_selected" => Ok(EvidenceVerificationStatus::UserSelected),
        "user_reviewed" => Ok(EvidenceVerificationStatus::UserReviewed),
        "superseded" => Ok(EvidenceVerificationStatus::Superseded),
        _ => Err(invalid_persisted("evidence verification status")),
    }
}

fn memory_source_name(source_type: MemorySourceType) -> &'static str {
    match source_type {
        MemorySourceType::Annotation => "annotation",
        MemorySourceType::EvidenceCard => "evidence_card",
        MemorySourceType::PassportField => "passport_field",
        MemorySourceType::UserQuestion => "user_question",
    }
}

fn parse_memory_source(value: &str) -> Result<MemorySourceType, DbError> {
    match value {
        "annotation" => Ok(MemorySourceType::Annotation),
        "evidence_card" => Ok(MemorySourceType::EvidenceCard),
        "passport_field" => Ok(MemorySourceType::PassportField),
        "user_question" => Ok(MemorySourceType::UserQuestion),
        _ => Err(invalid_persisted("memory source type")),
    }
}

fn memory_status_name(status: MemoryStatus) -> &'static str {
    match status {
        MemoryStatus::Active => "active",
        MemoryStatus::Snoozed => "snoozed",
        MemoryStatus::Retired => "retired",
    }
}

fn parse_memory_status(value: &str) -> Result<MemoryStatus, DbError> {
    match value {
        "active" => Ok(MemoryStatus::Active),
        "snoozed" => Ok(MemoryStatus::Snoozed),
        "retired" => Ok(MemoryStatus::Retired),
        _ => Err(invalid_persisted("memory status")),
    }
}

fn reanchor_strategy_name(strategy: ReanchorStrategy) -> &'static str {
    match strategy {
        ReanchorStrategy::StableBlockExact => "stable_block_exact",
        ReanchorStrategy::QuoteContext => "quote_context",
        ReanchorStrategy::FuzzyHighThreshold => "fuzzy_high_threshold",
        ReanchorStrategy::Manual => "manual",
    }
}

fn parse_reanchor_strategy(value: &str) -> Result<ReanchorStrategy, DbError> {
    match value {
        "stable_block_exact" => Ok(ReanchorStrategy::StableBlockExact),
        "quote_context" => Ok(ReanchorStrategy::QuoteContext),
        "fuzzy_high_threshold" => Ok(ReanchorStrategy::FuzzyHighThreshold),
        "manual" => Ok(ReanchorStrategy::Manual),
        _ => Err(invalid_persisted("reanchor strategy")),
    }
}

const fn valid_reanchor_observation(observation: &ReanchorObservation) -> bool {
    matches!(
        (observation.result, observation.strategy),
        (
            AnnotationAnchorStatus::Anchored,
            Some(
                ReanchorStrategy::StableBlockExact
                    | ReanchorStrategy::QuoteContext
                    | ReanchorStrategy::Manual
            )
        ) | (
            AnnotationAnchorStatus::Uncertain,
            Some(ReanchorStrategy::FuzzyHighThreshold)
        ) | (AnnotationAnchorStatus::Orphaned, None)
    )
}

fn reader_mode_name(mode: ReaderMode) -> &'static str {
    match mode {
        ReaderMode::Skim => "skim",
        ReaderMode::Read => "read",
        ReaderMode::Inspect => "inspect",
    }
}

fn parse_reader_mode(value: &str) -> Result<ReaderMode, DbError> {
    match value {
        "skim" => Ok(ReaderMode::Skim),
        "read" => Ok(ReaderMode::Read),
        "inspect" => Ok(ReaderMode::Inspect),
        _ => Err(invalid_persisted("reader mode")),
    }
}

fn reader_stage_name(stage: ReaderStage) -> &'static str {
    match stage {
        ReaderStage::Abstract => "abstract",
        ReaderStage::Introduction => "introduction",
        ReaderStage::Connections => "connections",
    }
}

fn parse_reader_stage(value: &str) -> Result<ReaderStage, DbError> {
    match value {
        "abstract" => Ok(ReaderStage::Abstract),
        "introduction" => Ok(ReaderStage::Introduction),
        "connections" => Ok(ReaderStage::Connections),
        _ => Err(invalid_persisted("reader stage")),
    }
}

fn nonnegative_i32_to_u32(value: i32) -> Result<u32, DbError> {
    u32::try_from(value).map_err(|_| invalid_persisted("nonnegative offset"))
}

fn positive_i32_to_u32(value: i32) -> Result<u32, DbError> {
    let value = nonnegative_i32_to_u32(value)?;
    if value == 0 {
        Err(invalid_persisted("positive integer"))
    } else {
        Ok(value)
    }
}

fn u32_to_i32(value: u32) -> Result<i32, DbError> {
    i32::try_from(value)
        .map_err(|_| DbError::InvalidData("offset or page exceeds the database range".to_owned()))
}

fn reanchored_context(
    target_text: &str,
    start: Option<u32>,
    end: Option<u32>,
    source_prefix: Option<&str>,
    source_suffix: Option<&str>,
) -> Result<(Option<String>, Option<String>), DbError> {
    let (Some(start), Some(end)) = (start, end) else {
        return Err(invalid_persisted("reanchor target offsets"));
    };
    let start = usize::try_from(start).map_err(|_| invalid_persisted("reanchor target start"))?;
    let end = usize::try_from(end).map_err(|_| invalid_persisted("reanchor target end"))?;
    let scalars = target_text.chars().collect::<Vec<_>>();
    if start >= end || end > scalars.len() {
        return Err(invalid_persisted("reanchor target range"));
    }
    let prefix = source_prefix.and_then(|source| {
        let length = source.chars().count().min(start);
        (length > 0).then(|| scalars[start - length..start].iter().collect())
    });
    let suffix = source_suffix.and_then(|source| {
        let length = source
            .chars()
            .count()
            .min(scalars.len().saturating_sub(end));
        (length > 0).then(|| scalars[end..end + length].iter().collect())
    });
    Ok((prefix, suffix))
}

fn invalid_persisted(field: &str) -> DbError {
    DbError::InvalidData(format!("persisted {field} is invalid"))
}

fn invalid_replay(kind: &str) -> DbError {
    DbError::InvalidData(format!(
        "accepted research {kind} operation has no canonical artifact"
    ))
}

#[cfg(test)]
mod tests {
    use base64::{Engine as _, engine::general_purpose::STANDARD};

    use super::*;

    fn highlight_pair() -> (Annotation, AnnotationWrite) {
        let paper_id = Uuid::now_v7();
        let block_id = Uuid::now_v7();
        let selector = TextQuotePositionSelector {
            exact: "quote".to_owned(),
            prefix: Some("before".to_owned()),
            suffix: Some("after".to_owned()),
            start: Some(0),
            end: Some(5),
        };
        let now = Utc::now();
        (
            Annotation {
                id: Uuid::now_v7(),
                paper_id,
                generation: 1,
                block_id: Some(block_id),
                kind: AnnotationKind::Highlight,
                body: None,
                color_role: Some(AnnotationColorRole::Yellow),
                selector: Some(selector.clone()),
                section_hint: vec!["Introduction".to_owned()],
                page_hint: Some(1),
                anchor_status: AnnotationAnchorStatus::Anchored,
                revision: 7,
                deleted_at: None,
                created_at: now,
                updated_at: now,
            },
            AnnotationWrite {
                id: Uuid::now_v7(),
                operation_id: Uuid::now_v7(),
                paper_id,
                generation: 1,
                block_id: Some(block_id),
                kind: AnnotationKind::Highlight,
                body: None,
                color_role: Some(AnnotationColorRole::Blue),
                selector,
                section_hint: vec!["Introduction".to_owned()],
                page_hint: Some(1),
                base_revision: 6,
            },
        )
    }

    #[test]
    fn request_hash_covers_private_body_without_exposing_it() {
        let first = canonical_request_hash("annotation", &("private one", 1)).unwrap();
        let second = canonical_request_hash("annotation", &("private two", 1)).unwrap();
        assert_ne!(first, second);
        assert_eq!(first.len(), 64);
        assert!(!first.contains("private"));
    }

    #[test]
    fn export_cursor_is_opaque_and_bound_to_principal_and_paper_scope() {
        let key = STANDARD.encode([0x45; 32]);
        let codec =
            OpaqueCursorCodec::parse_keyring(&format!("export_test:{key}")).expect("test keyring");
        let owner = AuthenticatedUserId::new(Uuid::from_u128(1));
        let other = AuthenticatedUserId::new(Uuid::from_u128(2));
        let paper = Uuid::from_u128(3);
        let other_paper = Uuid::from_u128(4);
        let now = Utc::now();
        let cursor = ResearchExportPageCursor {
            kind: 0,
            sort_at: now,
            id: Uuid::now_v7(),
            snapshot_at: now,
            page_number: 2,
        };
        let encoded = codec
            .seal(
                RESEARCH_EXPORT_CURSOR_PURPOSE,
                &research_export_cursor_scope(owner, Some(paper)),
                &cursor,
            )
            .expect("bounded export cursor");

        assert!(encoded.len() <= opaque_cursor::MAX_TOKEN_BYTES);
        assert!(!encoded.contains(&paper.to_string()));
        assert_eq!(
            codec
                .open::<ResearchExportPageCursor>(
                    RESEARCH_EXPORT_CURSOR_PURPOSE,
                    &research_export_cursor_scope(owner, Some(paper)),
                    &encoded,
                )
                .unwrap(),
            cursor
        );
        assert!(
            codec
                .open::<ResearchExportPageCursor>(
                    RESEARCH_EXPORT_CURSOR_PURPOSE,
                    &research_export_cursor_scope(other, Some(paper)),
                    &encoded,
                )
                .is_err()
        );
        assert!(
            codec
                .open::<ResearchExportPageCursor>(
                    RESEARCH_EXPORT_CURSOR_PURPOSE,
                    &research_export_cursor_scope(owner, Some(other_paper)),
                    &encoded,
                )
                .is_err()
        );
        assert!(
            codec
                .open::<ResearchExportPageCursor>(
                    RESEARCH_EXPORT_CURSOR_PURPOSE,
                    &research_export_cursor_scope(owner, None),
                    &encoded,
                )
                .is_err()
        );
    }

    #[test]
    fn checkpoint_storage_enums_are_closed() {
        for mode in [ReaderMode::Skim, ReaderMode::Read, ReaderMode::Inspect] {
            assert_eq!(parse_reader_mode(reader_mode_name(mode)).unwrap(), mode);
        }
        for stage in [
            ReaderStage::Abstract,
            ReaderStage::Introduction,
            ReaderStage::Connections,
        ] {
            assert_eq!(parse_reader_stage(reader_stage_name(stage)).unwrap(), stage);
        }
        assert!(parse_reader_mode("reviewed").is_err());
        assert!(parse_reader_stage("archived").is_err());
    }

    #[test]
    fn stale_highlight_merge_is_color_only_and_never_repairs_an_anchor() {
        let (existing, mut write) = highlight_pair();
        write.id = existing.id;
        assert!(annotation_stale_highlight_merge_allowed(&existing, &write));

        write.section_hint.push("Changed".to_owned());
        assert!(!annotation_stale_highlight_merge_allowed(&existing, &write));
        write.section_hint.pop();

        let mut uncertain = existing.clone();
        uncertain.anchor_status = AnnotationAnchorStatus::Uncertain;
        assert!(!annotation_stale_highlight_merge_allowed(
            &uncertain, &write
        ));

        write.body = Some("private note".to_owned());
        assert!(!annotation_stale_highlight_merge_allowed(&existing, &write));
    }

    #[test]
    fn manual_reanchor_is_a_same_paper_newer_generation_move_only() {
        let (existing, mut write) = highlight_pair();
        write.id = existing.id;
        write.base_revision = existing.revision;
        write.generation = existing.generation + 1;
        write.block_id = Some(Uuid::now_v7());
        assert!(manual_reanchor_allowed(&existing, &write));

        write.paper_id = Uuid::now_v7();
        assert!(!manual_reanchor_allowed(&existing, &write));
        write.paper_id = existing.paper_id;
        write.generation = existing.generation;
        assert!(!manual_reanchor_allowed(&existing, &write));
        write.generation = existing.generation + 1;
        write.kind = AnnotationKind::Question;
        assert!(!manual_reanchor_allowed(&existing, &write));
    }

    #[test]
    fn automatic_reanchor_refreshes_context_using_unicode_scalar_offsets() {
        let (prefix, suffix) = reanchored_context(
            "α🙂 revised quote 后缀",
            Some(11),
            Some(16),
            Some("old "),
            Some(" tail"),
        )
        .unwrap();
        assert_eq!(prefix.as_deref(), Some("sed "));
        assert_eq!(suffix.as_deref(), Some(" 后缀"));

        assert!(reanchored_context("short", Some(3), Some(9), None, None).is_err());
    }

    #[test]
    fn reanchor_observation_rejects_impossible_strategy_outcome_pairs() {
        assert!(valid_reanchor_observation(&ReanchorObservation {
            strategy: Some(ReanchorStrategy::StableBlockExact),
            result: AnnotationAnchorStatus::Anchored,
        }));
        assert!(valid_reanchor_observation(&ReanchorObservation {
            strategy: Some(ReanchorStrategy::FuzzyHighThreshold),
            result: AnnotationAnchorStatus::Uncertain,
        }));
        assert!(valid_reanchor_observation(&ReanchorObservation {
            strategy: None,
            result: AnnotationAnchorStatus::Orphaned,
        }));
        assert!(!valid_reanchor_observation(&ReanchorObservation {
            strategy: Some(ReanchorStrategy::FuzzyHighThreshold),
            result: AnnotationAnchorStatus::Anchored,
        }));
    }
}
