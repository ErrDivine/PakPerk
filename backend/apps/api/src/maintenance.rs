//! Bounded maintenance for shared API infrastructure.

use std::time::{Duration, Instant};

use db::Database;
use library::LibraryService;
use observability::{
    BacklogClass, OperationClass, OperationOutcome, record_backlog, record_operation,
};
use tokio::task::JoinHandle;
use tracing::{error, info};

const RATE_LIMIT_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const RATE_LIMIT_CLEANUP_BATCH: u32 = 1_000;
const LIBRARY_TOMBSTONE_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const LIBRARY_TOMBSTONE_CLEANUP_BATCH: u32 = 1_000;
const OPERATIONAL_TELEMETRY_INTERVAL: Duration = Duration::from_secs(60);

/// Removes at most one capped batch per interval. Scope keys are never logged.
pub fn spawn_rate_limit_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.rate_limits();
        let mut interval = tokio::time::interval(RATE_LIMIT_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            match repository.cleanup_expired(RATE_LIMIT_CLEANUP_BATCH).await {
                Ok(removed) if removed > 0 => {
                    info!(removed, "expired shared rate-limit buckets removed");
                }
                Ok(_) => {}
                Err(_error_value) => {
                    error!(
                        error.kind = "database",
                        "shared rate-limit maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only a capped 90-day tombstone batch. The service transaction
/// advances the affected account reset floors before deleting rows; operation
/// ledger entries remain until account deletion.
pub fn spawn_library_maintenance(service: Option<LibraryService>) -> Option<JoinHandle<()>> {
    service.map(|service| {
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(LIBRARY_TOMBSTONE_CLEANUP_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                match service
                    .cleanup_tombstones(LIBRARY_TOMBSTONE_CLEANUP_BATCH)
                    .await
                {
                    Ok(removed) if removed > 0 => {
                        info!(removed, "expired library tombstones removed");
                    }
                    Ok(_) => {}
                    Err(_error_value) => {
                        error!(
                            error.kind = "library_service",
                            "library tombstone maintenance failed"
                        );
                    }
                }
            }
        })
    })
}

/// Samples aggregate moderation pressure. The query returns only fixed counts
/// and ages; report reasons, details, authors, and identifiers never cross the
/// telemetry boundary.
pub fn spawn_operational_telemetry(
    database: Database,
    comments_enabled: bool,
) -> Option<JoinHandle<()>> {
    comments_enabled.then(|| {
        tokio::spawn(async move {
            let repository = database.moderation();
            let mut interval = tokio::time::interval(OPERATIONAL_TELEMETRY_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let started = Instant::now();
                let metrics = repository.report_age_metrics().await;
                record_operation(
                    OperationClass::DatabaseRead,
                    if metrics.is_ok() {
                        OperationOutcome::Success
                    } else {
                        OperationOutcome::RetryableFailure
                    },
                    started.elapsed(),
                );
                if let Ok(metrics) = metrics {
                    record_backlog(
                        BacklogClass::ModerationReports,
                        u64::try_from(metrics.open_count.max(0)).unwrap_or(u64::MAX),
                        bounded_age(metrics.oldest_open_age_seconds),
                    );
                } else {
                    error!(
                        error.kind = "database",
                        "moderation backlog telemetry query failed"
                    );
                }
            }
        })
    })
}

fn bounded_age(seconds: Option<f64>) -> Duration {
    seconds
        .filter(|value| value.is_finite() && *value > 0.0)
        .map_or(Duration::ZERO, |value| {
            Duration::from_secs_f64(value.min(10.0 * 365.0 * 24.0 * 60.0 * 60.0))
        })
}

#[cfg(test)]
mod tests {
    use sqlx::postgres::PgPoolOptions;

    use super::*;

    #[tokio::test]
    async fn feature_gated_maintenance_is_not_started_when_disabled() {
        let database = Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        let rate_limit_maintenance = spawn_rate_limit_maintenance(database);
        rate_limit_maintenance.abort();
        assert!(spawn_library_maintenance(None).is_none());
        let database = Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        assert!(spawn_operational_telemetry(database, false).is_none());
    }

    #[test]
    fn operational_age_is_bounded_and_rejects_invalid_values() {
        assert_eq!(bounded_age(None), Duration::ZERO);
        assert_eq!(bounded_age(Some(f64::NAN)), Duration::ZERO);
        assert_eq!(bounded_age(Some(-1.0)), Duration::ZERO);
        assert_eq!(bounded_age(Some(7.5)), Duration::from_secs_f64(7.5));
        assert_eq!(
            bounded_age(Some(f64::MAX)),
            Duration::from_secs(10 * 365 * 24 * 60 * 60)
        );
    }
}
