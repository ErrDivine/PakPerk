//! Cross-process isolation for integration tests that create or claim global
//! account-deletion queue entries.

use db::Database;
use sqlx::{Postgres, Transaction};

// The two-int PostgreSQL advisory-lock key space is distinct from the bigint
// key space used for identity locks. These ASCII-derived keys spell PAKP/DELQ
// and must remain identical for every deletion-queue integration binary.
const PAKPERK_TEST_LOCK_DOMAIN: i32 = 0x5041_4b50;
const ACCOUNT_DELETION_QUEUE_LOCK_KEY: i32 = 0x4445_4c51;

pub async fn acquire(database: &Database) -> Result<Transaction<'static, Postgres>, sqlx::Error> {
    let mut transaction = database.pool().begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock($1, $2)")
        .bind(PAKPERK_TEST_LOCK_DOMAIN)
        .bind(ACCOUNT_DELETION_QUEUE_LOCK_KEY)
        .execute(&mut *transaction)
        .await?;
    let unfinished: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM account_deletion_jobs
        WHERE state IN (
            'requested', 'sessions_revoked', 'identity_deleted',
            'app_data_deleted', 'failed_retryable'
        )
        ",
    )
    .fetch_one(&mut *transaction)
    .await?;
    if unfinished != 0 {
        return Err(sqlx::Error::InvalidArgument(
            "TEST_DATABASE_URL contains unfinished account-deletion residue; use a fresh disposable database after an interrupted test run"
                .to_owned(),
        ));
    }
    Ok(transaction)
}
