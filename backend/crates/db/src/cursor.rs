use chrono::{DateTime, Utc};
use opaque_cursor::{OpaqueCursorCodec, OpenError, SealError};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

pub(crate) const FEED_CURSOR_PURPOSE: &str = "feed.v1";
pub(crate) const LIBRARY_CURSOR_PURPOSE: &str = "library.v1";
pub(crate) const PUBLIC_COMMENTS_CURSOR_PURPOSE: &str = "comments.public.v1";
pub(crate) const OWN_COMMENTS_CURSOR_PURPOSE: &str = "comments.own.v1";
pub(crate) const BLOCKED_USERS_CURSOR_PURPOSE: &str = "blocked-users.v1";
pub(crate) const MODERATION_COMMENTS_CURSOR_PURPOSE: &str = "moderation.comments.v1";
pub(crate) const MODERATION_REPORTS_CURSOR_PURPOSE: &str = "moderation.reports.v1";
pub(crate) const MODERATION_USER_REPORTS_CURSOR_PURPOSE: &str = "moderation.user-reports.v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FeedCursor {
    pub published_at: DateTime<Utc>,
    pub paper_id: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LibraryCursor {
    pub saved_at: DateTime<Utc>,
    pub paper_id: Uuid,
    /// The first page's committed revision fence. Every later page repeats it
    /// so pagination never absorbs a mutation that happened mid-walk.
    pub sync_revision: i64,
}

/// Newest-first ordering coordinates encrypted behind a purpose- and
/// resource-bound token before crossing any API or operator boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreatedAtCursor {
    pub created_at: DateTime<Utc>,
    pub id: Uuid,
}

#[derive(Debug, Error)]
pub enum CursorError {
    #[error("cursor is invalid or expired")]
    Invalid,
    #[error("cursor could not be issued")]
    Unavailable,
}

impl FeedCursor {
    pub fn encode(
        self,
        codec: &OpaqueCursorCodec,
        category: Option<&str>,
    ) -> Result<String, CursorError> {
        codec
            .seal(FEED_CURSOR_PURPOSE, feed_scope(category), &self)
            .map_err(CursorError::from)
    }

    pub fn decode(
        codec: &OpaqueCursorCodec,
        category: Option<&str>,
        value: &str,
    ) -> Result<Self, CursorError> {
        codec
            .open(FEED_CURSOR_PURPOSE, feed_scope(category), value)
            .map_err(CursorError::from)
    }
}

impl LibraryCursor {
    pub fn encode(self, codec: &OpaqueCursorCodec, scope: &[u8]) -> Result<String, CursorError> {
        codec
            .seal(LIBRARY_CURSOR_PURPOSE, scope, &self)
            .map_err(CursorError::from)
    }

    pub fn decode(
        codec: &OpaqueCursorCodec,
        scope: &[u8],
        value: &str,
    ) -> Result<Self, CursorError> {
        codec
            .open(LIBRARY_CURSOR_PURPOSE, scope, value)
            .map_err(CursorError::from)
    }
}

impl CreatedAtCursor {
    pub fn encode(
        self,
        codec: &OpaqueCursorCodec,
        purpose: &str,
        scope: &[u8],
    ) -> Result<String, CursorError> {
        codec.seal(purpose, scope, &self).map_err(CursorError::from)
    }

    pub fn decode(
        codec: &OpaqueCursorCodec,
        purpose: &str,
        scope: &[u8],
        value: &str,
    ) -> Result<Self, CursorError> {
        codec.open(purpose, scope, value).map_err(CursorError::from)
    }
}

impl From<OpenError> for CursorError {
    fn from(_: OpenError) -> Self {
        Self::Invalid
    }
}

impl From<SealError> for CursorError {
    fn from(_: SealError) -> Self {
        Self::Unavailable
    }
}

fn feed_scope(category: Option<&str>) -> &[u8] {
    category.unwrap_or("").as_bytes()
}

#[cfg(test)]
mod tests {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use chrono::TimeZone as _;

    use super::*;

    #[test]
    fn opaque_cursor_round_trips() {
        let codec = codec();
        let cursor = FeedCursor {
            published_at: Utc.with_ymd_and_hms(2026, 7, 29, 12, 13, 14).unwrap(),
            paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
        };
        let encoded = cursor.encode(&codec, Some("cs.AI")).unwrap();

        assert!(!encoded.contains(['+', '/', '=']));
        assert!(!encoded.contains("published_at"));
        assert_eq!(
            FeedCursor::decode(&codec, Some("cs.AI"), &encoded).unwrap(),
            cursor
        );
        assert!(FeedCursor::decode(&codec, Some("cs.CL"), &encoded).is_err());
    }

    #[test]
    fn malformed_cursor_is_rejected() {
        assert!(FeedCursor::decode(&codec(), None, "not a cursor!").is_err());
    }

    #[test]
    fn library_cursor_round_trips() {
        let codec = codec();
        let cursor = LibraryCursor {
            saved_at: Utc.with_ymd_and_hms(2026, 7, 31, 12, 13, 14).unwrap(),
            paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
            sync_revision: 42,
        };
        let encoded = cursor.encode(&codec, b"user-and-state").unwrap();
        assert_eq!(
            LibraryCursor::decode(&codec, b"user-and-state", &encoded).unwrap(),
            cursor
        );
    }

    #[test]
    fn library_cursor_rejects_unknown_payload_fields() {
        #[derive(Serialize)]
        struct Payload<'a> {
            saved_at: &'a str,
            paper_id: &'a str,
            sync_revision: i64,
            extra: bool,
        }
        let codec = codec();
        let payload = codec
            .seal(
                LIBRARY_CURSOR_PURPOSE,
                b"user-and-state",
                &Payload {
                    saved_at: "2026-07-31T12:13:14Z",
                    paper_id: "0198fa17-3499-7a02-8406-846ab42ba686",
                    sync_revision: 42,
                    extra: true,
                },
            )
            .unwrap();
        assert!(LibraryCursor::decode(&codec, b"user-and-state", &payload).is_err());
    }

    #[test]
    fn created_at_cursor_round_trips() {
        let codec = codec();
        let cursor = CreatedAtCursor {
            created_at: Utc.with_ymd_and_hms(2026, 8, 1, 12, 13, 14).unwrap(),
            id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
        };
        let encoded = cursor
            .encode(&codec, PUBLIC_COMMENTS_CURSOR_PURPOSE, b"paper-id")
            .unwrap();
        assert_eq!(
            CreatedAtCursor::decode(
                &codec,
                PUBLIC_COMMENTS_CURSOR_PURPOSE,
                b"paper-id",
                &encoded,
            )
            .unwrap(),
            cursor
        );
    }

    fn codec() -> OpaqueCursorCodec {
        let key = STANDARD.encode([0x42; 32]);
        OpaqueCursorCodec::parse_keyring(&format!("test_cursor:{key}")).unwrap()
    }
}
