use serde::{Deserialize, Serialize};

/// Closed, stable reason codes carried by recommendation explanations,
/// reading-feed items, and persisted reading briefs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecommendationReasonCode {
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

impl RecommendationReasonCode {
    pub const ALL: [Self; 14] = [
        Self::RecentCategory,
        Self::FollowedCategory,
        Self::FollowedTopic,
        Self::FollowedAuthor,
        Self::SavedQueryMatch,
        Self::FeedbackCategoryAffinity,
        Self::InferredCategoryAffinity,
        Self::ReviewedPaperSimilarity,
        Self::ArchivedPaperSimilarity,
        Self::ReviewedPaperCitation,
        Self::ArchivedPaperCitation,
        Self::AdjacentTopicExploration,
        Self::UnderrepresentedCategoryExploration,
        Self::DiversitySlot,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::RecentCategory => "recent_category",
            Self::FollowedCategory => "followed_category",
            Self::FollowedTopic => "followed_topic",
            Self::FollowedAuthor => "followed_author",
            Self::SavedQueryMatch => "saved_query_match",
            Self::FeedbackCategoryAffinity => "feedback_category_affinity",
            Self::InferredCategoryAffinity => "inferred_category_affinity",
            Self::ReviewedPaperSimilarity => "reviewed_paper_similarity",
            Self::ArchivedPaperSimilarity => "archived_paper_similarity",
            Self::ReviewedPaperCitation => "reviewed_paper_citation",
            Self::ArchivedPaperCitation => "archived_paper_citation",
            Self::AdjacentTopicExploration => "adjacent_topic_exploration",
            Self::UnderrepresentedCategoryExploration => "underrepresented_category_exploration",
            Self::DiversitySlot => "diversity_slot",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "recent_category" => Some(Self::RecentCategory),
            "followed_category" => Some(Self::FollowedCategory),
            "followed_topic" => Some(Self::FollowedTopic),
            "followed_author" => Some(Self::FollowedAuthor),
            "saved_query_match" => Some(Self::SavedQueryMatch),
            "feedback_category_affinity" => Some(Self::FeedbackCategoryAffinity),
            "inferred_category_affinity" => Some(Self::InferredCategoryAffinity),
            "reviewed_paper_similarity" => Some(Self::ReviewedPaperSimilarity),
            "archived_paper_similarity" => Some(Self::ArchivedPaperSimilarity),
            "reviewed_paper_citation" => Some(Self::ReviewedPaperCitation),
            "archived_paper_citation" => Some(Self::ArchivedPaperCitation),
            "adjacent_topic_exploration" => Some(Self::AdjacentTopicExploration),
            "underrepresented_category_exploration" => {
                Some(Self::UnderrepresentedCategoryExploration)
            }
            "diversity_slot" => Some(Self::DiversitySlot),
            _ => None,
        }
    }

    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::RecentCategory => "Recent in your categories",
            Self::FollowedCategory => "From a followed category",
            Self::FollowedTopic => "Matches a followed topic",
            Self::FollowedAuthor => "From a followed author",
            Self::SavedQueryMatch => "Matches a saved search",
            Self::FeedbackCategoryAffinity => "Based on your relevance feedback",
            Self::InferredCategoryAffinity => "Based on an inferred interest",
            Self::ReviewedPaperSimilarity
            | Self::ArchivedPaperSimilarity
            | Self::ReviewedPaperCitation
            | Self::ArchivedPaperCitation => "Based on your research history",
            Self::AdjacentTopicExploration => "Explore an adjacent topic",
            Self::UnderrepresentedCategoryExploration => "Broaden your research mix",
            Self::DiversitySlot => "Adds variety",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::RecommendationReasonCode;

    #[test]
    fn recommendation_reason_codes_are_an_exact_closed_wire_set() {
        let values = RecommendationReasonCode::ALL
            .map(RecommendationReasonCode::as_str)
            .to_vec();
        assert_eq!(
            values,
            vec![
                "recent_category",
                "followed_category",
                "followed_topic",
                "followed_author",
                "saved_query_match",
                "feedback_category_affinity",
                "inferred_category_affinity",
                "reviewed_paper_similarity",
                "archived_paper_similarity",
                "reviewed_paper_citation",
                "archived_paper_citation",
                "adjacent_topic_exploration",
                "underrepresented_category_exploration",
                "diversity_slot",
            ]
        );
        assert_eq!(
            serde_json::to_value(RecommendationReasonCode::ALL).unwrap(),
            serde_json::json!(values)
        );
        assert!(values.iter().all(|value| {
            RecommendationReasonCode::parse(value).is_some_and(|code| code.as_str() == *value)
        }));
        assert_eq!(
            RecommendationReasonCode::parse("client_forged_reason"),
            None
        );
        assert!(
            serde_json::from_str::<RecommendationReasonCode>("\"client_forged_reason\"").is_err()
        );
    }
}
