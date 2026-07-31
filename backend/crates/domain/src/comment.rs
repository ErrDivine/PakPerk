use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::{PaperId, PublicUser};

/// Authoritative maximum number of Unicode scalar values in a normalized comment.
pub const COMMENT_MAX_SCALARS: usize = 2_000;
/// Authoritative maximum UTF-8 byte length of a normalized comment.
pub const COMMENT_MAX_BYTES: usize = 8_000;
/// Authoritative maximum number of HTTP(S) URLs in a normalized comment.
pub const COMMENT_MAX_URLS: usize = 3;
const MAX_GUIDELINES_VERSION_LENGTH: usize = 64;
const MAX_REPORT_DETAIL_SCALARS: usize = 500;
const MAX_REPORT_DETAIL_BYTES: usize = 2_000;

/// Validated comment text. Its debug representation is deliberately redacted
/// so deriving `Debug` on containing requests cannot leak public UGC to logs.
#[derive(Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct CommentBody(String);

impl CommentBody {
    pub fn parse(input: &str) -> Result<Self, CommentBodyValidationError> {
        if input.chars().any(|character| {
            is_unsafe_comment_character(character) && !matches!(character, '\n' | '\r' | '\t')
        }) {
            return Err(CommentBodyValidationError::ControlCharacter);
        }

        let canonical_newlines = input.replace("\r\n", "\n").replace('\r', "\n");
        let normalized = canonical_newlines
            .nfkc()
            .collect::<String>()
            .replace('\t', " ");
        if normalized
            .chars()
            .any(|character| is_unsafe_comment_character(character) && character != '\n')
        {
            return Err(CommentBodyValidationError::ControlCharacter);
        }

        let mut lines = Vec::new();
        let mut previous_was_blank = false;
        for line in normalized.trim().lines() {
            let line = line.trim_end();
            if line.trim().is_empty() {
                if !previous_was_blank {
                    lines.push("");
                }
                previous_was_blank = true;
            } else {
                lines.push(line);
                previous_was_blank = false;
            }
        }
        let bounded_blank_lines = lines.join("\n");

        if bounded_blank_lines.trim().is_empty() {
            return Err(CommentBodyValidationError::Empty);
        }
        let scalar_count = bounded_blank_lines.chars().count();
        if scalar_count > COMMENT_MAX_SCALARS || bounded_blank_lines.len() > COMMENT_MAX_BYTES {
            return Err(CommentBodyValidationError::TooLong {
                maximum_scalars: COMMENT_MAX_SCALARS,
                maximum_bytes: COMMENT_MAX_BYTES,
            });
        }
        let lowercase = bounded_blank_lines.to_lowercase();
        let url_count = lowercase.match_indices("http://").count()
            + lowercase.match_indices("https://").count();
        if url_count > COMMENT_MAX_URLS {
            return Err(CommentBodyValidationError::TooManyUrls {
                maximum: COMMENT_MAX_URLS,
            });
        }
        Ok(Self(bounded_blank_lines))
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

fn is_unsafe_comment_character(character: char) -> bool {
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

impl fmt::Debug for CommentBody {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommentBody([redacted])")
    }
}

impl FromStr for CommentBody {
    type Err = CommentBodyValidationError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for CommentBody {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CommentBodyValidationError {
    #[error("comment must not be empty")]
    Empty,
    #[error("comment contains an unsupported control character")]
    ControlCharacter,
    #[error("comment exceeds {maximum_scalars} characters or {maximum_bytes} bytes")]
    TooLong {
        maximum_scalars: usize,
        maximum_bytes: usize,
    },
    #[error("comment contains more than {maximum} URLs")]
    TooManyUrls { maximum: usize },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct CommunityGuidelinesVersion(String);

impl CommunityGuidelinesVersion {
    pub fn parse(input: &str) -> Result<Self, CommunityGuidelinesVersionValidationError> {
        let value = input.trim();
        if value.is_empty() || value.len() > MAX_GUIDELINES_VERSION_LENGTH {
            return Err(CommunityGuidelinesVersionValidationError::Length {
                maximum: MAX_GUIDELINES_VERSION_LENGTH,
            });
        }
        if !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b':'))
        {
            return Err(CommunityGuidelinesVersionValidationError::InvalidCharacter);
        }
        Ok(Self(value.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for CommunityGuidelinesVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for CommunityGuidelinesVersion {
    type Err = CommunityGuidelinesVersionValidationError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for CommunityGuidelinesVersion {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CommunityGuidelinesVersionValidationError {
    #[error("community-guidelines version must contain between 1 and {maximum} characters")]
    Length { maximum: usize },
    #[error("community-guidelines version contains an unsupported character")]
    InvalidCharacter,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommentStatus {
    PendingReview,
    Published,
    Hidden,
    Deleted,
}

impl CommentStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PendingReview => "pending_review",
            Self::Published => "published",
            Self::Hidden => "hidden",
            Self::Deleted => "deleted",
        }
    }
}

impl fmt::Display for CommentStatus {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for CommentStatus {
    type Err = CommentStatusParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "pending_review" => Ok(Self::PendingReview),
            "published" => Ok(Self::Published),
            "hidden" => Ok(Self::Hidden),
            "deleted" => Ok(Self::Deleted),
            _ => Err(CommentStatusParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown comment status")]
pub struct CommentStatusParseError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaperComment {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub author: PublicUser,
    pub body: CommentBody,
    pub status: CommentStatus,
    pub version: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub edited_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CommentPage {
    pub items: Vec<PaperComment>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommentReportReason {
    Spam,
    Harassment,
    Hate,
    Threat,
    SexualContent,
    Privacy,
    Impersonation,
    Copyright,
    Other,
}

impl CommentReportReason {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Spam => "spam",
            Self::Harassment => "harassment",
            Self::Hate => "hate",
            Self::Threat => "threat",
            Self::SexualContent => "sexual_content",
            Self::Privacy => "privacy",
            Self::Impersonation => "impersonation",
            Self::Copyright => "copyright",
            Self::Other => "other",
        }
    }
}

impl FromStr for CommentReportReason {
    type Err = CommentReportReasonParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "spam" => Ok(Self::Spam),
            "harassment" => Ok(Self::Harassment),
            "hate" => Ok(Self::Hate),
            "threat" => Ok(Self::Threat),
            "sexual_content" => Ok(Self::SexualContent),
            "privacy" => Ok(Self::Privacy),
            "impersonation" => Ok(Self::Impersonation),
            "copyright" => Ok(Self::Copyright),
            "other" => Ok(Self::Other),
            _ => Err(CommentReportReasonParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown comment-report reason")]
pub struct CommentReportReasonParseError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommentReportStatus {
    Open,
    Reviewed,
    Actioned,
    Dismissed,
}

impl CommentReportStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Reviewed => "reviewed",
            Self::Actioned => "actioned",
            Self::Dismissed => "dismissed",
        }
    }
}

impl FromStr for CommentReportStatus {
    type Err = CommentReportStatusParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "open" => Ok(Self::Open),
            "reviewed" => Ok(Self::Reviewed),
            "actioned" => Ok(Self::Actioned),
            "dismissed" => Ok(Self::Dismissed),
            _ => Err(CommentReportStatusParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown comment-report status")]
pub struct CommentReportStatusParseError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CommentReportReceipt {
    pub id: Uuid,
    pub comment_id: Uuid,
    pub reason: CommentReportReason,
    pub status: CommentReportStatus,
    pub created_at: DateTime<Utc>,
}

/// Optional reporter context, also redacted from debug output.
#[derive(Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ReportDetail(String);

impl ReportDetail {
    pub fn parse(input: &str) -> Result<Self, ReportDetailValidationError> {
        if input.chars().any(char::is_control) {
            return Err(ReportDetailValidationError::ControlCharacter);
        }
        let normalized = input
            .nfkc()
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if normalized.is_empty()
            || normalized.chars().count() > MAX_REPORT_DETAIL_SCALARS
            || normalized.len() > MAX_REPORT_DETAIL_BYTES
        {
            return Err(ReportDetailValidationError::Length {
                maximum_scalars: MAX_REPORT_DETAIL_SCALARS,
                maximum_bytes: MAX_REPORT_DETAIL_BYTES,
            });
        }
        Ok(Self(normalized))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ReportDetail {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ReportDetail([redacted])")
    }
}

impl<'de> Deserialize<'de> for ReportDetail {
    fn deserialize<Deserializer>(deserializer: Deserializer) -> Result<Self, Deserializer::Error>
    where
        Deserializer: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ReportDetailValidationError {
    #[error(
        "report detail must contain between 1 and {maximum_scalars} characters and at most {maximum_bytes} bytes"
    )]
    Length {
        maximum_scalars: usize,
        maximum_bytes: usize,
    },
    #[error("report detail contains an unsupported control character")]
    ControlCharacter,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BlockedUser {
    pub user: PublicUser,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BlockedUserPage {
    pub items: Vec<BlockedUser>,
    pub next_cursor: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comment_body_is_normalized_bounded_and_debug_redacted() {
        let body = CommentBody::parse("  Ａ useful point\r\n\r\n\r\nnext\tline  ").unwrap();
        assert_eq!(body.as_str(), "A useful point\n\nnext line");
        assert_eq!(format!("{body:?}"), "CommentBody([redacted])");
        assert!(CommentBody::parse("\u{0007}").is_err());
        assert!(CommentBody::parse("direction\u{202e}override").is_err());
        assert!(CommentBody::parse("   \n ").is_err());
        assert_eq!(
            CommentBody::parse("one\n \n\t\n\n two").unwrap().as_str(),
            "one\n\n two"
        );
        assert!(CommentBody::parse(&"x".repeat(COMMENT_MAX_SCALARS + 1)).is_err());
        assert!(
            CommentBody::parse("https://a.test https://b.test https://c.test https://d.test")
                .is_err()
        );
        assert!(
            CommentBody::parse("(HTTPS://a.test),https://b.test;http://c.test,https://d.test")
                .is_err()
        );
    }

    #[test]
    fn fixed_enums_and_versions_are_strict() {
        assert_eq!(
            CommentStatus::from_str("published").unwrap(),
            CommentStatus::Published
        );
        assert!(CommentStatus::from_str("open").is_err());
        assert_eq!(
            CommentReportReason::from_str("sexual_content").unwrap(),
            CommentReportReason::SexualContent
        );
        assert!(CommentReportReason::from_str("dislike").is_err());
        assert_eq!(
            CommentReportStatus::from_str("open").unwrap(),
            CommentReportStatus::Open
        );
        assert!(CommunityGuidelinesVersion::parse("2026-08-01").is_ok());
        assert!(CommunityGuidelinesVersion::parse("bad version").is_err());
    }
}
