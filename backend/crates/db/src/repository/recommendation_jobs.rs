use std::{collections::BTreeMap, str::FromStr as _, time::Duration};

use chrono::{DateTime, NaiveDate, Utc};
use domain::{AccountStatus, AuthenticatedUserId, PaperId, PaperSummary};
use reading_feed::RecommendationPosition;
use recommendations::RecommendationMode;
use sha2::{Digest as _, Sha256};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;

use super::{DbError, rows::PaperSummaryRow};

const MAX_GENERATION_CANDIDATES: usize = 50;
const MAX_EXHAUSTED_LEASE_REAP: i64 = 100;

/// Durable, account-owned recommendation work. It is intentionally separate
/// from the paper-processing queue whose identity is paper/generation/kind.
#[derive(Clone)]
pub struct RecommendationGenerationRepository {
    pool: PgPool,
}

impl RecommendationGenerationRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Re-proves the initial account queue/revision fence and records one exact
    /// content-free intent. Generator code is never invoked by this method.
    #[allow(clippy::too_many_lines)] // One transaction binds authority, private revisions, identity, and ordered candidates atomically.
    pub async fn enqueue(
        &self,
        request: RecommendationGenerationEnqueue<'_>,
    ) -> Result<RecommendationGenerationEnqueueOutcome, RecommendationGenerationRepositoryError>
    {
        validate_enqueue(&request)?;
        let fingerprint = intent_fingerprint(&request);
        let mut transaction = self.pool.begin().await?;
        let authority = lock_authority(&mut transaction, request.user_id).await?;
        if authority.library_revision != request.library_revision || authority.active_count != 0 {
            transaction.commit().await?;
            return Ok(RecommendationGenerationEnqueueOutcome::AuthorityChanged {
                library_revision: authority.library_revision,
                active_count: authority.active_count,
            });
        }
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
            return Ok(RecommendationGenerationEnqueueOutcome::ContextChanged);
        }
        let inserted = sqlx::query_scalar::<_, Uuid>(
            r"
            INSERT INTO recommendation_generation_jobs (
                id, user_id, batch_id, mode, query_key, local_date,
                profile_revision, feedback_revision, library_revision,
                algorithm_version, policy_version, seed, page_limit,
                intent_fingerprint, saved_search_revision_digest,
                next_published_at, next_paper_id,
                state, max_attempts, available_at, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6,
                $7, $8, $9, $10, $11, $12, $13,
                $14, $15, $16, $17, 'queued', $18, $19, $19, $19
            )
            ON CONFLICT (user_id, intent_fingerprint) DO NOTHING
            RETURNING id
            ",
        )
        .bind(request.job_id)
        .bind(request.user_id.into_inner())
        .bind(request.batch_id)
        .bind(request.mode.as_str())
        .bind(request.query_key)
        .bind(request.local_date)
        .bind(request.profile_revision)
        .bind(request.feedback_revision)
        .bind(request.library_revision)
        .bind(request.algorithm_version)
        .bind(request.policy_version)
        .bind(
            i64::try_from(request.seed)
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidRequest)?,
        )
        .bind(
            i32::try_from(request.page_limit)
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidRequest)?,
        )
        .bind(fingerprint.as_slice())
        .bind(
            request
                .saved_search_revision_digest
                .map(|value| value.to_vec()),
        )
        .bind(request.next_position.map(|position| position.published_at))
        .bind(request.next_position.map(|position| position.paper_id))
        .bind(
            i32::try_from(request.max_attempts)
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidRequest)?,
        )
        .bind(request.now)
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(job_id) = inserted {
            insert_candidate_identities(&mut transaction, job_id, request.candidate_paper_ids)
                .await?;
            transaction.commit().await?;
            return Ok(RecommendationGenerationEnqueueOutcome::Queued {
                job_id,
                batch_id: request.batch_id,
            });
        }
        let existing = load_existing_intent(&mut transaction, request.user_id, &fingerprint)
            .await?
            .ok_or(RecommendationGenerationRepositoryError::InvalidPersistedData)?;
        let candidates = candidate_ids(&mut transaction, existing.id).await?;
        if !existing.matches(&request) || candidates != request.candidate_paper_ids {
            return Err(RecommendationGenerationRepositoryError::FingerprintCollision);
        }
        let state = RecommendationGenerationJobState::parse(&existing.state)?;
        transaction.commit().await?;
        Ok(RecommendationGenerationEnqueueOutcome::Replayed {
            job_id: existing.id,
            batch_id: existing.batch_id,
            state,
        })
    }

    /// Claims at most one due intent using a bounded, recoverable lease.
    pub async fn claim(
        &self,
        worker_id: &str,
        now: DateTime<Utc>,
        lease_duration: Duration,
    ) -> Result<Option<ClaimedRecommendationGeneration>, RecommendationGenerationRepositoryError>
    {
        if !valid_worker_id(worker_id)
            || lease_duration < Duration::from_secs(5)
            || lease_duration > Duration::from_secs(15 * 60)
        {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let lease_seconds = lease_duration.as_secs_f64();
        sqlx::query(
            r"
            WITH exhausted AS (
                SELECT id
                FROM recommendation_generation_jobs
                WHERE state = 'running'
                  AND lease_expires_at <= $1
                  AND attempts >= max_attempts
                ORDER BY lease_expires_at ASC, id ASC
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            UPDATE recommendation_generation_jobs AS job
            SET state = 'failed',
                lease_owner = NULL,
                lease_expires_at = NULL,
                last_error_code = 'lease_exhausted',
                completed_at = $1,
                updated_at = $1
            FROM exhausted
            WHERE job.id = exhausted.id
            ",
        )
        .bind(now)
        .bind(MAX_EXHAUSTED_LEASE_REAP)
        .execute(&self.pool)
        .await?;
        let row = sqlx::query_as::<_, ClaimedGenerationRow>(
            r"
            WITH candidate AS (
                SELECT id
                FROM recommendation_generation_jobs
                WHERE available_at <= $2
                  AND attempts < max_attempts
                  AND (
                      state = 'queued'
                      OR (state = 'running' AND lease_expires_at <= $2)
                  )
                ORDER BY available_at ASC, created_at ASC, id ASC
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            UPDATE recommendation_generation_jobs AS job
            SET state = 'running',
                attempts = attempts + 1,
                lease_owner = $1,
                lease_expires_at = $2 + make_interval(secs => $3),
                updated_at = $2
            FROM candidate
            WHERE job.id = candidate.id
            RETURNING
                job.id, job.user_id, job.batch_id, job.mode, job.query_key,
                job.local_date, job.profile_revision, job.feedback_revision,
                job.library_revision, job.algorithm_version, job.policy_version,
                job.seed, job.page_limit, job.next_published_at,
                job.next_paper_id, job.saved_search_revision_digest,
                job.attempts, job.max_attempts,
                job.lease_expires_at,
                (
                    SELECT count(*)
                    FROM recommendation_generation_candidates AS candidate
                    WHERE candidate.job_id = job.id
                ) AS candidate_count
            ",
        )
        .bind(worker_id)
        .bind(now)
        .bind(lease_seconds)
        .fetch_optional(&self.pool)
        .await?;
        row.map(TryInto::try_into).transpose()
    }

    /// Hydrates only public paper metadata for the exact ordered identities
    /// stored with a claimed intent.
    pub async fn candidates(
        &self,
        job_id: Uuid,
    ) -> Result<Vec<PaperSummary>, RecommendationGenerationRepositoryError> {
        if job_id.is_nil() {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let rows = sqlx::query_as::<_, GenerationCandidateRow>(
            r"
            SELECT candidate.ordinal,
                   paper.id, paper.arxiv_base_id, paper.arxiv_version,
                   paper.title, paper.abstract AS abstract_text, paper.authors,
                   paper.primary_category, paper.categories, paper.published_at,
                   paper.updated_at, paper.abs_url, paper.pdf_url,
                   processing.metadata_ready, processing.introduction_ready,
                   processing.chat_ready, processing.connections_ready
            FROM recommendation_generation_candidates AS candidate
            JOIN papers AS paper ON paper.id = candidate.paper_id
            JOIN paper_processing AS processing ON processing.paper_id = paper.id
            WHERE candidate.job_id = $1 AND processing.metadata_ready
            ORDER BY candidate.ordinal ASC
            ",
        )
        .bind(job_id)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| row.paper.try_into().map_err(Into::into))
            .collect()
    }

    pub async fn complete(
        &self,
        job_id: Uuid,
        worker_id: &str,
        now: DateTime<Utc>,
        state: RecommendationGenerationJobState,
    ) -> Result<(), RecommendationGenerationRepositoryError> {
        if job_id.is_nil()
            || !valid_worker_id(worker_id)
            || !matches!(
                state,
                RecommendationGenerationJobState::Completed
                    | RecommendationGenerationJobState::Superseded
            )
        {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let updated = sqlx::query(
            r"
            UPDATE recommendation_generation_jobs
            SET state = $4,
                lease_owner = NULL,
                lease_expires_at = NULL,
                completed_at = $3,
                updated_at = $3
            WHERE id = $1
              AND state = 'running'
              AND lease_owner = $2
              AND lease_expires_at > $3
            ",
        )
        .bind(job_id)
        .bind(worker_id)
        .bind(now)
        .bind(state.as_str())
        .execute(&self.pool)
        .await?
        .rows_affected();
        if updated != 1 {
            return Err(RecommendationGenerationRepositoryError::LeaseLost);
        }
        Ok(())
    }

    pub async fn retry(
        &self,
        job_id: Uuid,
        worker_id: &str,
        now: DateTime<Utc>,
        retry_at: DateTime<Utc>,
        error_code: &str,
    ) -> Result<RecommendationGenerationRetryOutcome, RecommendationGenerationRepositoryError> {
        if job_id.is_nil()
            || !valid_worker_id(worker_id)
            || retry_at < now
            || retry_at > now + chrono::Duration::hours(1)
            || !valid_error_code(error_code)
        {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let row = sqlx::query_as::<_, RetryRow>(
            r"
            UPDATE recommendation_generation_jobs
            SET state = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'queued' END,
                available_at = CASE WHEN attempts >= max_attempts THEN available_at ELSE $4 END,
                lease_owner = NULL,
                lease_expires_at = NULL,
                last_error_code = $5,
                completed_at = CASE WHEN attempts >= max_attempts THEN $3 ELSE NULL END,
                updated_at = $3
            WHERE id = $1
              AND state = 'running'
              AND lease_owner = $2
              AND lease_expires_at > $3
            RETURNING state, attempts
            ",
        )
        .bind(job_id)
        .bind(worker_id)
        .bind(now)
        .bind(retry_at)
        .bind(error_code)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else {
            return Err(RecommendationGenerationRepositoryError::LeaseLost);
        };
        Ok(if row.state == "failed" {
            RecommendationGenerationRetryOutcome::Failed {
                attempts: u32::try_from(row.attempts)
                    .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)?,
            }
        } else if row.state == "queued" {
            RecommendationGenerationRetryOutcome::Queued {
                attempts: u32::try_from(row.attempts)
                    .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)?,
            }
        } else {
            return Err(RecommendationGenerationRepositoryError::InvalidPersistedData);
        })
    }

    /// Returns exact saved-query matches for already-authorized candidates and
    /// a stable revision digest. Query text stays inside `PostgreSQL` and is never
    /// carried into a job, recommendation reason, log, metric, or trace.
    pub async fn saved_search_context(
        &self,
        user_id: AuthenticatedUserId,
        paper_ids: &[PaperId],
    ) -> Result<SavedSearchRecommendationContext, RecommendationGenerationRepositoryError> {
        if paper_ids.len() > MAX_GENERATION_CANDIDATES
            || paper_ids.iter().any(Uuid::is_nil)
            || paper_ids
                .iter()
                .copied()
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                != paper_ids.len()
        {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let revisions = sqlx::query_as::<_, SavedSearchRevisionRow>(
            "SELECT id, revision FROM saved_searches WHERE user_id = $1 ORDER BY id ASC",
        )
        .bind(user_id.into_inner())
        .fetch_all(&self.pool)
        .await?;
        let revision_digest = saved_search_digest(&revisions);
        if paper_ids.is_empty() || revisions.is_empty() {
            return Ok(SavedSearchRecommendationContext {
                revision_digest,
                matches: BTreeMap::new(),
            });
        }
        let rows = sqlx::query_as::<_, SavedSearchMatchRow>(
            r"
            SELECT DISTINCT ON (paper.id)
                   paper.id AS paper_id, saved.id AS saved_search_id
            FROM papers AS paper
            JOIN saved_searches AS saved ON saved.user_id = $1
            WHERE paper.id = ANY($2)
              AND paper.search_document @@ websearch_to_tsquery(
                    'english'::regconfig, saved.normalized_query
                  )
              AND (
                    cardinality(saved.categories) = 0
                    OR paper.categories && saved.categories
                  )
              AND (
                    cardinality(saved.topics) = 0
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(saved.topics) AS requested_topic(value)
                        WHERE paper.search_document @@ websearch_to_tsquery(
                            'english'::regconfig,
                            requested_topic.value
                        )
                    )
                  )
              AND (saved.published_after IS NULL OR paper.published_at::date >= saved.published_after)
              AND (saved.published_before IS NULL OR paper.published_at::date <= saved.published_before)
              AND 'arxiv' = ANY(saved.sources)
            ORDER BY paper.id, saved.updated_at DESC, saved.id DESC
            ",
        )
        .bind(user_id.into_inner())
        .bind(paper_ids)
        .fetch_all(&self.pool)
        .await?;
        Ok(SavedSearchRecommendationContext {
            revision_digest,
            matches: rows
                .into_iter()
                .map(|row| (row.paper_id, row.saved_search_id))
                .collect(),
        })
    }

    /// Deletes bounded old terminal work and old pending work left dormant by
    /// rollback. A running job is eligible only after its lease has expired;
    /// live owners are never removed.
    pub async fn cleanup_completed(
        &self,
        before: DateTime<Utc>,
        limit: u32,
    ) -> Result<RecommendationGenerationCleanup, RecommendationGenerationRepositoryError> {
        if !(1..=10_000).contains(&limit) {
            return Err(RecommendationGenerationRepositoryError::InvalidRequest);
        }
        let row = sqlx::query_as::<_, RecommendationGenerationCleanupRow>(
            r"
            WITH deleted AS (
                DELETE FROM recommendation_generation_jobs
                WHERE id IN (
                    SELECT id
                    FROM recommendation_generation_jobs
                    WHERE (
                            state IN ('completed', 'superseded', 'failed')
                            AND completed_at <= $1
                          )
                       OR (state = 'queued' AND created_at <= $1)
                       OR (
                            state = 'running'
                            AND created_at <= $1
                            AND lease_expires_at <= statement_timestamp()
                          )
                    ORDER BY COALESCE(completed_at, created_at) ASC, id ASC
                    LIMIT $2
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING 1
            ), backlog AS (
                SELECT count(*)::bigint AS backlog_items,
                       CASE
                           WHEN min(created_at) IS NULL THEN NULL
                           ELSE extract(epoch FROM greatest(
                               statement_timestamp() - min(created_at),
                               interval '0 seconds'
                           ))::double precision
                       END AS oldest_age_seconds
                FROM recommendation_generation_jobs
                WHERE state IN ('queued', 'running')
            )
            SELECT (SELECT count(*)::bigint FROM deleted) AS removed,
                   backlog_items, oldest_age_seconds
            FROM backlog
            ",
        )
        .bind(before)
        .bind(i64::from(limit))
        .fetch_one(&self.pool)
        .await?;
        row.try_into()
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecommendationGenerationCleanup {
    pub removed: u64,
    pub backlog_items: u64,
    pub oldest_age_seconds: Option<f64>,
}

#[derive(Debug, FromRow)]
struct RecommendationGenerationCleanupRow {
    removed: i64,
    backlog_items: i64,
    oldest_age_seconds: Option<f64>,
}

impl TryFrom<RecommendationGenerationCleanupRow> for RecommendationGenerationCleanup {
    type Error = RecommendationGenerationRepositoryError;

    fn try_from(row: RecommendationGenerationCleanupRow) -> Result<Self, Self::Error> {
        if row
            .oldest_age_seconds
            .is_some_and(|age| !age.is_finite() || age < 0.0)
        {
            return Err(RecommendationGenerationRepositoryError::InvalidPersistedData);
        }
        Ok(Self {
            removed: u64::try_from(row.removed)
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)?,
            backlog_items: u64::try_from(row.backlog_items)
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)?,
            oldest_age_seconds: row.oldest_age_seconds,
        })
    }
}

#[derive(Clone, Copy)]
pub struct RecommendationGenerationEnqueue<'a> {
    pub user_id: AuthenticatedUserId,
    pub job_id: Uuid,
    pub batch_id: Uuid,
    pub mode: RecommendationMode,
    pub query_key: &'a str,
    pub local_date: NaiveDate,
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub library_revision: i64,
    pub algorithm_version: &'a str,
    pub policy_version: &'a str,
    pub seed: u64,
    pub page_limit: u32,
    pub candidate_paper_ids: &'a [PaperId],
    pub saved_search_revision_digest: Option<[u8; 32]>,
    pub next_position: Option<RecommendationPosition>,
    pub max_attempts: u32,
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGenerationEnqueueOutcome {
    Queued {
        job_id: Uuid,
        batch_id: Uuid,
    },
    Replayed {
        job_id: Uuid,
        batch_id: Uuid,
        state: RecommendationGenerationJobState,
    },
    AuthorityChanged {
        library_revision: i64,
        active_count: u64,
    },
    ContextChanged,
}

#[derive(Debug, Clone)]
pub struct ClaimedRecommendationGeneration {
    pub job_id: Uuid,
    pub user_id: AuthenticatedUserId,
    pub batch_id: Uuid,
    pub mode: RecommendationMode,
    pub query_key: String,
    pub local_date: NaiveDate,
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub library_revision: i64,
    pub algorithm_version: String,
    pub policy_version: String,
    pub seed: u64,
    pub page_limit: u32,
    pub next_position: Option<RecommendationPosition>,
    pub saved_search_revision_digest: Option<[u8; 32]>,
    pub attempt: u32,
    pub max_attempts: u32,
    pub candidate_count: u32,
    pub lease_expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGenerationJobState {
    Queued,
    Running,
    Completed,
    Superseded,
    Failed,
}

impl RecommendationGenerationJobState {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Superseded => "superseded",
            Self::Failed => "failed",
        }
    }

    fn parse(value: &str) -> Result<Self, RecommendationGenerationRepositoryError> {
        match value {
            "queued" => Ok(Self::Queued),
            "running" => Ok(Self::Running),
            "completed" => Ok(Self::Completed),
            "superseded" => Ok(Self::Superseded),
            "failed" => Ok(Self::Failed),
            _ => Err(RecommendationGenerationRepositoryError::InvalidPersistedData),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGenerationRetryOutcome {
    Queued { attempts: u32 },
    Failed { attempts: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedSearchRecommendationContext {
    pub revision_digest: [u8; 32],
    pub matches: BTreeMap<PaperId, Uuid>,
}

#[derive(Debug, Error)]
pub enum RecommendationGenerationRepositoryError {
    #[error("recommendation generation request is invalid")]
    InvalidRequest,
    #[error("recommendation generation account was not found")]
    AccountNotFound,
    #[error("recommendation generation account is unavailable")]
    AccountUnavailable,
    #[error("recommendation generation lease is no longer owned")]
    LeaseLost,
    #[error("recommendation generation intent fingerprint collided")]
    FingerprintCollision,
    #[error("persisted recommendation generation data is invalid")]
    InvalidPersistedData,
    #[error(transparent)]
    Database(#[from] DbError),
}

impl From<sqlx::Error> for RecommendationGenerationRepositoryError {
    fn from(error: sqlx::Error) -> Self {
        Self::Database(DbError::from(error))
    }
}

#[derive(Debug, Clone, Copy)]
struct QueueAuthority {
    library_revision: i64,
    active_count: u64,
}

async fn lock_authority(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<QueueAuthority, RecommendationGenerationRepositoryError> {
    let status =
        sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1 FOR SHARE")
            .bind(user_id.into_inner())
            .fetch_optional(&mut **transaction)
            .await?;
    let Some(status) = status else {
        return Err(RecommendationGenerationRepositoryError::AccountNotFound);
    };
    if AccountStatus::from_str(&status).ok() != Some(AccountStatus::Active) {
        return Err(RecommendationGenerationRepositoryError::AccountUnavailable);
    }
    sqlx::query(
        r"
        INSERT INTO library_sync_metadata (
            user_id, current_revision, purged_through_revision, updated_at
        ) VALUES ($1, 0, 0, statement_timestamp())
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
            .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)?,
    })
}

async fn lock_feedback_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, RecommendationGenerationRepositoryError> {
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
    let value: i64 = sqlx::query_scalar(
        "SELECT current_revision FROM recommendation_feedback_revisions WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if value < 0 {
        return Err(RecommendationGenerationRepositoryError::InvalidPersistedData);
    }
    Ok(value)
}

async fn current_profile_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<i64>, RecommendationGenerationRepositoryError> {
    let value = sqlx::query_scalar::<_, i64>(
        "SELECT profile_revision FROM research_profiles WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?;
    if value.is_some_and(|revision| revision <= 0) {
        return Err(RecommendationGenerationRepositoryError::InvalidPersistedData);
    }
    Ok(value)
}

async fn current_saved_search_digest(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<[u8; 32], RecommendationGenerationRepositoryError> {
    let revisions = sqlx::query_as::<_, SavedSearchRevisionRow>(
        "SELECT id, revision FROM saved_searches WHERE user_id = $1 ORDER BY id ASC",
    )
    .bind(user_id.into_inner())
    .fetch_all(&mut **transaction)
    .await?;
    Ok(saved_search_digest(&revisions))
}

fn saved_search_digest(revisions: &[SavedSearchRevisionRow]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"saved_search_context_v1");
    for row in revisions {
        digest.update(row.id.as_bytes());
        digest.update(row.revision.to_be_bytes());
    }
    digest.finalize().into()
}

async fn insert_candidate_identities(
    transaction: &mut Transaction<'_, Postgres>,
    job_id: Uuid,
    paper_ids: &[PaperId],
) -> Result<(), RecommendationGenerationRepositoryError> {
    for (ordinal, paper_id) in paper_ids.iter().enumerate() {
        sqlx::query(
            "INSERT INTO recommendation_generation_candidates (job_id, ordinal, paper_id) VALUES ($1, $2, $3)",
        )
        .bind(job_id)
        .bind(i32::try_from(ordinal).map_err(|_| {
            RecommendationGenerationRepositoryError::InvalidRequest
        })?)
        .bind(paper_id)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

fn validate_enqueue(
    request: &RecommendationGenerationEnqueue<'_>,
) -> Result<(), RecommendationGenerationRepositoryError> {
    let unique = request
        .candidate_paper_ids
        .iter()
        .copied()
        .collect::<std::collections::BTreeSet<_>>();
    let next_matches = request.next_position.is_none_or(|position| {
        request
            .candidate_paper_ids
            .last()
            .is_some_and(|paper_id| *paper_id == position.paper_id)
    });
    if request.job_id.is_nil()
        || request.batch_id.is_nil()
        || request.feedback_revision < 0
        || request.library_revision < 0
        || request.profile_revision.is_some_and(|value| value <= 0)
        || (request.mode == RecommendationMode::Following)
            != request.saved_search_revision_digest.is_some()
        || !(1..=50).contains(&request.page_limit)
        || !(1..=10).contains(&request.max_attempts)
        || request.candidate_paper_ids.len() > MAX_GENERATION_CANDIDATES
        || unique.len() != request.candidate_paper_ids.len()
        || request.candidate_paper_ids.iter().any(Uuid::is_nil)
        || !next_matches
        || !valid_text(request.query_key, 160)
        || !valid_version(request.algorithm_version)
        || !valid_version(request.policy_version)
        || i64::try_from(request.seed).is_err()
    {
        return Err(RecommendationGenerationRepositoryError::InvalidRequest);
    }
    Ok(())
}

fn intent_fingerprint(request: &RecommendationGenerationEnqueue<'_>) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"recommendation_generation_intent_v1");
    digest.update(request.mode.as_str().as_bytes());
    digest.update(request.local_date.to_string().as_bytes());
    digest.update(request.query_key.as_bytes());
    digest.update(request.profile_revision.unwrap_or(-1).to_be_bytes());
    digest.update(request.feedback_revision.to_be_bytes());
    digest.update(request.library_revision.to_be_bytes());
    digest.update(request.algorithm_version.as_bytes());
    digest.update(request.policy_version.as_bytes());
    digest.update(request.seed.to_be_bytes());
    digest.update(request.page_limit.to_be_bytes());
    if let Some(saved_search_revision_digest) = request.saved_search_revision_digest {
        digest.update(saved_search_revision_digest);
    }
    for paper_id in request.candidate_paper_ids {
        digest.update(paper_id.as_bytes());
    }
    if let Some(position) = request.next_position {
        digest.update(position.published_at.timestamp_micros().to_be_bytes());
        digest.update(position.paper_id.as_bytes());
    }
    digest.finalize().into()
}

fn valid_worker_id(value: &str) -> bool {
    valid_text(value, 96)
}

fn valid_text(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.trim() == value
        && !value.chars().any(char::is_control)
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

fn valid_error_code(value: &str) -> bool {
    valid_version(value)
}

#[derive(Debug, FromRow)]
struct ExistingIntentRow {
    id: Uuid,
    batch_id: Uuid,
    mode: String,
    query_key: String,
    local_date: NaiveDate,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    library_revision: i64,
    algorithm_version: String,
    policy_version: String,
    seed: i64,
    page_limit: i32,
    next_published_at: Option<DateTime<Utc>>,
    next_paper_id: Option<Uuid>,
    saved_search_revision_digest: Option<Vec<u8>>,
    state: String,
}

impl ExistingIntentRow {
    fn matches(&self, request: &RecommendationGenerationEnqueue<'_>) -> bool {
        self.mode == request.mode.as_str()
            && self.query_key == request.query_key
            && self.local_date == request.local_date
            && self.profile_revision == request.profile_revision
            && self.feedback_revision == request.feedback_revision
            && self.library_revision == request.library_revision
            && self.algorithm_version == request.algorithm_version
            && self.policy_version == request.policy_version
            && u64::try_from(self.seed).ok() == Some(request.seed)
            && u32::try_from(self.page_limit).ok() == Some(request.page_limit)
            && decode_digest(self.saved_search_revision_digest.as_deref()).ok()
                == Some(request.saved_search_revision_digest)
            && position(self.next_published_at, self.next_paper_id) == request.next_position
    }
}

async fn load_existing_intent(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    fingerprint: &[u8; 32],
) -> Result<Option<ExistingIntentRow>, RecommendationGenerationRepositoryError> {
    Ok(sqlx::query_as(
        r"
        SELECT id, batch_id, mode, query_key, local_date, profile_revision,
               feedback_revision, library_revision, algorithm_version,
               policy_version, seed, page_limit, next_published_at,
               next_paper_id, saved_search_revision_digest, state
        FROM recommendation_generation_jobs
        WHERE user_id = $1 AND intent_fingerprint = $2
        FOR UPDATE
        ",
    )
    .bind(user_id.into_inner())
    .bind(fingerprint.as_slice())
    .fetch_optional(&mut **transaction)
    .await?)
}

async fn candidate_ids(
    transaction: &mut Transaction<'_, Postgres>,
    job_id: Uuid,
) -> Result<Vec<PaperId>, RecommendationGenerationRepositoryError> {
    Ok(sqlx::query_scalar(
        "SELECT paper_id FROM recommendation_generation_candidates WHERE job_id = $1 ORDER BY ordinal ASC",
    )
    .bind(job_id)
    .fetch_all(&mut **transaction)
    .await?)
}

fn position(
    published_at: Option<DateTime<Utc>>,
    paper_id: Option<Uuid>,
) -> Option<RecommendationPosition> {
    published_at
        .zip(paper_id)
        .map(|(published_at, paper_id)| RecommendationPosition {
            published_at,
            paper_id,
        })
}

fn decode_digest(
    value: Option<&[u8]>,
) -> Result<Option<[u8; 32]>, RecommendationGenerationRepositoryError> {
    value
        .map(|value| {
            value
                .try_into()
                .map_err(|_| RecommendationGenerationRepositoryError::InvalidPersistedData)
        })
        .transpose()
}

#[derive(Debug, FromRow)]
struct ClaimedGenerationRow {
    id: Uuid,
    user_id: Uuid,
    batch_id: Uuid,
    mode: String,
    query_key: String,
    local_date: NaiveDate,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    library_revision: i64,
    algorithm_version: String,
    policy_version: String,
    seed: i64,
    page_limit: i32,
    next_published_at: Option<DateTime<Utc>>,
    next_paper_id: Option<Uuid>,
    saved_search_revision_digest: Option<Vec<u8>>,
    attempts: i32,
    max_attempts: i32,
    candidate_count: i64,
    lease_expires_at: DateTime<Utc>,
}

impl TryFrom<ClaimedGenerationRow> for ClaimedRecommendationGeneration {
    type Error = RecommendationGenerationRepositoryError;

    fn try_from(row: ClaimedGenerationRow) -> Result<Self, Self::Error> {
        Ok(Self {
            job_id: row.id,
            user_id: AuthenticatedUserId::new(row.user_id),
            batch_id: row.batch_id,
            mode: RecommendationMode::parse(&row.mode).ok_or(Self::Error::InvalidPersistedData)?,
            query_key: row.query_key,
            local_date: row.local_date,
            profile_revision: row.profile_revision,
            feedback_revision: row.feedback_revision,
            library_revision: row.library_revision,
            algorithm_version: row.algorithm_version,
            policy_version: row.policy_version,
            seed: u64::try_from(row.seed).map_err(|_| Self::Error::InvalidPersistedData)?,
            page_limit: u32::try_from(row.page_limit)
                .map_err(|_| Self::Error::InvalidPersistedData)?,
            next_position: position(row.next_published_at, row.next_paper_id),
            saved_search_revision_digest: decode_digest(
                row.saved_search_revision_digest.as_deref(),
            )?,
            attempt: u32::try_from(row.attempts).map_err(|_| Self::Error::InvalidPersistedData)?,
            max_attempts: u32::try_from(row.max_attempts)
                .map_err(|_| Self::Error::InvalidPersistedData)?,
            candidate_count: u32::try_from(row.candidate_count)
                .map_err(|_| Self::Error::InvalidPersistedData)?,
            lease_expires_at: row.lease_expires_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct GenerationCandidateRow {
    #[allow(dead_code)]
    ordinal: i32,
    #[sqlx(flatten)]
    paper: PaperSummaryRow,
}

#[derive(Debug, FromRow)]
struct RetryRow {
    state: String,
    attempts: i32,
}

#[derive(Debug, FromRow)]
struct SavedSearchRevisionRow {
    id: Uuid,
    revision: i64,
}

#[derive(Debug, FromRow)]
struct SavedSearchMatchRow {
    paper_id: Uuid,
    saved_search_id: Uuid,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intent_fingerprint_is_content_free_deterministic_and_page_bound() {
        let user_id = AuthenticatedUserId::new(Uuid::from_u128(1));
        let paper_id = Uuid::from_u128(2);
        let request = RecommendationGenerationEnqueue {
            user_id,
            job_id: Uuid::from_u128(3),
            batch_id: Uuid::from_u128(4),
            mode: RecommendationMode::Following,
            query_key: "following:v1:page:a",
            local_date: NaiveDate::from_ymd_opt(2026, 8, 19).unwrap(),
            profile_revision: Some(3),
            feedback_revision: 4,
            library_revision: 5,
            algorithm_version: "recommendations_v1",
            policy_version: "weighted_v1",
            seed: 6,
            page_limit: 20,
            candidate_paper_ids: &[paper_id],
            saved_search_revision_digest: Some([9; 32]),
            next_position: Some(RecommendationPosition {
                published_at: DateTime::UNIX_EPOCH,
                paper_id,
            }),
            max_attempts: 3,
            now: DateTime::UNIX_EPOCH,
        };
        let first = intent_fingerprint(&request);
        assert_eq!(first, intent_fingerprint(&request));
        let changed = RecommendationGenerationEnqueue {
            query_key: "following:v1:page:b",
            ..request
        };
        assert_ne!(first, intent_fingerprint(&changed));
    }

    #[test]
    fn validation_rejects_duplicate_candidates_and_unbound_continuations() {
        let paper_id = Uuid::from_u128(2);
        let candidates = [paper_id, paper_id];
        let request = RecommendationGenerationEnqueue {
            user_id: AuthenticatedUserId::new(Uuid::from_u128(1)),
            job_id: Uuid::from_u128(3),
            batch_id: Uuid::from_u128(4),
            mode: RecommendationMode::Recent,
            query_key: "recent:v1:page:a",
            local_date: NaiveDate::from_ymd_opt(2026, 8, 19).unwrap(),
            profile_revision: Some(1),
            feedback_revision: 0,
            library_revision: 0,
            algorithm_version: "recommendations_v1",
            policy_version: "weighted_v1",
            seed: 1,
            page_limit: 20,
            candidate_paper_ids: &candidates,
            saved_search_revision_digest: None,
            next_position: None,
            max_attempts: 3,
            now: DateTime::UNIX_EPOCH,
        };
        assert!(validate_enqueue(&request).is_err());
    }

    #[test]
    fn cleanup_sample_rejects_invalid_aggregate_values() {
        let cleanup =
            RecommendationGenerationCleanup::try_from(RecommendationGenerationCleanupRow {
                removed: 3,
                backlog_items: 5,
                oldest_age_seconds: Some(12.5),
            })
            .unwrap();
        assert_eq!(cleanup.removed, 3);
        assert_eq!(cleanup.backlog_items, 5);
        assert_eq!(cleanup.oldest_age_seconds, Some(12.5));

        for row in [
            RecommendationGenerationCleanupRow {
                removed: -1,
                backlog_items: 0,
                oldest_age_seconds: None,
            },
            RecommendationGenerationCleanupRow {
                removed: 0,
                backlog_items: -1,
                oldest_age_seconds: None,
            },
            RecommendationGenerationCleanupRow {
                removed: 0,
                backlog_items: 0,
                oldest_age_seconds: Some(f64::NAN),
            },
            RecommendationGenerationCleanupRow {
                removed: 0,
                backlog_items: 0,
                oldest_age_seconds: Some(-0.1),
            },
        ] {
            assert!(matches!(
                RecommendationGenerationCleanup::try_from(row),
                Err(RecommendationGenerationRepositoryError::InvalidPersistedData)
            ));
        }
    }
}
