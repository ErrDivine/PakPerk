//! Bounded maintenance for account-owned shared infrastructure.

use std::time::Duration;

use db::Database;
use tokio::task::JoinHandle;
use tracing::{error, info};

const RATE_LIMIT_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const RATE_LIMIT_CLEANUP_BATCH: u32 = 1_000;

/// Removes at most one capped batch per interval. Scope keys are never logged.
pub fn spawn_account_maintenance(
    database: Database,
    accounts_enabled: bool,
) -> Option<JoinHandle<()>> {
    accounts_enabled.then(|| {
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
                    Err(error_value) => {
                        error!(error = %error_value, "shared rate-limit maintenance failed");
                    }
                }
            }
        })
    })
}

#[cfg(test)]
mod tests {
    use sqlx::postgres::PgPoolOptions;

    use super::*;

    #[tokio::test]
    async fn maintenance_is_not_started_when_accounts_are_disabled() {
        let database = Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        assert!(spawn_account_maintenance(database, false).is_none());
    }
}
