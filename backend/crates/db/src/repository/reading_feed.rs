use std::{num::NonZeroU64, str::FromStr as _};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId, LibrarySaveSourceKind, PaperSummary};
use reading_feed::{
    FeedMode, QueueSnapshotItem, ReadingFeedCursorPosition, ReadingFeedSnapshot,
    ReadingFeedSnapshotRequest, ReadingFeedStore, ReadingFeedStoreError, RecommendationPage,
    RecommendationPosition, ToReadPosition,
};
use sqlx::{FromRow, PgPool, Postgres, QueryBuilder, Transaction};

use super::{DbError, library::library_state_from_storage, rows::PaperSummaryRow};

/// `PostgreSQL` implementation of the authenticated reading-feed snapshot.
/// Queue authority, revision fencing, the selected page, and recommendation
/// exclusions all come from one read-only repeatable-read transaction.
#[derive(Clone)]
pub struct ReadingFeedRepository {
    pool: PgPool,
}

impl ReadingFeedRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    #[tracing::instrument(name = "reading_feed.queue_snapshot", skip_all)]
    async fn snapshot_in_database(
        &self,
        request: &ReadingFeedSnapshotRequest,
    ) -> Result<ReadingFeedSnapshot, SnapshotError> {
        if request.limit == 0 {
            return Err(SnapshotError::AuthorityUnavailable);
        }
        let mut transaction = begin_consistent_read(&self.pool).await?;
        match account_status(&mut transaction, request.user_id).await? {
            None => return Err(SnapshotError::AccountNotFound),
            Some(AccountStatus::Active) => {}
            Some(AccountStatus::Suspended) => return Err(SnapshotError::Suspended),
            Some(AccountStatus::DeletionPending) => return Err(SnapshotError::DeletionPending),
            Some(AccountStatus::Deleted) => return Err(SnapshotError::Deleted),
        }

        let library_revision = committed_revision(&mut transaction, request.user_id).await?;
        if request
            .continuation
            .is_some_and(|cursor| cursor.library_revision != library_revision)
        {
            return Err(SnapshotError::RevisionStale);
        }
        let active_count = active_to_read_count(&mut transaction, request.user_id).await?;
        let snapshot = if let Some(active_count) = NonZeroU64::new(active_count) {
            queue_snapshot(&mut transaction, request, library_revision, active_count).await?
        } else {
            recommendation_snapshot(&mut transaction, request, library_revision).await?
        };
        transaction.commit().await?;
        Ok(snapshot)
    }
}

#[async_trait]
impl ReadingFeedStore for ReadingFeedRepository {
    async fn snapshot(
        &self,
        request: &ReadingFeedSnapshotRequest,
    ) -> Result<ReadingFeedSnapshot, ReadingFeedStoreError> {
        self.snapshot_in_database(request)
            .await
            .map_err(SnapshotError::into_store_error)
    }
}

#[derive(Debug)]
enum SnapshotError {
    AccountNotFound,
    Suspended,
    DeletionPending,
    Deleted,
    RevisionStale,
    AuthorityUnavailable,
    Database,
}

impl SnapshotError {
    fn into_store_error(self) -> ReadingFeedStoreError {
        match self {
            Self::AccountNotFound => ReadingFeedStoreError::AccountNotFound,
            Self::Suspended => ReadingFeedStoreError::Suspended,
            Self::DeletionPending => ReadingFeedStoreError::DeletionPending,
            Self::Deleted => ReadingFeedStoreError::Deleted,
            Self::RevisionStale => ReadingFeedStoreError::RevisionStale,
            Self::AuthorityUnavailable | Self::Database => ReadingFeedStoreError::Unavailable,
        }
    }
}

impl From<DbError> for SnapshotError {
    fn from(_error: DbError) -> Self {
        Self::Database
    }
}

impl From<sqlx::Error> for SnapshotError {
    fn from(error: sqlx::Error) -> Self {
        Self::from(DbError::from(error))
    }
}

async fn begin_consistent_read(
    pool: &PgPool,
) -> Result<Transaction<'static, Postgres>, SnapshotError> {
    let mut transaction = pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        .execute(&mut *transaction)
        .await?;
    Ok(transaction)
}

async fn account_status(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<AccountStatus>, SnapshotError> {
    sqlx::query_scalar::<_, String>("SELECT status FROM users WHERE id = $1")
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await?
        .map(|status| {
            AccountStatus::from_str(&status).map_err(|_| SnapshotError::AuthorityUnavailable)
        })
        .transpose()
}

async fn committed_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<i64, SnapshotError> {
    let revision: i64 = sqlx::query_scalar(
        r"
        SELECT COALESCE(
            (
                SELECT current_revision
                FROM library_sync_metadata
                WHERE user_id = $1
            ),
            0
        )
        ",
    )
    .bind(user_id.into_inner())
    .fetch_one(&mut **transaction)
    .await?;
    if revision < 0 {
        return Err(SnapshotError::AuthorityUnavailable);
    }
    Ok(revision)
}

async fn active_to_read_count(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<u64, SnapshotError> {
    let count: i64 = sqlx::query_scalar(
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
    u64::try_from(count).map_err(|_| SnapshotError::AuthorityUnavailable)
}

async fn queue_snapshot(
    transaction: &mut Transaction<'_, Postgres>,
    request: &ReadingFeedSnapshotRequest,
    library_revision: i64,
    active_count: NonZeroU64,
) -> Result<ReadingFeedSnapshot, SnapshotError> {
    let position = match request.continuation {
        None => None,
        Some(continuation) if continuation.mode == FeedMode::ToRead => {
            match continuation.position {
                ReadingFeedCursorPosition::ToRead { position } => Some(position),
                ReadingFeedCursorPosition::Recommendations { .. } => {
                    return Err(SnapshotError::RevisionStale);
                }
            }
        }
        Some(_) => return Err(SnapshotError::RevisionStale),
    };
    let mut builder = QueryBuilder::<Postgres>::new(
        r"
        SELECT
            library.state AS queue_state,
            library.saved_at AS queue_saved_at,
            library.revision AS queue_revision,
            library.save_source_kind AS queue_save_source_kind,
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
        FROM user_paper_library AS library
        JOIN papers AS paper ON paper.id = library.paper_id
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE library.user_id =
        ",
    );
    builder.push_bind(request.user_id.into_inner());
    builder.push(
        " AND library.state IN ('to_read', 'inbox', 'read_next', 'reading') \
         AND library.removed_at IS NULL",
    );
    if let Some(position) = position {
        builder.push(" AND (library.saved_at, library.paper_id) > (");
        builder.push_bind(position.saved_at);
        builder.push(", ");
        builder.push_bind(position.paper_id);
        builder.push(")");
    }
    builder.push(" ORDER BY library.saved_at ASC, library.paper_id ASC LIMIT ");
    builder.push_bind(i64::from(request.limit) + 1);

    let mut rows = builder
        .build_query_as::<QueuePaperRow>()
        .fetch_all(&mut **transaction)
        .await?;
    let has_more = rows.len() > request.limit as usize;
    if has_more {
        rows.pop();
    }
    let next_position = has_more.then(|| {
        let row = rows
            .last()
            .expect("a positive page limit with an overflow row retains one row");
        ToReadPosition {
            saved_at: row.queue_saved_at,
            paper_id: row.paper.id,
        }
    });
    let items = rows
        .into_iter()
        .map(QueueSnapshotItem::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ReadingFeedSnapshot::Queue {
        library_revision,
        active_to_read_count: active_count,
        items,
        next_position,
    })
}

async fn recommendation_snapshot(
    transaction: &mut Transaction<'_, Postgres>,
    request: &ReadingFeedSnapshotRequest,
    library_revision: i64,
) -> Result<ReadingFeedSnapshot, SnapshotError> {
    let position = recommendation_position(request)?;
    let mut builder = QueryBuilder::<Postgres>::new(
        r"
        SELECT
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
        FROM papers AS paper
        JOIN paper_processing AS processing ON processing.paper_id = paper.id
        WHERE processing.metadata_ready
          AND NOT EXISTS (
              SELECT 1
              FROM user_paper_library AS excluded
              JOIN papers AS excluded_paper ON excluded_paper.id = excluded.paper_id
              WHERE excluded.user_id =
        ",
    );
    builder.push_bind(request.user_id.into_inner());
    builder.push(
        r"
              AND (
                  excluded.paper_id = paper.id
                  OR excluded_paper.arxiv_base_id = paper.arxiv_base_id
              )
          )
          AND NOT EXISTS (
              SELECT 1
              FROM recommendation_feedback AS feedback
              JOIN papers AS feedback_paper ON feedback_paper.id = feedback.paper_id
              WHERE feedback.user_id =
        ",
    );
    builder.push_bind(request.user_id.into_inner());
    builder.push(
        r"
              AND (
                  feedback.paper_id = paper.id
                  OR feedback_paper.arxiv_base_id = paper.arxiv_base_id
              )
          )
        ",
    );
    if let Some(category) = &request.category {
        builder.push(" AND ");
        builder.push_bind(category);
        builder.push(" = ANY(paper.categories)");
    }
    if let Some(position) = position {
        builder.push(" AND (paper.published_at, paper.id) < (");
        builder.push_bind(position.published_at);
        builder.push(", ");
        builder.push_bind(position.paper_id);
        builder.push(")");
    }
    builder.push(" ORDER BY paper.published_at DESC, paper.id DESC LIMIT ");
    builder.push_bind(i64::from(request.limit) + 1);

    let mut rows = builder
        .build_query_as::<PaperSummaryRow>()
        .fetch_all(&mut **transaction)
        .await?;
    let has_more = rows.len() > request.limit as usize;
    if has_more {
        rows.pop();
    }
    let next_position = has_more.then(|| {
        let row = rows
            .last()
            .expect("a positive page limit with an overflow row retains one row");
        RecommendationPosition {
            published_at: row.published_at,
            paper_id: row.id,
        }
    });
    let items = rows
        .into_iter()
        .map(PaperSummary::try_from)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ReadingFeedSnapshot::Empty {
        library_revision,
        recommendations: RecommendationPage {
            items,
            next_position,
        },
    })
}

fn recommendation_position(
    request: &ReadingFeedSnapshotRequest,
) -> Result<Option<RecommendationPosition>, SnapshotError> {
    Ok(match request.continuation {
        None => None,
        Some(continuation) if continuation.mode == FeedMode::Recommendations => {
            match continuation.position {
                ReadingFeedCursorPosition::Recommendations { position } => Some(position),
                ReadingFeedCursorPosition::ToRead { .. } => {
                    return Err(SnapshotError::RevisionStale);
                }
            }
        }
        Some(_) => return Err(SnapshotError::RevisionStale),
    })
}

#[derive(Debug, FromRow)]
struct QueuePaperRow {
    queue_state: String,
    queue_saved_at: DateTime<Utc>,
    queue_revision: i64,
    queue_save_source_kind: Option<String>,
    #[sqlx(flatten)]
    paper: PaperSummaryRow,
}

impl TryFrom<QueuePaperRow> for QueueSnapshotItem {
    type Error = DbError;

    fn try_from(row: QueuePaperRow) -> Result<Self, Self::Error> {
        Ok(Self {
            paper: PaperSummary::try_from(row.paper)?,
            state: library_state_from_storage(&row.queue_state)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            saved_at: row.queue_saved_at,
            revision: row.queue_revision,
            save_source_kind: row
                .queue_save_source_kind
                .as_deref()
                .map(LibrarySaveSourceKind::from_str)
                .transpose()
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
        })
    }
}
