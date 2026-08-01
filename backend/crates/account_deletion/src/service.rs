use std::{sync::Arc, time::Duration};

use accounts::{FingerprintKeyringError, IdentityFingerprintKeyring, VerifiedIdentity};
use db::{
    AccountDeletionRepository, AccountDeletionRequest, AccountDeletionRequestOutcome,
    ClaimedAccountDeletion, DbError, DeletionLedgerRecord, StoredDeletionIdentityVerification,
};
use domain::{AccountDeletionOperation, AccountStatus, AuthenticatedUserId, IdentityFingerprint};
use thiserror::Error;

use crate::{
    DeletionLedgerSigner, ExternalDeletionLedger, ExternalDeletionLedgerError,
    ExternalDeletionRecord, ProviderIdentityCipher, ProviderIdentityCoordinates,
    SignedExternalDeletionRecord,
};

#[derive(Debug, Clone)]
pub struct AccountDeletionPolicy {
    recent_auth: Duration,
    request_limit: u32,
    request_window: Duration,
    maximum_attempts: u32,
    security_retention: Duration,
    ledger_retention: Duration,
    recoverable_backup_horizon: Duration,
}

impl AccountDeletionPolicy {
    pub fn new(
        recent_auth: Duration,
        request_limit: u32,
        request_window: Duration,
        maximum_attempts: u32,
        security_retention: Duration,
        ledger_retention: Duration,
        recoverable_backup_horizon: Duration,
    ) -> Result<Self, AccountDeletionServiceError> {
        let policy = Self {
            recent_auth,
            request_limit,
            request_window,
            maximum_attempts,
            security_retention,
            ledger_retention,
            recoverable_backup_horizon,
        };
        policy.validate()?;
        Ok(policy)
    }

    fn validate(&self) -> Result<(), AccountDeletionServiceError> {
        if self.recent_auth < Duration::from_secs(30)
            || self.recent_auth > Duration::from_secs(24 * 60 * 60)
            || self.request_limit == 0
            || self.request_window < Duration::from_secs(1)
            || self.request_window > Duration::from_secs(30 * 24 * 60 * 60)
            || !(1..=100).contains(&self.maximum_attempts)
            || self.security_retention < Duration::from_secs(24 * 60 * 60)
            || self.security_retention > Duration::from_secs(10 * 365 * 24 * 60 * 60)
            || self.ledger_retention < self.security_retention
            || self.ledger_retention <= self.recoverable_backup_horizon
            || self.recoverable_backup_horizon < Duration::from_secs(24 * 60 * 60)
            || self.ledger_retention > Duration::from_secs(10 * 365 * 24 * 60 * 60)
        {
            return Err(AccountDeletionServiceError::InvalidPolicy);
        }
        Ok(())
    }

    #[must_use]
    pub const fn recent_auth(&self) -> Duration {
        self.recent_auth
    }

    #[must_use]
    pub const fn security_retention(&self) -> Duration {
        self.security_retention
    }

    #[must_use]
    pub const fn ledger_retention(&self) -> Duration {
        self.ledger_retention
    }

    #[must_use]
    pub const fn recoverable_backup_horizon(&self) -> Duration {
        self.recoverable_backup_horizon
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestDeletionOutcome {
    Accepted {
        operation: AccountDeletionOperation,
        replayed: bool,
    },
    RateLimited {
        retry_after_seconds: u64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeletionIdentityVerification {
    pub account_id: AuthenticatedUserId,
    pub status: AccountStatus,
    pub operation_id: Option<uuid::Uuid>,
}

impl From<StoredDeletionIdentityVerification> for DeletionIdentityVerification {
    fn from(value: StoredDeletionIdentityVerification) -> Self {
        Self {
            account_id: value.user_id,
            status: value.status,
            operation_id: value.operation_id,
        }
    }
}

#[derive(Clone)]
pub struct AccountDeletionService {
    repository: AccountDeletionRepository,
    keyring: IdentityFingerprintKeyring,
    external_ledger: Arc<dyn ExternalDeletionLedger>,
    signer: DeletionLedgerSigner,
    provider_identity_cipher: ProviderIdentityCipher,
    policy: AccountDeletionPolicy,
}

impl std::fmt::Debug for AccountDeletionService {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountDeletionService")
            .field("keyring", &self.keyring)
            .field("external_ledger", &"[configured]")
            .field("signer", &self.signer)
            .field("provider_identity_cipher", &self.provider_identity_cipher)
            .field("policy", &self.policy)
            .finish_non_exhaustive()
    }
}

impl AccountDeletionService {
    pub fn new(
        repository: AccountDeletionRepository,
        keyring: IdentityFingerprintKeyring,
        external_ledger: Arc<dyn ExternalDeletionLedger>,
        signer: DeletionLedgerSigner,
        provider_identity_cipher: ProviderIdentityCipher,
        policy: AccountDeletionPolicy,
    ) -> Result<Self, AccountDeletionServiceError> {
        policy.validate()?;
        Ok(Self {
            repository,
            keyring,
            external_ledger,
            signer,
            provider_identity_cipher,
            policy,
        })
    }

    #[must_use]
    pub const fn policy(&self) -> &AccountDeletionPolicy {
        &self.policy
    }

    #[must_use]
    pub const fn repository(&self) -> &AccountDeletionRepository {
        &self.repository
    }

    pub fn fingerprints(
        &self,
        identity: &VerifiedIdentity,
    ) -> Result<Vec<IdentityFingerprint>, AccountDeletionServiceError> {
        self.keyring
            .fingerprints(identity.issuer(), identity.subject())
            .map_err(AccountDeletionServiceError::from)
    }

    /// Maps a verified provider identity to an existing bounded account view
    /// without JIT provisioning or exposing issuer/subject claims.
    pub async fn verify_identity(
        &self,
        identity: &VerifiedIdentity,
    ) -> Result<Option<DeletionIdentityVerification>, AccountDeletionServiceError> {
        let fingerprints = self.fingerprints(identity)?;
        self.repository
            .verify_identity(identity.issuer(), identity.subject(), &fingerprints)
            .await
            .map(|verification| verification.map(DeletionIdentityVerification::from))
            .map_err(AccountDeletionServiceError::from)
    }

    /// Commits `deletion_pending` and the local operation before accessing the
    /// external failure domain. A 202 is returned by callers only after this
    /// method has synchronously appended and verified the signed tombstone.
    pub async fn request(
        &self,
        identity: &VerifiedIdentity,
    ) -> Result<RequestDeletionOutcome, AccountDeletionServiceError> {
        let fingerprints = self.fingerprints(identity)?;
        let outcome = self
            .repository
            .request(
                identity.issuer(),
                identity.subject(),
                &fingerprints,
                self.policy.request_limit,
                self.policy.request_window,
                self.policy.maximum_attempts,
            )
            .await?;
        let AccountDeletionRequestOutcome::Accepted(request) = outcome else {
            let AccountDeletionRequestOutcome::RateLimited {
                retry_after_seconds,
            } = outcome
            else {
                unreachable!("exhaustive deletion request outcome")
            };
            return Ok(RequestDeletionOutcome::RateLimited {
                retry_after_seconds,
            });
        };
        self.externalize(&request, identity)
            .await
            .map_err(
                |source| AccountDeletionServiceError::ExternalizationUnavailable {
                    operation: request.operation.clone(),
                    source,
                },
            )?;
        let operation = self
            .repository
            .mark_externalized(request.operation.operation_id)
            .await
            .map_err(
                |source| AccountDeletionServiceError::PostCommitStorageUnavailable {
                    operation: request.operation.clone(),
                    source,
                },
            )?;
        Ok(RequestDeletionOutcome::Accepted {
            operation,
            replayed: request.replayed,
        })
    }

    pub async fn ensure_externalized(
        &self,
        job: &ClaimedAccountDeletion,
    ) -> Result<(), AccountDeletionServiceError> {
        let coordinates = match (&job.issuer, &job.subject) {
            (Some(issuer), Some(subject)) => Some(ProviderIdentityCoordinates::new(
                issuer.clone(),
                subject.clone(),
            )?),
            (None, None) => None,
            _ => return Err(ExternalDeletionLedgerError::InvalidRecord.into()),
        };
        let ledger = job.ledger_record();
        self.ensure_external_record(&ledger, coordinates.as_ref())
            .await?;
        self.repository
            .mark_externalized(ledger.operation_id)
            .await?;
        Ok(())
    }

    async fn externalize(
        &self,
        request: &AccountDeletionRequest,
        identity: &VerifiedIdentity,
    ) -> Result<(), ExternalDeletionLedgerError> {
        let coordinates = ProviderIdentityCoordinates::new(
            identity.issuer().to_owned(),
            identity.subject().to_owned(),
        )?;
        self.ensure_external_record(&request.ledger, Some(&coordinates))
            .await
    }

    async fn ensure_external_record(
        &self,
        ledger: &DeletionLedgerRecord,
        coordinates: Option<&ProviderIdentityCoordinates>,
    ) -> Result<(), ExternalDeletionLedgerError> {
        if let Some(persisted) = self.external_ledger.read(ledger.operation_id).await? {
            return self.verify_equivalent_record(&persisted, ledger, coordinates);
        }
        if !self
            .repository
            .external_record_required(ledger.operation_id)
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
        {
            return Ok(());
        }
        let coordinates = coordinates.ok_or(ExternalDeletionLedgerError::InvalidRecord)?;
        let record = ExternalDeletionRecord::from_ledger(
            self.signer.environment_id(),
            ledger,
            &self.provider_identity_cipher,
            coordinates,
        )?;
        let expected = self.signer.sign(&record)?;
        match self.external_ledger.append_and_verify(&expected).await {
            // Another process may have won the no-replace publish with a
            // historical but still trusted signing key during rotation.
            Ok(()) | Err(ExternalDeletionLedgerError::Conflict) => {}
            Err(error_value) => return Err(error_value),
        }
        let persisted = self
            .external_ledger
            .read(ledger.operation_id)
            .await?
            .ok_or(ExternalDeletionLedgerError::Unavailable)?;
        self.verify_equivalent_record(&persisted, ledger, Some(coordinates))
    }

    fn verify_equivalent_record(
        &self,
        persisted: &SignedExternalDeletionRecord,
        expected_ledger: &DeletionLedgerRecord,
        expected_coordinates: Option<&ProviderIdentityCoordinates>,
    ) -> Result<(), ExternalDeletionLedgerError> {
        let restored = self.decode_external_record(persisted)?;
        if restored.ledger.operation_id != expected_ledger.operation_id
            || restored.ledger.original_user_id != expected_ledger.original_user_id
            || restored.ledger.fingerprint != expected_ledger.fingerprint
            || restored.ledger.requested_at.timestamp_millis()
                != expected_ledger.requested_at.timestamp_millis()
            || expected_coordinates.is_some_and(|expected| expected != &restored.provider_identity)
        {
            return Err(ExternalDeletionLedgerError::Conflict);
        }
        Ok(())
    }

    pub fn decode_external_record(
        &self,
        signed: &SignedExternalDeletionRecord,
    ) -> Result<RestoredExternalDeletionRecord, ExternalDeletionLedgerError> {
        self.signer.verify(signed)?;
        let ledger = signed.record.ledger_record()?;
        let provider_identity = signed
            .record
            .decrypt_provider_identity(&self.provider_identity_cipher)?;
        let matches_fingerprint = self
            .keyring
            .fingerprints(provider_identity.issuer(), provider_identity.subject())
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?
            .iter()
            .any(|candidate| candidate == &ledger.fingerprint);
        if !matches_fingerprint {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        Ok(RestoredExternalDeletionRecord {
            ledger,
            provider_identity,
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct RestoredExternalDeletionRecord {
    pub ledger: DeletionLedgerRecord,
    pub provider_identity: ProviderIdentityCoordinates,
}

impl std::fmt::Debug for RestoredExternalDeletionRecord {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RestoredExternalDeletionRecord")
            .field("operation_id", &self.ledger.operation_id)
            .field("original_user_id", &self.ledger.original_user_id)
            .field("identity_fingerprint", &"[redacted]")
            .field("provider_identity", &"[redacted]")
            .field("requested_at", &self.ledger.requested_at)
            .finish()
    }
}

#[derive(Debug, Error)]
pub enum AccountDeletionServiceError {
    #[error("account-deletion policy is invalid")]
    InvalidPolicy,
    #[error("account-deletion identity fingerprint is unavailable")]
    Fingerprint(#[from] FingerprintKeyringError),
    #[error("account-deletion storage is unavailable")]
    Storage(#[from] DbError),
    #[error("external deletion ledger is unavailable after local account disable")]
    ExternalizationUnavailable {
        operation: AccountDeletionOperation,
        #[source]
        source: ExternalDeletionLedgerError,
    },
    #[error("account-deletion storage acknowledgement is unavailable after local account disable")]
    PostCommitStorageUnavailable {
        operation: AccountDeletionOperation,
        #[source]
        source: DbError,
    },
    #[error("external deletion ledger is unavailable")]
    ExternalLedger(#[from] ExternalDeletionLedgerError),
    #[error("provider identity coordinates are invalid")]
    ProviderIdentity(#[from] crate::ProviderIdentityCipherError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_requires_ledger_retention_to_cover_security_and_backups() {
        assert!(
            AccountDeletionPolicy::new(
                Duration::from_secs(300),
                2,
                Duration::from_secs(3600),
                12,
                Duration::from_secs(30 * 24 * 60 * 60),
                Duration::from_secs(29 * 24 * 60 * 60),
                Duration::from_secs(7 * 24 * 60 * 60),
            )
            .is_err()
        );
        assert!(
            AccountDeletionPolicy::new(
                Duration::from_secs(300),
                2,
                Duration::from_secs(3600),
                12,
                Duration::from_secs(30 * 24 * 60 * 60),
                Duration::from_secs(400 * 24 * 60 * 60),
                Duration::from_secs(400 * 24 * 60 * 60),
            )
            .is_err()
        );
        assert!(
            AccountDeletionPolicy::new(
                Duration::from_secs(300),
                2,
                Duration::from_secs(3600),
                12,
                Duration::from_secs(30 * 24 * 60 * 60),
                Duration::from_secs(400 * 24 * 60 * 60),
                Duration::from_secs(35 * 24 * 60 * 60),
            )
            .is_ok()
        );
    }
}
