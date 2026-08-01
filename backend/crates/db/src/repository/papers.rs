use super::{
    CapabilityToPublish, CapabilityTransition, CitationContextRow, ConnectionReference,
    ConnectionReferenceRow, ConnectionsResponse, DateTime, DbError, Duration, FeedCursor, FeedPage,
    FeedQuery, HashMap, Instant, Introduction, IntroductionDetection, IntroductionHeaderRow,
    IntroductionResolvedReferenceRow, IntroductionSectionRow, JobKind, KeyConnection,
    KeyConnectionRow, LicenseUriRow, PAPER_SELECT_BY_ARXIV, PAPER_SELECT_BY_ID,
    PAPER_SUMMARY_BY_ID, PROCESSING_SELECT, Paper, PaperId, PaperMetadata, PaperRepository,
    PaperRow, PaperSummary, PaperSummaryRow, ParsedPaper, Postgres, PrepareResult,
    ProcessingGeneration, ProcessingRow, ProcessingStage, ProcessingState, QueryBuilder,
    ReferenceResolutionStatus, ReferenceRow, RetrievalCandidate, RetrievalRow, StoredSection,
    StoredSectionRow, TitleCandidate, TitleCandidateRow, Url, Utc, Uuid, Value, Vector,
    VerificationMetrics, build_introduction_content, debug, failure_category_name, i64_to_usize,
    info, instrument, lock_current_generation, observe_capability_transition, option_u32_to_i32,
    processing_stage_name, publish_capability, reference_status_name, relation_type_name,
    require_current_generation, section_kind_name, usize_to_i32,
};

impl PaperRepository {
    #[instrument(
        skip(self, query),
        fields(
            category_filtered = query.category.is_some(),
            cursor_present = query.cursor.is_some()
        )
    )]
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
            generation: processing.generation,
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
