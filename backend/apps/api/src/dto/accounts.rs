use domain::{
    AccountDeletionOperation, AccountDeletionState, AccountStatus, CommunityGuidelinesVersion,
    TermsVersion, User,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::format_timestamp;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum ProfilePatchField<T> {
    #[default]
    Omitted,
    Null,
    Value(T),
}

impl<'de, T> Deserialize<'de> for ProfilePatchField<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        Option::<T>::deserialize(deserializer).map(|value| match value {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

/// Supported compare-and-swap fields for `PATCH /v1/me`. All properties are
/// optional, while an explicit JSON null is meaningful only for
/// `display_name`.
#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ProfileUpdateBody {
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 3,
        max_length = 30,
        pattern = "^[A-Za-z0-9_]+$",
        example = "ada_reader"
    )]
    pub(crate) handle: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        nullable,
        min_length = 1,
        max_length = 80,
        example = "Ada Reader"
    )]
    pub(crate) display_name: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 1,
        max_length = 64,
        pattern = "^[A-Za-z0-9._:-]+$",
        example = "2026-07-31"
    )]
    pub(crate) accept_terms_version: ProfilePatchField<String>,
    #[serde(default)]
    #[schema(
        value_type = String,
        required = false,
        min_length = 1,
        max_length = 64,
        pattern = "^[A-Za-z0-9._:-]+$",
        example = "2026-07-31"
    )]
    pub(crate) accept_community_guidelines_version: ProfilePatchField<String>,
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AccountStatusSchema {
    Active,
    Suspended,
    DeletionPending,
    Deleted,
}

impl From<AccountStatus> for AccountStatusSchema {
    fn from(value: AccountStatus) -> Self {
        match value {
            AccountStatus::Active => Self::Active,
            AccountStatus::Suspended => Self::Suspended,
            AccountStatus::DeletionPending => Self::DeletionPending,
            AccountStatus::Deleted => Self::Deleted,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DeletionVerificationEnvelope {
    pub(crate) account: DeletionVerificationAccount,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DeletionVerificationAccount {
    pub(crate) id: Uuid,
    pub(crate) status: AccountStatusSchema,
    #[schema(required = true, nullable)]
    pub(crate) deletion_operation_id: Option<Uuid>,
}

impl From<account_deletion::DeletionIdentityVerification> for DeletionVerificationEnvelope {
    fn from(value: account_deletion::DeletionIdentityVerification) -> Self {
        Self {
            account: DeletionVerificationAccount {
                id: value.account_id.into_inner(),
                status: value.status.into(),
                deletion_operation_id: value.operation_id,
            },
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountProfileEnvelope {
    pub(crate) account: AccountProfileResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
#[allow(clippy::struct_excessive_bools)] // Wire contract exposes independent onboarding states.
pub(crate) struct AccountProfileResponse {
    pub(crate) id: Uuid,
    #[schema(required = true, nullable)]
    #[schema(min_length = 3, max_length = 30, pattern = "^[a-z0-9_]+$")]
    pub(crate) handle: Option<String>,
    #[schema(required = true, nullable)]
    #[schema(min_length = 1, max_length = 80)]
    pub(crate) display_name: Option<String>,
    pub(crate) status: AccountStatusSchema,
    #[schema(minimum = 1)]
    pub(crate) profile_version: i64,
    pub(crate) profile_complete: bool,
    #[schema(required = true, nullable)]
    pub(crate) terms_version: Option<String>,
    #[schema(required = true, nullable)]
    pub(crate) terms_accepted_at: Option<String>,
    pub(crate) current_terms_version: String,
    pub(crate) terms_current: bool,
    #[schema(required = true, nullable)]
    pub(crate) community_guidelines_version: Option<String>,
    #[schema(required = true, nullable)]
    pub(crate) community_guidelines_accepted_at: Option<String>,
    pub(crate) current_community_guidelines_version: String,
    pub(crate) community_guidelines_current: bool,
    pub(crate) comment_profile_complete: bool,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl AccountProfileEnvelope {
    pub(crate) fn new(
        user: &User,
        current_terms_version: &TermsVersion,
        current_community_guidelines_version: &CommunityGuidelinesVersion,
    ) -> Self {
        Self {
            account: AccountProfileResponse {
                id: *user.id.as_uuid(),
                handle: user.handle.as_ref().map(ToString::to_string),
                display_name: user.display_name.as_ref().map(ToString::to_string),
                status: user.status.into(),
                profile_version: user.profile_version,
                profile_complete: user.profile_complete(current_terms_version),
                terms_version: user.terms_version.as_ref().map(ToString::to_string),
                terms_accepted_at: user.terms_accepted_at.map(format_timestamp),
                current_terms_version: current_terms_version.to_string(),
                terms_current: user.has_accepted_terms(current_terms_version),
                community_guidelines_version: user
                    .community_guidelines_version
                    .as_ref()
                    .map(ToString::to_string),
                community_guidelines_accepted_at: user
                    .community_guidelines_accepted_at
                    .map(format_timestamp),
                current_community_guidelines_version: current_community_guidelines_version
                    .to_string(),
                community_guidelines_current: user
                    .has_accepted_community_guidelines(current_community_guidelines_version),
                comment_profile_complete: user.comment_profile_complete(
                    current_terms_version,
                    current_community_guidelines_version,
                ),
                created_at: format_timestamp(user.created_at),
                updated_at: format_timestamp(user.updated_at),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AccountDeletionStateSchema {
    Requested,
    SessionsRevoked,
    IdentityDeleted,
    AppDataDeleted,
    Completed,
    FailedRetryable,
    FailedTerminal,
}

impl From<AccountDeletionState> for AccountDeletionStateSchema {
    fn from(value: AccountDeletionState) -> Self {
        match value {
            AccountDeletionState::Requested => Self::Requested,
            AccountDeletionState::SessionsRevoked => Self::SessionsRevoked,
            AccountDeletionState::IdentityDeleted => Self::IdentityDeleted,
            AccountDeletionState::AppDataDeleted => Self::AppDataDeleted,
            AccountDeletionState::Completed => Self::Completed,
            AccountDeletionState::FailedRetryable => Self::FailedRetryable,
            AccountDeletionState::FailedTerminal => Self::FailedTerminal,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountDeletionResponse {
    pub(crate) operation_id: Uuid,
    pub(crate) state: AccountDeletionStateSchema,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) requested_at: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) updated_at: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AccountDeletionEnvelope {
    pub(crate) deletion: AccountDeletionResponse,
}

impl From<AccountDeletionOperation> for AccountDeletionEnvelope {
    fn from(operation: AccountDeletionOperation) -> Self {
        Self {
            deletion: AccountDeletionResponse {
                operation_id: operation.operation_id,
                state: operation.state.into(),
                requested_at: format_timestamp(operation.requested_at),
                updated_at: format_timestamp(operation.updated_at),
            },
        }
    }
}
