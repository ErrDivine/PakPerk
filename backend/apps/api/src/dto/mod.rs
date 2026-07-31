//! HTTP-only request and response DTOs.

use chrono::{SecondsFormat, Utc};
use domain::{AccountStatus, TermsVersion, User};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub(crate) struct FeedParams {
    pub(crate) category: Option<String>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
pub(crate) struct PrepareBody {
    #[serde(default)]
    pub(crate) retry: bool,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub(crate) struct ChatBody {
    pub(crate) thread_id: Option<Uuid>,
    pub(crate) message: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct ChatResponse {
    pub(crate) thread_id: Uuid,
    pub(crate) generation: domain::ProcessingGeneration,
    #[serde(flatten)]
    pub(crate) answer: domain::ChatAnswer,
}

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
pub(crate) struct AccountProfileEnvelope {
    pub(crate) account: AccountProfileResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
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
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl AccountProfileEnvelope {
    pub(crate) fn new(user: &User, current_terms_version: &TermsVersion) -> Self {
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
                created_at: format_timestamp(user.created_at),
                updated_at: format_timestamp(user.updated_at),
            },
        }
    }
}

fn format_timestamp(value: chrono::DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}
