use std::{
    collections::{BTreeMap, BTreeSet},
    str::FromStr as _,
};

use chrono::{DateTime, NaiveDate, Utc};
use domain::{AccountStatus, AuthenticatedUserId, PaperId, PaperSummary};
use reading_feed::{RecommendationBatchMetadata, RecommendationPosition};
use recommendations::{
    BuiltRecommendationBatch, CandidateDocument, CandidateSource, ExplanationCode,
    GeneratedCandidate, HistoricalSeed, HistoricalSeedState, METADATA_EMBEDDING_VERSION_V1,
    RECOMMENDATION_ALGORITHM_VERSION_V1, ReasonEvidence, RecommendationCandidateHistory,
    RecommendationExplanation, RecommendationFeatures, RecommendationMode, explain_candidate,
};
use serde_json::json;
use sha2::{Digest as _, Sha256};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;

use super::{DbError, rows::PAPER_SUMMARY_BY_ID, rows::PaperSummaryRow};

#[derive(Clone)]
pub struct RecommendationBatchRepository {
    pool: PgPool,
}

impl RecommendationBatchRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Finalizes an already-built batch only after serializing against the
    /// account's library revision fence and re-proving active count zero.
    #[allow(clippy::too_many_lines)] // One short transaction binds queue, profile, feedback, header, and candidates atomically.
    pub async fn persist_ready(
        &self,
        request: RecommendationBatchPersistRequest<'_>,
    ) -> Result<RecommendationBatchPersistOutcome, RecommendationBatchRepositoryError> {
        validate_persist_request(&request)?;
        let mut transaction = self.pool.begin().await?;
        let authority = lock_queue_authority(&mut transaction, request.user_id).await?;
        let feedback_revision = lock_feedback_revision(&mut transaction, request.user_id).await?;
        let profile_revision = current_profile_revision(&mut transaction, request.user_id).await?;
        let saved_search_revision_digest = if request.batch.mode == RecommendationMode::Following {
            Some(current_saved_search_digest(&mut transaction, request.user_id).await?)
        } else {
            None
        };
        if authority.library_revision != request.batch.library_revision
            || authority.active_count != 0
            || feedback_revision != request.batch.feedback_revision
            || request.batch.profile_revision != profile_revision
            || request.saved_search_revision_digest != saved_search_revision_digest
        {
            insert_batch_header(
                &mut transaction,
                BatchHeader {
                    batch_id: request.batch_id,
                    user_id: request.user_id,
                    mode: request.batch.mode,
                    query_key: request.query_key,
                    local_date: request.local_date,
                    profile_revision: request.batch.profile_revision,
                    feedback_revision: request.batch.feedback_revision,
                    library_revision: request.batch.library_revision,
                    queue_proven_empty: true,
                    algorithm_version: request.batch.algorithm_version,
                    policy_version: &request.batch.policy_version,
                    seed: request.batch.seed,
                    created_at: request.created_at,
                    expires_at: request.expires_at,
                    status: StoredRecommendationBatchStatus::Superseded,
                    next_position: request.next_position,
                    saved_search_revision_digest: request.saved_search_revision_digest,
                    metadata: json!({
                        "rejected_at_revision": authority.library_revision,
                        "active_count": authority.active_count,
                        "current_feedback_revision": feedback_revision,
                        "current_profile_revision": profile_revision,
                        "metadata_embedding_version": METADATA_EMBEDDING_VERSION_V1,
                    }),
                },
            )
            .await?;
            transaction.commit().await?;
            return Ok(RecommendationBatchPersistOutcome::Superseded {
                batch_id: request.batch_id,
                current_library_revision: authority.library_revision,
                active_count: authority.active_count,
            });
        }
        if let Some(existing) = find_existing(
            &mut transaction,
            BatchLookup {
                user_id: request.user_id,
                mode: request.batch.mode,
                local_date: request.local_date,
                query_key: request.query_key,
                profile_revision: request.batch.profile_revision,
                feedback_revision: request.batch.feedback_revision,
                library_revision: request.batch.library_revision,
                algorithm_version: request.batch.algorithm_version,
                policy_version: &request.batch.policy_version,
                saved_search_revision_digest: request.saved_search_revision_digest,
            },
        )
        .await?
        {
            transaction.commit().await?;
            return Ok(RecommendationBatchPersistOutcome::Replayed {
                batch_id: existing.id,
                status: existing.status()?,
            });
        }

        insert_batch_header(
            &mut transaction,
            BatchHeader {
                batch_id: request.batch_id,
                user_id: request.user_id,
                mode: request.batch.mode,
                query_key: request.query_key,
                local_date: request.local_date,
                profile_revision: request.batch.profile_revision,
                feedback_revision: request.batch.feedback_revision,
                library_revision: request.batch.library_revision,
                queue_proven_empty: true,
                algorithm_version: request.batch.algorithm_version,
                policy_version: &request.batch.policy_version,
                seed: request.batch.seed,
                created_at: request.created_at,
                expires_at: request.expires_at,
                status: StoredRecommendationBatchStatus::Ready,
                next_position: request.next_position,
                saved_search_revision_digest: request.saved_search_revision_digest,
                metadata: json!({
                    "metadata_embedding_version": METADATA_EMBEDDING_VERSION_V1,
                }),
            },
        )
        .await?;
        insert_candidates(&mut transaction, request.batch_id, request.batch).await?;
        transaction.commit().await?;
        Ok(RecommendationBatchPersistOutcome::Ready {
            batch_id: request.batch_id,
            library_revision: request.batch.library_revision,
            candidate_count: request.batch.candidates.len(),
        })
    }

    /// Records an active-queue decision without accepting candidate material.
    /// Calling this path before generators is what makes `blocked_by_queue`
    /// auditable while preserving a zero generator-invocation invariant.
    pub async fn record_blocked_by_queue(
        &self,
        request: RecommendationBatchBlockRequest<'_>,
    ) -> Result<RecommendationBatchBlockOutcome, RecommendationBatchRepositoryError> {
        validate_block_request(&request)?;
        let mut transaction = self.pool.begin().await?;
        let authority = lock_queue_authority(&mut transaction, request.user_id).await?;
        let feedback_revision = lock_feedback_revision(&mut transaction, request.user_id).await?;
        let profile_revision = current_profile_revision(&mut transaction, request.user_id).await?;
        let saved_search_revision_digest = if request.mode == RecommendationMode::Following {
            Some(current_saved_search_digest(&mut transaction, request.user_id).await?)
        } else {
            None
        };
        if feedback_revision != request.feedback_revision
            || profile_revision != request.profile_revision
            || saved_search_revision_digest != request.saved_search_revision_digest
        {
            transaction.commit().await?;
            return Ok(RecommendationBatchBlockOutcome::ContextChanged);
        }
        if let Some(existing) = find_existing(
            &mut transaction,
            BatchLookup {
                user_id: request.user_id,
                mode: request.mode,
                local_date: request.local_date,
                query_key: request.query_key,
                profile_revision: request.profile_revision,
                feedback_revision: request.feedback_revision,
                library_revision: authority.library_revision,
                algorithm_version: request.algorithm_version,
                policy_version: request.policy_version,
                saved_search_revision_digest: request.saved_search_revision_digest,
            },
        )
        .await?
        {
            transaction.commit().await?;
            return Ok(RecommendationBatchBlockOutcome::Replayed {
                batch_id: existing.id,
                status: existing.status()?,
            });
        }
        if authority.active_count == 0 {
            transaction.commit().await?;
            return Ok(RecommendationBatchBlockOutcome::QueueProvenEmpty {
                library_revision: authority.library_revision,
            });
        }
        insert_batch_header(
            &mut transaction,
            BatchHeader {
                batch_id: request.batch_id,
                user_id: request.user_id,
                mode: request.mode,
                query_key: request.query_key,
                local_date: request.local_date,
                profile_revision: request.profile_revision,
                feedback_revision: request.feedback_revision,
                library_revision: authority.library_revision,
                queue_proven_empty: false,
                algorithm_version: request.algorithm_version,
                policy_version: request.policy_version,
                seed: request.seed,
                created_at: request.created_at,
                expires_at: request.expires_at,
                status: StoredRecommendationBatchStatus::BlockedByQueue,
                next_position: None,
                saved_search_revision_digest: request.saved_search_revision_digest,
                metadata: json!({"active_count": authority.active_count}),
            },
        )
        .await?;
        transaction.commit().await?;
        Ok(RecommendationBatchBlockOutcome::BlockedByQueue {
            batch_id: request.batch_id,
            library_revision: authority.library_revision,
            active_count: authority.active_count,
        })
    }

    /// Reconstructs and revalidates immutable template reasons for an owned
    /// batch/item pair. Queue items have no batch pair and cannot enter here.
    pub async fn explanation(
        &self,
        user_id: AuthenticatedUserId,
        batch_id: Uuid,
        paper_id: PaperId,
        now: DateTime<Utc>,
    ) -> Result<RecommendationExplanationReadOutcome, RecommendationBatchRepositoryError> {
        if batch_id.is_nil() || paper_id.is_nil() {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        let evidence = sqlx::query_as::<_, StoredCandidateEvidenceRow>(
            r"
            SELECT
                candidate.candidate_sources,
                candidate.raw_features,
                candidate.reason_codes,
                candidate.reason_evidence
            FROM recommendation_candidates AS candidate
            JOIN recommendation_batches AS batch ON batch.id = candidate.batch_id
            WHERE batch.id = $1
              AND batch.user_id = $2
              AND candidate.paper_id = $3
              AND batch.status IN ('ready', 'served')
              AND batch.queue_proven_empty IS TRUE
              AND batch.library_revision IS NOT NULL
              AND batch.expires_at > $4
            ",
        )
        .bind(batch_id)
        .bind(user_id.into_inner())
        .bind(paper_id)
        .bind(now)
        .fetch_optional(&self.pool)
        .await?;
        let Some(evidence) = evidence else {
            return Ok(RecommendationExplanationReadOutcome::NotFound);
        };
        let paper = sqlx::query_as::<_, PaperSummaryRow>(PAPER_SUMMARY_BY_ID)
            .bind(paper_id)
            .fetch_optional(&self.pool)
            .await?
            .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?
            .try_into()?;
        let explanations = decode_explanations(paper, evidence)?;
        Ok(RecommendationExplanationReadOutcome::Found {
            batch_id,
            paper_id,
            explanations,
        })
    }

    /// Stores feedback only for an owned, server-created batch/item pair. The
    /// user-scoped idempotency key makes retries content-stable.
    pub async fn record_feedback(
        &self,
        request: RecommendationFeedbackWrite,
    ) -> Result<RecommendationFeedbackOutcome, RecommendationBatchRepositoryError> {
        validate_feedback(&request)?;
        let mut transaction = self.pool.begin().await?;
        let batch_mode: Option<String> = sqlx::query_scalar(
            r"
            SELECT batch.mode
            FROM recommendation_batches AS batch
            JOIN recommendation_candidates AS candidate
              ON candidate.batch_id = batch.id
            WHERE batch.id = $1
              AND batch.user_id = $2
              AND candidate.paper_id = $3
              AND batch.status IN ('ready', 'served')
              AND batch.queue_proven_empty IS TRUE
              AND batch.expires_at > $4
            LIMIT 1
            ",
        )
        .bind(request.batch_id)
        .bind(request.user_id.into_inner())
        .bind(request.paper_id)
        .bind(request.created_at)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(batch_mode) = batch_mode else {
            transaction.commit().await?;
            return Ok(RecommendationFeedbackOutcome::NotFound);
        };
        let mode = RecommendationMode::parse(&batch_mode)
            .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
        let inserted = sqlx::query(
            r"
            INSERT INTO recommendation_feedback (
                id, user_id, paper_id, batch_id, feedback_type, reason,
                idempotency_key, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (user_id, idempotency_key) DO NOTHING
            ",
        )
        .bind(request.feedback_id)
        .bind(request.user_id.into_inner())
        .bind(request.paper_id)
        .bind(request.batch_id)
        .bind(request.feedback_type.as_str())
        .bind(request.reason.map(RecommendationFeedbackReason::as_str))
        .bind(request.idempotency_key)
        .bind(request.created_at)
        .execute(&mut *transaction)
        .await?
        .rows_affected()
            == 1;
        let stored = sqlx::query_as::<_, StoredFeedbackRow>(
            r"
            SELECT id, paper_id, batch_id, feedback_type, reason
            FROM recommendation_feedback
            WHERE user_id = $1 AND idempotency_key = $2
            ",
        )
        .bind(request.user_id.into_inner())
        .bind(request.idempotency_key)
        .fetch_one(&mut *transaction)
        .await?;
        let matches = stored.matches(&request);
        if !matches {
            transaction.commit().await?;
            return Ok(RecommendationFeedbackOutcome::IdempotencyConflict { mode });
        }
        if inserted {
            let feedback_revision =
                advance_feedback_revision(&mut transaction, request.user_id).await?;
            if request.feedback_type == RecommendationFeedbackType::Relevant {
                apply_relevant_category_affinity(&mut transaction, &request).await?;
            }
            sqlx::query(
                r"
                UPDATE recommendation_batches
                SET status = 'superseded'
                WHERE user_id = $1
                  AND status IN ('building', 'ready')
                  AND feedback_revision IS DISTINCT FROM $2
                ",
            )
            .bind(request.user_id.into_inner())
            .bind(feedback_revision)
            .execute(&mut *transaction)
            .await?;
            transaction.commit().await?;
            Ok(RecommendationFeedbackOutcome::Applied {
                feedback_id: stored.id,
                mode,
            })
        } else {
            transaction.commit().await?;
            Ok(RecommendationFeedbackOutcome::Replayed {
                feedback_id: stored.id,
                mode,
            })
        }
    }

    /// Returns the current feedback fence and bounded, content-free history
    /// for the exact candidates authorized by the reading-feed snapshot.
    pub async fn feedback_context(
        &self,
        user_id: AuthenticatedUserId,
        paper_ids: &[PaperId],
        now: DateTime<Utc>,
    ) -> Result<RecommendationFeedbackContext, RecommendationBatchRepositoryError> {
        if paper_ids.len() > 500
            || paper_ids.iter().any(Uuid::is_nil)
            || paper_ids.iter().collect::<BTreeSet<_>>().len() != paper_ids.len()
        {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        let revision = feedback_revision(&self.pool, user_id).await?;
        if paper_ids.is_empty() {
            return Ok(RecommendationFeedbackContext {
                revision,
                history: BTreeMap::new(),
            });
        }
        let rows = sqlx::query_as::<_, CandidateHistoryRow>(
            r"
            SELECT
                paper_id,
                count(*) FILTER (
                    WHERE event_type = 'impression_qualified' AND expires_at > $3
                ) AS qualified_impressions,
                false AS hidden,
                false AS negative_feedback
            FROM paper_interactions
            WHERE user_id = $1 AND paper_id = ANY($2)
            GROUP BY paper_id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_ids)
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        let mut history = rows
            .into_iter()
            .map(CandidateHistoryRow::into_pair)
            .collect::<BTreeMap<_, _>>();
        let feedback = sqlx::query_as::<_, NegativeFeedbackRow>(
            r"
            SELECT
                paper_id,
                bool_or(feedback_type = 'dismissed') AS hidden,
                bool_or(feedback_type IN ('not_relevant', 'dismissed')) AS negative_feedback
            FROM recommendation_feedback
            WHERE user_id = $1
              AND paper_id = ANY($2)
              AND feedback_type IN ('not_relevant', 'dismissed')
            GROUP BY paper_id
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_ids)
        .fetch_all(&self.pool)
        .await?;
        for row in feedback {
            let value = history.entry(row.paper_id).or_default();
            value.hidden |= row.hidden;
            value.negative_feedback |= row.negative_feedback;
        }
        Ok(RecommendationFeedbackContext { revision, history })
    }

    /// Serves an owned ready batch only after re-locking the same library
    /// revision and re-proving the active queue empty. A concurrent save turns
    /// the batch into `superseded` before any item can escape this transaction.
    pub async fn serve_ready(
        &self,
        request: RecommendationBatchServeRequest,
    ) -> Result<RecommendationBatchServeOutcome, RecommendationBatchRepositoryError> {
        validate_serve_request(&request)?;
        let mut transaction = self.pool.begin().await?;
        let authority = lock_queue_authority(&mut transaction, request.user_id).await?;
        let feedback_revision = lock_feedback_revision(&mut transaction, request.user_id).await?;
        let profile_revision = current_profile_revision(&mut transaction, request.user_id).await?;
        if authority.library_revision != request.library_revision || authority.active_count != 0 {
            supersede_owned_batch(&mut transaction, request.user_id, request.batch_id).await?;
            transaction.commit().await?;
            return Ok(RecommendationBatchServeOutcome::AuthorityChanged {
                current_library_revision: authority.library_revision,
                active_count: authority.active_count,
            });
        }
        let Some(batch) = batch_for_serve(&mut transaction, &request).await? else {
            transaction.commit().await?;
            return Ok(RecommendationBatchServeOutcome::NotFound);
        };
        let mode = RecommendationMode::parse(&batch.mode)
            .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
        let batch_metadata = stored_batch_metadata(&batch)?;
        let saved_search_revision_digest = if mode == RecommendationMode::Following {
            Some(current_saved_search_digest(&mut transaction, request.user_id).await?)
        } else {
            None
        };
        let batch_saved_search_revision_digest =
            decode_optional_digest(batch.saved_search_revision_digest.as_deref())?;
        let status = StoredRecommendationBatchStatus::parse(&batch.status)?;
        let Some(library_revision) = batch.library_revision else {
            return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
        };
        if mode != request.mode
            || library_revision != request.library_revision
            || batch.feedback_revision != feedback_revision
            || batch.profile_revision != profile_revision
            || batch_saved_search_revision_digest != saved_search_revision_digest
        {
            supersede_owned_batch(&mut transaction, request.user_id, request.batch_id).await?;
            transaction.commit().await?;
            return Ok(RecommendationBatchServeOutcome::AuthorityChanged {
                current_library_revision: authority.library_revision,
                active_count: authority.active_count,
            });
        }
        if batch.expires_at <= request.now {
            expire_owned_batch(&mut transaction, request.user_id, request.batch_id).await?;
            transaction.commit().await?;
            return Ok(RecommendationBatchServeOutcome::NotFound);
        }
        if !matches!(
            status,
            StoredRecommendationBatchStatus::Ready | StoredRecommendationBatchStatus::Served
        ) {
            transaction.commit().await?;
            return Ok(RecommendationBatchServeOutcome::NotFound);
        }
        let items = load_served_candidates(&mut transaction, &request).await?;
        mark_batch_served(&mut transaction, &request, &items).await?;
        transaction.commit().await?;
        Ok(RecommendationBatchServeOutcome::Found {
            batch_id: request.batch_id,
            batch_metadata,
            created_at: batch.created_at,
            mode,
            library_revision,
            items,
            next_position: stored_position(batch.next_published_at, batch.next_paper_id)?,
        })
    }

    /// Loads only bounded inactive historical identities. Private note bodies,
    /// full text, interactions, and active queue rows are absent by construction.
    pub async fn historical_seeds(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
    ) -> Result<Vec<HistoricalSeed>, RecommendationBatchRepositoryError> {
        if !(1..=100).contains(&limit) {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        load_historical_seeds(&self.pool, user_id, limit).await
    }

    /// Loads only resolved current-generation citation identities for the
    /// already-authorized candidate set. Connection summaries and source
    /// contexts are intentionally excluded from the recommendation boundary.
    pub async fn citation_neighbors(
        &self,
        paper_ids: &[PaperId],
    ) -> Result<BTreeMap<PaperId, BTreeSet<PaperId>>, RecommendationBatchRepositoryError> {
        if paper_ids.len() > 500
            || paper_ids.iter().any(Uuid::is_nil)
            || paper_ids.iter().collect::<BTreeSet<_>>().len() != paper_ids.len()
        {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        if paper_ids.is_empty() {
            return Ok(BTreeMap::new());
        }
        let rows = sqlx::query_as::<_, CitationNeighborRow>(
            r"
            SELECT connection.citing_paper_id AS paper_id,
                   connection.cited_paper_id AS neighbor_id
            FROM paper_connections AS connection
            JOIN paper_processing AS processing
              ON processing.paper_id = connection.citing_paper_id
             AND processing.generation = connection.generation
            WHERE connection.citing_paper_id = ANY($1)
            UNION
            SELECT connection.cited_paper_id AS paper_id,
                   connection.citing_paper_id AS neighbor_id
            FROM paper_connections AS connection
            JOIN paper_processing AS processing
              ON processing.paper_id = connection.citing_paper_id
             AND processing.generation = connection.generation
            WHERE connection.cited_paper_id = ANY($1)
            LIMIT 5000
            ",
        )
        .bind(paper_ids)
        .fetch_all(&self.pool)
        .await?;
        let mut neighbors = BTreeMap::<PaperId, BTreeSet<PaperId>>::new();
        for row in rows {
            neighbors
                .entry(row.paper_id)
                .or_default()
                .insert(row.neighbor_id);
        }
        Ok(neighbors)
    }

    /// Deletes only expired recommendation batches and raw explicit feedback
    /// beyond the bounded diagnostic window. Account profile and library rows
    /// are never consulted or mutated by this maintenance path.
    pub async fn cleanup_retention(
        &self,
        now: DateTime<Utc>,
        feedback_before: DateTime<Utc>,
        limit: u32,
    ) -> Result<RecommendationRetentionCleanup, RecommendationBatchRepositoryError> {
        if !(1..=10_000).contains(&limit) || feedback_before > now {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        let mut transaction = self.pool.begin().await?;
        let feedback = sqlx::query(
            r"
            DELETE FROM recommendation_feedback
            WHERE id IN (
                SELECT id
                FROM recommendation_feedback
                WHERE created_at <= $1
                ORDER BY created_at ASC, id ASC
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            ",
        )
        .bind(feedback_before)
        .bind(i64::from(limit))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        let batches = sqlx::query(
            r"
            DELETE FROM recommendation_batches
            WHERE id IN (
                SELECT id
                FROM recommendation_batches
                WHERE expires_at <= $1
                ORDER BY expires_at ASC, id ASC
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            ",
        )
        .bind(now)
        .bind(i64::from(limit))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        transaction.commit().await?;
        Ok(RecommendationRetentionCleanup { batches, feedback })
    }
}

pub struct RecommendationBatchPersistRequest<'a> {
    pub user_id: AuthenticatedUserId,
    pub batch_id: Uuid,
    pub query_key: &'a str,
    pub local_date: NaiveDate,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub next_position: Option<RecommendationPosition>,
    pub saved_search_revision_digest: Option<[u8; 32]>,
    pub batch: &'a BuiltRecommendationBatch,
}

#[derive(Debug, Clone, Copy)]
pub struct RecommendationBatchServeRequest {
    pub user_id: AuthenticatedUserId,
    pub batch_id: Uuid,
    pub mode: RecommendationMode,
    pub library_revision: i64,
    pub limit: u32,
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredRecommendationCandidate {
    pub paper: PaperSummary,
    pub position: u32,
    pub reason_codes: Vec<ExplanationCode>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RecommendationBatchServeOutcome {
    Found {
        batch_id: Uuid,
        batch_metadata: RecommendationBatchMetadata,
        created_at: DateTime<Utc>,
        mode: RecommendationMode,
        library_revision: i64,
        items: Vec<StoredRecommendationCandidate>,
        next_position: Option<RecommendationPosition>,
    },
    AuthorityChanged {
        current_library_revision: i64,
        active_count: u64,
    },
    NotFound,
}

pub struct RecommendationBatchBlockRequest<'a> {
    pub user_id: AuthenticatedUserId,
    pub batch_id: Uuid,
    pub mode: RecommendationMode,
    pub query_key: &'a str,
    pub local_date: NaiveDate,
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub saved_search_revision_digest: Option<[u8; 32]>,
    pub algorithm_version: &'a str,
    pub policy_version: &'a str,
    pub seed: u64,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecommendationRetentionCleanup {
    pub batches: u64,
    pub feedback: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecommendationFeedbackContext {
    pub revision: i64,
    pub history: BTreeMap<PaperId, RecommendationCandidateHistory>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationBatchPersistOutcome {
    Ready {
        batch_id: Uuid,
        library_revision: i64,
        candidate_count: usize,
    },
    Superseded {
        batch_id: Uuid,
        current_library_revision: i64,
        active_count: u64,
    },
    Replayed {
        batch_id: Uuid,
        status: StoredRecommendationBatchStatus,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationBatchBlockOutcome {
    QueueProvenEmpty {
        library_revision: i64,
    },
    ContextChanged,
    BlockedByQueue {
        batch_id: Uuid,
        library_revision: i64,
        active_count: u64,
    },
    Replayed {
        batch_id: Uuid,
        status: StoredRecommendationBatchStatus,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecommendationExplanationReadOutcome {
    Found {
        batch_id: Uuid,
        paper_id: PaperId,
        explanations: Vec<RecommendationExplanation>,
    },
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationFeedbackType {
    Relevant,
    NotRelevant,
    Dismissed,
}

impl RecommendationFeedbackType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Relevant => "relevant",
            Self::NotRelevant => "not_relevant",
            Self::Dismissed => "dismissed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationFeedbackReason {
    AlreadySeen,
    OffTopic,
    TooBasic,
    TooAdvanced,
    LowQuality,
    Other,
}

impl RecommendationFeedbackReason {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AlreadySeen => "already_seen",
            Self::OffTopic => "off_topic",
            Self::TooBasic => "too_basic",
            Self::TooAdvanced => "too_advanced",
            Self::LowQuality => "low_quality",
            Self::Other => "other",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecommendationFeedbackWrite {
    pub user_id: AuthenticatedUserId,
    pub feedback_id: Uuid,
    pub idempotency_key: Uuid,
    pub batch_id: Uuid,
    pub paper_id: PaperId,
    pub feedback_type: RecommendationFeedbackType,
    pub reason: Option<RecommendationFeedbackReason>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationFeedbackOutcome {
    Applied {
        feedback_id: Uuid,
        mode: RecommendationMode,
    },
    Replayed {
        feedback_id: Uuid,
        mode: RecommendationMode,
    },
    IdempotencyConflict {
        mode: RecommendationMode,
    },
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredRecommendationBatchStatus {
    Building,
    Ready,
    Served,
    Superseded,
    BlockedByQueue,
    Expired,
    Failed,
}

impl StoredRecommendationBatchStatus {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Building => "building",
            Self::Ready => "ready",
            Self::Served => "served",
            Self::Superseded => "superseded",
            Self::BlockedByQueue => "blocked_by_queue",
            Self::Expired => "expired",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, RecommendationBatchRepositoryError> {
        match value {
            "building" => Ok(Self::Building),
            "ready" => Ok(Self::Ready),
            "served" => Ok(Self::Served),
            "superseded" => Ok(Self::Superseded),
            "blocked_by_queue" => Ok(Self::BlockedByQueue),
            "expired" => Ok(Self::Expired),
            "failed" => Ok(Self::Failed),
            _ => Err(RecommendationBatchRepositoryError::InvalidPersistedData),
        }
    }
}

#[derive(Debug, Error)]
pub enum RecommendationBatchRepositoryError {
    #[error("recommendation batch request is invalid")]
    InvalidRequest,
    #[error("recommendation batch account was not found")]
    AccountNotFound,
    #[error("recommendation batch account is unavailable")]
    AccountUnavailable,
    #[error("persisted recommendation batch data is invalid")]
    InvalidPersistedData,
    #[error(transparent)]
    Database(#[from] DbError),
}

impl From<sqlx::Error> for RecommendationBatchRepositoryError {
    fn from(error: sqlx::Error) -> Self {
        Self::Database(DbError::from(error))
    }
}

#[derive(Debug, Clone, Copy)]
struct QueueAuthority {
    library_revision: i64,
    active_count: u64,
}

async fn lock_queue_authority(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<QueueAuthority, RecommendationBatchRepositoryError> {
    let status =
        sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR SHARE")
            .bind(user_id.into_inner())
            .fetch_optional(&mut **transaction)
            .await?;
    let Some(status) = status else {
        return Err(RecommendationBatchRepositoryError::AccountNotFound);
    };
    if AccountStatus::from_str(&status).ok() != Some(AccountStatus::Active) {
        return Err(RecommendationBatchRepositoryError::AccountUnavailable);
    }
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        )
        VALUES ($1, 0, 0, statement_timestamp())
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    let library_revision: i64 = sqlx::query_scalar(
        "SELECT current_revision FROM library_sync_metadata WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    let active_count: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM user_paper_library
        WHERE user_id = $1
          AND state IN ('to_read', 'inbox', 'read_next', 'reading')
          AND removed_at IS NULL
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    Ok(QueueAuthority {
        library_revision,
        active_count: u64::try_from(active_count)
            .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)?,
    })
}

async fn feedback_revision(
    pool: &PgPool,
    user_id: AuthenticatedUserId,
) -> Result<i64, RecommendationBatchRepositoryError> {
    let revision: i64 = sqlx::query_scalar(
        r"
        SELECT COALESCE(
            (
                SELECT current_revision
                FROM recommendation_feedback_revisions
                WHERE user_id = $1
            ),
            0
        )
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(pool)
    .await?;
    if revision < 0 {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(revision)
}

async fn lock_feedback_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, RecommendationBatchRepositoryError> {
    sqlx::query(
        r"
        INSERT INTO recommendation_feedback_revisions (user_id, current_revision)
        VALUES ($1, 0)
        ON CONFLICT (user_id) DO NOTHING
        ",
    )
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    let revision: i64 = sqlx::query_scalar(
        r"
        SELECT current_revision
        FROM recommendation_feedback_revisions
        WHERE user_id = $1
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision < 0 {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(revision)
}

async fn advance_feedback_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, RecommendationBatchRepositoryError> {
    let revision: i64 = sqlx::query_scalar(
        r"
        INSERT INTO recommendation_feedback_revisions (
            user_id, current_revision, updated_at
        ) VALUES ($1, 1, statement_timestamp())
        ON CONFLICT (user_id) DO UPDATE
        SET current_revision = recommendation_feedback_revisions.current_revision + 1,
            updated_at = statement_timestamp()
        RETURNING current_revision
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision <= 0 {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(revision)
}

async fn current_profile_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<i64>, RecommendationBatchRepositoryError> {
    let revision = sqlx::query_scalar::<_, i64>(
        "SELECT profile_revision FROM research_profiles WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?;
    if revision.is_some_and(|value| value <= 0) {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(revision)
}

async fn current_saved_search_digest(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<[u8; 32], RecommendationBatchRepositoryError> {
    let revisions = sqlx::query_as::<_, SavedSearchRevisionRow>(
        "SELECT id, revision FROM saved_searches WHERE user_id = $1 ORDER BY id ASC",
    )
    .bind(user_id.into_inner())
    .fetch_all(&mut **transaction)
    .await?;
    let mut digest = Sha256::new();
    digest.update(b"saved_search_context_v1");
    for row in revisions {
        digest.update(row.id.as_bytes());
        digest.update(row.revision.to_be_bytes());
    }
    Ok(digest.finalize().into())
}

fn decode_optional_digest(
    value: Option<&[u8]>,
) -> Result<Option<[u8; 32]>, RecommendationBatchRepositoryError> {
    value
        .map(|value| {
            value
                .try_into()
                .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)
        })
        .transpose()
}

async fn apply_relevant_category_affinity(
    transaction: &mut Transaction<'_, Postgres>,
    request: &RecommendationFeedbackWrite,
) -> Result<(), RecommendationBatchRepositoryError> {
    let revision = sqlx::query_scalar::<_, i64>(
        r"
        UPDATE research_profiles
        SET profile_revision = profile_revision + 1,
            updated_at = statement_timestamp()
        WHERE user_id = $1 AND personalization_enabled IS TRUE
        RETURNING profile_revision
        ",
    )
    .bind(request.user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(revision) = revision else {
        return Ok(());
    };
    if revision <= 0 {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    let category =
        sqlx::query_scalar::<_, String>("SELECT primary_category FROM papers WHERE id = $1")
            .bind(request.paper_id)
            .fetch_one(&mut **transaction)
            .await?;
    sqlx::query(
        r"
        INSERT INTO profile_categories (
            user_id, category, weight, source, created_at, updated_at
        ) VALUES ($1, $2, 1.0, 'feedback', $3, $3)
        ON CONFLICT (user_id, category, source) DO UPDATE
        SET weight = GREATEST(profile_categories.weight, EXCLUDED.weight),
            updated_at = EXCLUDED.updated_at
        ",
    )
    .bind(request.user_id.into_inner())
    .bind(category)
    .bind(request.created_at)
    .execute(&mut **transaction)
    .await?;
    sqlx::query(
        r"
        UPDATE recommendation_batches
        SET status = 'superseded'
        WHERE user_id = $1
          AND status IN ('building', 'ready')
          AND profile_revision IS DISTINCT FROM $2
        ",
    )
    .bind(request.user_id.into_inner())
    .bind(revision)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn validate_serve_request(
    request: &RecommendationBatchServeRequest,
) -> Result<(), RecommendationBatchRepositoryError> {
    if request.batch_id.is_nil()
        || request.library_revision < 0
        || !(1..=50).contains(&request.limit)
    {
        return Err(RecommendationBatchRepositoryError::InvalidRequest);
    }
    Ok(())
}

async fn supersede_owned_batch(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
) -> Result<(), RecommendationBatchRepositoryError> {
    sqlx::query(
        r"
        UPDATE recommendation_batches
        SET status = 'superseded'
        WHERE id = $1 AND user_id = $2 AND status IN ('building', 'ready')
        ",
    )
    .bind(batch_id)
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn expire_owned_batch(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    batch_id: Uuid,
) -> Result<(), RecommendationBatchRepositoryError> {
    sqlx::query(
        "UPDATE recommendation_batches SET status = 'expired' \
         WHERE id = $1 AND user_id = $2 AND status IN ('building', 'ready')",
    )
    .bind(batch_id)
    .bind(user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn batch_for_serve(
    transaction: &mut Transaction<'_, Postgres>,
    request: &RecommendationBatchServeRequest,
) -> Result<Option<StoredBatchForServeRow>, RecommendationBatchRepositoryError> {
    Ok(sqlx::query_as(
        r"
        SELECT mode, status, profile_revision, feedback_revision, library_revision,
               algorithm_version, policy_version, created_at, expires_at, next_published_at,
               next_paper_id, saved_search_revision_digest
        FROM recommendation_batches
        WHERE id = $1
          AND user_id = $2
          AND queue_proven_empty IS TRUE
        FOR UPDATE
        ",
    )
    .bind(request.batch_id)
    .bind(request.user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?)
}

async fn load_served_candidates(
    transaction: &mut Transaction<'_, Postgres>,
    request: &RecommendationBatchServeRequest,
) -> Result<Vec<StoredRecommendationCandidate>, RecommendationBatchRepositoryError> {
    let rows = sqlx::query_as::<_, StoredCandidateForServeRow>(
        r"
        SELECT
            candidate.reranked_position,
            candidate.reason_codes,
            paper.id,
            paper.arxiv_base_id,
            paper.arxiv_version,
            paper.title,
            paper.abstract AS abstract_text,
            paper.authors,
            paper.primary_category,
            paper.categories,
            paper.published_at,
            paper.updated_at,
            paper.abs_url,
            paper.pdf_url,
            processing.metadata_ready,
            processing.introduction_ready,
            processing.chat_ready,
            processing.connections_ready
        FROM recommendation_candidates AS candidate
        JOIN papers AS paper ON paper.id = candidate.paper_id
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE candidate.batch_id = $1
          AND candidate.reranked_position IS NOT NULL
          AND processing.metadata_ready
        ORDER BY candidate.reranked_position ASC, candidate.paper_id ASC
        LIMIT $2
        ",
    )
    .bind(request.batch_id)
    .bind(i64::from(request.limit))
    .fetch_all(&mut **transaction)
    .await?;
    rows.into_iter().map(TryInto::try_into).collect()
}

async fn mark_batch_served(
    transaction: &mut Transaction<'_, Postgres>,
    request: &RecommendationBatchServeRequest,
    items: &[StoredRecommendationCandidate],
) -> Result<(), RecommendationBatchRepositoryError> {
    sqlx::query(
        "UPDATE recommendation_batches SET status = 'served' \
         WHERE id = $1 AND user_id = $2 AND status IN ('ready', 'served')",
    )
    .bind(request.batch_id)
    .bind(request.user_id.into_inner())
    .execute(&mut **transaction)
    .await?;
    let paper_ids = items
        .iter()
        .map(|item| item.paper.paper_id)
        .collect::<Vec<_>>();
    if !paper_ids.is_empty() {
        sqlx::query(
            "UPDATE recommendation_candidates SET served_at = COALESCE(served_at, $3) \
             WHERE batch_id = $1 AND paper_id = ANY($2)",
        )
        .bind(request.batch_id)
        .bind(paper_ids)
        .bind(request.now)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn load_historical_seeds(
    pool: &PgPool,
    user_id: AuthenticatedUserId,
    limit: u32,
) -> Result<Vec<HistoricalSeed>, RecommendationBatchRepositoryError> {
    let rows = sqlx::query_as::<_, HistoricalSeedRow>(
        r"
        SELECT library.state, paper.id AS paper_id, paper.title,
               paper.abstract AS abstract_text, paper.categories
        FROM user_paper_library AS library
        JOIN papers AS paper ON paper.id = library.paper_id
        WHERE library.user_id = $1
          AND library.removed_at IS NULL
          AND library.state IN ('reviewed', 'archived')
        ORDER BY library.updated_at DESC, library.paper_id ASC
        LIMIT $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(i64::from(limit))
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(TryInto::try_into).collect()
}

#[derive(Debug, FromRow)]
struct ExistingBatchRow {
    id: Uuid,
    status: String,
}

#[derive(Debug, Clone, FromRow)]
struct StoredBatchForServeRow {
    mode: String,
    status: String,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    library_revision: Option<i64>,
    algorithm_version: String,
    policy_version: String,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    next_published_at: Option<DateTime<Utc>>,
    next_paper_id: Option<Uuid>,
    saved_search_revision_digest: Option<Vec<u8>>,
}

fn stored_batch_metadata(
    row: &StoredBatchForServeRow,
) -> Result<RecommendationBatchMetadata, RecommendationBatchRepositoryError> {
    let metadata = RecommendationBatchMetadata {
        profile_revision: row.profile_revision,
        feedback_revision: row.feedback_revision,
        algorithm_version: row.algorithm_version.clone(),
        recommendation_policy_version: row.policy_version.clone(),
    };
    if !metadata.structurally_valid() {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(metadata)
}

#[derive(Debug, FromRow)]
struct StoredCandidateForServeRow {
    reranked_position: Option<i32>,
    reason_codes: Vec<String>,
    #[sqlx(flatten)]
    paper: PaperSummaryRow,
}

impl TryFrom<StoredCandidateForServeRow> for StoredRecommendationCandidate {
    type Error = RecommendationBatchRepositoryError;

    fn try_from(row: StoredCandidateForServeRow) -> Result<Self, Self::Error> {
        let position = row
            .reranked_position
            .and_then(|value| u32::try_from(value).ok())
            .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
        let reason_codes = row
            .reason_codes
            .iter()
            .map(|code| ExplanationCode::parse(code))
            .collect::<Option<Vec<_>>>()
            .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
        if reason_codes.is_empty() {
            return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
        }
        Ok(Self {
            paper: row.paper.try_into()?,
            position,
            reason_codes,
        })
    }
}

#[derive(Debug, FromRow)]
struct HistoricalSeedRow {
    state: String,
    paper_id: Uuid,
    title: String,
    abstract_text: String,
    categories: Vec<String>,
}

impl TryFrom<HistoricalSeedRow> for HistoricalSeed {
    type Error = RecommendationBatchRepositoryError;

    fn try_from(row: HistoricalSeedRow) -> Result<Self, Self::Error> {
        let state = match row.state.as_str() {
            "reviewed" => HistoricalSeedState::Reviewed,
            "archived" => HistoricalSeedState::Archived,
            _ => return Err(RecommendationBatchRepositoryError::InvalidPersistedData),
        };
        let embedding =
            recommendations::metadata_embedding_v1(recommendations::MetadataEmbeddingInput {
                title: &row.title,
                abstract_text: &row.abstract_text,
                categories: &row.categories,
            });
        Ok(Self {
            paper_id: row.paper_id,
            title: row.title,
            state,
            topics: row.categories.into_iter().collect(),
            embedding,
        })
    }
}

impl ExistingBatchRow {
    fn status(
        &self,
    ) -> Result<StoredRecommendationBatchStatus, RecommendationBatchRepositoryError> {
        StoredRecommendationBatchStatus::parse(&self.status)
    }
}

#[derive(Debug, FromRow)]
struct StoredCandidateEvidenceRow {
    candidate_sources: Vec<String>,
    raw_features: serde_json::Value,
    reason_codes: Vec<String>,
    reason_evidence: serde_json::Value,
}

fn decode_explanations(
    paper: PaperSummary,
    stored: StoredCandidateEvidenceRow,
) -> Result<Vec<RecommendationExplanation>, RecommendationBatchRepositoryError> {
    if !paper.capabilities.metadata {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    let sources = stored
        .candidate_sources
        .iter()
        .map(|source| CandidateSource::parse(source))
        .collect::<Option<BTreeSet<_>>>()
        .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
    let features: RecommendationFeatures = serde_json::from_value(stored.raw_features)
        .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)?;
    let reasons: Vec<ReasonEvidence> = serde_json::from_value(stored.reason_evidence)
        .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)?;
    let topics = reasons
        .iter()
        .filter_map(|reason| match reason {
            ReasonEvidence::FollowedTopic { topic } => Some(topic.clone()),
            _ => None,
        })
        .collect();
    let candidate = GeneratedCandidate {
        document: CandidateDocument {
            paper,
            topics,
            embedding: Vec::new(),
            citation_neighbors: BTreeSet::new(),
            metadata_completeness: features.metadata_completeness,
        },
        sources,
        features,
        reasons,
        qualified_impressions: 0,
        hidden: false,
        negative_feedback: false,
    };
    let explanations = explain_candidate(&candidate)
        .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)?;
    let expected_codes = stored
        .reason_codes
        .iter()
        .map(|code| ExplanationCode::parse(code))
        .collect::<Option<Vec<_>>>()
        .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
    if explanations
        .iter()
        .map(|explanation| explanation.code)
        .ne(expected_codes)
    {
        return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
    }
    Ok(explanations)
}

#[derive(Debug, FromRow)]
struct StoredFeedbackRow {
    id: Uuid,
    paper_id: Uuid,
    batch_id: Option<Uuid>,
    feedback_type: String,
    reason: Option<String>,
}

#[derive(Debug, FromRow)]
struct CandidateHistoryRow {
    paper_id: Uuid,
    qualified_impressions: i64,
    hidden: bool,
    negative_feedback: bool,
}

impl CandidateHistoryRow {
    fn into_pair(self) -> (PaperId, RecommendationCandidateHistory) {
        (
            self.paper_id,
            RecommendationCandidateHistory {
                qualified_impressions: u32::try_from(self.qualified_impressions)
                    .unwrap_or(u32::MAX),
                hidden: self.hidden,
                negative_feedback: self.negative_feedback,
            },
        )
    }
}

#[derive(Debug, FromRow)]
struct NegativeFeedbackRow {
    paper_id: Uuid,
    hidden: bool,
    negative_feedback: bool,
}

#[derive(Debug, FromRow)]
struct CitationNeighborRow {
    paper_id: Uuid,
    neighbor_id: Uuid,
}

#[derive(Debug, FromRow)]
struct SavedSearchRevisionRow {
    id: Uuid,
    revision: i64,
}

impl StoredFeedbackRow {
    fn matches(&self, request: &RecommendationFeedbackWrite) -> bool {
        self.paper_id == request.paper_id
            && self.batch_id == Some(request.batch_id)
            && self.feedback_type == request.feedback_type.as_str()
            && self.reason.as_deref() == request.reason.map(RecommendationFeedbackReason::as_str)
    }
}

struct BatchLookup<'a> {
    user_id: AuthenticatedUserId,
    mode: RecommendationMode,
    local_date: NaiveDate,
    query_key: &'a str,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    library_revision: i64,
    algorithm_version: &'a str,
    policy_version: &'a str,
    saved_search_revision_digest: Option<[u8; 32]>,
}

async fn find_existing(
    transaction: &mut Transaction<'_, Postgres>,
    lookup: BatchLookup<'_>,
) -> Result<Option<ExistingBatchRow>, RecommendationBatchRepositoryError> {
    Ok(sqlx::query_as(
        r"
        SELECT id, status
        FROM recommendation_batches
        WHERE user_id = $1
          AND mode = $2
          AND local_date = $3
          AND query_key = $4
          AND profile_revision IS NOT DISTINCT FROM $5
          AND feedback_revision = $6
          AND library_revision = $7
          AND algorithm_version = $8
          AND policy_version = $9
          AND saved_search_revision_digest IS NOT DISTINCT FROM $10
        FOR UPDATE
        ",
    )
    .bind(lookup.user_id.into_inner())
    .bind(lookup.mode.as_str())
    .bind(lookup.local_date)
    .bind(lookup.query_key)
    .bind(lookup.profile_revision)
    .bind(lookup.feedback_revision)
    .bind(lookup.library_revision)
    .bind(lookup.algorithm_version)
    .bind(lookup.policy_version)
    .bind(
        lookup
            .saved_search_revision_digest
            .map(|digest| digest.to_vec()),
    )
    .fetch_optional(&mut **transaction)
    .await?)
}

struct BatchHeader<'a> {
    batch_id: Uuid,
    user_id: AuthenticatedUserId,
    mode: RecommendationMode,
    query_key: &'a str,
    local_date: NaiveDate,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    library_revision: i64,
    queue_proven_empty: bool,
    algorithm_version: &'a str,
    policy_version: &'a str,
    seed: u64,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    status: StoredRecommendationBatchStatus,
    next_position: Option<RecommendationPosition>,
    saved_search_revision_digest: Option<[u8; 32]>,
    metadata: serde_json::Value,
}

async fn insert_batch_header(
    transaction: &mut Transaction<'_, Postgres>,
    header: BatchHeader<'_>,
) -> Result<(), RecommendationBatchRepositoryError> {
    let seed = i64::try_from(header.seed)
        .map_err(|_| RecommendationBatchRepositoryError::InvalidRequest)?;
    sqlx::query(
        r"
        INSERT INTO recommendation_batches (
            id, user_id, anonymous_session_id, mode, query_key, local_date,
            profile_revision, feedback_revision, library_revision, queue_proven_empty,
            algorithm_version, policy_version, seed, created_at, expires_at,
            status, metadata, next_published_at, next_paper_id,
            saved_search_revision_digest
        )
        VALUES (
            $1, $2, NULL, $3, $4, $5,
            $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19
        )
        ",
    )
    .bind(header.batch_id)
    .bind(header.user_id.into_inner())
    .bind(header.mode.as_str())
    .bind(header.query_key)
    .bind(header.local_date)
    .bind(header.profile_revision)
    .bind(header.feedback_revision)
    .bind(header.library_revision)
    .bind(header.queue_proven_empty)
    .bind(header.algorithm_version)
    .bind(header.policy_version)
    .bind(seed)
    .bind(header.created_at)
    .bind(header.expires_at)
    .bind(header.status.as_str())
    .bind(header.metadata)
    .bind(header.next_position.map(|position| position.published_at))
    .bind(header.next_position.map(|position| position.paper_id))
    .bind(
        header
            .saved_search_revision_digest
            .map(|digest| digest.to_vec()),
    )
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_candidates(
    transaction: &mut Transaction<'_, Postgres>,
    batch_id: Uuid,
    batch: &BuiltRecommendationBatch,
) -> Result<(), RecommendationBatchRepositoryError> {
    for (position, candidate) in batch.candidates.iter().enumerate() {
        let sources = candidate
            .scored
            .candidate
            .sources
            .iter()
            .map(|source| source.as_str())
            .collect::<Vec<_>>();
        let reason_codes = candidate
            .explanations
            .iter()
            .map(|explanation| explanation.code.as_str())
            .collect::<Vec<_>>();
        let raw_features = serde_json::to_value(candidate.scored.candidate.features)
            .map_err(|_| RecommendationBatchRepositoryError::InvalidRequest)?;
        let reason_evidence = serde_json::to_value(&candidate.scored.candidate.reasons)
            .map_err(|_| RecommendationBatchRepositoryError::InvalidRequest)?;
        let position = i32::try_from(position)
            .map_err(|_| RecommendationBatchRepositoryError::InvalidRequest)?;
        sqlx::query(
            r"
            INSERT INTO recommendation_candidates (
                batch_id, paper_id, candidate_sources, raw_features, base_score,
                reranked_position, reason_codes, reason_evidence, served_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL)
            ",
        )
        .bind(batch_id)
        .bind(candidate.scored.candidate.document.paper.paper_id)
        .bind(sources)
        .bind(raw_features)
        .bind(candidate.scored.base_score)
        .bind(position)
        .bind(reason_codes)
        .bind(reason_evidence)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

fn validate_persist_request(
    request: &RecommendationBatchPersistRequest<'_>,
) -> Result<(), RecommendationBatchRepositoryError> {
    if request.batch.algorithm_version != RECOMMENDATION_ALGORITHM_VERSION_V1
        || request.batch_id.is_nil()
        || request.batch.library_revision < 0
        || request.batch.feedback_revision < 0
        || request.batch.candidates.len() > 100
        || (request.batch.mode == RecommendationMode::Following)
            != request.saved_search_revision_digest.is_some()
        || request
            .next_position
            .is_some_and(|position| position.paper_id.is_nil())
        || !valid_common(
            request.query_key,
            request.batch.profile_revision,
            &request.batch.policy_version,
            request.batch.seed,
            request.created_at,
            request.expires_at,
        )
    {
        return Err(RecommendationBatchRepositoryError::InvalidRequest);
    }
    let mut paper_ids = BTreeSet::new();
    if request.batch.candidates.iter().any(|candidate| {
        candidate.explanations.is_empty()
            || !candidate.scored.base_score.is_finite()
            || !paper_ids.insert(candidate.scored.candidate.document.paper.paper_id)
    }) {
        return Err(RecommendationBatchRepositoryError::InvalidRequest);
    }
    Ok(())
}

fn stored_position(
    published_at: Option<DateTime<Utc>>,
    paper_id: Option<Uuid>,
) -> Result<Option<RecommendationPosition>, RecommendationBatchRepositoryError> {
    match (published_at, paper_id) {
        (None, None) => Ok(None),
        (Some(published_at), Some(paper_id)) if !paper_id.is_nil() => {
            Ok(Some(RecommendationPosition {
                published_at,
                paper_id,
            }))
        }
        _ => Err(RecommendationBatchRepositoryError::InvalidPersistedData),
    }
}

fn validate_block_request(
    request: &RecommendationBatchBlockRequest<'_>,
) -> Result<(), RecommendationBatchRepositoryError> {
    if request.batch_id.is_nil()
        || request.algorithm_version != RECOMMENDATION_ALGORITHM_VERSION_V1
        || request.feedback_revision < 0
        || (request.mode == RecommendationMode::Following)
            != request.saved_search_revision_digest.is_some()
        || !valid_common(
            request.query_key,
            request.profile_revision,
            request.policy_version,
            request.seed,
            request.created_at,
            request.expires_at,
        )
    {
        return Err(RecommendationBatchRepositoryError::InvalidRequest);
    }
    Ok(())
}

fn validate_feedback(
    request: &RecommendationFeedbackWrite,
) -> Result<(), RecommendationBatchRepositoryError> {
    if request.feedback_id.is_nil()
        || request.idempotency_key.is_nil()
        || request.batch_id.is_nil()
        || request.paper_id.is_nil()
        || (request.feedback_type == RecommendationFeedbackType::Relevant
            && request.reason.is_some())
    {
        return Err(RecommendationBatchRepositoryError::InvalidRequest);
    }
    Ok(())
}

fn valid_common(
    query_key: &str,
    profile_revision: Option<i64>,
    policy_version: &str,
    seed: u64,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
) -> bool {
    !query_key.is_empty()
        && query_key.len() <= 160
        && query_key.trim() == query_key
        && !query_key.contains('\0')
        && profile_revision.is_none_or(|revision| revision >= 0)
        && valid_version(policy_version)
        && i64::try_from(seed).is_ok()
        && expires_at > created_at
        && expires_at <= created_at + chrono::Duration::days(30)
}

fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}

#[cfg(test)]
mod tests {
    use domain::Capabilities;
    use url::Url;

    use super::*;

    #[test]
    fn versions_and_private_query_keys_are_strictly_bounded() {
        assert!(valid_version("weighted_v1"));
        assert!(!valid_version("Weighted v1"));
        assert!(!valid_common(
            " bad ",
            None,
            "weighted_v1",
            1,
            DateTime::UNIX_EPOCH,
            DateTime::UNIX_EPOCH + chrono::Duration::hours(1),
        ));
    }

    #[test]
    fn served_batch_metadata_rejects_corrupt_revisions_and_versions() {
        let valid = stored_batch_metadata(&stored_batch_row()).unwrap();
        assert_eq!(valid.profile_revision, Some(3));
        assert_eq!(valid.feedback_revision, 4);
        assert_eq!(valid.algorithm_version, "recommendations_v1");
        assert_eq!(valid.recommendation_policy_version, "weighted_v1");

        let mut row = stored_batch_row();
        row.profile_revision = Some(-1);
        assert!(matches!(
            stored_batch_metadata(&row),
            Err(RecommendationBatchRepositoryError::InvalidPersistedData)
        ));

        let mut row = stored_batch_row();
        row.feedback_revision = -1;
        assert!(matches!(
            stored_batch_metadata(&row),
            Err(RecommendationBatchRepositoryError::InvalidPersistedData)
        ));

        let mut row = stored_batch_row();
        row.algorithm_version = String::new();
        assert!(matches!(
            stored_batch_metadata(&row),
            Err(RecommendationBatchRepositoryError::InvalidPersistedData)
        ));

        let mut row = stored_batch_row();
        row.policy_version = "a".repeat(65);
        assert!(matches!(
            stored_batch_metadata(&row),
            Err(RecommendationBatchRepositoryError::InvalidPersistedData)
        ));
    }

    #[test]
    fn explanation_replay_derives_behavior_from_stored_features() {
        let features = RecommendationFeatures {
            recency: 1.0,
            repeat_exposure: 0.4,
            metadata_completeness: 1.0,
            ..RecommendationFeatures::ZERO
        };
        let explanations = decode_explanations(
            paper_summary(),
            StoredCandidateEvidenceRow {
                candidate_sources: vec!["recent".to_owned()],
                raw_features: serde_json::to_value(features).unwrap(),
                reason_codes: vec!["recent_category".to_owned()],
                reason_evidence: serde_json::to_value(vec![ReasonEvidence::RecentCategory {
                    category: "cs.CL".to_owned(),
                }])
                .unwrap(),
            },
        )
        .unwrap();

        assert_eq!(explanations.len(), 1);
        assert!(explanations[0].behavior_used);
    }

    fn stored_batch_row() -> StoredBatchForServeRow {
        StoredBatchForServeRow {
            mode: "recent".to_owned(),
            status: "ready".to_owned(),
            profile_revision: Some(3),
            feedback_revision: 4,
            library_revision: Some(5),
            algorithm_version: "recommendations_v1".to_owned(),
            policy_version: "weighted_v1".to_owned(),
            created_at: DateTime::UNIX_EPOCH,
            expires_at: DateTime::UNIX_EPOCH + chrono::Duration::hours(1),
            next_published_at: None,
            next_paper_id: None,
            saved_search_revision_digest: None,
        }
    }

    fn paper_summary() -> PaperSummary {
        PaperSummary {
            paper_id: Uuid::from_u128(42),
            arxiv_id: "2608.00042v1".to_owned(),
            title: "Stored explanation evidence".to_owned(),
            abstract_text: "Metadata-only replay fixture.".to_owned(),
            authors: vec!["Ada Reader".to_owned()],
            primary_category: "cs.CL".to_owned(),
            categories: vec!["cs.CL".to_owned()],
            published_at: DateTime::UNIX_EPOCH,
            updated_at: DateTime::UNIX_EPOCH,
            abs_url: Url::parse("https://arxiv.org/abs/2608.00042v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2608.00042v1").unwrap(),
            capabilities: Capabilities::metadata_only(),
        }
    }
}
