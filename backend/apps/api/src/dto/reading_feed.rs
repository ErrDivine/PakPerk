use domain::{LibrarySaveSourceKind, LibraryState, PaperSummary};
use engagement::{BriefStatus, ReadingBrief};
use reading_feed::{
    FeedItemSource, FeedMode, QueueMetadata, ReadingFeedDecision, ReadingFeedPage,
    RecommendationBatchMetadata, RecommendationMetadata, RecommendationMode,
};
use serde::{Deserialize, Serialize};

use super::format_timestamp;

const QUEUE_POLICY_VERSION: &str = "queue_first_v1";

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReadingFeedEnforcementResponse {
    Shadow,
    Strict,
}

impl From<bool> for ReadingFeedEnforcementResponse {
    fn from(enforced: bool) -> Self {
        if enforced { Self::Strict } else { Self::Shadow }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReadingFeedParams {
    pub(crate) category: Option<String>,
    pub(crate) recommendation_mode: Option<RecommendationMode>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
    pub(crate) brief_id: Option<uuid::Uuid>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingFeedQueueResponse {
    pub(crate) state: LibraryState,
    pub(crate) saved_at: String,
    pub(crate) revision: i64,
    pub(crate) save_source_kind: Option<LibrarySaveSourceKind>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingFeedDecisionResponse {
    pub(crate) library_revision: i64,
    pub(crate) active_to_read_count: u64,
    pub(crate) queue_proven_empty: bool,
    pub(crate) policy_version: &'static str,
}

impl From<ReadingFeedDecision> for ReadingFeedDecisionResponse {
    fn from(value: ReadingFeedDecision) -> Self {
        Self {
            library_revision: value.library_revision,
            active_to_read_count: value.active_to_read_count,
            queue_proven_empty: value.queue_proven_empty,
            policy_version: QUEUE_POLICY_VERSION,
        }
    }
}

impl From<QueueMetadata> for ReadingFeedQueueResponse {
    fn from(queue: QueueMetadata) -> Self {
        Self {
            state: queue.state,
            saved_at: format_timestamp(queue.saved_at),
            revision: queue.revision,
            save_source_kind: queue.save_source_kind,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingFeedItemResponse {
    pub(crate) paper: PaperSummary,
    pub(crate) queue: Option<ReadingFeedQueueResponse>,
    pub(crate) source: FeedItemSource,
    pub(crate) recommendation: Option<RecommendationMetadata>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingFeedBatchMetadataResponse {
    pub(crate) profile_revision: Option<i64>,
    pub(crate) feedback_revision: i64,
    pub(crate) algorithm_version: String,
    pub(crate) recommendation_policy_version: String,
}

impl From<RecommendationBatchMetadata> for ReadingFeedBatchMetadataResponse {
    fn from(metadata: RecommendationBatchMetadata) -> Self {
        Self {
            profile_revision: metadata.profile_revision,
            feedback_revision: metadata.feedback_revision,
            algorithm_version: metadata.algorithm_version,
            recommendation_policy_version: metadata.recommendation_policy_version,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) struct ReadingFeedBriefResponse {
    pub(crate) id: uuid::Uuid,
    pub(crate) position: u16,
    pub(crate) total: u16,
    pub(crate) complete: bool,
}

impl From<&ReadingBrief> for ReadingFeedBriefResponse {
    fn from(value: &ReadingBrief) -> Self {
        Self {
            id: value.id,
            position: value.position,
            total: u16::try_from(value.items.len()).unwrap_or(u16::MAX),
            complete: value.status == BriefStatus::Complete,
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct ReadingFeedEnvelope {
    pub(crate) enforcement: ReadingFeedEnforcementResponse,
    pub(crate) mode: FeedMode,
    pub(crate) decision: ReadingFeedDecisionResponse,
    pub(crate) batch_id: Option<uuid::Uuid>,
    pub(crate) batch_metadata: Option<ReadingFeedBatchMetadataResponse>,
    pub(crate) items: Vec<ReadingFeedItemResponse>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) brief: Option<ReadingFeedBriefResponse>,
    pub(crate) server_time: String,
}

impl ReadingFeedEnvelope {
    pub(crate) fn new(
        page: ReadingFeedPage,
        enforced: bool,
        brief: Option<ReadingFeedBriefResponse>,
    ) -> Self {
        Self {
            enforcement: enforced.into(),
            mode: page.mode,
            decision: page.decision.into(),
            batch_id: page.batch_id,
            batch_metadata: page.batch_metadata.map(Into::into),
            items: page
                .items
                .into_iter()
                .map(|item| ReadingFeedItemResponse {
                    paper: item.paper,
                    queue: item.queue.map(Into::into),
                    source: item.source,
                    recommendation: item.recommendation,
                })
                .collect(),
            next_cursor: page.next_cursor,
            brief,
            server_time: format_timestamp(page.server_time),
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone as _, Utc};

    use super::*;

    #[test]
    fn query_is_strict_and_response_never_serializes_an_account_identifier() {
        assert!(
            serde_json::from_value::<ReadingFeedParams>(
                serde_json::json!({"category":"cs.AI","admin":true})
            )
            .is_err()
        );
        let params = serde_json::from_value::<ReadingFeedParams>(serde_json::json!({
            "brief_id":"0198cafa-4db2-75e0-b7cf-a4a30b80d1a1"
        }))
        .unwrap();
        assert_eq!(
            params.brief_id,
            Some(uuid::Uuid::parse_str("0198cafa-4db2-75e0-b7cf-a4a30b80d1a1").unwrap())
        );

        let response = ReadingFeedEnvelope::new(
            ReadingFeedPage {
                mode: FeedMode::Recommendations,
                decision: ReadingFeedDecision {
                    library_revision: 7,
                    active_to_read_count: 0,
                    queue_proven_empty: true,
                },
                batch_id: None,
                batch_metadata: None,
                items: Vec::new(),
                next_cursor: None,
                server_time: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            },
            false,
            None,
        );
        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["enforcement"], "shadow");
        assert_eq!(value["mode"], "recommendations");
        assert_eq!(value["decision"]["library_revision"], 7);
        assert_eq!(value["decision"]["policy_version"], "queue_first_v1");
        assert!(value.get("user_id").is_none());
        assert!(value["batch_metadata"].is_null());
        assert!(value["brief"].is_null());
        assert_eq!(value["server_time"], "2026-08-19T12:00:00.000Z");
    }

    #[test]
    fn strict_enforcement_is_explicit_in_every_response() {
        let response = ReadingFeedEnvelope::new(
            ReadingFeedPage {
                mode: FeedMode::Recommendations,
                decision: ReadingFeedDecision {
                    library_revision: 0,
                    active_to_read_count: 0,
                    queue_proven_empty: true,
                },
                batch_id: None,
                batch_metadata: None,
                items: Vec::new(),
                next_cursor: None,
                server_time: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            },
            true,
            None,
        );

        assert_eq!(
            serde_json::to_value(response).unwrap()["enforcement"],
            "strict"
        );
    }

    #[test]
    fn batch_metadata_serializes_exact_persisted_authority_and_versions() {
        let batch_id = uuid::Uuid::from_u128(77);
        let response = ReadingFeedEnvelope::new(
            ReadingFeedPage {
                mode: FeedMode::Recommendations,
                decision: ReadingFeedDecision {
                    library_revision: 7,
                    active_to_read_count: 0,
                    queue_proven_empty: true,
                },
                batch_id: Some(batch_id),
                batch_metadata: Some(RecommendationBatchMetadata {
                    profile_revision: None,
                    feedback_revision: 4,
                    algorithm_version: "recommendations_v1".to_owned(),
                    recommendation_policy_version: "weighted_v1".to_owned(),
                }),
                items: Vec::new(),
                next_cursor: None,
                server_time: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            },
            true,
            None,
        );

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["batch_id"], batch_id.to_string());
        assert_eq!(
            value["batch_metadata"],
            serde_json::json!({
                "profile_revision": null,
                "feedback_revision": 4,
                "algorithm_version": "recommendations_v1",
                "recommendation_policy_version": "weighted_v1"
            })
        );
    }

    #[test]
    fn persisted_batch_identity_and_next_cursor_are_valid_together() {
        let batch_id = uuid::Uuid::from_u128(77);
        let response = ReadingFeedEnvelope::new(
            ReadingFeedPage {
                mode: FeedMode::Recommendations,
                decision: ReadingFeedDecision {
                    library_revision: 7,
                    active_to_read_count: 0,
                    queue_proven_empty: true,
                },
                batch_id: Some(batch_id),
                batch_metadata: Some(RecommendationBatchMetadata {
                    profile_revision: Some(3),
                    feedback_revision: 4,
                    algorithm_version: "recommendations_v1".to_owned(),
                    recommendation_policy_version: "weighted_v1".to_owned(),
                }),
                items: Vec::new(),
                next_cursor: Some("opaque-page-two".to_owned()),
                server_time: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            },
            true,
            None,
        );

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["batch_id"], batch_id.to_string());
        assert_eq!(value["next_cursor"], "opaque-page-two");
        assert_eq!(value["batch_metadata"]["profile_revision"], 3);
    }
}
