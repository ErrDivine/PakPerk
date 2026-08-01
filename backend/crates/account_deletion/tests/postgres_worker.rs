use std::{
    collections::VecDeque,
    fs,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use account_deletion::{
    AccountDeletionPolicy, AccountDeletionService, AccountDeletionWorker, DeletionLedgerSigner,
    ExternalDeletionLedger as _, ExternalDeletionRecord, FileExternalDeletionLedger,
    ProviderIdentityCipher, ProviderIdentityCoordinates, RequestDeletionOutcome, WorkerRunOutcome,
};
use accounts::{IdentityFingerprintKeyring, VerifiedIdentity};
use async_trait::async_trait;
use auth::{IdentityAdmin, IdentityAdminError, IdentityAdminReadiness};
use db::{AccountDeletionRequestOutcome, Database};
use domain::AccountDeletionState;
use tokio::sync::Mutex;
use uuid::Uuid;

const IDENTITY_KEY: &str = "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=";
const SIGNING_KEY: &str = "YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI=";

#[derive(Debug)]
struct ScriptedIdentityAdmin {
    revoke: Mutex<VecDeque<Result<(), IdentityAdminError>>>,
    delete: Mutex<VecDeque<Result<(), IdentityAdminError>>>,
    revoke_delay: Duration,
    revoke_calls: AtomicUsize,
    delete_calls: AtomicUsize,
}

impl ScriptedIdentityAdmin {
    fn new(
        revoke: impl IntoIterator<Item = Result<(), IdentityAdminError>>,
        delete: impl IntoIterator<Item = Result<(), IdentityAdminError>>,
        revoke_delay: Duration,
    ) -> Self {
        Self {
            revoke: Mutex::new(revoke.into_iter().collect()),
            delete: Mutex::new(delete.into_iter().collect()),
            revoke_delay,
            revoke_calls: AtomicUsize::new(0),
            delete_calls: AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl IdentityAdmin for ScriptedIdentityAdmin {
    fn readiness(&self) -> IdentityAdminReadiness {
        IdentityAdminReadiness::Functional
    }

    async fn revoke_user_sessions(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        self.revoke_calls.fetch_add(1, Ordering::SeqCst);
        if !self.revoke_delay.is_zero() {
            tokio::time::sleep(self.revoke_delay).await;
        }
        self.revoke.lock().await.pop_front().unwrap_or(Ok(()))
    }

    async fn delete_identity(
        &self,
        _issuer: &str,
        _subject: &str,
    ) -> Result<(), IdentityAdminError> {
        self.delete_calls.fetch_add(1, Ordering::SeqCst);
        self.delete.lock().await.pop_front().unwrap_or(Ok(()))
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_worker_retries_times_out_and_recovers_external_append_crash() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL deletion-worker coverage");
        return;
    };
    let database = Database::connect(&database_url, 24).await.unwrap();
    database.migrate_embedded().await.unwrap();
    let unique = Uuid::now_v7().simple().to_string();
    let issuer = format!("https://deletion-worker.test/{unique}");
    let keyring = IdentityFingerprintKeyring::parse(&format!("identity_1:{IDENTITY_KEY}")).unwrap();
    let signer =
        DeletionLedgerSigner::parse("development", &format!("signing_1:{SIGNING_KEY}")).unwrap();
    let provider_identity_cipher =
        ProviderIdentityCipher::new("provider_1", vec![0x73; 32]).unwrap();
    let directory = tempfile::tempdir().unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    }
    let external = FileExternalDeletionLedger::new(directory.path(), signer.clone()).unwrap();
    let policy = AccountDeletionPolicy::new(
        Duration::from_secs(300),
        2,
        Duration::from_secs(3600),
        4,
        Duration::from_secs(24 * 60 * 60),
        Duration::from_secs(2 * 24 * 60 * 60),
        Duration::from_secs(24 * 60 * 60),
    )
    .unwrap();
    let service = AccountDeletionService::new(
        database.account_deletions(),
        keyring.clone(),
        Arc::new(external.clone()),
        signer.clone(),
        provider_identity_cipher.clone(),
        policy,
    )
    .unwrap();

    let identity = VerifiedIdentity::new(issuer.clone(), format!("retry-{unique}")).unwrap();
    database
        .accounts()
        .provision_oidc_identity_guarded(
            identity.issuer(),
            identity.subject(),
            Duration::from_secs(900),
            &keyring
                .fingerprints(identity.issuer(), identity.subject())
                .unwrap(),
        )
        .await
        .unwrap();
    let operation_id = match service.request(&identity).await.unwrap() {
        RequestDeletionOutcome::Accepted { operation, .. } => operation.operation_id,
        RequestDeletionOutcome::RateLimited { .. } => panic!("unexpected rate limit"),
    };
    let admin = Arc::new(ScriptedIdentityAdmin::new(
        [Err(IdentityAdminError::ProviderUnavailable), Ok(())],
        // An idempotent provider absence is surfaced to the worker as success;
        // the Keycloak adapter's real 404 mapping is covered in its mock HTTP tests.
        [Ok(())],
        Duration::ZERO,
    ));
    let worker = AccountDeletionWorker::new(
        "retry-worker",
        service.clone(),
        admin.clone(),
        Duration::from_secs(30),
        Duration::from_secs(10),
        Duration::from_secs(1),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(
        worker.run_once().await.unwrap(),
        WorkerRunOutcome::RetryScheduled
    );
    let failed = database
        .account_deletions()
        .get_status(operation_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(failed.state, AccountDeletionState::FailedRetryable);
    assert_eq!(failed.retry_from, Some(AccountDeletionState::Requested));
    sqlx::query(
        "UPDATE account_deletion_jobs SET available_at = statement_timestamp() WHERE operation_id = $1",
    )
    .bind(operation_id)
    .execute(database.pool())
    .await
    .unwrap();
    assert_eq!(
        worker.run_once().await.unwrap(),
        WorkerRunOutcome::Advanced(AccountDeletionState::SessionsRevoked)
    );
    assert_eq!(
        worker.run_once().await.unwrap(),
        WorkerRunOutcome::Advanced(AccountDeletionState::IdentityDeleted)
    );
    assert_eq!(
        worker.run_once().await.unwrap(),
        WorkerRunOutcome::Advanced(AccountDeletionState::AppDataDeleted)
    );
    assert_eq!(
        worker.run_once().await.unwrap(),
        WorkerRunOutcome::Advanced(AccountDeletionState::Completed)
    );
    assert_eq!(admin.revoke_calls.load(Ordering::SeqCst), 2);
    assert_eq!(admin.delete_calls.load(Ordering::SeqCst), 1);

    let timeout_identity =
        VerifiedIdentity::new(issuer.clone(), format!("timeout-{unique}")).unwrap();
    database
        .accounts()
        .provision_oidc_identity_guarded(
            timeout_identity.issuer(),
            timeout_identity.subject(),
            Duration::from_secs(900),
            &keyring
                .fingerprints(timeout_identity.issuer(), timeout_identity.subject())
                .unwrap(),
        )
        .await
        .unwrap();
    let timeout_operation = match service.request(&timeout_identity).await.unwrap() {
        RequestDeletionOutcome::Accepted { operation, .. } => operation.operation_id,
        RequestDeletionOutcome::RateLimited { .. } => panic!("unexpected rate limit"),
    };
    let slow_admin = Arc::new(ScriptedIdentityAdmin::new(
        [Ok(())],
        [Ok(())],
        Duration::from_secs(5),
    ));
    let timeout_worker = AccountDeletionWorker::new(
        "timeout-worker",
        service.clone(),
        slow_admin,
        Duration::from_secs(5),
        Duration::from_secs(1),
        Duration::from_secs(1),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(
        timeout_worker.run_once().await.unwrap(),
        WorkerRunOutcome::RetryScheduled
    );
    let timeout_status = database
        .account_deletions()
        .get_status(timeout_operation)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(timeout_status.state, AccountDeletionState::FailedRetryable);
    assert_eq!(
        timeout_status.last_error_code.as_deref(),
        Some("step_timeout")
    );
    sqlx::query(
        "UPDATE account_deletion_jobs SET available_at = statement_timestamp() + interval '1 hour' WHERE operation_id = $1",
    )
    .bind(timeout_operation)
    .execute(database.pool())
    .await
    .unwrap();

    // Local request committed, the signed file was appended, then the process
    // "crashed" before `mark_externalized`. A fresh worker verifies that exact
    // file, repairs the acknowledgement, and advances without duplicating it.
    let crash_identity = VerifiedIdentity::new(issuer.clone(), format!("crash-{unique}")).unwrap();
    database
        .accounts()
        .provision_oidc_identity_guarded(
            crash_identity.issuer(),
            crash_identity.subject(),
            Duration::from_secs(900),
            &keyring
                .fingerprints(crash_identity.issuer(), crash_identity.subject())
                .unwrap(),
        )
        .await
        .unwrap();
    let crash_request = match database
        .account_deletions()
        .request(
            crash_identity.issuer(),
            crash_identity.subject(),
            &keyring
                .fingerprints(crash_identity.issuer(), crash_identity.subject())
                .unwrap(),
            2,
            Duration::from_secs(3600),
            4,
        )
        .await
        .unwrap()
    {
        AccountDeletionRequestOutcome::Accepted(request) => request,
        AccountDeletionRequestOutcome::RateLimited { .. } => panic!("unexpected rate limit"),
    };
    assert!(!crash_request.externalized);
    let crash_record = ExternalDeletionRecord::from_ledger(
        "development",
        &crash_request.ledger,
        &provider_identity_cipher,
        &ProviderIdentityCoordinates::new(
            crash_identity.issuer().to_owned(),
            crash_identity.subject().to_owned(),
        )
        .unwrap(),
    )
    .unwrap();
    external
        .append_and_verify(&signer.sign(&crash_record).unwrap())
        .await
        .unwrap();
    let crash_admin = Arc::new(ScriptedIdentityAdmin::new(
        [Ok(())],
        [Ok(())],
        Duration::ZERO,
    ));
    let crash_worker = AccountDeletionWorker::new(
        "crash-worker",
        service,
        crash_admin,
        Duration::from_secs(30),
        Duration::from_secs(10),
        Duration::from_secs(1),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(
        crash_worker.run_once().await.unwrap(),
        WorkerRunOutcome::Advanced(AccountDeletionState::SessionsRevoked)
    );
    assert!(
        database
            .account_deletions()
            .get_status(crash_request.operation.operation_id)
            .await
            .unwrap()
            .unwrap()
            .externalized
    );

    sqlx::query("DELETE FROM account_deletion_events WHERE operation_id IN ($1, $2, $3)")
        .bind(operation_id)
        .bind(timeout_operation)
        .bind(crash_request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_jobs WHERE operation_id IN ($1, $2, $3)")
        .bind(operation_id)
        .bind(timeout_operation)
        .bind(crash_request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM account_deletion_ledger WHERE operation_id IN ($1, $2, $3)")
        .bind(operation_id)
        .bind(timeout_operation)
        .bind(crash_request.operation.operation_id)
        .execute(database.pool())
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE oidc_issuer = $1")
        .bind(&issuer)
        .execute(database.pool())
        .await
        .unwrap();
}
