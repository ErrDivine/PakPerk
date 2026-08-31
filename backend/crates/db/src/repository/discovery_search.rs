use std::{str::FromStr as _, time::Duration};

use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use discovery_search::{
    ExploreSearchRequest, LookupSearchRequest, MatchKind, RelatedTopic, SavedSearch,
    SavedSearchDefinition, SavedSearchDeleteOutcome, SavedSearchReadOutcome,
    SavedSearchWriteOutcome, SearchFingerprint, SearchMutationRateDecision, SearchPage,
    SearchRateLimitStore, SearchResult, SearchSource, SearchStore, SearchStoreError,
    SearchSuggestions, SourceCoverage, SourceDiagnostic, SourceStatus,
};
use domain::{AccountStatus, AuthenticatedUserId, PaperSummary};
use opaque_cursor::OpaqueCursorCodec;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::{DbError, RateLimitRepository, RateLimitRequest, rows::PaperSummaryRow};

const LOOKUP_CURSOR_PURPOSE: &str = "search.lookup.v1";
const EXPLORE_CURSOR_PURPOSE: &str = "search.explore.v1";

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchCursor {
    order_bucket: i64,
    published_at: DateTime<Utc>,
    paper_id: Uuid,
}

#[derive(Debug, FromRow)]
struct SearchPaperRow {
    #[sqlx(flatten)]
    paper: PaperSummaryRow,
    match_kind: String,
    relevance_bucket: i64,
}

#[derive(Debug, FromRow)]
struct TopicSuggestionRow {
    id: Uuid,
    label: String,
    source_vocabulary: String,
}

#[derive(Debug, FromRow)]
struct AccountStatusRow {
    status: String,
}

#[derive(Debug, FromRow)]
struct SavedSearchRow {
    id: Uuid,
    user_id: Uuid,
    normalized_query: String,
    categories: Vec<String>,
    topics: Vec<String>,
    published_after: Option<NaiveDate>,
    published_before: Option<NaiveDate>,
    sources: Vec<String>,
    sort: String,
    revision: i64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct SavedSearchOperationRow {
    intent_fingerprint: Vec<u8>,
    saved_search_id: Uuid,
}

#[derive(Clone)]
pub struct DiscoverySearchRepository {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

impl DiscoverySearchRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    #[must_use]
    pub const fn with_cursor_codec(pool: PgPool, cursor_codec: Option<OpaqueCursorCodec>) -> Self {
        Self { pool, cursor_codec }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Removes only expired content-free retry bindings. Saved query
    /// definitions remain account-owned until explicit or account deletion.
    pub async fn cleanup_expired_operations(&self, batch_size: u32) -> Result<u64, DbError> {
        if batch_size == 0 || batch_size > 10_000 {
            return Err(DbError::InvalidData(
                "saved-search cleanup batch is invalid".to_owned(),
            ));
        }
        let result = sqlx::query(
            r"
            WITH expired AS (
                SELECT user_id, operation_id
                FROM saved_search_operations
                WHERE expires_at <= statement_timestamp()
                ORDER BY expires_at, user_id, operation_id
                LIMIT $1
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM saved_search_operations AS operation
            USING expired
            WHERE operation.user_id = expired.user_id
              AND operation.operation_id = expired.operation_id
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    // Keeping the complete ranking ladder in one statement makes cursor order
    // and rank-tier changes auditable together.
    #[allow(clippy::too_many_lines)]
    async fn lookup_inner(
        &self,
        request: &LookupSearchRequest,
    ) -> Result<SearchPage, SearchStoreError> {
        let scope = lookup_scope(request);
        let cursor =
            self.decode_cursor(LOOKUP_CURSOR_PURPOSE, &scope, request.cursor.as_deref())?;
        let fetch_limit = i64::from(request.limit) + 1;
        let mut rows = sqlx::query_as::<_, SearchPaperRow>(
            r"
            WITH ranked AS (
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
                    processing.connections_ready,
                    CASE
                        WHEN $2::text IS NOT NULL AND p.arxiv_base_id = $2 THEN 0
                        WHEN p.doi IS NOT NULL AND lower(p.doi) = $1 THEN 1
                        WHEN p.normalized_title = btrim(regexp_replace($1, '[^[:alnum:]]+', ' ', 'g')) THEN 2
                        WHEN similarity(p.normalized_title, $1) >= 0.6 THEN 3
                        WHEN author_title.exact_author_with_title_tokens THEN 4
                        ELSE 6
                    END::bigint AS relevance_bucket,
                    CASE
                        WHEN $2::text IS NOT NULL AND p.arxiv_base_id = $2 THEN 'exact_arxiv_id'
                        WHEN p.doi IS NOT NULL AND lower(p.doi) = $1 THEN 'exact_doi'
                        WHEN p.normalized_title = btrim(regexp_replace($1, '[^[:alnum:]]+', ' ', 'g')) THEN 'exact_title'
                        WHEN similarity(p.normalized_title, $1) >= 0.6 THEN 'phrase'
                        WHEN author_title.exact_author_with_title_tokens THEN 'exact_author'
                        ELSE 'related_text'
                    END AS match_kind
                FROM papers AS p
                JOIN paper_processing AS processing ON processing.paper_id = p.id
                CROSS JOIN LATERAL (
                    SELECT EXISTS (
                        SELECT 1
                        FROM (
                            SELECT lower(btrim(coalesce(
                                author.value ->> 'name',
                                trim(both chr(34) from author.value::text)
                            ))) AS author_name
                            FROM jsonb_array_elements(p.authors) AS author(value)
                        ) AS normalized_author
                        WHERE position(normalized_author.author_name in $1) > 0
                          AND char_length(btrim(replace(
                              $1,
                              normalized_author.author_name,
                              ''
                          ))) >= 2
                          AND to_tsvector(
                              'english'::regconfig,
                              p.normalized_title
                          ) @@ websearch_to_tsquery(
                              'english'::regconfig,
                              btrim(replace(
                                  $1,
                                  normalized_author.author_name,
                                  ''
                              ))
                          )
                    ) AS exact_author_with_title_tokens
                ) AS author_title
                WHERE processing.metadata_ready
                  AND p.metadata_source = 'arxiv'
                  AND (
                    ($2::text IS NOT NULL AND p.arxiv_base_id = $2)
                    OR (p.doi IS NOT NULL AND lower(p.doi) = $1)
                    OR p.normalized_title % $1
                    OR lower(p.authors::text) % $1
                    OR p.search_document @@ websearch_to_tsquery('english'::regconfig, $1)
                  )
            )
            SELECT *
            FROM ranked
            WHERE
                $3::bigint IS NULL
                OR relevance_bucket > $3
                OR (
                    relevance_bucket = $3
                    AND (
                        published_at < $4
                        OR (published_at = $4 AND id < $5)
                    )
                )
            ORDER BY relevance_bucket ASC, published_at DESC, id DESC
            LIMIT $6
            ",
        )
        .bind(&request.normalized_query)
        .bind(request.exact_arxiv_base_id.as_deref())
        .bind(cursor.map(|value| value.order_bucket))
        .bind(cursor.map(|value| value.published_at))
        .bind(cursor.map(|value| value.paper_id))
        .bind(fetch_limit)
        .fetch_all(&self.pool)
        .await
        .map_err(store_sql)?;

        self.finish_page(
            LOOKUP_CURSOR_PURPOSE,
            &scope,
            request.normalized_query.clone(),
            request.limit,
            &mut rows,
            Vec::new(),
        )
    }

    async fn explore_inner(
        &self,
        request: &ExploreSearchRequest,
    ) -> Result<SearchPage, SearchStoreError> {
        let scope = explore_scope(request);
        let cursor =
            self.decode_cursor(EXPLORE_CURSOR_PURPOSE, &scope, request.cursor.as_deref())?;
        let categories = request.filters.categories.clone();
        let topics = request.filters.topics.clone();
        let sources = request
            .filters
            .sources
            .iter()
            .map(|source| source.as_str().to_owned())
            .collect::<Vec<_>>();
        let fetch_limit = i64::from(request.limit) + 1;
        let mut transaction = self.pool.begin().await.map_err(store_sql)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .execute(&mut *transaction)
            .await
            .map_err(store_sql)?;
        let mut rows = sqlx::query_as::<_, SearchPaperRow>(EXPLORE_SEARCH_SQL)
            .bind(&request.normalized_query)
            .bind(&categories)
            .bind(&topics)
            .bind(request.filters.published_after)
            .bind(request.filters.published_before)
            .bind(&sources)
            .bind(request.sort.as_str())
            .bind(cursor.map(|value| value.order_bucket))
            .bind(cursor.map(|value| value.published_at))
            .bind(cursor.map(|value| value.paper_id))
            .bind(fetch_limit)
            .fetch_all(&mut *transaction)
            .await
            .map_err(store_sql)?;
        let related_topics = sqlx::query_as::<_, TopicSuggestionRow>(RELATED_TOPICS_SQL)
            .bind(&request.normalized_query)
            .bind(8_i64)
            .fetch_all(&mut *transaction)
            .await
            .map_err(store_sql)?
            .into_iter()
            .map(|row| RelatedTopic {
                topic_id: row.id,
                label: row.label,
                source_vocabulary: row.source_vocabulary,
            })
            .collect();
        transaction.commit().await.map_err(store_sql)?;

        self.finish_page(
            EXPLORE_CURSOR_PURPOSE,
            &scope,
            request.normalized_query.clone(),
            request.limit,
            &mut rows,
            related_topics,
        )
    }

    async fn suggestions_inner(
        &self,
        normalized_query: &str,
        limit: u32,
    ) -> Result<SearchSuggestions, SearchStoreError> {
        if normalized_query.is_empty() || !(1..=20).contains(&limit) {
            return Err(SearchStoreError::InvalidData);
        }
        let items = sqlx::query_as::<_, TopicSuggestionRow>(RELATED_TOPICS_SQL)
            .bind(normalized_query)
            .bind(i64::from(limit))
            .fetch_all(&self.pool)
            .await
            .map_err(store_sql)?
            .into_iter()
            .map(|row| RelatedTopic {
                topic_id: row.id,
                label: row.label,
                source_vocabulary: row.source_vocabulary,
            })
            .collect();
        Ok(SearchSuggestions {
            normalized_query: normalized_query.to_owned(),
            items,
        })
    }

    fn finish_page(
        &self,
        purpose: &str,
        scope: &[u8; 32],
        normalized_query: String,
        limit: u32,
        rows: &mut Vec<SearchPaperRow>,
        related_topics: Vec<RelatedTopic>,
    ) -> Result<SearchPage, SearchStoreError> {
        let has_more = rows.len() > limit as usize;
        rows.truncate(limit as usize);
        let next_cursor = if has_more {
            let last = rows.last().ok_or(SearchStoreError::InvalidData)?;
            Some(self.encode_cursor(
                purpose,
                scope,
                SearchCursor {
                    order_bucket: last.relevance_bucket,
                    published_at: last.paper.published_at,
                    paper_id: last.paper.id,
                },
            )?)
        } else {
            None
        };
        let items = rows
            .drain(..)
            .map(search_result)
            .collect::<Result<Vec<_>, _>>()?;
        let matches_returned =
            u32::try_from(items.len()).map_err(|_| SearchStoreError::InvalidData)?;
        Ok(SearchPage {
            normalized_query,
            diagnostics: vec![SourceDiagnostic {
                source: SearchSource::ArxivMetadata,
                status: if items.is_empty() {
                    SourceStatus::NoMatches
                } else {
                    SourceStatus::Queried
                },
                coverage: SourceCoverage::Partial,
                matches_returned,
            }],
            items,
            next_cursor,
            related_topics,
        })
    }

    fn decode_cursor(
        &self,
        purpose: &str,
        scope: &[u8; 32],
        token: Option<&str>,
    ) -> Result<Option<SearchCursor>, SearchStoreError> {
        token
            .map(|token| {
                self.cursor_codec
                    .as_ref()
                    .ok_or(SearchStoreError::Unavailable)?
                    .open(purpose, scope, token)
                    .map_err(|_| SearchStoreError::InvalidCursor)
            })
            .transpose()
    }

    fn encode_cursor(
        &self,
        purpose: &str,
        scope: &[u8; 32],
        cursor: SearchCursor,
    ) -> Result<String, SearchStoreError> {
        self.cursor_codec
            .as_ref()
            .ok_or(SearchStoreError::Unavailable)?
            .seal(purpose, scope, &cursor)
            .map_err(|_| SearchStoreError::Unavailable)
    }

    async fn list_saved_inner(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<SavedSearchReadOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .execute(&mut *transaction)
            .await?;
        let Some(status) = account_status(&mut transaction, user_id, false).await? else {
            transaction.commit().await?;
            return Ok(SavedSearchReadOutcome::AccountNotFound);
        };
        if status != AccountStatus::Active {
            transaction.commit().await?;
            return Ok(SavedSearchReadOutcome::Inactive(status));
        }
        let rows = sqlx::query_as::<_, SavedSearchRow>(SAVED_SEARCH_SELECT)
            .bind(user_id.into_inner())
            .fetch_all(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(SavedSearchReadOutcome::Found(
            rows.into_iter()
                .map(saved_search)
                .collect::<Result<Vec<_>, _>>()?,
        ))
    }

    async fn resolve_operation_inner(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
    ) -> Result<Option<SavedSearchWriteOutcome>, DbError> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .execute(&mut *transaction)
            .await?;
        let Some(status) = account_status(&mut transaction, user_id, false).await? else {
            transaction.commit().await?;
            return Ok(Some(SavedSearchWriteOutcome::AccountNotFound));
        };
        if status != AccountStatus::Active {
            transaction.commit().await?;
            return Ok(Some(SavedSearchWriteOutcome::Inactive(status)));
        }
        let Some(operation) =
            saved_operation(&mut transaction, user_id, operation_id, true).await?
        else {
            transaction.commit().await?;
            return Ok(None);
        };
        if operation.intent_fingerprint.as_slice() != fingerprint.as_bytes() {
            transaction.commit().await?;
            return Ok(Some(SavedSearchWriteOutcome::IdempotencyConflict));
        }
        let row = saved_by_id(&mut transaction, user_id, operation.saved_search_id)
            .await?
            .ok_or_else(invalid_data)?;
        transaction.commit().await?;
        Ok(Some(SavedSearchWriteOutcome::Applied {
            saved: Box::new(saved_search(row)?),
            replayed: true,
        }))
    }

    async fn save_query_inner(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
        definition: &SavedSearchDefinition,
        maximum_saved_searches: u32,
    ) -> Result<SavedSearchWriteOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        let Some(status) = account_status(&mut transaction, user_id, true).await? else {
            transaction.rollback().await?;
            return Ok(SavedSearchWriteOutcome::AccountNotFound);
        };
        if status != AccountStatus::Active {
            transaction.rollback().await?;
            return Ok(SavedSearchWriteOutcome::Inactive(status));
        }
        sqlx::query(
            "DELETE FROM saved_search_operations WHERE user_id = $1 AND expires_at <= statement_timestamp()",
        )
        .bind(user_id.into_inner())
        .execute(&mut *transaction)
        .await?;
        if let Some(operation) =
            saved_operation(&mut transaction, user_id, operation_id, false).await?
        {
            let outcome = if operation.intent_fingerprint.as_slice() == fingerprint.as_bytes() {
                let existing = saved_by_id(&mut transaction, user_id, operation.saved_search_id)
                    .await?
                    .ok_or_else(invalid_data)?;
                SavedSearchWriteOutcome::Applied {
                    saved: Box::new(saved_search(existing)?),
                    replayed: true,
                }
            } else {
                SavedSearchWriteOutcome::IdempotencyConflict
            };
            transaction.commit().await?;
            return Ok(outcome);
        }
        if let Some(existing) = saved_by_fingerprint(&mut transaction, user_id, fingerprint).await?
        {
            record_saved_operation(
                &mut transaction,
                user_id,
                operation_id,
                fingerprint,
                existing.id,
            )
            .await?;
            transaction.commit().await?;
            return Ok(SavedSearchWriteOutcome::Applied {
                saved: Box::new(saved_search(existing)?),
                replayed: true,
            });
        }
        let count: i64 =
            sqlx::query_scalar("SELECT count(*) FROM saved_searches WHERE user_id = $1")
                .bind(user_id.into_inner())
                .fetch_one(&mut *transaction)
                .await?;
        if count >= i64::from(maximum_saved_searches) {
            transaction.rollback().await?;
            return Ok(SavedSearchWriteOutcome::LimitReached);
        }
        let saved_search_id = Uuid::now_v7();
        let row = insert_saved_search(
            &mut transaction,
            user_id,
            saved_search_id,
            fingerprint,
            definition,
        )
        .await?;
        record_saved_operation(
            &mut transaction,
            user_id,
            operation_id,
            fingerprint,
            saved_search_id,
        )
        .await?;
        transaction.commit().await?;
        Ok(SavedSearchWriteOutcome::Applied {
            saved: Box::new(saved_search(row)?),
            replayed: false,
        })
    }

    /// Removes the owned definition and retires its one possible active
    /// saved-query subscription in the same account-locked transaction.
    /// Unknown and foreign IDs are intentionally indistinguishable.
    async fn delete_saved_inner(
        &self,
        user_id: AuthenticatedUserId,
        saved_search_id: Uuid,
    ) -> Result<SavedSearchDeleteOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        let Some(status) = account_status(&mut transaction, user_id, true).await? else {
            transaction.rollback().await?;
            return Ok(SavedSearchDeleteOutcome::AccountNotFound);
        };
        if status != AccountStatus::Active {
            transaction.rollback().await?;
            return Ok(SavedSearchDeleteOutcome::Inactive(status));
        }

        let owned = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM saved_searches WHERE user_id = $1 AND id = $2 FOR UPDATE",
        )
        .bind(user_id.into_inner())
        .bind(saved_search_id)
        .fetch_optional(&mut *transaction)
        .await?
        .is_some();
        if !owned {
            transaction.commit().await?;
            return Ok(SavedSearchDeleteOutcome::AlreadyAbsent);
        }

        let linked_subscriptions = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT id
            FROM subscriptions
            WHERE user_id = $1
              AND kind = 'saved_query'
              AND key = $2
              AND deleted_at IS NULL
            FOR UPDATE
            ",
        )
        .bind(user_id.into_inner())
        .bind(saved_search_id.to_string())
        .fetch_all(&mut *transaction)
        .await?;

        for subscription_id in &linked_subscriptions {
            let revision: i64 = sqlx::query_scalar(
                "SELECT COALESCE(MAX(revision), 0) + 1 FROM subscriptions WHERE user_id = $1",
            )
            .bind(user_id.into_inner())
            .fetch_one(&mut *transaction)
            .await?;
            sqlx::query(
                r"
                UPDATE subscriptions
                SET label = 'Deleted saved query', frequency = 'off',
                    last_evaluated_at = NULL, revision = $3,
                    deleted_at = statement_timestamp(),
                    updated_at = statement_timestamp(), last_operation_id = $4
                WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
                ",
            )
            .bind(user_id.into_inner())
            .bind(subscription_id)
            .bind(revision)
            .bind(Uuid::now_v7())
            .execute(&mut *transaction)
            .await?;
            invalidate_saved_query_subscription(&mut transaction, user_id, *subscription_id)
                .await?;
            sqlx::query(
                r"
                UPDATE notification_work_items
                SET state = 'complete', lease_owner = NULL,
                    lease_expires_at = NULL, last_error_code = NULL,
                    completed_at = statement_timestamp(),
                    updated_at = statement_timestamp()
                WHERE user_id = $1 AND subscription_id = $2 AND state = 'queued'
                ",
            )
            .bind(user_id.into_inner())
            .bind(subscription_id)
            .execute(&mut *transaction)
            .await?;
        }

        let removed = sqlx::query("DELETE FROM saved_searches WHERE user_id = $1 AND id = $2")
            .bind(user_id.into_inner())
            .bind(saved_search_id)
            .execute(&mut *transaction)
            .await?;
        if removed.rows_affected() != 1 {
            return Err(invalid_data());
        }
        transaction.commit().await?;
        Ok(SavedSearchDeleteOutcome::Deleted {
            linked_subscriptions_deleted: u32::try_from(linked_subscriptions.len())
                .map_err(|_| invalid_data())?,
        })
    }
}

#[async_trait]
impl SearchStore for DiscoverySearchRepository {
    async fn lookup(&self, request: &LookupSearchRequest) -> Result<SearchPage, SearchStoreError> {
        self.lookup_inner(request).await
    }

    async fn explore(
        &self,
        request: &ExploreSearchRequest,
    ) -> Result<SearchPage, SearchStoreError> {
        self.explore_inner(request).await
    }

    async fn suggestions(
        &self,
        normalized_query: &str,
        limit: u32,
    ) -> Result<SearchSuggestions, SearchStoreError> {
        self.suggestions_inner(normalized_query, limit).await
    }

    async fn list_saved(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<SavedSearchReadOutcome, SearchStoreError> {
        self.list_saved_inner(user_id)
            .await
            .map_err(|error| store_error(&error))
    }

    async fn resolve_saved_operation(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
    ) -> Result<Option<SavedSearchWriteOutcome>, SearchStoreError> {
        self.resolve_operation_inner(user_id, operation_id, fingerprint)
            .await
            .map_err(|error| store_error(&error))
    }

    async fn save_query(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        fingerprint: SearchFingerprint,
        definition: &SavedSearchDefinition,
        maximum_saved_searches: u32,
    ) -> Result<SavedSearchWriteOutcome, SearchStoreError> {
        self.save_query_inner(
            user_id,
            operation_id,
            fingerprint,
            definition,
            maximum_saved_searches,
        )
        .await
        .map_err(|error| store_error(&error))
    }

    async fn delete_saved(
        &self,
        user_id: AuthenticatedUserId,
        saved_search_id: Uuid,
    ) -> Result<SavedSearchDeleteOutcome, SearchStoreError> {
        self.delete_saved_inner(user_id, saved_search_id)
            .await
            .map_err(|error| store_error(&error))
    }
}

#[async_trait]
impl SearchRateLimitStore for DiscoverySearchRepository {
    async fn check_saved_search_mutation(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
        window: Duration,
    ) -> Result<SearchMutationRateDecision, SearchStoreError> {
        let request = RateLimitRequest::saved_search_mutation(user_id, limit, window)
            .map_err(|_| SearchStoreError::InvalidData)?;
        let decision = RateLimitRepository::new(self.pool.clone())
            .check(&request)
            .await
            .map_err(|error| store_error(&error))?;
        Ok(SearchMutationRateDecision {
            allowed: decision.allowed,
            retry_after_seconds: decision.retry_after_seconds,
        })
    }
}

const SAVED_SEARCH_SELECT: &str = r"
    SELECT
        id, user_id, normalized_query,
        categories, topics, published_after, published_before, sources,
        sort, revision, created_at, updated_at
    FROM saved_searches
    WHERE user_id = $1
    ORDER BY updated_at DESC, id DESC
";

// Auditable fixed-weight fusion: direct local text (1.0), a published
// citation-neighbor edge (0.25), and an explicit topic/category filter
// (0.125). Abstract-vector retrieval remains optional until a compatible
// query-embedding model is configured; it is never silently approximated.
const EXPLORE_SEARCH_SQL: &str = r"
    WITH candidates AS (
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
            processing.connections_ready,
            CASE
                WHEN $7 = 'recency' THEN 0
                ELSE -round(
                    1000000 * (
                        ts_rank_cd(
                            p.search_document,
                            websearch_to_tsquery('english'::regconfig, $1)
                        )
                        + similarity(p.normalized_title, $1)
                        + CASE WHEN retrieval.direct_text THEN 1.0::real ELSE 0.0::real END
                        + CASE WHEN retrieval.citation_neighbor THEN 0.25::real ELSE 0.0::real END
                        + CASE WHEN retrieval.explicit_filter THEN 0.125::real ELSE 0.0::real END
                    )
                )::bigint
            END AS relevance_bucket,
            CASE
                WHEN p.normalized_title = btrim(
                    regexp_replace($1, '[^[:alnum:]]+', ' ', 'g')
                ) THEN 'exact_title'
                WHEN EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(p.authors) AS author(value)
                    WHERE lower(btrim(coalesce(
                        author.value ->> 'name',
                        trim(both chr(34) from author.value::text)
                    ))) = $1
                ) THEN 'exact_author'
                WHEN position($1 in p.normalized_title) > 0 THEN 'phrase'
                ELSE 'related_text'
            END AS match_kind
        FROM papers AS p
        JOIN paper_processing AS processing ON processing.paper_id = p.id
        CROSS JOIN LATERAL (
            SELECT
                (
                    p.search_document @@ websearch_to_tsquery(
                        'english'::regconfig,
                        $1
                    )
                    OR p.normalized_title % $1
                    OR lower(p.authors::text) % $1
                ) AS direct_text,
                EXISTS (
                    SELECT 1
                    FROM paper_connections AS connection
                    JOIN paper_processing AS citing_processing
                      ON citing_processing.paper_id = connection.citing_paper_id
                     AND citing_processing.generation = connection.generation
                     AND citing_processing.connections_ready
                    JOIN papers AS seed
                      ON seed.id = CASE
                          WHEN connection.citing_paper_id = p.id
                              THEN connection.cited_paper_id
                          ELSE connection.citing_paper_id
                      END
                    JOIN paper_processing AS seed_processing
                      ON seed_processing.paper_id = seed.id
                     AND seed_processing.metadata_ready
                    WHERE (
                        connection.citing_paper_id = p.id
                        OR connection.cited_paper_id = p.id
                    )
                      AND (
                          seed.search_document @@ websearch_to_tsquery(
                              'english'::regconfig,
                              $1
                          )
                          OR seed.normalized_title % $1
                          OR lower(seed.authors::text) % $1
                      )
                ) AS citation_neighbor,
                (
                    cardinality($2::text[]) > 0
                    OR cardinality($3::text[]) > 0
                ) AS explicit_filter
        ) AS retrieval
        WHERE processing.metadata_ready
          AND (
              retrieval.direct_text
              OR retrieval.citation_neighbor
              OR retrieval.explicit_filter
          )
            AND (cardinality($2::text[]) = 0 OR p.categories && $2)
            AND (
                cardinality($3::text[]) = 0
                OR EXISTS (
                    SELECT 1
                    FROM unnest($3::text[]) AS requested_topic(value)
                    WHERE p.search_document @@ websearch_to_tsquery(
                        'english'::regconfig,
                        requested_topic.value
                    )
                )
            )
            AND ($4::date IS NULL OR p.published_at >= $4::date)
            AND ($5::date IS NULL OR p.published_at < ($5::date + 1))
            AND p.metadata_source = ANY($6::text[])
    )
    SELECT *
    FROM candidates
    WHERE
        $8::bigint IS NULL
        OR relevance_bucket > $8
        OR (
            relevance_bucket = $8
            AND (
                published_at < $9
                OR (published_at = $9 AND id < $10)
            )
        )
    ORDER BY relevance_bucket ASC, published_at DESC, id DESC
    LIMIT $11
";

const RELATED_TOPICS_SQL: &str = r"
    SELECT id, label, source_vocabulary
    FROM topics
    WHERE normalized_label % $1
       OR to_tsvector('english'::regconfig, normalized_label)
          @@ websearch_to_tsquery('english'::regconfig, $1)
    ORDER BY
        similarity(normalized_label, $1) DESC,
        normalized_label ASC,
        id ASC
    LIMIT $2
";

async fn account_status(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    lock: bool,
) -> Result<Option<AccountStatus>, DbError> {
    let query = if lock {
        "SELECT status FROM users WHERE id = $1 FOR UPDATE"
    } else {
        "SELECT status FROM users WHERE id = $1"
    };
    sqlx::query_as::<_, AccountStatusRow>(query)
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await?
        .map(|row| AccountStatus::from_str(&row.status).map_err(|_| invalid_data()))
        .transpose()
}

async fn saved_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    require_unexpired: bool,
) -> Result<Option<SavedSearchOperationRow>, DbError> {
    sqlx::query_as::<_, SavedSearchOperationRow>(
        r"
        SELECT intent_fingerprint, saved_search_id
        FROM saved_search_operations
        WHERE user_id = $1
          AND operation_id = $2
          AND (NOT $3::boolean OR expires_at > statement_timestamp())
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(require_unexpired)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn saved_by_id(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    saved_search_id: Uuid,
) -> Result<Option<SavedSearchRow>, DbError> {
    sqlx::query_as::<_, SavedSearchRow>(
        r"
        SELECT
            id, user_id, normalized_query, categories, topics,
            published_after, published_before, sources, sort,
            revision, created_at, updated_at
        FROM saved_searches
        WHERE user_id = $1 AND id = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(saved_search_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn saved_by_fingerprint(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    fingerprint: SearchFingerprint,
) -> Result<Option<SavedSearchRow>, DbError> {
    sqlx::query_as::<_, SavedSearchRow>(
        r"
        SELECT
            id, user_id, normalized_query,
            categories, topics, published_after, published_before, sources,
            sort, revision, created_at, updated_at
        FROM saved_searches
        WHERE user_id = $1 AND definition_fingerprint = $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(fingerprint.as_bytes().as_slice())
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn insert_saved_search(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    saved_search_id: Uuid,
    fingerprint: SearchFingerprint,
    definition: &SavedSearchDefinition,
) -> Result<SavedSearchRow, DbError> {
    let sources = definition
        .filters
        .sources
        .iter()
        .map(|source| source.as_str().to_owned())
        .collect::<Vec<_>>();
    sqlx::query_as::<_, SavedSearchRow>(
        r"
        INSERT INTO saved_searches (
            id, user_id, definition_fingerprint, normalized_query,
            categories, topics, published_after, published_before, sources, sort
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        RETURNING
            id, user_id, normalized_query, categories, topics,
            published_after, published_before, sources, sort,
            revision, created_at, updated_at
        ",
    )
    .bind(saved_search_id)
    .bind(user_id.into_inner())
    .bind(fingerprint.as_bytes().as_slice())
    .bind(&definition.normalized_query)
    .bind(&definition.filters.categories)
    .bind(&definition.filters.topics)
    .bind(definition.filters.published_after)
    .bind(definition.filters.published_before)
    .bind(&sources)
    .bind(definition.sort.as_str())
    .fetch_one(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn record_saved_operation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    operation_id: Uuid,
    fingerprint: SearchFingerprint,
    saved_search_id: Uuid,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO saved_search_operations (
            user_id, operation_id, intent_fingerprint, saved_search_id, expires_at
        )
        VALUES ($1, $2, $3, $4, statement_timestamp() + interval '30 days')
        ",
    )
    .bind(user_id.into_inner())
    .bind(operation_id)
    .bind(fingerprint.as_bytes().as_slice())
    .bind(saved_search_id)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

/// Hides every pending discovery delivery derived from a subscription being
/// retired. Digests are invalidated as a whole when they contain one of the
/// withdrawn matches, matching the engagement mutation contract.
async fn invalidate_saved_query_subscription(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    subscription_id: Uuid,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        WITH subscription_matches AS MATERIALIZED (
            SELECT id, entity_id AS paper_id
            FROM notifications
            WHERE user_id = $1
              AND notification_scope = 'discovery'
              AND notification_type = 'discovery_match'
              AND payload ->> 'subscription_id' = $2::uuid::text
        ), affected_digests AS (
            SELECT DISTINCT digest.id
            FROM notifications AS digest
            JOIN notification_digest_items AS item
              ON item.notification_id = digest.id
            JOIN subscription_matches AS matched
              ON matched.paper_id = item.paper_id
            WHERE digest.user_id = $1
              AND digest.notification_scope = 'discovery'
              AND digest.notification_type = 'discovery_digest'
        ), affected AS (
            SELECT id FROM subscription_matches
            UNION
            SELECT id FROM affected_digests
        )
        UPDATE notifications AS notification
        SET delivery_eligibility = 'expired',
            eligibility_library_revision = NULL,
            dismissed_at = COALESCE(
                notification.dismissed_at,
                statement_timestamp()
            )
        FROM affected
        WHERE notification.id = affected.id
          AND notification.user_id = $1
        ",
    )
    .bind(user_id.into_inner())
    .bind(subscription_id)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn saved_search(row: SavedSearchRow) -> Result<SavedSearch, DbError> {
    let sources = row
        .sources
        .into_iter()
        .map(|source| match source.as_str() {
            "arxiv" => Ok(SearchSource::ArxivMetadata),
            _ => Err(invalid_data()),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(SavedSearch {
        id: row.id,
        user_id: AuthenticatedUserId::new(row.user_id),
        definition: SavedSearchDefinition {
            normalized_query: row.normalized_query,
            filters: discovery_search::SearchFilters {
                categories: row.categories,
                topics: row.topics,
                published_after: row.published_after,
                published_before: row.published_before,
                sources,
            },
            sort: match row.sort.as_str() {
                "relevance" => discovery_search::SearchSort::Relevance,
                "recency" => discovery_search::SearchSort::Recency,
                _ => return Err(invalid_data()),
            },
        },
        revision: row.revision,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn search_result(row: SearchPaperRow) -> Result<SearchResult, SearchStoreError> {
    let match_kind = match row.match_kind.as_str() {
        "exact_arxiv_id" => MatchKind::ExactArxivId,
        "exact_doi" => MatchKind::ExactDoi,
        "exact_title" => MatchKind::ExactTitle,
        "exact_author" => MatchKind::ExactAuthor,
        "phrase" => MatchKind::Phrase,
        "related_text" => MatchKind::RelatedText,
        _ => return Err(SearchStoreError::InvalidData),
    };
    Ok(SearchResult {
        paper: PaperSummary::try_from(row.paper).map_err(|_| SearchStoreError::InvalidData)?,
        match_kind,
        relevance_bucket: row.relevance_bucket,
        source: SearchSource::ArxivMetadata,
    })
}

fn lookup_scope(request: &LookupSearchRequest) -> [u8; 32] {
    scope_hash(
        b"pakperk/search-lookup-scope/v1\0",
        &[request.normalized_query.as_bytes()],
    )
}

fn explore_scope(request: &ExploreSearchRequest) -> [u8; 32] {
    let encoded = serde_json::to_vec(&(&request.normalized_query, &request.filters, request.sort))
        .expect("validated Explore scope serializes");
    scope_hash(b"pakperk/search-explore-scope/v1\0", &[&encoded])
}

fn scope_hash(prefix: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(prefix);
    for part in parts {
        digest.update((part.len() as u64).to_be_bytes());
        digest.update(part);
    }
    digest.finalize().into()
}

fn store_sql(_: sqlx::Error) -> SearchStoreError {
    SearchStoreError::Unavailable
}

fn store_error(error: &DbError) -> SearchStoreError {
    match error {
        DbError::InvalidData(_) | DbError::InvalidUrl(_) => SearchStoreError::InvalidData,
        _ => SearchStoreError::Unavailable,
    }
}

fn invalid_data() -> DbError {
    DbError::InvalidData("persisted discovery-search data is invalid".to_owned())
}
