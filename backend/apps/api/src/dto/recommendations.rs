use db::{RecommendationFeedbackReason, RecommendationFeedbackType};
use domain::PaperId;
use recommendations::{CandidateSource, ExplanationCode, RecommendationExplanation};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationFeedbackTypeBody {
    Relevant,
    NotRelevant,
    Dismissed,
}

impl From<RecommendationFeedbackTypeBody> for RecommendationFeedbackType {
    fn from(value: RecommendationFeedbackTypeBody) -> Self {
        match value {
            RecommendationFeedbackTypeBody::Relevant => Self::Relevant,
            RecommendationFeedbackTypeBody::NotRelevant => Self::NotRelevant,
            RecommendationFeedbackTypeBody::Dismissed => Self::Dismissed,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationFeedbackReasonBody {
    AlreadySeen,
    OffTopic,
    TooBasic,
    TooAdvanced,
    LowQuality,
    Other,
}

impl From<RecommendationFeedbackReasonBody> for RecommendationFeedbackReason {
    fn from(value: RecommendationFeedbackReasonBody) -> Self {
        match value {
            RecommendationFeedbackReasonBody::AlreadySeen => Self::AlreadySeen,
            RecommendationFeedbackReasonBody::OffTopic => Self::OffTopic,
            RecommendationFeedbackReasonBody::TooBasic => Self::TooBasic,
            RecommendationFeedbackReasonBody::TooAdvanced => Self::TooAdvanced,
            RecommendationFeedbackReasonBody::LowQuality => Self::LowQuality,
            RecommendationFeedbackReasonBody::Other => Self::Other,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct RecommendationFeedbackBody {
    #[schema(value_type = uuid::Uuid)]
    pub(crate) paper_id: PaperId,
    pub(crate) feedback_type: RecommendationFeedbackTypeBody,
    pub(crate) reason: Option<RecommendationFeedbackReasonBody>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RecommendationFeedbackEnvelope {
    pub(crate) feedback_id: Uuid,
    pub(crate) replayed: bool,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationExplanationCodeResponse {
    RecentCategory,
    FollowedCategory,
    FollowedTopic,
    FollowedAuthor,
    SavedQueryMatch,
    FeedbackCategoryAffinity,
    InferredCategoryAffinity,
    ReviewedPaperSimilarity,
    ArchivedPaperSimilarity,
    ReviewedPaperCitation,
    ArchivedPaperCitation,
    AdjacentTopicExploration,
    UnderrepresentedCategoryExploration,
    DiversitySlot,
}

impl From<ExplanationCode> for RecommendationExplanationCodeResponse {
    fn from(value: ExplanationCode) -> Self {
        match value {
            ExplanationCode::RecentCategory => Self::RecentCategory,
            ExplanationCode::FollowedCategory => Self::FollowedCategory,
            ExplanationCode::FollowedTopic => Self::FollowedTopic,
            ExplanationCode::FollowedAuthor => Self::FollowedAuthor,
            ExplanationCode::SavedQueryMatch => Self::SavedQueryMatch,
            ExplanationCode::FeedbackCategoryAffinity => Self::FeedbackCategoryAffinity,
            ExplanationCode::InferredCategoryAffinity => Self::InferredCategoryAffinity,
            ExplanationCode::ReviewedPaperSimilarity => Self::ReviewedPaperSimilarity,
            ExplanationCode::ArchivedPaperSimilarity => Self::ArchivedPaperSimilarity,
            ExplanationCode::ReviewedPaperCitation => Self::ReviewedPaperCitation,
            ExplanationCode::ArchivedPaperCitation => Self::ArchivedPaperCitation,
            ExplanationCode::AdjacentTopicExploration => Self::AdjacentTopicExploration,
            ExplanationCode::UnderrepresentedCategoryExploration => {
                Self::UnderrepresentedCategoryExploration
            }
            ExplanationCode::DiversitySlot => Self::DiversitySlot,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RecommendationSourceResponse {
    Recent,
    CategoryFollow,
    TopicFollow,
    AuthorFollow,
    SavedQuery,
    FeedbackAffinity,
    InferredAffinity,
    Semantic,
    Citation,
    Exploration,
}

impl From<CandidateSource> for RecommendationSourceResponse {
    fn from(value: CandidateSource) -> Self {
        match value {
            CandidateSource::Recent => Self::Recent,
            CandidateSource::CategoryFollow => Self::CategoryFollow,
            CandidateSource::TopicFollow => Self::TopicFollow,
            CandidateSource::AuthorFollow => Self::AuthorFollow,
            CandidateSource::SavedQuery => Self::SavedQuery,
            CandidateSource::FeedbackAffinity => Self::FeedbackAffinity,
            CandidateSource::InferredAffinity => Self::InferredAffinity,
            CandidateSource::Semantic => Self::Semantic,
            CandidateSource::Citation => Self::Citation,
            CandidateSource::Exploration => Self::Exploration,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RecommendationExplanationResponse {
    pub(crate) code: RecommendationExplanationCodeResponse,
    pub(crate) title: String,
    pub(crate) detail: String,
    pub(crate) source: RecommendationSourceResponse,
    pub(crate) behavior_used: bool,
    #[schema(value_type = Option<uuid::Uuid>)]
    pub(crate) seed_paper_id: Option<PaperId>,
}

impl From<RecommendationExplanation> for RecommendationExplanationResponse {
    fn from(value: RecommendationExplanation) -> Self {
        Self {
            code: value.code.into(),
            title: value.title,
            detail: value.detail,
            source: value.source.into(),
            behavior_used: value.behavior_used,
            seed_paper_id: value.seed_paper_id,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct RecommendationExplanationEnvelope {
    pub(crate) batch_id: Uuid,
    #[schema(value_type = uuid::Uuid)]
    pub(crate) paper_id: PaperId,
    pub(crate) explanations: Vec<RecommendationExplanationResponse>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feedback_body_is_closed_and_does_not_accept_explanation_or_queue_claims() {
        assert!(
            serde_json::from_value::<RecommendationFeedbackBody>(serde_json::json!({
                "paper_id": Uuid::now_v7(),
                "feedback_type": "not_relevant",
                "reason": "off_topic",
                "queue_proven_empty": true
            }))
            .is_err()
        );
    }

    #[test]
    fn explanation_response_serializes_closed_saved_query_values() {
        let response = RecommendationExplanationResponse::from(RecommendationExplanation {
            code: ExplanationCode::SavedQueryMatch,
            title: "Matches a saved search".to_owned(),
            detail: "This paper matches one of your saved searches.".to_owned(),
            source: CandidateSource::SavedQuery,
            behavior_used: false,
            seed_paper_id: None,
        });
        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["code"], "saved_query_match");
        assert_eq!(value["source"], "saved_query");
        assert_eq!(value["behavior_used"], false);
    }
}
