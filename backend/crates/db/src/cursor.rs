use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use opaque_cursor::{OpaqueCursorCodec, OpenError, SealError};
use reading_feed::{
    CursorCodecError as ReadingFeedCursorCodecError, CursorKeyEpoch, ReadingFeedCursorClaims,
    ReadingFeedCursorCodec,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

pub(crate) const FEED_CURSOR_PURPOSE: &str = "feed.v1";
pub(crate) const LIBRARY_CURSOR_PURPOSE: &str = "library.v1";
pub const READING_FEED_CURSOR_PURPOSE: &str = "reading_feed.v1";
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

/// AES-GCM reading-feed cursor adapter. Tokens are bound to both their
/// dedicated purpose and the authenticated local account through AEAD
/// additional data; the encrypted claims repeat the account as a fail-closed
/// consistency check.
#[derive(Clone)]
pub struct EncryptedReadingFeedCursorCodec {
    codec: OpaqueCursorCodec,
}

impl EncryptedReadingFeedCursorCodec {
    #[must_use]
    pub const fn new(codec: OpaqueCursorCodec) -> Self {
        Self { codec }
    }

    fn key_epoch(&self) -> CursorKeyEpoch {
        CursorKeyEpoch::parse(URL_SAFE_NO_PAD.encode(self.codec.active_key_epoch()))
            .expect("a SHA-256 digest has one canonical 43-byte base64url representation")
    }
}

impl ReadingFeedCursorCodec for EncryptedReadingFeedCursorCodec {
    fn active_key_epoch(&self) -> CursorKeyEpoch {
        self.key_epoch()
    }

    fn seal(
        &self,
        claims: &ReadingFeedCursorClaims,
    ) -> Result<String, ReadingFeedCursorCodecError> {
        if !claims.structurally_valid() || claims.key_epoch != self.key_epoch() {
            return Err(ReadingFeedCursorCodecError::Unavailable);
        }
        self.codec
            .seal(
                READING_FEED_CURSOR_PURPOSE,
                claims.user_id.as_uuid().as_bytes(),
                claims,
            )
            .map_err(|_| ReadingFeedCursorCodecError::Unavailable)
    }

    fn open(
        &self,
        expected_user_id: domain::AuthenticatedUserId,
        token: &str,
        now: DateTime<Utc>,
    ) -> Result<ReadingFeedCursorClaims, ReadingFeedCursorCodecError> {
        let claims: ReadingFeedCursorClaims = self
            .codec
            .open(
                READING_FEED_CURSOR_PURPOSE,
                expected_user_id.as_uuid().as_bytes(),
                token,
            )
            .map_err(|_| ReadingFeedCursorCodecError::Invalid)?;
        if claims.user_id != expected_user_id
            || claims.key_epoch != self.key_epoch()
            || claims.expires_at <= now
            || !claims.structurally_valid()
        {
            return Err(ReadingFeedCursorCodecError::Invalid);
        }
        Ok(claims)
    }
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
    fn reading_feed_cursor_round_trips_every_account_policy_claim() {
        use reading_feed::{
            FeedMode, ReadingFeedCursorOrdering, ReadingFeedCursorPosition, RecommendationPosition,
        };

        let cursor_codec = codec();
        let codec = EncryptedReadingFeedCursorCodec::new(cursor_codec);
        let maximum_category = "cs.AAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        assert_eq!(maximum_category.len(), 32);
        let user_id = domain::AuthenticatedUserId::new(
            Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba686").unwrap(),
        );
        let claims = ReadingFeedCursorClaims {
            user_id,
            mode: FeedMode::Recommendations,
            library_revision: 42,
            ordering: ReadingFeedCursorOrdering::DiscoveryNewestV1,
            position: ReadingFeedCursorPosition::Recommendations {
                position: RecommendationPosition {
                    published_at: Utc.with_ymd_and_hms(2026, 8, 18, 12, 0, 0).unwrap(),
                    paper_id: Uuid::parse_str("0198fa17-3499-7a02-8406-846ab42ba687").unwrap(),
                },
            },
            category: Some(maximum_category.to_owned()),
            recommendation_mode: reading_feed::RecommendationMode::ForYou,
            page_size: 20,
            page_policy_version: 1,
            key_epoch: codec.active_key_epoch(),
            expires_at: Utc.with_ymd_and_hms(2026, 8, 20, 12, 0, 0).unwrap(),
        };

        let encoded = codec.seal(&claims).unwrap();

        assert!(encoded.len() <= opaque_cursor::MAX_TOKEN_BYTES);
        assert!(!encoded.contains(maximum_category));
        assert!(!encoded.contains("0198fa17"));
        assert_eq!(
            codec
                .open(
                    user_id,
                    &encoded,
                    Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
                )
                .unwrap(),
            claims
        );
    }

    #[test]
    fn reading_feed_cursor_rejects_wrong_account_and_expiry() {
        use reading_feed::{FeedMode, ReadingFeedCursorPosition, ToReadPosition};

        let codec = EncryptedReadingFeedCursorCodec::new(codec());
        let user_id = domain::AuthenticatedUserId::new(Uuid::from_u128(1));
        let position = ToReadPosition {
            saved_at: Utc.with_ymd_and_hms(2026, 8, 18, 12, 0, 0).unwrap(),
            paper_id: Uuid::from_u128(9),
        };
        let claims = ReadingFeedCursorClaims {
            user_id,
            mode: FeedMode::ToRead,
            library_revision: 7,
            ordering: reading_feed::ReadingFeedCursorOrdering::QueueFifoV1,
            position: ReadingFeedCursorPosition::ToRead { position },
            category: None,
            recommendation_mode: reading_feed::RecommendationMode::Recent,
            page_size: 20,
            page_policy_version: 1,
            key_epoch: codec.active_key_epoch(),
            expires_at: Utc.with_ymd_and_hms(2026, 8, 20, 12, 0, 0).unwrap(),
        };
        let encoded = codec.seal(&claims).unwrap();

        assert_eq!(
            codec.open(
                domain::AuthenticatedUserId::new(Uuid::from_u128(2)),
                &encoded,
                Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            ),
            Err(ReadingFeedCursorCodecError::Invalid)
        );
        assert_eq!(
            codec.open(
                user_id,
                &encoded,
                Utc.with_ymd_and_hms(2026, 8, 20, 12, 0, 0).unwrap(),
            ),
            Err(ReadingFeedCursorCodecError::Invalid)
        );
    }

    #[test]
    fn reading_feed_cursor_is_invalidated_when_active_key_epoch_changes() {
        use reading_feed::{
            FeedMode, ReadingFeedCursorOrdering, ReadingFeedCursorPosition, ToReadPosition,
        };

        let legacy_key = STANDARD.encode([0x42; 32]);
        let current_key = STANDARD.encode([0x24; 32]);
        let legacy = EncryptedReadingFeedCursorCodec::new(
            OpaqueCursorCodec::parse_keyring(&format!("legacy:{legacy_key}")).unwrap(),
        );
        let user_id = domain::AuthenticatedUserId::new(Uuid::from_u128(1));
        let claims = ReadingFeedCursorClaims {
            user_id,
            mode: FeedMode::ToRead,
            library_revision: 7,
            ordering: ReadingFeedCursorOrdering::QueueFifoV1,
            position: ReadingFeedCursorPosition::ToRead {
                position: ToReadPosition {
                    saved_at: Utc.with_ymd_and_hms(2026, 8, 18, 12, 0, 0).unwrap(),
                    paper_id: Uuid::from_u128(9),
                },
            },
            category: None,
            recommendation_mode: reading_feed::RecommendationMode::Recent,
            page_size: 20,
            page_policy_version: 1,
            key_epoch: legacy.active_key_epoch(),
            expires_at: Utc.with_ymd_and_hms(2026, 8, 20, 12, 0, 0).unwrap(),
        };
        let encoded = legacy.seal(&claims).unwrap();
        let rotated = EncryptedReadingFeedCursorCodec::new(
            OpaqueCursorCodec::parse_keyring(&format!(
                "current:{current_key}\nlegacy:{legacy_key}"
            ))
            .unwrap(),
        );

        assert_eq!(
            rotated.open(
                user_id,
                &encoded,
                Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            ),
            Err(ReadingFeedCursorCodecError::Invalid)
        );
    }

    #[test]
    fn reading_feed_cursor_rejects_unknown_claims_and_wrong_purpose() {
        use reading_feed::{
            FeedMode, ReadingFeedCursorOrdering, ReadingFeedCursorPosition, ToReadPosition,
        };

        let opaque = codec();
        let codec = EncryptedReadingFeedCursorCodec::new(opaque.clone());
        let user_id = domain::AuthenticatedUserId::new(Uuid::from_u128(1));
        let claims = ReadingFeedCursorClaims {
            user_id,
            mode: FeedMode::ToRead,
            library_revision: 7,
            ordering: ReadingFeedCursorOrdering::QueueFifoV1,
            position: ReadingFeedCursorPosition::ToRead {
                position: ToReadPosition {
                    saved_at: Utc.with_ymd_and_hms(2026, 8, 18, 12, 0, 0).unwrap(),
                    paper_id: Uuid::from_u128(9),
                },
            },
            category: None,
            recommendation_mode: reading_feed::RecommendationMode::Recent,
            page_size: 20,
            page_policy_version: 1,
            key_epoch: codec.active_key_epoch(),
            expires_at: Utc.with_ymd_and_hms(2026, 8, 20, 12, 0, 0).unwrap(),
        };
        let mut payload = serde_json::to_value(&claims).unwrap();
        payload
            .as_object_mut()
            .unwrap()
            .insert("unexpected".to_owned(), serde_json::Value::Bool(true));
        let unknown = opaque
            .seal(
                READING_FEED_CURSOR_PURPOSE,
                user_id.as_uuid().as_bytes(),
                &payload,
            )
            .unwrap();
        let wrong_purpose = opaque
            .seal(FEED_CURSOR_PURPOSE, user_id.as_uuid().as_bytes(), &claims)
            .unwrap();

        let now = Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap();
        assert_eq!(
            codec.open(user_id, &unknown, now),
            Err(ReadingFeedCursorCodecError::Invalid)
        );
        assert_eq!(
            codec.open(user_id, &wrong_purpose, now),
            Err(ReadingFeedCursorCodecError::Invalid)
        );
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
