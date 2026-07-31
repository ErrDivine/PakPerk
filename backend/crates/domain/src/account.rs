use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

const MIN_HANDLE_LENGTH: usize = 3;
const MAX_HANDLE_LENGTH: usize = 30;
const MAX_DISPLAY_NAME_LENGTH: usize = 80;
const MAX_TERMS_VERSION_LENGTH: usize = 64;

const RESERVED_HANDLES: &[&str] = &[
    "admin",
    "administrator",
    "anonymous",
    "api",
    "deleted",
    "help",
    "me",
    "mod",
    "moderator",
    "null",
    "pakperk",
    "root",
    "security",
    "staff",
    "support",
    "system",
    "undefined",
    "www",
];

/// The stable Pakperk identifier derived only after a verified OIDC identity
/// has been mapped to a local user row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AuthenticatedUserId(Uuid);

impl AuthenticatedUserId {
    #[must_use]
    pub const fn new(id: Uuid) -> Self {
        Self(id)
    }

    #[must_use]
    pub const fn into_inner(self) -> Uuid {
        self.0
    }

    #[must_use]
    pub const fn as_uuid(&self) -> &Uuid {
        &self.0
    }
}

impl From<Uuid> for AuthenticatedUserId {
    fn from(value: Uuid) -> Self {
        Self::new(value)
    }
}

impl From<AuthenticatedUserId> for Uuid {
    fn from(value: AuthenticatedUserId) -> Self {
        value.into_inner()
    }
}

impl fmt::Display for AuthenticatedUserId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountStatus {
    Active,
    Suspended,
    DeletionPending,
    Deleted,
}

impl AccountStatus {
    #[must_use]
    pub const fn is_active(self) -> bool {
        matches!(self, Self::Active)
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Suspended => "suspended",
            Self::DeletionPending => "deletion_pending",
            Self::Deleted => "deleted",
        }
    }
}

impl fmt::Display for AccountStatus {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for AccountStatus {
    type Err = AccountStatusParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "active" => Ok(Self::Active),
            "suspended" => Ok(Self::Suspended),
            "deletion_pending" => Ok(Self::DeletionPending),
            "deleted" => Ok(Self::Deleted),
            _ => Err(AccountStatusParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown account status")]
pub struct AccountStatusParseError;

/// A canonical public handle. Keeping this alphabet deliberately narrow makes
/// case-insensitive uniqueness predictable and avoids Unicode-confusable
/// impersonation in the first public release.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct Handle(String);

impl Handle {
    pub fn parse(input: &str) -> Result<Self, HandleValidationError> {
        let trimmed = input.trim();
        if trimmed.contains('@')
            || trimmed.contains('.')
            || trimmed.contains("://")
            || trimmed.to_ascii_lowercase().starts_with("www")
        {
            return Err(HandleValidationError::UrlOrEmail);
        }
        if !trimmed.is_ascii() {
            return Err(HandleValidationError::NonAscii);
        }

        let normalized = trimmed.to_ascii_lowercase();
        let length = normalized.len();
        if !(MIN_HANDLE_LENGTH..=MAX_HANDLE_LENGTH).contains(&length) {
            return Err(HandleValidationError::Length {
                minimum: MIN_HANDLE_LENGTH,
                maximum: MAX_HANDLE_LENGTH,
            });
        }
        if !normalized
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
            || !normalized.bytes().any(|byte| byte.is_ascii_alphanumeric())
        {
            return Err(HandleValidationError::InvalidCharacter);
        }
        if RESERVED_HANDLES.binary_search(&normalized.as_str()).is_ok() {
            return Err(HandleValidationError::Reserved);
        }
        Ok(Self(normalized))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for Handle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for Handle {
    type Err = HandleValidationError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for Handle {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HandleValidationError {
    #[error("handle must contain between {minimum} and {maximum} characters")]
    Length { minimum: usize, maximum: usize },
    #[error("handle must use only ASCII letters, digits, and underscores")]
    InvalidCharacter,
    #[error("handle must use ASCII characters")]
    NonAscii,
    #[error("handle is reserved")]
    Reserved,
    #[error("handle must not be a URL or email address")]
    UrlOrEmail,
}

/// A normalized, bounded display label. This field is optional and is never an
/// authorization identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct DisplayName(String);

impl DisplayName {
    pub fn parse(input: &str) -> Result<Self, DisplayNameValidationError> {
        if input.chars().any(is_unsafe_display_character) {
            return Err(DisplayNameValidationError::UnsafeCharacter);
        }
        let normalized = input
            .nfkc()
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let length = normalized.chars().count();
        if length == 0 || length > MAX_DISPLAY_NAME_LENGTH {
            return Err(DisplayNameValidationError::Length {
                maximum: MAX_DISPLAY_NAME_LENGTH,
            });
        }
        if normalized.chars().any(is_unsafe_display_character) {
            return Err(DisplayNameValidationError::UnsafeCharacter);
        }
        Ok(Self(normalized))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

fn is_unsafe_display_character(character: char) -> bool {
    character.is_control()
        || matches!(
            character,
            '\u{061C}'
                | '\u{200B}'..='\u{200F}'
                | '\u{202A}'..='\u{202E}'
                | '\u{2060}'..='\u{2069}'
                | '\u{FEFF}'
        )
}

impl fmt::Display for DisplayName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for DisplayName {
    type Err = DisplayNameValidationError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for DisplayName {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DisplayNameValidationError {
    #[error("display name must contain between 1 and {maximum} characters")]
    Length { maximum: usize },
    #[error("display name contains an unsafe control or directionality character")]
    UnsafeCharacter,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct TermsVersion(String);

impl TermsVersion {
    pub fn parse(input: &str) -> Result<Self, TermsVersionValidationError> {
        let value = input.trim();
        if value.is_empty() || value.len() > MAX_TERMS_VERSION_LENGTH {
            return Err(TermsVersionValidationError::Length {
                maximum: MAX_TERMS_VERSION_LENGTH,
            });
        }
        if !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b':'))
        {
            return Err(TermsVersionValidationError::InvalidCharacter);
        }
        Ok(Self(value.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for TermsVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for TermsVersion {
    type Err = TermsVersionValidationError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for TermsVersion {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TermsVersionValidationError {
    #[error("terms version must contain between 1 and {maximum} characters")]
    Length { maximum: usize },
    #[error("terms version contains an unsupported character")]
    InvalidCharacter,
}

/// Private account-owner projection. OIDC issuer and subject are deliberately
/// absent so they cannot leak through transport serialization.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct User {
    pub id: AuthenticatedUserId,
    pub handle: Option<Handle>,
    pub display_name: Option<DisplayName>,
    pub status: AccountStatus,
    pub profile_version: i64,
    pub terms_version: Option<TermsVersion>,
    pub terms_accepted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
}

impl User {
    #[must_use]
    pub fn has_accepted_terms(&self, current_version: &TermsVersion) -> bool {
        self.terms_accepted_at.is_some() && self.terms_version.as_ref() == Some(current_version)
    }

    #[must_use]
    pub const fn has_public_handle(&self) -> bool {
        self.handle.is_some()
    }

    #[must_use]
    pub fn profile_complete(&self, current_terms_version: &TermsVersion) -> bool {
        self.status.is_active()
            && self.has_public_handle()
            && self.has_accepted_terms(current_terms_version)
    }

    #[must_use]
    pub fn public_projection(&self) -> PublicUser {
        PublicUser {
            id: self.id,
            handle: self.handle.clone(),
            display_name: self.display_name.clone(),
            status: self.status,
        }
    }
}

/// Bounded author information suitable for later public comment responses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PublicUser {
    pub id: AuthenticatedUserId,
    pub handle: Option<Handle>,
    pub display_name: Option<DisplayName>,
    pub status: AccountStatus,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_normalization_is_narrow_and_case_insensitive() {
        assert_eq!(Handle::parse("  Ada_2026  ").unwrap().as_str(), "ada_2026");
        assert_eq!(
            Handle::parse("Ｓupport").unwrap_err(),
            HandleValidationError::NonAscii
        );
        assert_eq!(
            Handle::parse("support").unwrap_err(),
            HandleValidationError::Reserved
        );
        assert_eq!(
            Handle::parse("ada@example.com").unwrap_err(),
            HandleValidationError::UrlOrEmail
        );
        assert_eq!(
            Handle::parse("https://example").unwrap_err(),
            HandleValidationError::UrlOrEmail
        );
        assert_eq!(
            Handle::parse("___").unwrap_err(),
            HandleValidationError::InvalidCharacter
        );
    }

    #[test]
    fn display_names_are_nfkc_normalized_and_bounded() {
        assert_eq!(
            DisplayName::parse("  Ａda   李  ").unwrap().as_str(),
            "Ada 李"
        );
        assert_eq!(
            DisplayName::parse("Ada\u{202e}resu").unwrap_err(),
            DisplayNameValidationError::UnsafeCharacter
        );
        assert_eq!(
            DisplayName::parse("   ").unwrap_err(),
            DisplayNameValidationError::Length { maximum: 80 }
        );
    }

    #[test]
    fn account_status_and_terms_helpers_are_explicit() {
        for status in [
            AccountStatus::Active,
            AccountStatus::Suspended,
            AccountStatus::DeletionPending,
            AccountStatus::Deleted,
        ] {
            assert_eq!(AccountStatus::from_str(status.as_str()).unwrap(), status);
        }
        let terms = TermsVersion::parse("2026-07-31").unwrap();
        assert_eq!(terms.as_str(), "2026-07-31");
        assert!(TermsVersion::parse("version with spaces").is_err());
    }

    #[test]
    fn validated_strings_cannot_be_bypassed_by_deserialization() {
        assert_eq!(
            serde_json::from_str::<Handle>(r#""Ada_2026""#)
                .unwrap()
                .as_str(),
            "ada_2026"
        );
        assert!(serde_json::from_str::<Handle>(r#""support""#).is_err());
        assert!(serde_json::from_str::<DisplayName>(r#""Ada\u202eresu""#).is_err());
        assert!(serde_json::from_str::<TermsVersion>(r#""bad version""#).is_err());
    }
}
