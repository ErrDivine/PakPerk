use domain::PaperId;
pub use domain::RecommendationReasonCode as ExplanationCode;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    CandidateSource, GeneratedCandidate, HistoricalRelation, HistoricalSeedState, ReasonEvidence,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecommendationExplanation {
    pub code: ExplanationCode,
    pub title: String,
    pub detail: String,
    pub source: CandidateSource,
    /// True only when the persisted ranking evidence records a behavioral
    /// signal, rather than an explicit preference or public metadata alone.
    pub behavior_used: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed_paper_id: Option<PaperId>,
}

/// Produces immutable, template-only explanations after proving every reason
/// is backed by the candidate's recorded source and feature vector.
pub fn explain_candidate(
    candidate: &GeneratedCandidate,
) -> Result<Vec<RecommendationExplanation>, ExplanationError> {
    candidate
        .features
        .validate()
        .map_err(|_| ExplanationError::InvalidFeature)?;
    if candidate.reasons.is_empty() {
        return Err(ExplanationError::MissingReason);
    }
    candidate
        .reasons
        .iter()
        .map(|reason| explain_reason(candidate, reason))
        .collect()
}

fn explain_reason(
    candidate: &GeneratedCandidate,
    reason: &ReasonEvidence,
) -> Result<RecommendationExplanation, ExplanationError> {
    let explanation = match reason {
        ReasonEvidence::RecentCategory { category } => recent_explanation(candidate, category)?,
        ReasonEvidence::FollowedCategory { category } => {
            followed_category_explanation(candidate, category)?
        }
        ReasonEvidence::FollowedTopic { topic } => followed_topic_explanation(candidate, topic)?,
        ReasonEvidence::FollowedAuthor { author } => {
            followed_author_explanation(candidate, author)?
        }
        ReasonEvidence::SavedQuery { saved_search_id } => {
            saved_query_explanation(candidate, *saved_search_id)?
        }
        ReasonEvidence::FeedbackCategoryAffinity { category } => {
            affinity_explanation(candidate, category, true)?
        }
        ReasonEvidence::InferredCategoryAffinity { category } => {
            affinity_explanation(candidate, category, false)?
        }
        ReasonEvidence::HistoricalSeed {
            paper_id,
            title,
            state,
            relation,
        } => historical_explanation(candidate, *paper_id, title, *state, *relation)?,
        ReasonEvidence::Exploration { role } => exploration_explanation(candidate, *role)?,
        ReasonEvidence::DiversitySlot => {
            require_source(candidate, CandidateSource::Exploration)?;
            require_positive(candidate.features.exploration_slot)?;
            RecommendationExplanation {
                code: ExplanationCode::DiversitySlot,
                title: "Adds variety".to_owned(),
                detail: "This paper fills a controlled diversity slot.".to_owned(),
                source: CandidateSource::Exploration,
                behavior_used: behavior_used(candidate),
                seed_paper_id: None,
            }
        }
    };
    Ok(explanation)
}

fn recent_explanation(
    candidate: &GeneratedCandidate,
    category: &str,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::Recent)?;
    if category != candidate.document.paper.primary_category {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code: ExplanationCode::RecentCategory,
        title: "Recent in your categories".to_owned(),
        detail: format!("A recent paper in {category}."),
        source: CandidateSource::Recent,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn followed_category_explanation(
    candidate: &GeneratedCandidate,
    category: &str,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::CategoryFollow)?;
    require_positive(candidate.features.explicit_follow)?;
    if category != candidate.document.paper.primary_category {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code: ExplanationCode::FollowedCategory,
        title: "From a followed category".to_owned(),
        detail: format!("You follow {category}."),
        source: CandidateSource::CategoryFollow,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn followed_topic_explanation(
    candidate: &GeneratedCandidate,
    topic: &str,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::TopicFollow)?;
    require_positive(candidate.features.explicit_follow)?;
    require_positive(candidate.features.topic_overlap)?;
    if !candidate
        .document
        .topics
        .iter()
        .any(|value| value.eq_ignore_ascii_case(topic))
    {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code: ExplanationCode::FollowedTopic,
        title: "Matches a followed topic".to_owned(),
        detail: format!("It matches your followed topic {topic}."),
        source: CandidateSource::TopicFollow,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn followed_author_explanation(
    candidate: &GeneratedCandidate,
    author: &str,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::AuthorFollow)?;
    require_positive(candidate.features.explicit_follow)?;
    if !candidate
        .document
        .paper
        .authors
        .iter()
        .any(|value| value.eq_ignore_ascii_case(author))
    {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code: ExplanationCode::FollowedAuthor,
        title: "From a followed author".to_owned(),
        detail: format!("You follow {author}."),
        source: CandidateSource::AuthorFollow,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn saved_query_explanation(
    candidate: &GeneratedCandidate,
    saved_search_id: uuid::Uuid,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::SavedQuery)?;
    require_positive(candidate.features.explicit_follow)?;
    if saved_search_id.is_nil() {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code: ExplanationCode::SavedQueryMatch,
        title: "Matches a saved search".to_owned(),
        detail: "This paper matches one of your saved searches.".to_owned(),
        source: CandidateSource::SavedQuery,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn affinity_explanation(
    candidate: &GeneratedCandidate,
    category: &str,
    feedback: bool,
) -> Result<RecommendationExplanation, ExplanationError> {
    let (source, code, title, detail) = if feedback {
        (
            CandidateSource::FeedbackAffinity,
            ExplanationCode::FeedbackCategoryAffinity,
            "Based on your relevance feedback",
            format!("You marked a paper in {category} as relevant."),
        )
    } else {
        (
            CandidateSource::InferredAffinity,
            ExplanationCode::InferredCategoryAffinity,
            "Based on an inferred interest",
            format!("Your inferred interests include {category}."),
        )
    };
    require_source(candidate, source)?;
    require_positive(candidate.features.topic_overlap)?;
    if category != candidate.document.paper.primary_category {
        return Err(ExplanationError::EvidenceMismatch);
    }
    Ok(RecommendationExplanation {
        code,
        title: title.to_owned(),
        detail,
        source,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn exploration_explanation(
    candidate: &GeneratedCandidate,
    role: crate::ExplorationRole,
) -> Result<RecommendationExplanation, ExplanationError> {
    require_source(candidate, CandidateSource::Exploration)?;
    require_positive(candidate.features.exploration_slot)?;
    let (code, title, detail) = match role {
        crate::ExplorationRole::AdjacentTopic => (
            ExplanationCode::AdjacentTopicExploration,
            "Explore an adjacent topic",
            "A controlled exploration outside your usual results.",
        ),
        crate::ExplorationRole::UnderrepresentedCategory => (
            ExplanationCode::UnderrepresentedCategoryExploration,
            "Broaden your research mix",
            "A controlled exploration from an underrepresented category.",
        ),
    };
    Ok(RecommendationExplanation {
        code,
        title: title.to_owned(),
        detail: detail.to_owned(),
        source: CandidateSource::Exploration,
        behavior_used: behavior_used(candidate),
        seed_paper_id: None,
    })
}

fn historical_explanation(
    candidate: &GeneratedCandidate,
    paper_id: PaperId,
    title: &str,
    state: HistoricalSeedState,
    relation: HistoricalRelation,
) -> Result<RecommendationExplanation, ExplanationError> {
    let (source, feature) = match relation {
        HistoricalRelation::Semantic => (
            CandidateSource::Semantic,
            candidate.features.semantic_similarity,
        ),
        HistoricalRelation::Citation => (
            CandidateSource::Citation,
            candidate.features.citation_affinity,
        ),
    };
    require_source(candidate, source)?;
    require_positive(feature)?;
    let (code, state_label) = match (state, relation) {
        (HistoricalSeedState::Reviewed, HistoricalRelation::Semantic) => {
            (ExplanationCode::ReviewedPaperSimilarity, "reviewed")
        }
        (HistoricalSeedState::Archived, HistoricalRelation::Semantic) => {
            (ExplanationCode::ArchivedPaperSimilarity, "archived")
        }
        (HistoricalSeedState::Reviewed, HistoricalRelation::Citation) => {
            (ExplanationCode::ReviewedPaperCitation, "reviewed")
        }
        (HistoricalSeedState::Archived, HistoricalRelation::Citation) => {
            (ExplanationCode::ArchivedPaperCitation, "archived")
        }
    };
    let relation_label = match relation {
        HistoricalRelation::Semantic => "is similar to",
        HistoricalRelation::Citation => "is connected by citations to",
    };
    Ok(RecommendationExplanation {
        code,
        title: "Based on your research history".to_owned(),
        detail: format!("This paper {relation_label} your {state_label} paper ‘{title}’."),
        source,
        behavior_used: behavior_used(candidate),
        seed_paper_id: Some(paper_id),
    })
}

/// Uses only the immutable, content-free feature vector and reason evidence
/// persisted with the candidate. The UI must never infer this value from a
/// display template or source label.
fn behavior_used(candidate: &GeneratedCandidate) -> bool {
    candidate.features.repeat_exposure > 0.0
        || candidate.features.negative_feedback > 0.0
        || candidate.reasons.iter().any(|reason| {
            matches!(
                reason,
                ReasonEvidence::FeedbackCategoryAffinity { .. }
                    | ReasonEvidence::InferredCategoryAffinity { .. }
                    | ReasonEvidence::HistoricalSeed { .. }
            )
        })
}

fn require_source(
    candidate: &GeneratedCandidate,
    source: CandidateSource,
) -> Result<(), ExplanationError> {
    if candidate.sources.contains(&source) {
        Ok(())
    } else {
        Err(ExplanationError::EvidenceMismatch)
    }
}

fn require_positive(value: f32) -> Result<(), ExplanationError> {
    if value > 0.0 {
        Ok(())
    } else {
        Err(ExplanationError::EvidenceMismatch)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ExplanationError {
    #[error("recommendation has no recorded reason")]
    MissingReason,
    #[error("recommendation reason does not match recorded evidence")]
    EvidenceMismatch,
    #[error("recommendation explanation feature is invalid")]
    InvalidFeature,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::candidates::tests::document;
    use crate::{ReasonEvidence, RecommendationFeatures};

    use super::*;

    #[test]
    fn refuses_a_reason_without_the_feature_and_source_that_created_it() {
        let candidate = GeneratedCandidate {
            document: document(1, "cs.CL"),
            sources: BTreeSet::from([CandidateSource::Recent]),
            features: RecommendationFeatures::ZERO,
            reasons: vec![ReasonEvidence::FollowedCategory {
                category: "cs.CL".to_owned(),
            }],
            qualified_impressions: 0,
            hidden: false,
            negative_feedback: false,
        };
        assert_eq!(
            explain_candidate(&candidate),
            Err(ExplanationError::EvidenceMismatch)
        );
    }

    #[test]
    fn inactive_seed_explanation_retains_exact_seed_identity_and_state() {
        let mut candidate = GeneratedCandidate {
            document: document(1, "cs.CL"),
            sources: BTreeSet::from([CandidateSource::Semantic]),
            features: RecommendationFeatures {
                semantic_similarity: 0.8,
                ..RecommendationFeatures::ZERO
            },
            reasons: vec![ReasonEvidence::HistoricalSeed {
                paper_id: PaperId::from_u128(77),
                title: "A retained result".to_owned(),
                state: HistoricalSeedState::Archived,
                relation: HistoricalRelation::Semantic,
            }],
            qualified_impressions: 0,
            hidden: false,
            negative_feedback: false,
        };
        let explanations = explain_candidate(&candidate).unwrap();
        assert_eq!(
            explanations[0].code,
            ExplanationCode::ArchivedPaperSimilarity
        );
        assert_eq!(explanations[0].seed_paper_id, Some(PaperId::from_u128(77)));
        assert!(explanations[0].behavior_used);

        candidate.sources.clear();
        assert_eq!(
            explain_candidate(&candidate),
            Err(ExplanationError::EvidenceMismatch)
        );
    }

    #[test]
    fn behavior_flag_comes_from_actual_candidate_evidence() {
        let mut candidate = GeneratedCandidate {
            document: document(1, "cs.CL"),
            sources: BTreeSet::from([CandidateSource::Recent]),
            features: RecommendationFeatures::ZERO,
            reasons: vec![ReasonEvidence::RecentCategory {
                category: "cs.CL".to_owned(),
            }],
            qualified_impressions: 0,
            hidden: false,
            negative_feedback: false,
        };
        assert!(!explain_candidate(&candidate).unwrap()[0].behavior_used);

        candidate.features.repeat_exposure = 0.4;
        candidate.qualified_impressions = 2;
        assert!(explain_candidate(&candidate).unwrap()[0].behavior_used);
    }
}
