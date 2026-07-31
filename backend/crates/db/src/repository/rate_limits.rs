use std::time::Duration;

use chrono::{DateTime, Utc};
use domain::AuthenticatedUserId;
use sqlx::{FromRow, PgPool};
use thiserror::Error;

use super::DbError;

const MAX_WINDOW: Duration = Duration::from_secs(30 * 24 * 60 * 60);

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RateLimitConfigError {
    #[error("rate-limit bucket is invalid")]
    InvalidBucket,
    #[error("rate-limit scope key is invalid")]
    InvalidScopeKey,
    #[error("rate-limit maximum must be positive")]
    InvalidLimit,
    #[error("rate-limit window must be between one second and thirty days")]
    InvalidWindow,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RateLimitRequest {
    // This is deliberately opaque. Callers must hash IP/device identifiers
    // before constructing a request; server-owned user UUIDs need no hashing.
    bucket: String,
    scope_key: String,
    limit: u32,
    window: Duration,
}

impl RateLimitRequest {
    pub fn new(
        bucket: impl Into<String>,
        scope_key: impl Into<String>,
        limit: u32,
        window: Duration,
    ) -> Result<Self, RateLimitConfigError> {
        let bucket = bucket.into();
        let scope_key = scope_key.into();
        if bucket.is_empty()
            || bucket.len() > 64
            || !bucket.bytes().all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'_' | b':' | b'-')
            })
        {
            return Err(RateLimitConfigError::InvalidBucket);
        }
        if scope_key.is_empty()
            || scope_key.len() > 256
            || scope_key.trim() != scope_key
            || scope_key.chars().any(char::is_control)
        {
            return Err(RateLimitConfigError::InvalidScopeKey);
        }
        if limit == 0 {
            return Err(RateLimitConfigError::InvalidLimit);
        }
        if window < Duration::from_secs(1) || window > MAX_WINDOW {
            return Err(RateLimitConfigError::InvalidWindow);
        }
        Ok(Self {
            bucket,
            scope_key,
            limit,
            window,
        })
    }

    pub fn profile_update(
        user_id: AuthenticatedUserId,
        limit: u32,
        window: Duration,
    ) -> Result<Self, RateLimitConfigError> {
        Self::new("profile_update", format!("user:{user_id}"), limit, window)
    }

    #[must_use]
    pub fn bucket(&self) -> &str {
        &self.bucket
    }

    #[must_use]
    pub fn scope_key(&self) -> &str {
        &self.scope_key
    }

    #[must_use]
    pub const fn limit(&self) -> u32 {
        self.limit
    }

    #[must_use]
    pub const fn window(&self) -> Duration {
        self.window
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RateLimitDecision {
    pub allowed: bool,
    pub limit: u32,
    pub remaining: u32,
    pub reset_at: DateTime<Utc>,
    /// Suitable for a `Retry-After` delta-seconds header when denied.
    pub retry_after_seconds: Option<u64>,
}

#[derive(Debug, FromRow)]
struct RateLimitRow {
    request_count: i64,
    window_ends_at: DateTime<Utc>,
    retry_after_seconds: i64,
}

#[derive(Clone)]
pub struct RateLimitRepository {
    pool: PgPool,
}

impl RateLimitRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Atomically consumes one fixed-window permit. A single row is shared by
    /// every API replica, and database statement time prevents host-clock skew
    /// from creating extra windows.
    pub async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
        let row = sqlx::query_as::<_, RateLimitRow>(
            r"
            WITH upserted AS (
                INSERT INTO shared_rate_limit_buckets (
                    bucket,
                    scope_key,
                    window_started_at,
                    window_ends_at,
                    request_count,
                    updated_at
                )
                VALUES (
                    $1,
                    $2,
                    statement_timestamp(),
                    statement_timestamp()
                        + make_interval(secs => $3::double precision),
                    1,
                    statement_timestamp()
                )
                ON CONFLICT (bucket, scope_key) DO UPDATE
                SET window_started_at = CASE
                        WHEN shared_rate_limit_buckets.window_ends_at
                                <= EXCLUDED.window_started_at
                        THEN EXCLUDED.window_started_at
                        ELSE shared_rate_limit_buckets.window_started_at
                    END,
                    window_ends_at = CASE
                        WHEN shared_rate_limit_buckets.window_ends_at
                                <= EXCLUDED.window_started_at
                        THEN EXCLUDED.window_ends_at
                        ELSE shared_rate_limit_buckets.window_ends_at
                    END,
                    request_count = CASE
                        WHEN shared_rate_limit_buckets.window_ends_at
                                <= EXCLUDED.window_started_at
                        THEN 1
                        ELSE LEAST(
                            shared_rate_limit_buckets.request_count,
                            9223372036854775806
                        ) + 1
                    END,
                    updated_at = EXCLUDED.updated_at
                RETURNING request_count, window_ends_at
            )
            SELECT
                request_count,
                window_ends_at,
                GREATEST(
                    1,
                    CEIL(EXTRACT(EPOCH FROM (
                        window_ends_at - statement_timestamp()
                    )))::bigint
                ) AS retry_after_seconds
            FROM upserted
            ",
        )
        .bind(request.bucket())
        .bind(request.scope_key())
        .bind(request.window().as_secs_f64())
        .fetch_one(&self.pool)
        .await?;

        let used = u64::try_from(row.request_count).unwrap_or(u64::MAX);
        let limit = u64::from(request.limit());
        let allowed = used <= limit;
        let remaining = u32::try_from(limit.saturating_sub(used)).unwrap_or(0);
        Ok(RateLimitDecision {
            allowed,
            limit: request.limit(),
            remaining,
            reset_at: row.window_ends_at,
            retry_after_seconds: (!allowed)
                .then_some(u64::try_from(row.retry_after_seconds).unwrap_or(1).max(1)),
        })
    }

    /// Removes expired rows in bounded, skip-locked batches so maintenance
    /// does not block an active bucket update.
    pub async fn cleanup_expired(&self, batch_size: u32) -> Result<u64, DbError> {
        if batch_size == 0 {
            return Ok(0);
        }
        let result = sqlx::query(
            r"
            WITH expired AS (
                SELECT ctid
                FROM shared_rate_limit_buckets
                WHERE window_ends_at <= statement_timestamp()
                ORDER BY window_ends_at
                FOR UPDATE SKIP LOCKED
                LIMIT $1
            )
            DELETE FROM shared_rate_limit_buckets AS bucket
            USING expired
            WHERE bucket.ctid = expired.ctid
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn profile_bucket_uses_only_the_server_user_id() {
        let user_id = AuthenticatedUserId::new(Uuid::nil());
        let request =
            RateLimitRequest::profile_update(user_id, 3, Duration::from_secs(60)).unwrap();
        assert_eq!(request.bucket(), "profile_update");
        assert_eq!(
            request.scope_key(),
            "user:00000000-0000-0000-0000-000000000000"
        );
    }

    #[test]
    fn malformed_or_unbounded_rules_are_rejected() {
        assert_eq!(
            RateLimitRequest::new("Profile Update", "user:1", 1, Duration::from_secs(60))
                .unwrap_err(),
            RateLimitConfigError::InvalidBucket
        );
        assert_eq!(
            RateLimitRequest::new("profile_update", " user:1", 1, Duration::from_secs(60))
                .unwrap_err(),
            RateLimitConfigError::InvalidScopeKey
        );
        assert_eq!(
            RateLimitRequest::new("profile_update", "user:1", 0, Duration::from_secs(60))
                .unwrap_err(),
            RateLimitConfigError::InvalidLimit
        );
    }
}
