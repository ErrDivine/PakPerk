use chrono::{DateTime, Utc};
use db::{InteractionEventType, InteractionFeedMode};
use domain::PaperId;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum InteractionEventTypeBody {
    ImpressionQualified,
    AbstractOpened,
    IntroductionCommitted,
    ConnectionsOpened,
    Saved,
    Unsaved,
    MarkedRelevant,
    MarkedNotRelevant,
    Dismissed,
    OpenedOriginal,
    OpenedConnection,
    LibraryStateChanged,
}

impl From<InteractionEventTypeBody> for InteractionEventType {
    fn from(value: InteractionEventTypeBody) -> Self {
        match value {
            InteractionEventTypeBody::ImpressionQualified => Self::ImpressionQualified,
            InteractionEventTypeBody::AbstractOpened => Self::AbstractOpened,
            InteractionEventTypeBody::IntroductionCommitted => Self::IntroductionCommitted,
            InteractionEventTypeBody::ConnectionsOpened => Self::ConnectionsOpened,
            InteractionEventTypeBody::Saved => Self::Saved,
            InteractionEventTypeBody::Unsaved => Self::Unsaved,
            InteractionEventTypeBody::MarkedRelevant => Self::MarkedRelevant,
            InteractionEventTypeBody::MarkedNotRelevant => Self::MarkedNotRelevant,
            InteractionEventTypeBody::Dismissed => Self::Dismissed,
            InteractionEventTypeBody::OpenedOriginal => Self::OpenedOriginal,
            InteractionEventTypeBody::OpenedConnection => Self::OpenedConnection,
            InteractionEventTypeBody::LibraryStateChanged => Self::LibraryStateChanged,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum InteractionFeedModeBody {
    ToRead,
    Recent,
    Following,
    ForYou,
    Explore,
}

impl From<InteractionFeedModeBody> for InteractionFeedMode {
    fn from(value: InteractionFeedModeBody) -> Self {
        match value {
            InteractionFeedModeBody::ToRead => Self::ToRead,
            InteractionFeedModeBody::Recent => Self::Recent,
            InteractionFeedModeBody::Following => Self::Following,
            InteractionFeedModeBody::ForYou => Self::ForYou,
            InteractionFeedModeBody::Explore => Self::Explore,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaperInteractionBody {
    pub(crate) event_id: Uuid,
    pub(crate) event_type: InteractionEventTypeBody,
    #[schema(value_type = uuid::Uuid)]
    pub(crate) paper_id: PaperId,
    #[schema(required = true, nullable)]
    pub(crate) feed_mode: Option<InteractionFeedModeBody>,
    #[schema(required = true, nullable)]
    pub(crate) batch_id: Option<Uuid>,
    #[schema(required = true, nullable, maximum = 10000)]
    pub(crate) position: Option<u32>,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) occurred_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaperInteractionBatchBody {
    #[schema(min_items = 1, max_items = 50)]
    pub(crate) events: Vec<PaperInteractionBody>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct PaperInteractionBatchEnvelope {
    pub(crate) accepted: u32,
    pub(crate) duplicates: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_event() -> serde_json::Value {
        serde_json::json!({
            "event_id": Uuid::now_v7(),
            "event_type": "abstract_opened",
            "paper_id": Uuid::now_v7(),
            "feed_mode": null,
            "batch_id": null,
            "position": null,
            "occurred_at": "2026-08-19T12:00:00Z"
        })
    }

    #[test]
    fn event_schema_rejects_content_and_queue_authority_claims() {
        let mut event = valid_event();
        event["note"] = serde_json::json!("private content");
        assert!(serde_json::from_value::<PaperInteractionBody>(event).is_err());

        let mut event = valid_event();
        event["queue_proven_empty"] = serde_json::json!(true);
        assert!(serde_json::from_value::<PaperInteractionBody>(event).is_err());

        let mut event = valid_event();
        event["reason_codes"] = serde_json::json!(["followed_topic"]);
        assert!(serde_json::from_value::<PaperInteractionBody>(event).is_err());
    }
}
