use std::{
    collections::HashMap,
    path::Path,
    sync::OnceLock,
    time::{Duration, Instant},
};

use chrono::{DateTime, Utc};
use domain::{
    ArxivIdentifier, Author, Capabilities, ChatAnswer, ChatRole, ChatTurn, ConnectionReference,
    ConnectionsResponse, FailureCategory, FeedPage, Introduction, IntroductionCitation,
    IntroductionCitationReference, IntroductionDetection, IntroductionParagraph, KeyConnection,
    OverallProcessingState, Paper, PaperId, PaperMetadata, PaperSummary, ParsedPaper,
    ProcessingError, ProcessingGeneration, ProcessingStage, ProcessingState,
    ReferenceResolutionStatus, RelationType, SectionKind,
};
use jobs::JobKind;
use pgvector::Vector;
use regex::Regex;
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction, postgres::PgPoolOptions};
use thiserror::Error;
use tracing::{debug, info, instrument};
use url::Url;
use uuid::Uuid;

use crate::FeedCursor;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

#[derive(Debug, Error)]
pub enum DbError {
    #[error("database operation failed")]
    Sql(#[from] sqlx::Error),
    #[error("database migration failed")]
    Migration(#[from] sqlx::migrate::MigrateError),
    #[error("persisted URL is invalid")]
    InvalidUrl(#[from] url::ParseError),
    #[error("persisted data is invalid: {0}")]
    InvalidData(String),
    #[error("paper generation changed while work was in progress")]
    StaleGeneration,
    #[error("requested chat thread is not owned by this session and paper")]
    InvalidChatThread,
}

#[derive(Clone)]
pub struct Database {
    pool: PgPool,
}

impl Database {
    pub async fn connect(database_url: &str, max_connections: u32) -> Result<Self, DbError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections.max(1))
            .min_connections(1)
            .acquire_timeout(Duration::from_secs(10))
            .idle_timeout(Duration::from_secs(300))
            .connect(database_url)
            .await?;
        Ok(Self { pool })
    }

    #[must_use]
    pub const fn from_pool(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn migrate(&self, migration_path: impl AsRef<Path>) -> Result<(), DbError> {
        let migrator = sqlx::migrate::Migrator::new(migration_path.as_ref()).await?;
        migrator.run(&self.pool).await?;
        Ok(())
    }

    /// Runs migrations embedded in the binary at compile time. Runtime
    /// containers therefore do not need the source migration directory.
    pub async fn migrate_embedded(&self) -> Result<(), DbError> {
        MIGRATOR.run(&self.pool).await?;
        Ok(())
    }

    pub async fn ready(&self) -> Result<(), DbError> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        // Fail startup/readiness if required extensions were not installed.
        let extension_count: i64 = sqlx::query_scalar(
            r"
            SELECT count(*)
            FROM pg_extension
            WHERE extname IN ('vector', 'pg_trgm', 'pgcrypto')
            ",
        )
        .fetch_one(&self.pool)
        .await?;
        if extension_count != 3 {
            return Err(DbError::InvalidData(
                "required PostgreSQL extensions are missing".to_owned(),
            ));
        }
        let arxiv_gate_ready: bool = sqlx::query_scalar(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'external_rate_limits'
                  AND column_name = 'blocked_until'
            ) AND EXISTS (
                SELECT 1
                FROM external_rate_limits
                WHERE service = 'arxiv'
            )
            ",
        )
        .fetch_one(&self.pool)
        .await?;
        if !arxiv_gate_ready {
            return Err(DbError::InvalidData(
                "shared arXiv rate-limit schema is missing; apply database migrations".to_owned(),
            ));
        }
        Ok(())
    }

    #[must_use]
    pub fn papers(&self) -> PaperRepository {
        PaperRepository::new(self.pool.clone())
    }
}

#[derive(Debug, Clone)]
pub struct FeedQuery {
    pub category: Option<String>,
    pub cursor: Option<FeedCursor>,
    pub limit: u32,
}

impl Default for FeedQuery {
    fn default() -> Self {
        Self {
            category: None,
            cursor: None,
            limit: 20,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PrepareResult {
    pub state: ProcessingState,
    pub enqueued: bool,
}

#[derive(Debug, Clone)]
pub struct StoredSection {
    pub id: Uuid,
    pub kind: SectionKind,
    pub heading: Option<String>,
    pub text: String,
    pub paragraphs: Vec<domain::ParsedParagraph>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub ordinal: usize,
}

#[derive(Debug, Clone)]
pub struct RetrievalCandidate {
    pub chunk: domain::Chunk,
    /// Rank within this retrieval method, starting at one.
    pub rank: usize,
}

#[derive(Debug, Clone)]
pub struct TitleCandidate {
    pub paper: Paper,
    pub similarity: f32,
}

#[derive(Debug, Clone)]
pub struct ChatSession {
    pub thread_id: Uuid,
    pub recent_turns: Vec<ChatTurn>,
}

#[derive(Debug, Clone)]
pub struct VerificationMetrics {
    pub paper: Paper,
    pub processing: ProcessingState,
    pub introduction_paragraph_count: usize,
    pub chat_chunk_count: usize,
    pub resolved_reference_count: usize,
    pub key_connection_count: usize,
    pub resolved_arxiv_base_ids: Vec<String>,
    pub relationship_prompt_versions: Vec<String>,
}

#[derive(Clone)]
pub struct PaperRepository {
    pool: PgPool,
}

impl PaperRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    #[instrument(skip(self), fields(category = query.category.as_deref()))]
    pub async fn feed(&self, query: &FeedQuery) -> Result<FeedPage, DbError> {
        let limit = query.limit.clamp(1, 100);
        let mut builder = QueryBuilder::<Postgres>::new(
            r"
            SELECT
                p.id,
                p.arxiv_base_id,
                p.arxiv_version,
                p.title,
                p.abstract AS abstract_text,
                p.authors,
                p.primary_category,
                p.categories,
                p.published_at,
                p.updated_at,
                p.abs_url,
                p.pdf_url,
                processing.metadata_ready,
                processing.introduction_ready,
                processing.chat_ready,
                processing.connections_ready
            FROM papers AS p
            JOIN paper_processing AS processing ON processing.paper_id = p.id
            WHERE 1 = 1
            ",
        );
        if let Some(category) = &query.category {
            builder.push(" AND ");
            builder.push_bind(category.clone());
            builder.push(" = ANY(p.categories)");
        }
        if let Some(cursor) = query.cursor {
            builder.push(" AND (p.published_at, p.id) < (");
            builder.push_bind(cursor.published_at);
            builder.push(", ");
            builder.push_bind(cursor.paper_id);
            builder.push(")");
        }
        builder.push(" ORDER BY p.published_at DESC, p.id DESC LIMIT ");
        builder.push_bind(i64::from(limit) + 1);

        let mut rows = builder
            .build_query_as::<PaperSummaryRow>()
            .fetch_all(&self.pool)
            .await?;
        let has_more = rows.len() > limit as usize;
        if has_more {
            rows.pop();
        }
        let next_cursor = if has_more {
            rows.last().map(|row| {
                FeedCursor {
                    published_at: row.published_at,
                    paper_id: row.id,
                }
                .encode()
            })
        } else {
            None
        };
        let items = rows
            .into_iter()
            .map(PaperSummary::try_from)
            .collect::<Result<Vec<_>, _>>()?;

        Ok(FeedPage { items, next_cursor })
    }

    pub async fn get(&self, paper_id: PaperId) -> Result<Option<Paper>, DbError> {
        sqlx::query_as::<_, PaperRow>(PAPER_SELECT_BY_ID)
            .bind(paper_id)
            .fetch_optional(&self.pool)
            .await?
            .map(Paper::try_from)
            .transpose()
    }

    pub async fn get_summary(&self, paper_id: PaperId) -> Result<Option<PaperSummary>, DbError> {
        sqlx::query_as::<_, PaperSummaryRow>(PAPER_SUMMARY_BY_ID)
            .bind(paper_id)
            .fetch_optional(&self.pool)
            .await?
            .map(PaperSummary::try_from)
            .transpose()
    }

    /// Loads recorded licenses in one query for policy-aware feed rendering.
    ///
    /// Missing rows are omitted. Callers using a fail-closed policy must treat
    /// either an omitted row or a `None` value as an unknown license.
    pub async fn license_uris(
        &self,
        paper_ids: &[PaperId],
    ) -> Result<HashMap<PaperId, Option<Url>>, DbError> {
        if paper_ids.is_empty() {
            return Ok(HashMap::new());
        }
        sqlx::query_as::<_, LicenseUriRow>("SELECT id, license_uri FROM papers WHERE id = ANY($1)")
            .bind(paper_ids)
            .fetch_all(&self.pool)
            .await?
            .into_iter()
            .map(|row| {
                let license = row
                    .license_uri
                    .map(|value| Url::parse(&value))
                    .transpose()?;
                Ok((row.id, license))
            })
            .collect()
    }

    pub async fn get_by_arxiv_base(&self, base_id: &str) -> Result<Option<Paper>, DbError> {
        sqlx::query_as::<_, PaperRow>(PAPER_SELECT_BY_ARXIV)
            .bind(base_id)
            .fetch_optional(&self.pool)
            .await?
            .map(Paper::try_from)
            .transpose()
    }

    /// Inserts metadata or replaces it only when it is the same/newer arXiv
    /// version and was fetched more recently. The version trigger invalidates
    /// derived artifacts when the version increases.
    #[allow(clippy::too_many_lines)]
    #[instrument(skip(self, metadata), fields(arxiv_id = %metadata.arxiv_id.versioned()))]
    pub async fn upsert_metadata(&self, metadata: &PaperMetadata) -> Result<Paper, DbError> {
        let authors = serde_json::to_value(&metadata.authors)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let mut transaction = self.pool.begin().await?;
        let row = sqlx::query_as::<_, PaperRow>(
            r"
            INSERT INTO papers (
                arxiv_base_id,
                arxiv_version,
                title,
                abstract,
                authors,
                primary_category,
                categories,
                published_at,
                updated_at,
                abs_url,
                pdf_url,
                doi,
                journal_reference,
                comment,
                license_uri,
                metadata_source,
                metadata_fetched_at
            )
            VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9,
                $10, $11, $12, $13, $14, $15, 'arxiv', $16
            )
            ON CONFLICT (arxiv_base_id) DO UPDATE
            SET arxiv_version = EXCLUDED.arxiv_version,
                title = EXCLUDED.title,
                abstract = EXCLUDED.abstract,
                authors = EXCLUDED.authors,
                primary_category = EXCLUDED.primary_category,
                categories = EXCLUDED.categories,
                published_at = EXCLUDED.published_at,
                updated_at = EXCLUDED.updated_at,
                abs_url = EXCLUDED.abs_url,
                pdf_url = EXCLUDED.pdf_url,
                doi = EXCLUDED.doi,
                journal_reference = EXCLUDED.journal_reference,
                comment = EXCLUDED.comment,
                license_uri = EXCLUDED.license_uri,
                metadata_source = 'arxiv',
                metadata_fetched_at = EXCLUDED.metadata_fetched_at
            WHERE EXCLUDED.arxiv_version > papers.arxiv_version
               OR (
                    EXCLUDED.arxiv_version = papers.arxiv_version
                    AND EXCLUDED.metadata_fetched_at > papers.metadata_fetched_at
               )
            RETURNING
                id,
                arxiv_base_id,
                arxiv_version,
                title,
                abstract AS abstract_text,
                authors,
                primary_category,
                categories,
                published_at,
                updated_at,
                abs_url,
                pdf_url,
                doi,
                journal_reference,
                comment,
                license_uri,
                metadata_fetched_at
            ",
        )
        .bind(&metadata.arxiv_id.base_id)
        .bind(
            i32::try_from(metadata.arxiv_id.version)
                .map_err(|_| DbError::InvalidData("arXiv version is too large".to_owned()))?,
        )
        .bind(&metadata.title)
        .bind(&metadata.abstract_text)
        .bind(authors)
        .bind(&metadata.primary_category)
        .bind(&metadata.categories)
        .bind(metadata.published_at)
        .bind(metadata.updated_at)
        .bind(metadata.abs_url.as_str())
        .bind(metadata.pdf_url.as_str())
        .bind(&metadata.doi)
        .bind(&metadata.journal_reference)
        .bind(&metadata.comment)
        .bind(metadata.license_uri.as_ref().map(Url::as_str))
        .bind(metadata.metadata_fetched_at)
        .fetch_optional(&mut *transaction)
        .await?;

        let row = if let Some(row) = row {
            row
        } else {
            sqlx::query_as::<_, PaperRow>(PAPER_SELECT_BY_ARXIV)
                .bind(&metadata.arxiv_id.base_id)
                .fetch_one(&mut *transaction)
                .await?
        };
        transaction.commit().await?;
        Paper::try_from(row)
    }

    pub async fn processing(&self, paper_id: PaperId) -> Result<Option<ProcessingState>, DbError> {
        sqlx::query_as::<_, ProcessingRow>(PROCESSING_SELECT)
            .bind(paper_id)
            .fetch_optional(&self.pool)
            .await?
            .map(ProcessingState::try_from)
            .transpose()
    }

    /// Implements the idempotent prepare decision while holding the processing
    /// row lock. Concurrent swipes can therefore create at most one job.
    #[allow(clippy::too_many_lines)]
    pub async fn prepare(
        &self,
        paper_id: PaperId,
        retry: bool,
    ) -> Result<Option<PrepareResult>, DbError> {
        let mut transaction = self.pool.begin().await?;
        let Some(locked) = sqlx::query_as::<_, ProcessingRow>(
            r"
            SELECT
                paper_id,
                generation,
                stage,
                metadata_ready,
                introduction_ready,
                chat_ready,
                connections_ready,
                retryable,
                last_error_category,
                last_error_code,
                last_error_message,
                started_at,
                updated_at,
                completed_at,
                parser_version,
                embedding_model,
                summary_model
            FROM paper_processing
            WHERE paper_id = $1
            FOR UPDATE
            ",
        )
        .bind(paper_id)
        .fetch_optional(&mut *transaction)
        .await?
        else {
            transaction.rollback().await?;
            return Ok(None);
        };
        let state = ProcessingState::try_from(locked)?;

        if state.is_ready() || state.is_running() || (state.failed() && !retry) {
            transaction.commit().await?;
            return Ok(Some(PrepareResult {
                state,
                enqueued: false,
            }));
        }
        if matches!(state.stage, ProcessingStage::FailedTerminal) {
            transaction.commit().await?;
            return Ok(Some(PrepareResult {
                state,
                enqueued: false,
            }));
        }

        let mut kinds = Vec::with_capacity(2);
        if state.capabilities.introduction {
            if !state.capabilities.chat {
                kinds.push(JobKind::IndexChat);
            }
            if !state.capabilities.connections {
                kinds.push(JobKind::ResolveConnections);
            }
        } else {
            kinds.push(JobKind::PrepareDocument);
        }

        let mut enqueued = false;
        for kind in kinds {
            let changed = sqlx::query(
                r"
                INSERT INTO jobs (
                    job_type, paper_id, generation, state, attempts,
                    available_at, payload
                )
                VALUES ($1, $2, $3, 'queued', 0, now(), '{}'::jsonb)
                ON CONFLICT (paper_id, generation, job_type) DO UPDATE
                SET state = 'queued',
                    attempts = 0,
                    available_at = now(),
                    lease_owner = NULL,
                    lease_expires_at = NULL,
                    last_error_class = NULL,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    completed_at = NULL,
                    updated_at = now()
                WHERE $4 AND jobs.state = 'failed'
                ",
            )
            .bind(kind.as_str())
            .bind(paper_id)
            .bind(state.generation)
            .bind(retry)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            enqueued |= changed > 0;
        }

        if enqueued {
            let next_stage = if !state.capabilities.introduction {
                "queued"
            } else if !state.capabilities.chat {
                "indexing_chat"
            } else {
                "resolving_references"
            };
            sqlx::query(
                r"
                UPDATE paper_processing
                SET stage = $3,
                    retryable = false,
                    last_error_category = NULL,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    completed_at = NULL,
                    updated_at = now()
                WHERE paper_id = $1 AND generation = $2
                ",
            )
            .bind(paper_id)
            .bind(state.generation)
            .bind(next_stage)
            .execute(&mut *transaction)
            .await?;
        }

        let refreshed =
            sqlx::query_as::<_, ProcessingRow>(&format!("{PROCESSING_SELECT} FOR UPDATE"))
                .bind(paper_id)
                .fetch_one(&mut *transaction)
                .await?;
        transaction.commit().await?;

        Ok(Some(PrepareResult {
            state: ProcessingState::try_from(refreshed)?,
            enqueued,
        }))
    }

    pub async fn set_stage(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        stage: ProcessingStage,
    ) -> Result<(), DbError> {
        let changed = sqlx::query(
            r"
            UPDATE paper_processing
            SET stage = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal') THEN stage
                    ELSE $3
                END,
                started_at = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal') THEN started_at
                    ELSE COALESCE(started_at, now())
                END,
                retryable = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal') THEN retryable
                    ELSE false
                END,
                last_error_category = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal')
                        THEN last_error_category
                    ELSE NULL
                END,
                last_error_code = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal') THEN last_error_code
                    ELSE NULL
                END,
                last_error_message = CASE
                    WHEN stage IN ('failed_retryable', 'failed_terminal') THEN last_error_message
                    ELSE NULL
                END,
                updated_at = now()
            WHERE paper_id = $1 AND generation = $2
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(processing_stage_name(stage))
        .execute(&self.pool)
        .await?
        .rows_affected();
        require_current_generation(changed)
    }

    pub async fn mark_failure(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        failure: &jobs::JobFailure,
        retryable: bool,
    ) -> Result<(), DbError> {
        let stage = if retryable {
            "failed_retryable"
        } else {
            "failed_terminal"
        };
        let changed = sqlx::query(
            r"
            UPDATE paper_processing
            SET stage = $3,
                retryable = $4,
                last_error_category = $5,
                last_error_code = $6,
                last_error_message = $7,
                completed_at = now(),
                updated_at = now()
            WHERE paper_id = $1 AND generation = $2
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(stage)
        .bind(retryable)
        .bind(failure_category_name(failure.category))
        .bind(&failure.code)
        .bind(&failure.message)
        .execute(&self.pool)
        .await?
        .rows_affected();
        require_current_generation(changed)
    }

    /// Publishes an automatically scheduled retry without exposing a terminal
    /// failure state. Clients should keep polling while the durable job remains
    /// queued.
    pub async fn mark_retry_scheduled(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        stage: ProcessingStage,
        failure: &jobs::JobFailure,
    ) -> Result<(), DbError> {
        let changed = sqlx::query(
            r"
            UPDATE paper_processing
            SET stage = $3,
                retryable = false,
                last_error_category = $4,
                last_error_code = $5,
                last_error_message = $6,
                completed_at = NULL,
                updated_at = now()
            WHERE paper_id = $1 AND generation = $2
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(processing_stage_name(stage))
        .bind(failure_category_name(failure.category))
        .bind(&failure.code)
        .bind(&failure.message)
        .execute(&self.pool)
        .await?
        .rows_affected();
        require_current_generation(changed)
    }

    /// Reserves a cross-process arXiv request start. Each decision is made
    /// while holding the service row lock. Waiters release the transaction,
    /// sleep, and re-check so a long upstream cooldown does not pin a database
    /// connection and a concurrent extension cannot be bypassed.
    pub async fn reserve_arxiv_request(&self, minimum_interval: Duration) -> Result<(), DbError> {
        let minimum = chrono::Duration::from_std(minimum_interval)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let reservation_started = Instant::now();
        let mut wait_cycles = 0_u64;
        loop {
            let mut transaction = self.pool.begin().await?;
            let (last_started, blocked_until, database_now): (
                DateTime<Utc>,
                DateTime<Utc>,
                DateTime<Utc>,
            ) = sqlx::query_as(
                r"
                SELECT last_started_at, blocked_until, clock_timestamp()
                FROM external_rate_limits
                WHERE service = 'arxiv'
                FOR UPDATE
                ",
            )
            .fetch_one(&mut *transaction)
            .await?;
            let next_interval_start = last_started + minimum;
            let next_allowed_start = next_interval_start.max(blocked_until);
            if let Ok(wait) = next_allowed_start
                .signed_duration_since(database_now)
                .to_std()
                && !wait.is_zero()
            {
                transaction.commit().await?;
                wait_cycles += 1;
                debug!(
                    wait_ms = wait.as_millis(),
                    cooldown = blocked_until > next_interval_start,
                    "waiting for shared arXiv gate"
                );
                tokio::time::sleep(wait).await;
                continue;
            }
            let changed = sqlx::query(
                r"
                UPDATE external_rate_limits
                SET last_started_at = clock_timestamp()
                WHERE service = 'arxiv'
                ",
            )
            .execute(&mut *transaction)
            .await?
            .rows_affected();
            transaction.commit().await?;
            if changed != 1 {
                return Err(DbError::InvalidData(
                    "shared arXiv rate-limit row is missing".to_owned(),
                ));
            }
            info!(
                metric.name = "arxiv_rate_gate",
                arxiv.request_count = 1_u64,
                arxiv.wait_ms = reservation_started.elapsed().as_millis(),
                arxiv.wait_cycles = wait_cycles,
                gate.scope = "shared_postgres",
                "shared arXiv request permit granted"
            );
            return Ok(());
        }
    }

    /// Extends the shared arXiv cooldown after an upstream `Retry-After` or a
    /// conservative fallback for a 429 without that header. `GREATEST` ensures
    /// a shorter later response cannot pull an existing cooldown forward.
    pub async fn defer_arxiv_requests(&self, cooldown: Duration) -> Result<(), DbError> {
        let cooldown = chrono::Duration::from_std(cooldown)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let changed = sqlx::query(
            r"
            UPDATE external_rate_limits
            SET blocked_until = GREATEST(blocked_until, clock_timestamp() + $1)
            WHERE service = 'arxiv'
            ",
        )
        .bind(cooldown)
        .execute(&self.pool)
        .await?
        .rows_affected();
        if changed != 1 {
            return Err(DbError::InvalidData(
                "shared arXiv rate-limit row is missing".to_owned(),
            ));
        }
        Ok(())
    }

    pub async fn get_cached_arxiv(
        &self,
        cache_key: &str,
    ) -> Result<Option<Vec<PaperMetadata>>, DbError> {
        let payload = sqlx::query_scalar::<_, Value>(
            r"
            SELECT payload
            FROM arxiv_query_cache
            WHERE cache_key = $1 AND expires_at > now()
            ",
        )
        .bind(cache_key)
        .fetch_optional(&self.pool)
        .await?;
        payload
            .map(serde_json::from_value)
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))
    }

    pub async fn put_cached_arxiv(
        &self,
        cache_key: &str,
        query_kind: &str,
        papers: &[PaperMetadata],
        ttl: Duration,
    ) -> Result<(), DbError> {
        let payload = serde_json::to_value(papers)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let ttl = chrono::Duration::from_std(ttl)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        sqlx::query(
            r"
            INSERT INTO arxiv_query_cache (
                cache_key, query_kind, payload, fetched_at, expires_at
            )
            VALUES ($1, $2, $3, now(), now() + $4)
            ON CONFLICT (cache_key) DO UPDATE
            SET query_kind = EXCLUDED.query_kind,
                payload = EXCLUDED.payload,
                fetched_at = EXCLUDED.fetched_at,
                expires_at = EXCLUDED.expires_at
            ",
        )
        .bind(cache_key)
        .bind(query_kind)
        .bind(payload)
        .bind(ttl)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Establishes the durable embedding-dimension contract and rejects any
    /// mismatch with existing vectors.
    pub async fn validate_embedding_dimension(&self, dimension: usize) -> Result<(), DbError> {
        if dimension == 0 {
            return Err(DbError::InvalidData(
                "embedding dimension must be positive".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let configured = sqlx::query_scalar::<_, String>(
            r"
            SELECT value
            FROM service_configuration
            WHERE key = 'embedding_dimension'
            FOR UPDATE
            ",
        )
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(configured) = configured {
            let persisted = configured.parse::<usize>().map_err(|_| {
                DbError::InvalidData("persisted embedding dimension is invalid".to_owned())
            })?;
            if persisted != dimension {
                return Err(DbError::InvalidData(format!(
                    "configured embedding dimension {dimension} does not match database dimension {persisted}"
                )));
            }
        } else {
            sqlx::query(
                r"
                INSERT INTO service_configuration (key, value)
                VALUES ('embedding_dimension', $1)
                ",
            )
            .bind(dimension.to_string())
            .execute(&mut *transaction)
            .await?;
        }

        let stored_dimensions = sqlx::query_scalar::<_, i32>(
            "SELECT vector_dims(embedding) FROM paper_chunks WHERE embedding IS NOT NULL LIMIT 1",
        )
        .fetch_optional(&mut *transaction)
        .await?;
        if stored_dimensions.is_some_and(|stored| usize::try_from(stored).ok() != Some(dimension)) {
            return Err(DbError::InvalidData(
                "stored vectors do not match configured embedding dimension".to_owned(),
            ));
        }
        transaction.commit().await?;
        Ok(())
    }

    /// Replaces normalized parser output for one generation and commits the
    /// Introduction capability. Downstream jobs must only be enqueued after
    /// this method returns, which guarantees Introduction is externally
    /// observable first.
    #[allow(clippy::too_many_lines)]
    #[instrument(
        skip(self, paper, introduction_source_ids),
        fields(paper_id = %paper_id, generation)
    )]
    pub async fn persist_parsed_document(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        paper: &ParsedPaper,
        introduction_source_ids: &[String],
        detection: IntroductionDetection,
        parser_version: &str,
    ) -> Result<(), DbError> {
        if introduction_source_ids.is_empty() {
            return Err(DbError::InvalidData(
                "parser did not identify an introduction".to_owned(),
            ));
        }
        let visible_sources = introduction_source_ids
            .iter()
            .map(String::as_str)
            .collect::<std::collections::HashSet<_>>();
        if !paper.sections.iter().any(|section| {
            visible_sources.contains(section.source_id.as_str()) && !section.paragraphs.is_empty()
        }) {
            return Err(DbError::InvalidData(
                "identified introduction contains no paragraphs".to_owned(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        lock_current_generation(&mut transaction, paper_id, generation).await?;
        let introduction_was_ready = sqlx::query_scalar::<_, bool>(
            "SELECT introduction_ready FROM paper_processing WHERE paper_id = $1",
        )
        .bind(paper_id)
        .fetch_one(&mut *transaction)
        .await?;

        // Replaying parser output is safe. Cascades remove current-generation
        // chunks, contexts and connections, while older generations remain for
        // debugging and are never selected by current-generation queries.
        sqlx::query("DELETE FROM paper_sections WHERE paper_id = $1 AND generation = $2")
            .bind(paper_id)
            .bind(generation)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("DELETE FROM paper_references WHERE citing_paper_id = $1 AND generation = $2")
            .bind(paper_id)
            .bind(generation)
            .execute(&mut *transaction)
            .await?;

        for section in &paper.sections {
            let id = Uuid::now_v7();
            let text = section
                .paragraphs
                .iter()
                .map(|paragraph| paragraph.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            if text.trim().is_empty() {
                continue;
            }
            let paragraphs = serde_json::to_value(&section.paragraphs)
                .map_err(|error| DbError::InvalidData(error.to_string()))?;
            let visible = visible_sources.contains(section.source_id.as_str());
            sqlx::query(
                r"
                INSERT INTO paper_sections (
                    id,
                    paper_id,
                    generation,
                    ordinal,
                    kind,
                    heading,
                    text,
                    paragraphs,
                    page_start,
                    page_end,
                    visible_in_app,
                    detection_confidence
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
                ",
            )
            .bind(id)
            .bind(paper_id)
            .bind(generation)
            .bind(usize_to_i32(section.ordinal, "section ordinal")?)
            .bind(section_kind_name(section.kind))
            .bind(&section.heading)
            .bind(text)
            .bind(paragraphs)
            .bind(option_u32_to_i32(section.page_start, "section page")?)
            .bind(option_u32_to_i32(section.page_end, "section page")?)
            .bind(visible)
            .bind(visible.then_some(detection.confidence))
            .execute(&mut *transaction)
            .await?;
        }

        let mut reference_ids = HashMap::with_capacity(paper.references.len());
        for reference in &paper.references {
            let id = Uuid::now_v7();
            reference_ids.insert(reference.source_id.clone(), id);
            let authors = serde_json::to_value(&reference.authors)
                .map_err(|error| DbError::InvalidData(error.to_string()))?;
            sqlx::query(
                r"
                INSERT INTO paper_references (
                    id,
                    citing_paper_id,
                    generation,
                    ordinal,
                    raw_text,
                    extracted_title,
                    extracted_authors,
                    extracted_year,
                    doi,
                    extracted_arxiv_id,
                    resolution_status
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'unresolved')
                ",
            )
            .bind(id)
            .bind(paper_id)
            .bind(generation)
            .bind(usize_to_i32(reference.ordinal, "reference ordinal")?)
            .bind(&reference.raw_text)
            .bind(&reference.title)
            .bind(authors)
            .bind(reference.year)
            .bind(&reference.doi)
            .bind(&reference.arxiv_id)
            .execute(&mut *transaction)
            .await?;
        }

        for context in &paper.citation_contexts {
            let Some(reference_id) = reference_ids.get(&context.reference_source_id).copied()
            else {
                return Err(DbError::InvalidData(format!(
                    "citation context targets missing reference `{}`",
                    context.reference_source_id
                )));
            };
            sqlx::query(
                r"
                INSERT INTO citation_contexts (
                    reference_id,
                    section_kind,
                    section_heading,
                    context_text,
                    page_number,
                    occurrence_ordinal
                )
                VALUES ($1, $2, $3, $4, $5, $6)
                ",
            )
            .bind(reference_id)
            .bind(section_kind_name(context.section_kind))
            .bind(&context.section_heading)
            .bind(&context.context_text)
            .bind(option_u32_to_i32(context.page_number, "citation page")?)
            .bind(usize_to_i32(
                context.occurrence_ordinal,
                "citation occurrence",
            )?)
            .execute(&mut *transaction)
            .await?;
        }

        let transitioned_at = sqlx::query_scalar::<_, DateTime<Utc>>(
            r"
            UPDATE paper_processing
            SET stage = 'introduction_ready',
                introduction_ready = true,
                retryable = false,
                last_error_category = NULL,
                last_error_code = NULL,
                last_error_message = NULL,
                parser_version = $3,
                updated_at = now()
            WHERE paper_id = $1 AND generation = $2
            RETURNING updated_at
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(parser_version)
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or(DbError::StaleGeneration)?;
        transaction.commit().await?;
        if !introduction_was_ready {
            observe_capability_transition(
                paper_id,
                generation,
                CapabilityTransition {
                    capability: "introduction",
                    transitioned_at,
                },
            );
        }
        Ok(())
    }

    pub async fn introduction(&self, paper_id: PaperId) -> Result<Option<Introduction>, DbError> {
        let Some(header) = sqlx::query_as::<_, IntroductionHeaderRow>(
            r"
            SELECT
                processing.generation,
                processing.introduction_ready,
                p.pdf_url
            FROM papers AS p
            JOIN paper_processing AS processing ON processing.paper_id = p.id
            WHERE p.id = $1
            ",
        )
        .bind(paper_id)
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        if !header.introduction_ready {
            return Ok(None);
        }
        let rows = sqlx::query_as::<_, IntroductionSectionRow>(
            r"
            SELECT heading, paragraphs, detection_confidence
            FROM paper_sections
            WHERE paper_id = $1
              AND generation = $2
              AND visible_in_app
            ORDER BY ordinal ASC
            ",
        )
        .bind(paper_id)
        .bind(header.generation)
        .fetch_all(&self.pool)
        .await?;

        let resolved_references = sqlx::query_as::<_, IntroductionResolvedReferenceRow>(
            r"
            SELECT
                reference.ordinal,
                resolved.id AS paper_id,
                resolved.title,
                context.context_text
            FROM paper_references AS reference
            JOIN papers AS resolved ON resolved.id = reference.resolved_paper_id
            LEFT JOIN citation_contexts AS context ON context.reference_id = reference.id
            WHERE reference.citing_paper_id = $1
              AND reference.generation = $2
              AND reference.resolution_status = 'resolved'
              AND reference.resolution_confidence >= 0.90
            ORDER BY reference.ordinal ASC, context.occurrence_ordinal ASC
            ",
        )
        .bind(paper_id)
        .bind(header.generation)
        .fetch_all(&self.pool)
        .await?;
        let (heading, confidence, paragraphs) =
            build_introduction_content(rows, resolved_references)?;
        Ok(Some(Introduction {
            paper_id,
            generation: header.generation,
            heading,
            paragraphs,
            detection: IntroductionDetection {
                confidence,
                used_fallback: confidence < 0.7,
            },
            original_pdf_url: header.pdf_url,
        }))
    }

    pub async fn sections_for_chunking(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
    ) -> Result<Vec<StoredSection>, DbError> {
        let rows = sqlx::query_as::<_, StoredSectionRow>(
            r"
            SELECT id, kind, heading, text, paragraphs, page_start, page_end, ordinal
            FROM paper_sections
            WHERE paper_id = $1
              AND generation = $2
              AND kind IN (
                'introduction',
                'background',
                'related_work',
                'method',
                'experiment',
                'result',
                'discussion',
                'limitation',
                'conclusion',
                'appendix',
                'other'
              )
            ORDER BY ordinal ASC
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(StoredSection::try_from)
            .collect::<Result<_, _>>()
    }

    #[instrument(
        skip(self, chunks),
        fields(paper_id = %paper_id, generation, chunk_count = chunks.len())
    )]
    pub async fn replace_chunks_and_publish(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        chunks: &[(domain::Chunk, Vec<f32>)],
        embedding_model: &str,
    ) -> Result<(), DbError> {
        if chunks.is_empty() {
            return Err(DbError::InvalidData(
                "chat indexing produced no chunks".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        lock_current_generation(&mut transaction, paper_id, generation).await?;
        sqlx::query("DELETE FROM paper_chunks WHERE paper_id = $1 AND generation = $2")
            .bind(paper_id)
            .bind(generation)
            .execute(&mut *transaction)
            .await?;
        for (chunk, embedding) in chunks {
            if chunk.paper_id != paper_id || chunk.generation != generation {
                return Err(DbError::InvalidData(
                    "chunk belongs to a different paper or generation".to_owned(),
                ));
            }
            sqlx::query(
                r"
                INSERT INTO paper_chunks (
                    id,
                    paper_id,
                    section_id,
                    generation,
                    ordinal,
                    text,
                    page_start,
                    page_end,
                    token_count,
                    embedding
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                ",
            )
            .bind(chunk.id)
            .bind(paper_id)
            .bind(chunk.section_id)
            .bind(generation)
            .bind(usize_to_i32(chunk.ordinal, "chunk ordinal")?)
            .bind(&chunk.text)
            .bind(option_u32_to_i32(chunk.page_start, "chunk page")?)
            .bind(option_u32_to_i32(chunk.page_end, "chunk page")?)
            .bind(usize_to_i32(chunk.token_count, "chunk token count")?)
            .bind(Vector::from(embedding.clone()))
            .execute(&mut *transaction)
            .await?;
        }
        let transition = publish_capability(
            &mut transaction,
            paper_id,
            generation,
            CapabilityToPublish::Chat {
                model: embedding_model,
            },
        )
        .await?;
        transaction.commit().await?;
        if let Some(transition) = transition {
            observe_capability_transition(paper_id, generation, transition);
        }
        Ok(())
    }

    pub async fn keyword_candidates(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        question: &str,
        limit: u32,
    ) -> Result<Vec<RetrievalCandidate>, DbError> {
        let rows = sqlx::query_as::<_, RetrievalRow>(
            r"
            SELECT
                chunks.id,
                chunks.paper_id,
                chunks.section_id,
                chunks.generation,
                chunks.ordinal,
                sections.kind AS section_kind,
                sections.heading AS section_heading,
                chunks.text,
                chunks.page_start,
                chunks.page_end,
                chunks.token_count,
                row_number() OVER (
                    ORDER BY ts_rank_cd(
                        chunks.search_tsv,
                        websearch_to_tsquery('english'::regconfig, $3)
                    ) DESC,
                    chunks.id
                ) AS rank
            FROM paper_chunks AS chunks
            JOIN paper_sections AS sections ON sections.id = chunks.section_id
            WHERE chunks.paper_id = $1
              AND chunks.generation = $2
              AND chunks.search_tsv @@ websearch_to_tsquery('english'::regconfig, $3)
            ORDER BY rank
            LIMIT $4
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(question)
        .bind(i64::from(limit.clamp(1, 50)))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(RetrievalCandidate::try_from).collect()
    }

    pub async fn vector_candidates(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        embedding: &[f32],
        limit: u32,
    ) -> Result<Vec<RetrievalCandidate>, DbError> {
        let rows = sqlx::query_as::<_, RetrievalRow>(
            r"
            SELECT
                chunks.id,
                chunks.paper_id,
                chunks.section_id,
                chunks.generation,
                chunks.ordinal,
                sections.kind AS section_kind,
                sections.heading AS section_heading,
                chunks.text,
                chunks.page_start,
                chunks.page_end,
                chunks.token_count,
                row_number() OVER (
                    ORDER BY chunks.embedding <=> $3, chunks.id
                ) AS rank
            FROM paper_chunks AS chunks
            JOIN paper_sections AS sections ON sections.id = chunks.section_id
            WHERE chunks.paper_id = $1
              AND chunks.generation = $2
              AND chunks.embedding IS NOT NULL
            ORDER BY rank
            LIMIT $4
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(Vector::from(embedding.to_vec()))
        .bind(i64::from(limit.clamp(1, 50)))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(RetrievalCandidate::try_from).collect()
    }

    pub async fn open_chat(
        &self,
        anonymous_session_id: Uuid,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        requested_thread_id: Option<Uuid>,
    ) -> Result<ChatSession, DbError> {
        let mut transaction = self.pool.begin().await?;
        let thread_id = if let Some(thread_id) = requested_thread_id {
            sqlx::query_scalar::<_, Uuid>(
                r"
                SELECT id
                FROM chat_threads
                WHERE id = $1
                  AND anonymous_session_id = $2
                  AND paper_id = $3
                  AND generation = $4
                ",
            )
            .bind(thread_id)
            .bind(anonymous_session_id)
            .bind(paper_id)
            .bind(generation)
            .fetch_optional(&mut *transaction)
            .await?
            .ok_or(DbError::InvalidChatThread)?
        } else {
            sqlx::query_scalar::<_, Uuid>(
                r"
                INSERT INTO chat_threads (
                    anonymous_session_id, paper_id, generation
                )
                VALUES ($1, $2, $3)
                RETURNING id
                ",
            )
            .bind(anonymous_session_id)
            .bind(paper_id)
            .bind(generation)
            .fetch_one(&mut *transaction)
            .await?
        };

        let mut rows = sqlx::query_as::<_, ChatTurnRow>(
            r"
            SELECT role, content
            FROM chat_messages
            WHERE thread_id = $1
            ORDER BY created_at DESC, id DESC
            LIMIT 12
            ",
        )
        .bind(thread_id)
        .fetch_all(&mut *transaction)
        .await?;
        rows.reverse();
        let recent_turns = rows
            .into_iter()
            .map(ChatTurn::try_from)
            .collect::<Result<_, _>>()?;
        transaction.commit().await?;
        Ok(ChatSession {
            thread_id,
            recent_turns,
        })
    }

    pub async fn persist_chat_exchange(
        &self,
        anonymous_session_id: Uuid,
        paper_id: PaperId,
        thread_id: Uuid,
        question: &str,
        answer: &ChatAnswer,
    ) -> Result<(), DbError> {
        let evidence = serde_json::to_value(&answer.evidence)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let mut transaction = self.pool.begin().await?;
        let valid_thread = sqlx::query_scalar::<_, bool>(
            r"
            SELECT EXISTS (
                SELECT 1
                FROM chat_threads
                WHERE id = $1
                  AND anonymous_session_id = $2
                  AND paper_id = $3
            )
            ",
        )
        .bind(thread_id)
        .bind(anonymous_session_id)
        .bind(paper_id)
        .fetch_one(&mut *transaction)
        .await?;
        if !valid_thread {
            return Err(DbError::InvalidChatThread);
        }
        sqlx::query(
            r"
            INSERT INTO chat_messages (thread_id, role, content)
            VALUES ($1, 'user', $2)
            ",
        )
        .bind(thread_id)
        .bind(question)
        .execute(&mut *transaction)
        .await?;
        sqlx::query(
            r"
            INSERT INTO chat_messages (
                thread_id,
                role,
                content,
                source_metadata,
                provider_request_id,
                model_id,
                prompt_version
            )
            VALUES ($1, 'assistant', $2, $3, $4, $5, $6)
            ",
        )
        .bind(thread_id)
        .bind(&answer.answer_markdown)
        .bind(evidence)
        .bind(&answer.provider_request_id)
        .bind(&answer.model_id)
        .bind(&answer.prompt_version)
        .execute(&mut *transaction)
        .await?;
        sqlx::query("UPDATE chat_threads SET updated_at = now() WHERE id = $1")
            .bind(thread_id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn references(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
    ) -> Result<Vec<domain::Reference>, DbError> {
        sqlx::query_as::<_, ReferenceRow>(
            r"
            SELECT
                id,
                citing_paper_id,
                generation,
                ordinal,
                raw_text,
                extracted_title,
                extracted_authors,
                extracted_year,
                doi,
                extracted_arxiv_id,
                resolved_paper_id,
                resolution_status,
                resolution_confidence,
                resolution_method,
                key_score
            FROM paper_references
            WHERE citing_paper_id = $1 AND generation = $2
            ORDER BY ordinal ASC
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(domain::Reference::try_from)
        .collect()
    }

    pub async fn citation_contexts(
        &self,
        reference_id: Uuid,
    ) -> Result<Vec<domain::CitationContext>, DbError> {
        sqlx::query_as::<_, CitationContextRow>(
            r"
            SELECT
                id,
                reference_id,
                section_kind,
                section_heading,
                context_text,
                page_number,
                occurrence_ordinal
            FROM citation_contexts
            WHERE reference_id = $1
            ORDER BY occurrence_ordinal ASC
            ",
        )
        .bind(reference_id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(domain::CitationContext::try_from)
        .collect()
    }

    pub async fn local_title_candidates(
        &self,
        normalized_title: &str,
        excluding_paper_id: PaperId,
        limit: u32,
    ) -> Result<Vec<TitleCandidate>, DbError> {
        let rows = sqlx::query_as::<_, TitleCandidateRow>(
            r"
            SELECT
                id,
                arxiv_base_id,
                arxiv_version,
                title,
                abstract AS abstract_text,
                authors,
                primary_category,
                categories,
                published_at,
                updated_at,
                abs_url,
                pdf_url,
                doi,
                journal_reference,
                comment,
                license_uri,
                metadata_fetched_at,
                similarity(normalized_title, $1) AS similarity
            FROM papers
            WHERE id <> $2
              AND normalized_title % $1
            ORDER BY similarity DESC, published_at DESC
            LIMIT $3
            ",
        )
        .bind(normalized_title)
        .bind(excluding_paper_id)
        .bind(i64::from(limit.clamp(1, 20)))
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter().map(TitleCandidate::try_from).collect()
    }

    pub async fn update_reference_resolution(
        &self,
        reference_id: Uuid,
        status: ReferenceResolutionStatus,
        resolved_paper_id: Option<PaperId>,
        confidence: Option<f32>,
        method: Option<&str>,
        key_score: Option<f32>,
    ) -> Result<(), DbError> {
        let outcome = reference_status_name(status);
        let changed = sqlx::query(
            r"
            UPDATE paper_references
            SET resolution_status = $2,
                resolved_paper_id = $3,
                resolution_confidence = $4,
                resolution_method = $5,
                key_score = $6
            WHERE id = $1
            ",
        )
        .bind(reference_id)
        .bind(outcome)
        .bind(resolved_paper_id)
        .bind(confidence)
        .bind(method)
        .bind(key_score)
        .execute(&self.pool)
        .await?
        .rows_affected();
        if changed == 1 {
            info!(
                metric.name = "reference_resolution",
                reference_id = %reference_id,
                resolution.count = changed,
                resolution.outcome = outcome,
                resolution.method = method.unwrap_or("none"),
                resolution.matched = resolved_paper_id.is_some(),
                resolution.confidence = ?confidence,
                resolution.key_score = ?key_score,
                "reference resolution recorded"
            );
        }
        Ok(())
    }

    #[instrument(
        skip(self, connections),
        fields(paper_id = %paper_id, generation, connection_count = connections.len())
    )]
    pub async fn replace_connections_and_publish(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        connections: &[domain::Connection],
        summary_model: Option<&str>,
    ) -> Result<(), DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_current_generation(&mut transaction, paper_id, generation).await?;
        sqlx::query("DELETE FROM paper_connections WHERE citing_paper_id = $1 AND generation = $2")
            .bind(paper_id)
            .bind(generation)
            .execute(&mut *transaction)
            .await?;
        for connection in connections {
            if connection.citing_paper_id != paper_id || connection.generation != generation {
                return Err(DbError::InvalidData(
                    "connection belongs to a different paper or generation".to_owned(),
                ));
            }
            sqlx::query(
                r"
                INSERT INTO paper_connections (
                    id,
                    citing_paper_id,
                    cited_paper_id,
                    reference_id,
                    generation,
                    relation_type,
                    summary,
                    confidence,
                    source_context_ids,
                    model_id,
                    prompt_version
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                ",
            )
            .bind(connection.id)
            .bind(paper_id)
            .bind(connection.cited_paper_id)
            .bind(connection.reference_id)
            .bind(generation)
            .bind(relation_type_name(connection.relation_type))
            .bind(&connection.summary)
            .bind(connection.confidence)
            .bind(&connection.source_context_ids)
            .bind(&connection.model_id)
            .bind(&connection.prompt_version)
            .execute(&mut *transaction)
            .await?;
        }
        let transition = publish_capability(
            &mut transaction,
            paper_id,
            generation,
            CapabilityToPublish::Connections {
                model: summary_model,
            },
        )
        .await?;
        transaction.commit().await?;
        if let Some(transition) = transition {
            observe_capability_transition(paper_id, generation, transition);
        }
        Ok(())
    }

    pub async fn connections(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<ConnectionsResponse>, DbError> {
        let Some(processing) = self.processing(paper_id).await? else {
            return Ok(None);
        };
        let keys = sqlx::query_as::<_, KeyConnectionRow>(
            r"
            SELECT
                connection.reference_id,
                cited.id AS paper_id,
                cited.arxiv_base_id,
                cited.arxiv_version,
                cited.title,
                cited.authors,
                reference.extracted_year AS year,
                connection.relation_type,
                connection.summary,
                connection.confidence
            FROM paper_connections AS connection
            JOIN papers AS cited ON cited.id = connection.cited_paper_id
            JOIN paper_references AS reference ON reference.id = connection.reference_id
            WHERE connection.citing_paper_id = $1
              AND connection.generation = $2
            ORDER BY reference.key_score DESC NULLS LAST,
                     connection.confidence DESC,
                     reference.ordinal ASC
            LIMIT 5
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(KeyConnection::try_from)
        .collect::<Result<_, _>>()?;
        let references = sqlx::query_as::<_, ConnectionReferenceRow>(
            r"
            SELECT
                reference.ordinal,
                reference.raw_text,
                reference.resolved_paper_id AS paper_id,
                resolved.title,
                reference.resolution_status
            FROM paper_references AS reference
            LEFT JOIN papers AS resolved ON resolved.id = reference.resolved_paper_id
            WHERE reference.citing_paper_id = $1
              AND reference.generation = $2
            ORDER BY reference.ordinal ASC
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(ConnectionReference::try_from)
        .collect::<Result<_, _>>()?;

        Ok(Some(ConnectionsResponse {
            paper_id,
            ready: processing.capabilities.connections,
            key_connections: keys,
            references,
        }))
    }

    pub async fn verification_metrics(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<VerificationMetrics>, DbError> {
        let Some(paper) = self.get(paper_id).await? else {
            return Ok(None);
        };
        let processing = self
            .processing(paper_id)
            .await?
            .ok_or_else(|| DbError::InvalidData("paper has no processing row".to_owned()))?;
        let introduction_paragraph_count = self
            .introduction(paper_id)
            .await?
            .map_or(0, |introduction| introduction.paragraphs.len());
        let chat_chunk_count = sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM paper_chunks WHERE paper_id = $1 AND generation = $2",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_one(&self.pool)
        .await?;
        let resolved_reference_count = sqlx::query_scalar::<_, i64>(
            r"
            SELECT count(*)
            FROM paper_references
            WHERE citing_paper_id = $1
              AND generation = $2
              AND resolution_status = 'resolved'
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_one(&self.pool)
        .await?;
        let key_connection_count = sqlx::query_scalar::<_, i64>(
            r"
            SELECT count(*)
            FROM paper_connections
            WHERE citing_paper_id = $1 AND generation = $2
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_one(&self.pool)
        .await?;
        let resolved_arxiv_base_ids = sqlx::query_scalar::<_, String>(
            r"
            SELECT resolved.arxiv_base_id
            FROM paper_references AS reference
            JOIN papers AS resolved ON resolved.id = reference.resolved_paper_id
            WHERE reference.citing_paper_id = $1
              AND reference.generation = $2
              AND reference.resolution_status = 'resolved'
            ORDER BY reference.ordinal
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_all(&self.pool)
        .await?;
        let relationship_prompt_versions = sqlx::query_scalar::<_, String>(
            r"
            SELECT DISTINCT prompt_version
            FROM paper_connections
            WHERE citing_paper_id = $1
              AND generation = $2
              AND prompt_version IS NOT NULL
            ORDER BY prompt_version
            ",
        )
        .bind(paper_id)
        .bind(processing.generation)
        .fetch_all(&self.pool)
        .await?;
        Ok(Some(VerificationMetrics {
            paper,
            processing,
            introduction_paragraph_count,
            chat_chunk_count: i64_to_usize(chat_chunk_count, "chunk count")?,
            resolved_reference_count: i64_to_usize(
                resolved_reference_count,
                "resolved reference count",
            )?,
            key_connection_count: i64_to_usize(key_connection_count, "connection count")?,
            resolved_arxiv_base_ids,
            relationship_prompt_versions,
        }))
    }
}

const PAPER_SELECT_BY_ID: &str = r"
    SELECT
        id,
        arxiv_base_id,
        arxiv_version,
        title,
        abstract AS abstract_text,
        authors,
        primary_category,
        categories,
        published_at,
        updated_at,
        abs_url,
        pdf_url,
        doi,
        journal_reference,
        comment,
        license_uri,
        metadata_fetched_at
    FROM papers
    WHERE id = $1
";

const PAPER_SELECT_BY_ARXIV: &str = r"
    SELECT
        id,
        arxiv_base_id,
        arxiv_version,
        title,
        abstract AS abstract_text,
        authors,
        primary_category,
        categories,
        published_at,
        updated_at,
        abs_url,
        pdf_url,
        doi,
        journal_reference,
        comment,
        license_uri,
        metadata_fetched_at
    FROM papers
    WHERE arxiv_base_id = $1
";

const PAPER_SUMMARY_BY_ID: &str = r"
    SELECT
        p.id,
        p.arxiv_base_id,
        p.arxiv_version,
        p.title,
        p.abstract AS abstract_text,
        p.authors,
        p.primary_category,
        p.categories,
        p.published_at,
        p.updated_at,
        p.abs_url,
        p.pdf_url,
        processing.metadata_ready,
        processing.introduction_ready,
        processing.chat_ready,
        processing.connections_ready
    FROM papers AS p
    JOIN paper_processing AS processing ON processing.paper_id = p.id
    WHERE p.id = $1
";

const PROCESSING_SELECT: &str = r"
    SELECT
        paper_id,
        generation,
        stage,
        metadata_ready,
        introduction_ready,
        chat_ready,
        connections_ready,
        retryable,
        last_error_category,
        last_error_code,
        last_error_message,
        started_at,
        updated_at,
        completed_at,
        parser_version,
        embedding_model,
        summary_model
    FROM paper_processing
    WHERE paper_id = $1
";

#[derive(Debug, FromRow)]
struct PaperRow {
    id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    abstract_text: String,
    authors: Value,
    primary_category: String,
    categories: Vec<String>,
    published_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    abs_url: String,
    pdf_url: String,
    doi: Option<String>,
    journal_reference: Option<String>,
    comment: Option<String>,
    license_uri: Option<String>,
    metadata_fetched_at: DateTime<Utc>,
}

impl TryFrom<PaperRow> for Paper {
    type Error = DbError;

    fn try_from(row: PaperRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            metadata: PaperMetadata {
                arxiv_id: ArxivIdentifier {
                    base_id: row.arxiv_base_id,
                    version: u32::try_from(row.arxiv_version)
                        .map_err(|_| DbError::InvalidData("negative arXiv version".to_owned()))?,
                },
                title: row.title,
                abstract_text: row.abstract_text,
                authors: decode_authors(row.authors)?,
                primary_category: row.primary_category,
                categories: row.categories,
                published_at: row.published_at,
                updated_at: row.updated_at,
                abs_url: Url::parse(&row.abs_url)?,
                pdf_url: Url::parse(&row.pdf_url)?,
                doi: row.doi,
                journal_reference: row.journal_reference,
                comment: row.comment,
                license_uri: row.license_uri.map(|url| Url::parse(&url)).transpose()?,
                metadata_fetched_at: row.metadata_fetched_at,
            },
        })
    }
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
struct PaperSummaryRow {
    id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    abstract_text: String,
    authors: Value,
    primary_category: String,
    categories: Vec<String>,
    published_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    abs_url: String,
    pdf_url: String,
    metadata_ready: bool,
    introduction_ready: bool,
    chat_ready: bool,
    connections_ready: bool,
}

#[derive(Debug, FromRow)]
struct LicenseUriRow {
    id: Uuid,
    license_uri: Option<String>,
}

impl TryFrom<PaperSummaryRow> for PaperSummary {
    type Error = DbError;

    fn try_from(row: PaperSummaryRow) -> Result<Self, Self::Error> {
        let authors = decode_authors(row.authors)?
            .into_iter()
            .map(|author| author.name)
            .collect();
        Ok(Self {
            paper_id: row.id,
            arxiv_id: format!(
                "{}v{}",
                row.arxiv_base_id,
                u32::try_from(row.arxiv_version)
                    .map_err(|_| DbError::InvalidData("negative arXiv version".to_owned()))?
            ),
            title: row.title,
            abstract_text: row.abstract_text,
            authors,
            primary_category: row.primary_category,
            categories: row.categories,
            published_at: row.published_at,
            updated_at: row.updated_at,
            abs_url: Url::parse(&row.abs_url)?,
            pdf_url: Url::parse(&row.pdf_url)?,
            capabilities: Capabilities {
                metadata: row.metadata_ready,
                introduction: row.introduction_ready,
                chat: row.chat_ready,
                connections: row.connections_ready,
            },
        })
    }
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
struct ProcessingRow {
    paper_id: Uuid,
    generation: i32,
    stage: String,
    metadata_ready: bool,
    introduction_ready: bool,
    chat_ready: bool,
    connections_ready: bool,
    retryable: bool,
    last_error_category: Option<String>,
    last_error_code: Option<String>,
    last_error_message: Option<String>,
    started_at: Option<DateTime<Utc>>,
    updated_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
    parser_version: Option<String>,
    embedding_model: Option<String>,
    summary_model: Option<String>,
}

impl TryFrom<ProcessingRow> for ProcessingState {
    type Error = DbError;

    fn try_from(row: ProcessingRow) -> Result<Self, Self::Error> {
        let stage = parse_processing_stage(&row.stage)?;
        let capabilities = Capabilities {
            metadata: row.metadata_ready,
            introduction: row.introduction_ready,
            chat: row.chat_ready,
            connections: row.connections_ready,
        };
        if !capabilities.valid_for_stage(stage) {
            return Err(DbError::InvalidData(format!(
                "capabilities violate publication order for stage `{}`",
                processing_stage_name(stage)
            )));
        }
        let last_error = match (row.last_error_code, row.last_error_message) {
            (Some(code), Some(message)) => Some(ProcessingError {
                category: row
                    .last_error_category
                    .as_deref()
                    .map(parse_failure_category)
                    .transpose()?
                    .unwrap_or(FailureCategory::Internal),
                code,
                message,
            }),
            (None, None) => None,
            _ => {
                return Err(DbError::InvalidData(
                    "processing error code and message must be set together".to_owned(),
                ));
            }
        };
        let overall_state = match stage {
            ProcessingStage::NotRequested => OverallProcessingState::NotRequested,
            ProcessingStage::Ready => OverallProcessingState::Ready,
            ProcessingStage::FailedRetryable | ProcessingStage::FailedTerminal => {
                OverallProcessingState::Failed
            }
            _ => OverallProcessingState::Processing,
        };
        Ok(Self {
            paper_id: row.paper_id,
            generation: row.generation,
            overall_state,
            stage,
            capabilities,
            retryable: row.retryable,
            last_error,
            started_at: row.started_at,
            updated_at: row.updated_at,
            completed_at: row.completed_at,
            parser_version: row.parser_version,
            embedding_model: row.embedding_model,
            summary_model: row.summary_model,
        })
    }
}

#[derive(Debug, FromRow)]
struct IntroductionHeaderRow {
    generation: i32,
    introduction_ready: bool,
    pdf_url: String,
}

#[derive(Debug, FromRow)]
struct IntroductionSectionRow {
    heading: Option<String>,
    paragraphs: Value,
    detection_confidence: Option<f32>,
}

#[derive(Debug, FromRow)]
struct IntroductionResolvedReferenceRow {
    ordinal: i32,
    paper_id: Uuid,
    title: String,
    context_text: Option<String>,
}

fn build_introduction_content(
    rows: Vec<IntroductionSectionRow>,
    resolved_reference_rows: Vec<IntroductionResolvedReferenceRow>,
) -> Result<(Option<String>, f32, Vec<IntroductionParagraph>), DbError> {
    // Detection source IDs are persisted in document order, with the
    // Introduction root first. Do not promote a nested heading to the root
    // when an unheaded fallback section is used.
    let heading = rows.first().and_then(|row| row.heading.clone());
    let confidence = rows
        .iter()
        .filter_map(|row| row.detection_confidence)
        .fold(0.0_f32, f32::max);
    let mut resolved_references = HashMap::new();
    let mut legacy_contexts = HashMap::<usize, Vec<String>>::new();
    for row in resolved_reference_rows {
        let ordinal = i32_to_usize(row.ordinal, "reference ordinal")?;
        resolved_references
            .entry(ordinal)
            .or_insert(IntroductionCitationReference {
                paper_id: row.paper_id,
                title: row.title,
            });
        if let Some(context) = row.context_text {
            legacy_contexts.entry(ordinal).or_default().push(context);
        }
    }
    let mut paragraphs = Vec::new();
    for (section_index, row) in rows.into_iter().enumerate() {
        let parsed: Vec<domain::ParsedParagraph> = serde_json::from_value(row.paragraphs)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        for (paragraph_index, paragraph) in parsed.into_iter().enumerate() {
            let legacy_paragraph = paragraph.citations.is_empty();
            let mut citations = paragraph
                .citations
                .into_iter()
                .filter_map(|citation| {
                    let marker = paragraph
                        .text
                        .chars()
                        .skip(citation.start)
                        .take(citation.end.saturating_sub(citation.start))
                        .collect::<String>();
                    if citation.end < citation.start || marker != citation.marker {
                        return None;
                    }
                    let references = resolved_citation_references(
                        &citation.reference_ordinals,
                        &resolved_references,
                    )?;
                    Some(IntroductionCitation {
                        start: citation.start,
                        end: citation.end,
                        marker: citation.marker,
                        references,
                    })
                })
                .collect::<Vec<_>>();
            if legacy_paragraph {
                citations = legacy_numeric_citations(
                    &paragraph.text,
                    &resolved_references,
                    &legacy_contexts,
                );
            }
            paragraphs.push(IntroductionParagraph {
                ordinal: paragraphs.len(),
                text: paragraph.text,
                heading: (section_index > 0 && paragraph_index == 0)
                    .then(|| row.heading.clone())
                    .flatten(),
                citations,
                page_start: paragraph.page_start,
                page_end: paragraph.page_end,
            });
        }
    }
    Ok((heading, confidence, paragraphs))
}

fn resolved_citation_references(
    ordinals: &[usize],
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
) -> Option<Vec<IntroductionCitationReference>> {
    if ordinals.is_empty() {
        return None;
    }
    let mut references = Vec::with_capacity(ordinals.len());
    for ordinal in ordinals {
        let reference = resolved_references.get(ordinal)?;
        if !references
            .iter()
            .any(|existing: &IntroductionCitationReference| existing.paper_id == reference.paper_id)
        {
            references.push(reference.clone());
        }
    }
    Some(references)
}

fn legacy_numeric_citations(
    text: &str,
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
    legacy_contexts: &HashMap<usize, Vec<String>>,
) -> Vec<IntroductionCitation> {
    legacy_numeric_marker_regex()
        .captures_iter(text)
        .filter_map(|captures| {
            let marker = captures.get(0)?;
            if text[..marker.start()].ends_with('[') || text[marker.end()..].starts_with(']') {
                return None;
            }
            let labels = parse_numeric_reference_labels(captures.name("body")?.as_str().trim())?;
            let references = uniquely_context_backed_references(
                &labels,
                text,
                marker.as_str(),
                resolved_references,
                legacy_contexts,
            )?;
            let start = text[..marker.start()].chars().count();
            Some(IntroductionCitation {
                start,
                end: start + marker.as_str().chars().count(),
                marker: marker.as_str().to_owned(),
                references,
            })
        })
        .collect()
}

fn uniquely_context_backed_references(
    labels: &[usize],
    paragraph: &str,
    marker: &str,
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
    legacy_contexts: &HashMap<usize, Vec<String>>,
) -> Option<Vec<IntroductionCitationReference>> {
    let exact_ordinals = labels.to_vec();
    let conventional_one_based = labels
        .iter()
        .map(|label| label.checked_sub(1))
        .collect::<Option<Vec<_>>>();
    let mut matches = [Some(exact_ordinals), conventional_one_based]
        .into_iter()
        .flatten()
        .filter_map(|ordinals| {
            let all_contexts_match = ordinals.iter().all(|ordinal| {
                legacy_contexts.get(ordinal).is_some_and(|contexts| {
                    contexts
                        .iter()
                        .any(|context| citation_context_matches(context, paragraph, marker))
                })
            });
            all_contexts_match
                .then(|| resolved_citation_references(&ordinals, resolved_references))
                .flatten()
        });
    let only_match = matches.next()?;
    matches.next().is_none().then_some(only_match)
}

fn citation_context_matches(context: &str, paragraph: &str, marker: &str) -> bool {
    let context = context.trim();
    let paragraph = paragraph.trim();
    !context.is_empty()
        && context.contains(marker)
        && (paragraph.contains(context) || context.contains(paragraph))
}

fn legacy_numeric_marker_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"\[(?P<body>[0-9][0-9,\t \-–]*)\]")
            .expect("legacy numeric citation marker regex is valid")
    })
}

fn parse_numeric_reference_labels(body: &str) -> Option<Vec<usize>> {
    const MAX_REFERENCES_PER_MARKER: usize = 64;
    let mut ordinals = Vec::new();
    for item in body.split(',') {
        let item = item.trim();
        if item.is_empty() {
            return None;
        }
        let range_parts = item.split(['-', '–']).map(str::trim).collect::<Vec<_>>();
        let (start, end) = match range_parts.as_slice() {
            [single] => {
                let value = parse_positive_numeric_label(single)?;
                (value, value)
            }
            [start, end] => {
                let start = parse_positive_numeric_label(start)?;
                let end = parse_positive_numeric_label(end)?;
                if end < start {
                    return None;
                }
                (start, end)
            }
            _ => return None,
        };
        if end.saturating_sub(start) >= MAX_REFERENCES_PER_MARKER {
            return None;
        }
        for ordinal in start..=end {
            if ordinals.contains(&ordinal) || ordinals.len() == MAX_REFERENCES_PER_MARKER {
                return None;
            }
            ordinals.push(ordinal);
        }
    }
    (!ordinals.is_empty()).then_some(ordinals)
}

fn parse_positive_numeric_label(value: &str) -> Option<usize> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value = value.parse::<usize>().ok()?;
    (value > 0).then_some(value)
}

#[derive(Debug, FromRow)]
struct StoredSectionRow {
    id: Uuid,
    kind: String,
    heading: Option<String>,
    text: String,
    paragraphs: Value,
    page_start: Option<i32>,
    page_end: Option<i32>,
    ordinal: i32,
}

impl TryFrom<StoredSectionRow> for StoredSection {
    type Error = DbError;

    fn try_from(row: StoredSectionRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            kind: parse_section_kind(&row.kind)?,
            heading: row.heading,
            text: row.text,
            paragraphs: serde_json::from_value(row.paragraphs)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            page_start: option_i32_to_u32(row.page_start, "section page")?,
            page_end: option_i32_to_u32(row.page_end, "section page")?,
            ordinal: i32_to_usize(row.ordinal, "section ordinal")?,
        })
    }
}

#[derive(Debug, FromRow)]
struct RetrievalRow {
    id: Uuid,
    paper_id: Uuid,
    section_id: Uuid,
    generation: i32,
    ordinal: i32,
    section_kind: String,
    section_heading: Option<String>,
    text: String,
    page_start: Option<i32>,
    page_end: Option<i32>,
    token_count: Option<i32>,
    rank: i64,
}

impl TryFrom<RetrievalRow> for RetrievalCandidate {
    type Error = DbError;

    fn try_from(row: RetrievalRow) -> Result<Self, Self::Error> {
        Ok(Self {
            chunk: domain::Chunk {
                id: row.id,
                paper_id: row.paper_id,
                section_id: row.section_id,
                generation: row.generation,
                ordinal: i32_to_usize(row.ordinal, "chunk ordinal")?,
                section_kind: parse_section_kind(&row.section_kind)?,
                section_heading: row.section_heading,
                text: row.text,
                page_start: option_i32_to_u32(row.page_start, "chunk page")?,
                page_end: option_i32_to_u32(row.page_end, "chunk page")?,
                token_count: i32_to_usize(row.token_count.unwrap_or(1), "chunk token count")?,
            },
            rank: usize::try_from(row.rank)
                .map_err(|_| DbError::InvalidData("negative retrieval rank".to_owned()))?,
        })
    }
}

#[derive(Debug, FromRow)]
struct ChatTurnRow {
    role: String,
    content: String,
}

impl TryFrom<ChatTurnRow> for ChatTurn {
    type Error = DbError;

    fn try_from(row: ChatTurnRow) -> Result<Self, Self::Error> {
        let role = match row.role.as_str() {
            "user" => ChatRole::User,
            "assistant" => ChatRole::Assistant,
            other => {
                return Err(DbError::InvalidData(format!("unknown chat role `{other}`")));
            }
        };
        Ok(Self {
            role,
            content: row.content,
        })
    }
}

#[derive(Debug, FromRow)]
struct ReferenceRow {
    id: Uuid,
    citing_paper_id: Uuid,
    generation: i32,
    ordinal: i32,
    raw_text: String,
    extracted_title: Option<String>,
    extracted_authors: Option<Value>,
    extracted_year: Option<i32>,
    doi: Option<String>,
    extracted_arxiv_id: Option<String>,
    resolved_paper_id: Option<Uuid>,
    resolution_status: String,
    resolution_confidence: Option<f32>,
    resolution_method: Option<String>,
    key_score: Option<f32>,
}

impl TryFrom<ReferenceRow> for domain::Reference {
    type Error = DbError;

    fn try_from(row: ReferenceRow) -> Result<Self, Self::Error> {
        let extracted_authors = row
            .extracted_authors
            .map(serde_json::from_value)
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?
            .unwrap_or_default();
        Ok(Self {
            id: row.id,
            citing_paper_id: row.citing_paper_id,
            generation: row.generation,
            ordinal: i32_to_usize(row.ordinal, "reference ordinal")?,
            raw_text: row.raw_text,
            extracted_title: row.extracted_title,
            extracted_authors,
            extracted_year: row.extracted_year,
            doi: row.doi,
            extracted_arxiv_id: row.extracted_arxiv_id,
            resolved_paper_id: row.resolved_paper_id,
            resolution_status: parse_reference_status(&row.resolution_status)?,
            resolution_confidence: row.resolution_confidence,
            resolution_method: row.resolution_method,
            key_score: row.key_score,
        })
    }
}

#[derive(Debug, FromRow)]
struct CitationContextRow {
    id: Uuid,
    reference_id: Uuid,
    section_kind: String,
    section_heading: Option<String>,
    context_text: String,
    page_number: Option<i32>,
    occurrence_ordinal: i32,
}

impl TryFrom<CitationContextRow> for domain::CitationContext {
    type Error = DbError;

    fn try_from(row: CitationContextRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            reference_id: row.reference_id,
            section_kind: parse_section_kind(&row.section_kind)?,
            section_heading: row.section_heading,
            context_text: row.context_text,
            page_number: option_i32_to_u32(row.page_number, "citation page")?,
            occurrence_ordinal: i32_to_usize(row.occurrence_ordinal, "citation occurrence")?,
        })
    }
}

#[derive(Debug, FromRow)]
struct TitleCandidateRow {
    id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    abstract_text: String,
    authors: Value,
    primary_category: String,
    categories: Vec<String>,
    published_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    abs_url: String,
    pdf_url: String,
    doi: Option<String>,
    journal_reference: Option<String>,
    comment: Option<String>,
    license_uri: Option<String>,
    metadata_fetched_at: DateTime<Utc>,
    similarity: f32,
}

impl TryFrom<TitleCandidateRow> for TitleCandidate {
    type Error = DbError;

    fn try_from(row: TitleCandidateRow) -> Result<Self, Self::Error> {
        let similarity = row.similarity;
        let paper = Paper::try_from(PaperRow {
            id: row.id,
            arxiv_base_id: row.arxiv_base_id,
            arxiv_version: row.arxiv_version,
            title: row.title,
            abstract_text: row.abstract_text,
            authors: row.authors,
            primary_category: row.primary_category,
            categories: row.categories,
            published_at: row.published_at,
            updated_at: row.updated_at,
            abs_url: row.abs_url,
            pdf_url: row.pdf_url,
            doi: row.doi,
            journal_reference: row.journal_reference,
            comment: row.comment,
            license_uri: row.license_uri,
            metadata_fetched_at: row.metadata_fetched_at,
        })?;
        Ok(Self { paper, similarity })
    }
}

#[derive(Debug, FromRow)]
struct KeyConnectionRow {
    reference_id: Uuid,
    paper_id: Uuid,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    authors: Value,
    year: Option<i32>,
    relation_type: String,
    summary: String,
    confidence: f32,
}

impl TryFrom<KeyConnectionRow> for KeyConnection {
    type Error = DbError;

    fn try_from(row: KeyConnectionRow) -> Result<Self, Self::Error> {
        Ok(Self {
            reference_id: row.reference_id,
            paper_id: row.paper_id,
            arxiv_id: format!("{}v{}", row.arxiv_base_id, row.arxiv_version),
            title: row.title,
            authors: decode_authors(row.authors)?
                .into_iter()
                .map(|author| author.name)
                .collect(),
            year: row.year,
            relation_type: parse_relation_type(&row.relation_type)?,
            summary: row.summary,
            confidence: row.confidence,
        })
    }
}

#[derive(Debug, FromRow)]
struct ConnectionReferenceRow {
    ordinal: i32,
    raw_text: String,
    paper_id: Option<Uuid>,
    title: Option<String>,
    resolution_status: String,
}

impl TryFrom<ConnectionReferenceRow> for ConnectionReference {
    type Error = DbError;

    fn try_from(row: ConnectionReferenceRow) -> Result<Self, Self::Error> {
        Ok(Self {
            ordinal: i32_to_usize(row.ordinal, "reference ordinal")?,
            raw_text: row.raw_text,
            resolved: row.paper_id.is_some()
                && row.resolution_status
                    == reference_status_name(ReferenceResolutionStatus::Resolved),
            paper_id: row.paper_id,
            title: row.title,
            resolution_status: parse_reference_status(&row.resolution_status)?,
        })
    }
}

fn decode_authors(value: Value) -> Result<Vec<Author>, DbError> {
    if let Ok(authors) = serde_json::from_value::<Vec<Author>>(value.clone()) {
        return Ok(authors);
    }
    serde_json::from_value::<Vec<String>>(value)
        .map(|authors| authors.into_iter().map(Author::from).collect())
        .map_err(|error| DbError::InvalidData(error.to_string()))
}

fn processing_stage_name(stage: ProcessingStage) -> &'static str {
    match stage {
        ProcessingStage::NotRequested => "not_requested",
        ProcessingStage::Queued => "queued",
        ProcessingStage::FetchingLicense => "fetching_license",
        ProcessingStage::FetchingPdf => "fetching_pdf",
        ProcessingStage::ParsingPdf => "parsing_pdf",
        ProcessingStage::IntroductionReady => "introduction_ready",
        ProcessingStage::IndexingChat => "indexing_chat",
        ProcessingStage::ResolvingReferences => "resolving_references",
        ProcessingStage::Ready => "ready",
        ProcessingStage::FailedRetryable => "failed_retryable",
        ProcessingStage::FailedTerminal => "failed_terminal",
    }
}

fn parse_processing_stage(value: &str) -> Result<ProcessingStage, DbError> {
    match value {
        "not_requested" => Ok(ProcessingStage::NotRequested),
        "queued" => Ok(ProcessingStage::Queued),
        "fetching_license" => Ok(ProcessingStage::FetchingLicense),
        "fetching_pdf" => Ok(ProcessingStage::FetchingPdf),
        "parsing_pdf" => Ok(ProcessingStage::ParsingPdf),
        "introduction_ready" => Ok(ProcessingStage::IntroductionReady),
        "indexing_chat" => Ok(ProcessingStage::IndexingChat),
        "resolving_references" => Ok(ProcessingStage::ResolvingReferences),
        "ready" => Ok(ProcessingStage::Ready),
        "failed_retryable" => Ok(ProcessingStage::FailedRetryable),
        "failed_terminal" => Ok(ProcessingStage::FailedTerminal),
        other => Err(DbError::InvalidData(format!(
            "unknown processing stage `{other}`"
        ))),
    }
}

fn failure_category_name(category: FailureCategory) -> &'static str {
    match category {
        FailureCategory::ExternalTemporary => "external_temporary",
        FailureCategory::ExternalPermanent => "external_permanent",
        FailureCategory::ParserTemporary => "parser_temporary",
        FailureCategory::ParserDocument => "parser_document",
        FailureCategory::ModelTemporary => "model_temporary",
        FailureCategory::Validation => "validation",
        FailureCategory::Internal => "internal",
    }
}

fn parse_failure_category(value: &str) -> Result<FailureCategory, DbError> {
    match value {
        "external_temporary" => Ok(FailureCategory::ExternalTemporary),
        "external_permanent" => Ok(FailureCategory::ExternalPermanent),
        "parser_temporary" => Ok(FailureCategory::ParserTemporary),
        "parser_document" => Ok(FailureCategory::ParserDocument),
        "model_temporary" => Ok(FailureCategory::ModelTemporary),
        "validation" => Ok(FailureCategory::Validation),
        "internal" => Ok(FailureCategory::Internal),
        other => Err(DbError::InvalidData(format!(
            "unknown failure category `{other}`"
        ))),
    }
}

fn section_kind_name(kind: SectionKind) -> &'static str {
    match kind {
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

fn parse_section_kind(value: &str) -> Result<SectionKind, DbError> {
    match value {
        "abstract" => Ok(SectionKind::Abstract),
        "introduction" => Ok(SectionKind::Introduction),
        "background" => Ok(SectionKind::Background),
        "related_work" => Ok(SectionKind::RelatedWork),
        "method" => Ok(SectionKind::Method),
        "experiment" => Ok(SectionKind::Experiment),
        "result" => Ok(SectionKind::Result),
        "discussion" => Ok(SectionKind::Discussion),
        "limitation" => Ok(SectionKind::Limitation),
        "conclusion" => Ok(SectionKind::Conclusion),
        "appendix" => Ok(SectionKind::Appendix),
        "acknowledgment" => Ok(SectionKind::Acknowledgment),
        "references" => Ok(SectionKind::References),
        "other" => Ok(SectionKind::Other),
        other => Err(DbError::InvalidData(format!(
            "unknown section kind `{other}`"
        ))),
    }
}

fn reference_status_name(status: ReferenceResolutionStatus) -> &'static str {
    match status {
        ReferenceResolutionStatus::Unresolved => "unresolved",
        ReferenceResolutionStatus::Resolving => "resolving",
        ReferenceResolutionStatus::Resolved => "resolved",
        ReferenceResolutionStatus::Ambiguous => "ambiguous",
        ReferenceResolutionStatus::NotArxiv => "not_arxiv",
        ReferenceResolutionStatus::Failed => "failed",
    }
}

fn parse_reference_status(value: &str) -> Result<ReferenceResolutionStatus, DbError> {
    match value {
        "unresolved" => Ok(ReferenceResolutionStatus::Unresolved),
        "resolving" => Ok(ReferenceResolutionStatus::Resolving),
        "resolved" => Ok(ReferenceResolutionStatus::Resolved),
        "ambiguous" => Ok(ReferenceResolutionStatus::Ambiguous),
        "not_arxiv" => Ok(ReferenceResolutionStatus::NotArxiv),
        "failed" => Ok(ReferenceResolutionStatus::Failed),
        other => Err(DbError::InvalidData(format!(
            "unknown reference status `{other}`"
        ))),
    }
}

fn relation_type_name(relation_type: RelationType) -> &'static str {
    match relation_type {
        RelationType::BuildsOn => "builds_on",
        RelationType::Uses => "uses",
        RelationType::Extends => "extends",
        RelationType::Applies => "applies",
        RelationType::ComparesWith => "compares_with",
        RelationType::ContrastsWith => "contrasts_with",
        RelationType::Background => "background",
        RelationType::RelatedWork => "related_work",
        RelationType::Unknown => "unknown",
    }
}

fn parse_relation_type(value: &str) -> Result<RelationType, DbError> {
    match value {
        "builds_on" => Ok(RelationType::BuildsOn),
        "uses" => Ok(RelationType::Uses),
        "extends" => Ok(RelationType::Extends),
        "applies" => Ok(RelationType::Applies),
        "compares_with" => Ok(RelationType::ComparesWith),
        "contrasts_with" => Ok(RelationType::ContrastsWith),
        "background" => Ok(RelationType::Background),
        "related_work" => Ok(RelationType::RelatedWork),
        "unknown" => Ok(RelationType::Unknown),
        other => Err(DbError::InvalidData(format!(
            "unknown relation type `{other}`"
        ))),
    }
}

fn usize_to_i32(value: usize, field: &str) -> Result<i32, DbError> {
    i32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is too large")))
}

fn i32_to_usize(value: i32, field: &str) -> Result<usize, DbError> {
    usize::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
}

fn i64_to_usize(value: i64, field: &str) -> Result<usize, DbError> {
    usize::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
}

fn option_u32_to_i32(value: Option<u32>, field: &str) -> Result<Option<i32>, DbError> {
    value
        .map(|value| {
            i32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is too large")))
        })
        .transpose()
}

fn option_i32_to_u32(value: Option<i32>, field: &str) -> Result<Option<u32>, DbError> {
    value
        .map(|value| {
            u32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
        })
        .transpose()
}

fn require_current_generation(rows_affected: u64) -> Result<(), DbError> {
    if rows_affected == 1 {
        Ok(())
    } else {
        Err(DbError::StaleGeneration)
    }
}

async fn lock_current_generation(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<(), DbError> {
    let current = sqlx::query_scalar::<_, i32>(
        r"
        SELECT generation
        FROM paper_processing
        WHERE paper_id = $1
        FOR UPDATE
        ",
    )
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?;
    if current == Some(generation) {
        Ok(())
    } else {
        Err(DbError::StaleGeneration)
    }
}

#[derive(Clone, Copy)]
enum CapabilityToPublish<'a> {
    Chat { model: &'a str },
    Connections { model: Option<&'a str> },
}

#[derive(Clone, Copy)]
struct CapabilityTransition {
    capability: &'static str,
    transitioned_at: DateTime<Utc>,
}

async fn publish_capability(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
    capability: CapabilityToPublish<'_>,
) -> Result<Option<CapabilityTransition>, DbError> {
    let (capability_name, was_ready) = match capability {
        CapabilityToPublish::Chat { .. } => (
            "chat",
            sqlx::query_scalar::<_, bool>(
                "SELECT chat_ready FROM paper_processing WHERE paper_id = $1",
            )
            .bind(paper_id)
            .fetch_one(&mut **transaction)
            .await?,
        ),
        CapabilityToPublish::Connections { .. } => (
            "connections",
            sqlx::query_scalar::<_, bool>(
                "SELECT connections_ready FROM paper_processing WHERE paper_id = $1",
            )
            .bind(paper_id)
            .fetch_one(&mut **transaction)
            .await?,
        ),
    };
    let changed = match capability {
        CapabilityToPublish::Chat { model } => {
            sqlx::query(
                r"
                UPDATE paper_processing
                SET chat_ready = true,
                    embedding_model = $3,
                    stage = CASE
                        WHEN connections_ready THEN 'ready'
                        WHEN stage IN ('failed_retryable', 'failed_terminal') THEN stage
                        ELSE 'resolving_references'
                    END,
                    completed_at = CASE WHEN connections_ready THEN now() ELSE completed_at END,
                    retryable = CASE WHEN connections_ready THEN false ELSE retryable END,
                    last_error_category = CASE WHEN connections_ready THEN NULL ELSE last_error_category END,
                    last_error_code = CASE WHEN connections_ready THEN NULL ELSE last_error_code END,
                    last_error_message = CASE WHEN connections_ready THEN NULL ELSE last_error_message END,
                    updated_at = now()
                WHERE paper_id = $1 AND generation = $2
                ",
            )
            .bind(paper_id)
            .bind(generation)
            .bind(model)
            .execute(&mut **transaction)
            .await?
            .rows_affected()
        }
        CapabilityToPublish::Connections { model } => {
            sqlx::query(
                r"
                UPDATE paper_processing
                SET connections_ready = true,
                    summary_model = $3,
                    stage = CASE
                        WHEN chat_ready THEN 'ready'
                        WHEN stage IN ('failed_retryable', 'failed_terminal') THEN stage
                        ELSE 'indexing_chat'
                    END,
                    completed_at = CASE WHEN chat_ready THEN now() ELSE completed_at END,
                    retryable = CASE WHEN chat_ready THEN false ELSE retryable END,
                    last_error_category = CASE WHEN chat_ready THEN NULL ELSE last_error_category END,
                    last_error_code = CASE WHEN chat_ready THEN NULL ELSE last_error_code END,
                    last_error_message = CASE WHEN chat_ready THEN NULL ELSE last_error_message END,
                    updated_at = now()
                WHERE paper_id = $1 AND generation = $2
                ",
            )
            .bind(paper_id)
            .bind(generation)
            .bind(model)
            .execute(&mut **transaction)
            .await?
            .rows_affected()
        }
    };
    require_current_generation(changed)?;
    if was_ready {
        return Ok(None);
    }
    let transitioned_at = sqlx::query_scalar::<_, DateTime<Utc>>(
        "SELECT updated_at FROM paper_processing WHERE paper_id = $1 AND generation = $2",
    )
    .bind(paper_id)
    .bind(generation)
    .fetch_one(&mut **transaction)
    .await?;
    Ok(Some(CapabilityTransition {
        capability: capability_name,
        transitioned_at,
    }))
}

fn observe_capability_transition(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    transition: CapabilityTransition,
) {
    info!(
        metric.name = "capability_transition",
        paper_id = %paper_id,
        generation,
        capability = transition.capability,
        transition = "ready",
        transition.timestamp = %transition.transitioned_at.to_rfc3339(),
        "paper capability became ready"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enums_round_trip_database_names() {
        for stage in [
            ProcessingStage::NotRequested,
            ProcessingStage::Queued,
            ProcessingStage::FetchingLicense,
            ProcessingStage::FetchingPdf,
            ProcessingStage::ParsingPdf,
            ProcessingStage::IntroductionReady,
            ProcessingStage::IndexingChat,
            ProcessingStage::ResolvingReferences,
            ProcessingStage::Ready,
            ProcessingStage::FailedRetryable,
            ProcessingStage::FailedTerminal,
        ] {
            assert_eq!(
                parse_processing_stage(processing_stage_name(stage)).unwrap(),
                stage
            );
        }
        for kind in [
            SectionKind::Abstract,
            SectionKind::Introduction,
            SectionKind::Background,
            SectionKind::RelatedWork,
            SectionKind::Method,
            SectionKind::Experiment,
            SectionKind::Result,
            SectionKind::Discussion,
            SectionKind::Limitation,
            SectionKind::Conclusion,
            SectionKind::Appendix,
            SectionKind::Acknowledgment,
            SectionKind::References,
            SectionKind::Other,
        ] {
            assert_eq!(parse_section_kind(section_kind_name(kind)).unwrap(), kind);
        }
    }

    #[test]
    fn author_decoder_accepts_current_and_legacy_shapes() {
        let current = serde_json::json!([{"name": "Ada"}, {"name": "Grace"}]);
        let legacy = serde_json::json!(["Ada", "Grace"]);
        assert_eq!(
            decode_authors(current).unwrap(),
            decode_authors(legacy).unwrap()
        );
    }

    #[test]
    fn introduction_content_keeps_nested_headings_and_links_only_resolved_markers() {
        let resolved_paper_id = Uuid::new_v4();
        let rows = vec![
            IntroductionSectionRow {
                heading: Some("1 Introduction".to_owned()),
                paragraphs: serde_json::json!([{
                    "ordinal": 0,
                    "text": "Préface cites [1] and [2].",
                    "citations": [
                        {
                            "start": 14,
                            "end": 17,
                            "marker": "[1]",
                            "reference_ordinals": [0]
                        },
                        {
                            "start": 22,
                            "end": 25,
                            "marker": "[2]",
                            "reference_ordinals": [1]
                        }
                    ],
                    "page_start": 1,
                    "page_end": 1
                }]),
                detection_confidence: Some(0.99),
            },
            IntroductionSectionRow {
                heading: Some("1.1 Motivation".to_owned()),
                // This legacy paragraph shape deliberately lacks `citations`.
                paragraphs: serde_json::json!([{
                    "ordinal": 0,
                    "text": "A nested subsection remains readable.",
                    "page_start": 2,
                    "page_end": 2
                }]),
                detection_confidence: Some(0.99),
            },
        ];
        let resolved = vec![IntroductionResolvedReferenceRow {
            ordinal: 0,
            paper_id: resolved_paper_id,
            title: "Resolved work".to_owned(),
            context_text: None,
        }];

        let (heading, confidence, paragraphs) = build_introduction_content(rows, resolved).unwrap();

        assert_eq!(heading.as_deref(), Some("1 Introduction"));
        assert!((confidence - 0.99).abs() < f32::EPSILON);
        assert_eq!(paragraphs[0].citations.len(), 1);
        assert_eq!(paragraphs[0].citations[0].marker, "[1]");
        assert_eq!(
            paragraphs[0].citations[0].references[0].paper_id,
            resolved_paper_id
        );
        assert!(paragraphs[0].text.contains("[2]"));
        assert_eq!(paragraphs[1].heading.as_deref(), Some("1.1 Motivation"));
        assert!(paragraphs[1].citations.is_empty());
    }

    #[test]
    fn legacy_numeric_citations_handle_unicode_lists_ranges_and_unresolved_markers() {
        let resolved_references = [0usize, 1, 2, 3, 4, 11]
            .into_iter()
            .map(|ordinal| {
                (
                    ordinal,
                    IntroductionCitationReference {
                        paper_id: Uuid::new_v4(),
                        title: format!("Resolved reference {}", ordinal + 1),
                    },
                )
            })
            .collect::<HashMap<_, _>>();
        let legacy_contexts = HashMap::from([
            (0, vec!["combines [1, 3]".to_owned()]),
            (1, vec!["a context for another marker [9]".to_owned()]),
            (
                2,
                vec!["combines [1, 3]".to_owned(), "spans [2–4]".to_owned()],
            ),
            (3, vec!["spans [2–4]".to_owned()]),
            (4, vec!["spans [2–4]".to_owned()]),
            (11, vec!["Résumé cites [12]".to_owned()]),
        ]);
        let text = "Résumé cites [12], combines [1, 3], spans [2–4], and leaves [5] unresolved.";

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert_eq!(
            citations
                .iter()
                .map(|citation| citation.marker.as_str())
                .collect::<Vec<_>>(),
            ["[12]", "[1, 3]", "[2–4]"]
        );
        assert_eq!(citations[0].references.len(), 1);
        assert_eq!(citations[1].references.len(), 2);
        assert_eq!(citations[2].references.len(), 3);
        for citation in &citations {
            assert_eq!(
                text.chars()
                    .skip(citation.start)
                    .take(citation.end - citation.start)
                    .collect::<String>(),
                citation.marker
            );
        }
        assert!(text.contains("[5]"));
        assert!(citations.iter().all(|citation| citation.marker != "[5]"));
    }

    #[test]
    fn context_backed_legacy_mapping_ignores_spurious_self_entry_offset() {
        let wrong_paper_id = Uuid::new_v4();
        let correct_paper_id = Uuid::new_v4();
        let resolved_references = HashMap::from([
            (
                6,
                IntroductionCitationReference {
                    paper_id: wrong_paper_id,
                    title: "Xception".to_owned(),
                },
            ),
            (
                7,
                IntroductionCitationReference {
                    paper_id: correct_paper_id,
                    title: "The actual seventh citation".to_owned(),
                },
            ),
        ]);
        let legacy_contexts = HashMap::from([
            (
                6,
                vec!["A spurious self-entry belongs to a different context [1].".to_owned()],
            ),
            (
                7,
                vec!["The model follows [7] for sequence transduction.".to_owned()],
            ),
        ]);
        let text = "The model follows [7] for sequence transduction.";

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert_eq!(citations.len(), 1);
        assert_eq!(citations[0].marker, "[7]");
        assert_eq!(citations[0].references[0].paper_id, correct_paper_id);
        assert_ne!(citations[0].references[0].paper_id, wrong_paper_id);
    }

    #[test]
    fn legacy_numeric_citations_reject_ambiguous_or_partial_markers() {
        let first = IntroductionCitationReference {
            paper_id: Uuid::new_v4(),
            title: "Ordinal zero".to_owned(),
        };
        let second = IntroductionCitationReference {
            paper_id: Uuid::new_v4(),
            title: "Ordinal one".to_owned(),
        };
        let resolved_references = HashMap::from([(0, first), (1, second)]);
        let text = "Ambiguous [1]; partial [1, 2]; malformed [2–1], [1,,2], and [[1]].";
        let legacy_contexts = HashMap::from([
            (
                0,
                vec!["Ambiguous [1]".to_owned(), "partial [1, 2]".to_owned()],
            ),
            (1, vec!["Ambiguous [1]".to_owned()]),
        ]);

        let citations = legacy_numeric_citations(text, &resolved_references, &legacy_contexts);

        assert!(citations.is_empty());
    }

    #[test]
    fn processing_rows_reject_out_of_order_capability_publication() {
        let invalid = processing_row("indexing_chat", false, true, false);
        assert!(matches!(
            ProcessingState::try_from(invalid),
            Err(DbError::InvalidData(message)) if message.contains("publication order")
        ));

        let valid = processing_row("resolving_references", true, true, false);
        let state = ProcessingState::try_from(valid).unwrap();
        assert!(state.capabilities.introduction);
        assert!(state.capabilities.chat);
        assert!(!state.capabilities.connections);
    }

    fn processing_row(
        stage: &str,
        introduction_ready: bool,
        chat_ready: bool,
        connections_ready: bool,
    ) -> ProcessingRow {
        ProcessingRow {
            paper_id: Uuid::new_v4(),
            generation: 1,
            stage: stage.to_owned(),
            metadata_ready: true,
            introduction_ready,
            chat_ready,
            connections_ready,
            retryable: false,
            last_error_category: None,
            last_error_code: None,
            last_error_message: None,
            started_at: Some(Utc::now()),
            updated_at: Utc::now(),
            completed_at: None,
            parser_version: Some("fixture-parser".to_owned()),
            embedding_model: None,
            summary_model: None,
        }
    }

    /// Requires a disposable `PostgreSQL` database with `pgvector`, `pg_trgm`
    /// and `pgcrypto` available. This is intentionally opt-in for local/CI service
    /// jobs; unit tests never require a live database.
    #[tokio::test]
    #[ignore = "set TEST_DATABASE_URL to a disposable PostgreSQL database"]
    async fn migrations_apply_and_required_extensions_are_ready() {
        let url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let database = Database::connect(&url, 2).await.unwrap();
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../migrations");
        database.migrate(path).await.unwrap();
        database.ready().await.unwrap();
    }
}
