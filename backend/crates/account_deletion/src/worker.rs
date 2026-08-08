use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use auth::{IdentityAdmin, IdentityAdminError};
use db::{AccountDeletionFailure, ClaimedAccountDeletion, DbError};
use domain::AccountDeletionState;
use observability::{
    AccountDeletionMetricState, OperationClass, OperationOutcome, record_account_deletion_state,
    record_operation,
};
use thiserror::Error;
use tracing::{error, info, warn};

use crate::{AccountDeletionService, AccountDeletionServiceError, ExternalDeletionLedgerError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerRunOutcome {
    Idle,
    Advanced(AccountDeletionState),
    RetryScheduled,
    TerminalFailure,
}

pub struct AccountDeletionWorker {
    worker_id: String,
    service: AccountDeletionService,
    identity_admin: Arc<dyn IdentityAdmin>,
    lease_duration: Duration,
    step_timeout: Duration,
    retry_base: Duration,
    retry_maximum: Duration,
}

impl std::fmt::Debug for AccountDeletionWorker {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountDeletionWorker")
            .field("worker_id", &self.worker_id)
            .field("service", &self.service)
            .field("identity_admin", &"[configured]")
            .field("lease_duration", &self.lease_duration)
            .field("step_timeout", &self.step_timeout)
            .field("retry_base", &self.retry_base)
            .field("retry_maximum", &self.retry_maximum)
            .finish()
    }
}

impl AccountDeletionWorker {
    pub fn new(
        worker_id: impl Into<String>,
        service: AccountDeletionService,
        identity_admin: Arc<dyn IdentityAdmin>,
        lease_duration: Duration,
        step_timeout: Duration,
        retry_base: Duration,
        retry_maximum: Duration,
    ) -> Result<Self, AccountDeletionWorkerError> {
        let worker_id = worker_id.into();
        if worker_id.is_empty()
            || worker_id.len() > 128
            || worker_id.trim() != worker_id
            || worker_id.chars().any(char::is_control)
            || lease_duration < Duration::from_secs(5)
            || lease_duration > Duration::from_secs(60 * 60)
            || step_timeout < Duration::from_secs(1)
            || step_timeout > Duration::from_secs(30 * 60)
            || step_timeout
                .checked_add(Duration::from_secs(2))
                .is_none_or(|bounded_step| bounded_step > lease_duration)
            || retry_base < Duration::from_secs(1)
            || retry_base >= retry_maximum
            || retry_maximum > Duration::from_secs(24 * 60 * 60)
        {
            return Err(AccountDeletionWorkerError::InvalidConfiguration);
        }
        if identity_admin.readiness() != auth::IdentityAdminReadiness::Functional {
            return Err(AccountDeletionWorkerError::IdentityAdminUnavailable);
        }
        Ok(Self {
            worker_id,
            service,
            identity_admin,
            lease_duration,
            step_timeout,
            retry_base,
            retry_maximum,
        })
    }

    pub async fn run_once(&self) -> Result<WorkerRunOutcome, AccountDeletionWorkerError> {
        let started = Instant::now();
        let Some(job) = self
            .service
            .repository()
            .claim(&self.worker_id, self.lease_duration)
            .await?
        else {
            return Ok(WorkerRunOutcome::Idle);
        };
        let age = chrono::Utc::now()
            .signed_duration_since(job.requested_at)
            .to_std()
            .unwrap_or(Duration::ZERO);
        record_account_deletion_state(metric_state(job.state), age);

        let result = self.process_with_lease(&job).await;
        match result {
            Ok(state) => {
                record_operation(
                    OperationClass::AccountDeletion,
                    if state == AccountDeletionState::Completed {
                        OperationOutcome::Success
                    } else {
                        OperationOutcome::Pending
                    },
                    started.elapsed(),
                );
                info!(state = %state, "account deletion advanced");
                Ok(WorkerRunOutcome::Advanced(state))
            }
            Err(ProcessError::Database(error_value)) => {
                record_operation(
                    OperationClass::AccountDeletion,
                    OperationOutcome::RetryableFailure,
                    started.elapsed(),
                );
                Err(AccountDeletionWorkerError::Storage(error_value))
            }
            Err(ProcessError::LeaseLost) => {
                record_operation(
                    OperationClass::AccountDeletion,
                    OperationOutcome::RetryableFailure,
                    started.elapsed(),
                );
                warn!("account deletion worker lost its lease");
                Err(AccountDeletionWorkerError::LeaseLost)
            }
            Err(error_value) => {
                let failure =
                    process_failure(&job, &error_value, self.retry_base, self.retry_maximum);
                let state = self
                    .service
                    .repository()
                    .fail(&job, &self.worker_id, &failure)
                    .await?;
                let outcome = if state == AccountDeletionState::FailedRetryable {
                    warn!(code = %failure.code, "account deletion retry scheduled");
                    OperationOutcome::RetryableFailure
                } else {
                    if failure.code == "external_ledger_invalid" {
                        error!(
                            code = %failure.code,
                            "external deletion ledger failed verification"
                        );
                    } else {
                        error!(code = %failure.code, "account deletion reached terminal failure");
                    }
                    OperationOutcome::TerminalFailure
                };
                record_operation(OperationClass::AccountDeletion, outcome, started.elapsed());
                record_account_deletion_state(metric_state(state), age);
                Ok(if state == AccountDeletionState::FailedRetryable {
                    WorkerRunOutcome::RetryScheduled
                } else {
                    WorkerRunOutcome::TerminalFailure
                })
            }
        }
    }

    async fn process(
        &self,
        job: &ClaimedAccountDeletion,
    ) -> Result<AccountDeletionState, ProcessError> {
        // Verify the external record on every claim, even when PostgreSQL says
        // it was already externalized. Provider deletion cannot cross this gate.
        self.service
            .ensure_externalized(job)
            .await
            .map_err(|error_value| match error_value {
                AccountDeletionServiceError::Storage(error_value) => {
                    ProcessError::Database(error_value)
                }
                other => ProcessError::Externalization(other),
            })?;
        match job.effective_state() {
            AccountDeletionState::Requested => {
                let (issuer, subject) = provider_identity(job)?;
                self.identity_admin
                    .revoke_user_sessions(issuer, subject)
                    .await
                    .map_err(ProcessError::IdentityAdmin)?;
                advance(
                    self.service.repository(),
                    job.operation_id,
                    &self.worker_id,
                    AccountDeletionState::Requested,
                    AccountDeletionState::SessionsRevoked,
                )
                .await
            }
            AccountDeletionState::SessionsRevoked => {
                let (issuer, subject) = provider_identity(job)?;
                self.identity_admin
                    .delete_identity(issuer, subject)
                    .await
                    .map_err(ProcessError::IdentityAdmin)?;
                advance(
                    self.service.repository(),
                    job.operation_id,
                    &self.worker_id,
                    AccountDeletionState::SessionsRevoked,
                    AccountDeletionState::IdentityDeleted,
                )
                .await
            }
            AccountDeletionState::IdentityDeleted => {
                let advanced = self
                    .service
                    .repository()
                    .purge_app_data(
                        job,
                        &self.worker_id,
                        self.service.policy().security_retention(),
                    )
                    .await?;
                if !advanced {
                    return Err(ProcessError::LeaseLost);
                }
                Ok(AccountDeletionState::AppDataDeleted)
            }
            AccountDeletionState::AppDataDeleted => {
                let advanced = self
                    .service
                    .repository()
                    .complete(
                        job.operation_id,
                        &self.worker_id,
                        self.service.policy().ledger_retention(),
                    )
                    .await?;
                if !advanced {
                    return Err(ProcessError::LeaseLost);
                }
                Ok(AccountDeletionState::Completed)
            }
            AccountDeletionState::Completed => Ok(AccountDeletionState::Completed),
            AccountDeletionState::FailedRetryable | AccountDeletionState::FailedTerminal => {
                Err(ProcessError::InvalidState)
            }
        }
    }

    async fn process_with_lease(
        &self,
        job: &ClaimedAccountDeletion,
    ) -> Result<AccountDeletionState, ProcessError> {
        let process = self.process(job);
        let heartbeat = self.lease_heartbeat(job.operation_id);
        let deadline = tokio::time::sleep(self.step_timeout);
        tokio::pin!(process, heartbeat, deadline);
        tokio::select! {
            result = &mut process => result,
            error_value = &mut heartbeat => Err(error_value),
            () = &mut deadline => Err(ProcessError::TimedOut),
        }
    }

    async fn lease_heartbeat(&self, operation_id: uuid::Uuid) -> ProcessError {
        let interval = self.lease_duration / 3;
        loop {
            tokio::time::sleep(interval).await;
            match self
                .service
                .repository()
                .extend_lease(operation_id, &self.worker_id, self.lease_duration)
                .await
            {
                Ok(true) => {}
                Ok(false) => return ProcessError::LeaseLost,
                Err(error_value) => return ProcessError::Database(error_value),
            }
        }
    }
}

async fn advance(
    repository: &db::AccountDeletionRepository,
    operation_id: uuid::Uuid,
    worker_id: &str,
    from: AccountDeletionState,
    to: AccountDeletionState,
) -> Result<AccountDeletionState, ProcessError> {
    if !repository
        .advance(operation_id, worker_id, from, to)
        .await?
    {
        return Err(ProcessError::LeaseLost);
    }
    Ok(to)
}

fn provider_identity(job: &ClaimedAccountDeletion) -> Result<(&str, &str), ProcessError> {
    match (job.issuer.as_deref(), job.subject.as_deref()) {
        (Some(issuer), Some(subject)) => Ok((issuer, subject)),
        _ => Err(ProcessError::InvalidState),
    }
}

fn process_failure(
    job: &ClaimedAccountDeletion,
    error_value: &ProcessError,
    retry_base: Duration,
    retry_maximum: Duration,
) -> AccountDeletionFailure {
    let (class, code, message, retryable) = match error_value {
        ProcessError::Externalization(
            AccountDeletionServiceError::ExternalLedger(ExternalDeletionLedgerError::Unavailable)
            | AccountDeletionServiceError::ExternalizationUnavailable {
                source: ExternalDeletionLedgerError::Unavailable,
                ..
            },
        ) => (
            "external_ledger",
            "external_ledger_unavailable",
            "external deletion ledger is unavailable",
            true,
        ),
        ProcessError::Externalization(_) => (
            "external_ledger",
            "external_ledger_invalid",
            "external deletion ledger is invalid",
            false,
        ),
        ProcessError::IdentityAdmin(IdentityAdminError::ProviderUnavailable) => (
            "identity_provider",
            "provider_unavailable",
            "identity provider administration is unavailable",
            true,
        ),
        ProcessError::IdentityAdmin(IdentityAdminError::Unauthorized) => (
            "identity_provider",
            "provider_credentials_rejected",
            "identity provider rejected worker credentials",
            // Credentials and service-account roles can rotate after startup.
            // Retry through the normal bounded attempt budget so a corrected
            // replacement pod can reclaim the obligation automatically.
            true,
        ),
        ProcessError::IdentityAdmin(IdentityAdminError::Rejected) => (
            "identity_provider",
            "provider_operation_rejected",
            "identity provider rejected deletion operation",
            false,
        ),
        ProcessError::IdentityAdmin(
            IdentityAdminError::NotConfigured | IdentityAdminError::Unwired,
        ) => (
            "identity_provider",
            "provider_adapter_unavailable",
            "identity provider adapter is unavailable",
            false,
        ),
        ProcessError::LeaseLost => (
            "worker",
            "lease_lost",
            "account deletion worker lost its lease",
            true,
        ),
        ProcessError::TimedOut => (
            "worker",
            "step_timeout",
            "account deletion step exceeded its bounded deadline",
            true,
        ),
        ProcessError::InvalidState => (
            "worker",
            "invalid_state",
            "account deletion job state is invalid",
            false,
        ),
        ProcessError::Database(_) => (
            "database",
            "database_unavailable",
            "account deletion storage is unavailable",
            true,
        ),
    };
    AccountDeletionFailure {
        class: class.into(),
        code: code.into(),
        message: message.into(),
        retryable,
        retry_after: retry_delay(job.operation_id, job.attempt, retry_base, retry_maximum),
    }
}

fn retry_delay(
    operation_id: uuid::Uuid,
    attempt: u32,
    base: Duration,
    maximum: Duration,
) -> Duration {
    let exponent = attempt.saturating_sub(1).min(16);
    let factor = 1_u64 << exponent;
    let base_seconds = base.as_secs().saturating_mul(factor);
    let capped = base_seconds.min(maximum.as_secs());
    let jitter_ceiling = (capped / 4).max(1);
    let jitter = u64::from(operation_id.as_bytes()[15]) % jitter_ceiling;
    Duration::from_secs(capped.saturating_add(jitter).min(maximum.as_secs()))
}

const fn metric_state(state: AccountDeletionState) -> AccountDeletionMetricState {
    match state {
        AccountDeletionState::Requested => AccountDeletionMetricState::Requested,
        AccountDeletionState::SessionsRevoked => AccountDeletionMetricState::SessionsRevoked,
        AccountDeletionState::IdentityDeleted => AccountDeletionMetricState::IdentityDeleted,
        AccountDeletionState::AppDataDeleted => AccountDeletionMetricState::AppDataDeleted,
        AccountDeletionState::Completed => AccountDeletionMetricState::Completed,
        AccountDeletionState::FailedRetryable => AccountDeletionMetricState::RetryableFailure,
        AccountDeletionState::FailedTerminal => AccountDeletionMetricState::TerminalFailure,
    }
}

#[derive(Debug, Error)]
enum ProcessError {
    #[error("deletion storage is unavailable")]
    Database(#[from] DbError),
    #[error("deletion externalization failed")]
    Externalization(AccountDeletionServiceError),
    #[error("identity provider administration failed")]
    IdentityAdmin(IdentityAdminError),
    #[error("deletion worker lost its lease")]
    LeaseLost,
    #[error("deletion worker step timed out")]
    TimedOut,
    #[error("deletion job state is invalid")]
    InvalidState,
}

#[derive(Debug, Error)]
pub enum AccountDeletionWorkerError {
    #[error("account-deletion worker configuration is invalid")]
    InvalidConfiguration,
    #[error("functional identity-administration adapter is required")]
    IdentityAdminUnavailable,
    #[error("account-deletion storage is unavailable")]
    Storage(#[from] DbError),
    #[error("account-deletion worker lost its lease")]
    LeaseLost,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_is_bounded_and_operation_jitter_is_deterministic() {
        let operation_id =
            uuid::Uuid::from_bytes([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
        let first = retry_delay(
            operation_id,
            1,
            Duration::from_secs(5),
            Duration::from_secs(300),
        );
        assert!((Duration::from_secs(5)..=Duration::from_secs(6)).contains(&first));
        assert_eq!(
            retry_delay(
                operation_id,
                100,
                Duration::from_secs(5),
                Duration::from_secs(300)
            ),
            Duration::from_secs(300)
        );
    }

    #[test]
    fn provider_auth_failures_retry_boundedly_but_semantic_rejections_are_terminal() {
        let now = chrono::Utc::now();
        let job = ClaimedAccountDeletion {
            operation_id: uuid::Uuid::now_v7(),
            user_id: uuid::Uuid::now_v7(),
            fingerprint: domain::IdentityFingerprint::new("test_key", [7; 32]).unwrap(),
            issuer: Some("https://identity.example/realms/pakperk".to_owned()),
            subject: Some("0198f4d7-a4ce-7b40-8ee8-4f350350810c".to_owned()),
            state: AccountDeletionState::Requested,
            retry_from: None,
            attempt: 1,
            max_attempts: 12,
            requested_at: now,
            updated_at: now,
            externalized_at: Some(now),
        };
        for (error, expected_code, retryable) in [
            (
                IdentityAdminError::ProviderUnavailable,
                "provider_unavailable",
                true,
            ),
            (
                IdentityAdminError::Unauthorized,
                "provider_credentials_rejected",
                true,
            ),
            (
                IdentityAdminError::Rejected,
                "provider_operation_rejected",
                false,
            ),
        ] {
            let failure = process_failure(
                &job,
                &ProcessError::IdentityAdmin(error),
                Duration::from_secs(5),
                Duration::from_secs(300),
            );
            assert_eq!(failure.code, expected_code);
            assert_eq!(failure.retryable, retryable);
            assert!(failure.retry_after <= Duration::from_secs(300));
        }
    }
}
