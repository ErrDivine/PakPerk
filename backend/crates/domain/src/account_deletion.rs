use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Stable state names exposed by the deletion API and operator tooling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountDeletionState {
    Requested,
    SessionsRevoked,
    IdentityDeleted,
    AppDataDeleted,
    Completed,
    FailedRetryable,
    FailedTerminal,
}

impl AccountDeletionState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::SessionsRevoked => "sessions_revoked",
            Self::IdentityDeleted => "identity_deleted",
            Self::AppDataDeleted => "app_data_deleted",
            Self::Completed => "completed",
            Self::FailedRetryable => "failed_retryable",
            Self::FailedTerminal => "failed_terminal",
        }
    }

    #[must_use]
    pub const fn is_finished(self) -> bool {
        matches!(self, Self::Completed | Self::FailedTerminal)
    }
}

impl fmt::Display for AccountDeletionState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for AccountDeletionState {
    type Err = AccountDeletionStateParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "requested" => Ok(Self::Requested),
            "sessions_revoked" => Ok(Self::SessionsRevoked),
            "identity_deleted" => Ok(Self::IdentityDeleted),
            "app_data_deleted" => Ok(Self::AppDataDeleted),
            "completed" => Ok(Self::Completed),
            "failed_retryable" => Ok(Self::FailedRetryable),
            "failed_terminal" => Ok(Self::FailedTerminal),
            _ => Err(AccountDeletionStateParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("account-deletion state is invalid")]
pub struct AccountDeletionStateParseError;

/// A keyed, provider-neutral identity tombstone. Debug output deliberately
/// hides both the key identifier and digest because either can help correlate
/// an erased identity across systems.
#[derive(Clone, PartialEq, Eq)]
pub struct IdentityFingerprint {
    key_id: String,
    digest: [u8; 32],
}

impl IdentityFingerprint {
    pub fn new(
        key_id: impl Into<String>,
        digest: [u8; 32],
    ) -> Result<Self, IdentityFingerprintError> {
        let key_id = key_id.into();
        if key_id.is_empty()
            || key_id.len() > 64
            || key_id.trim() != key_id
            || !key_id.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
            })
        {
            return Err(IdentityFingerprintError::InvalidKeyId);
        }
        Ok(Self { key_id, digest })
    }

    #[must_use]
    pub fn key_id(&self) -> &str {
        &self.key_id
    }

    #[must_use]
    pub const fn digest(&self) -> &[u8; 32] {
        &self.digest
    }

    /// Stable signed integer used only as a `PostgreSQL` transaction-advisory
    /// lock key. Collisions merely serialize unrelated identities.
    #[must_use]
    pub fn advisory_lock_key(&self) -> i64 {
        i64::from_be_bytes(self.digest[..8].try_into().expect("fixed digest length"))
    }
}

impl fmt::Debug for IdentityFingerprint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IdentityFingerprint")
            .field("value", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum IdentityFingerprintError {
    #[error("identity-fingerprint key identifier is invalid")]
    InvalidKeyId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDeletionOperation {
    pub operation_id: Uuid,
    pub state: AccountDeletionState,
    pub requested_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_names_are_exact_and_round_trip() {
        for state in [
            AccountDeletionState::Requested,
            AccountDeletionState::SessionsRevoked,
            AccountDeletionState::IdentityDeleted,
            AccountDeletionState::AppDataDeleted,
            AccountDeletionState::Completed,
            AccountDeletionState::FailedRetryable,
            AccountDeletionState::FailedTerminal,
        ] {
            assert_eq!(state.as_str().parse(), Ok(state));
        }
        assert!("running".parse::<AccountDeletionState>().is_err());
    }

    #[test]
    fn fingerprint_debug_is_redacted() {
        let fingerprint = IdentityFingerprint::new("primary_1", [0x42; 32]).unwrap();
        let rendered = format!("{fingerprint:?}");
        assert!(!rendered.contains("primary_1"));
        assert!(!rendered.contains("42"));
        assert_eq!(fingerprint.advisory_lock_key(), 0x4242_4242_4242_4242_i64);
    }
}
