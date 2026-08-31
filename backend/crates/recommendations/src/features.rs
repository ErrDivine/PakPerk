use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Closed, normalized feature vector used by the v1 weighted policy.
///
/// Every value is numeric and content-free. The absence of fields for notes,
/// comment popularity, social status, exact dwell time, institution, or user
/// identity is an intentional privacy boundary.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecommendationFeatures {
    pub semantic_similarity: f32,
    pub topic_overlap: f32,
    pub explicit_follow: f32,
    pub citation_affinity: f32,
    pub recency: f32,
    pub novelty: f32,
    pub repeat_exposure: f32,
    pub negative_feedback: f32,
    pub exploration_slot: f32,
    pub metadata_completeness: f32,
}

impl RecommendationFeatures {
    pub const ZERO: Self = Self {
        semantic_similarity: 0.0,
        topic_overlap: 0.0,
        explicit_follow: 0.0,
        citation_affinity: 0.0,
        recency: 0.0,
        novelty: 0.0,
        repeat_exposure: 0.0,
        negative_feedback: 0.0,
        exploration_slot: 0.0,
        metadata_completeness: 0.0,
    };

    pub fn validate(self) -> Result<Self, FeatureValidationError> {
        for (name, value) in self.named_values() {
            if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                return Err(FeatureValidationError::OutsideUnitInterval(name));
            }
        }
        Ok(self)
    }

    #[must_use]
    pub fn named_values(self) -> [(&'static str, f32); 10] {
        [
            ("semantic_similarity", self.semantic_similarity),
            ("topic_overlap", self.topic_overlap),
            ("explicit_follow", self.explicit_follow),
            ("citation_affinity", self.citation_affinity),
            ("recency", self.recency),
            ("novelty", self.novelty),
            ("repeat_exposure", self.repeat_exposure),
            ("negative_feedback", self.negative_feedback),
            ("exploration_slot", self.exploration_slot),
            ("metadata_completeness", self.metadata_completeness),
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum FeatureValidationError {
    #[error("recommendation feature is outside the closed unit interval")]
    OutsideUnitInterval(&'static str),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_finite_and_out_of_range_values() {
        let invalid = RecommendationFeatures {
            semantic_similarity: f32::NAN,
            ..RecommendationFeatures::ZERO
        };
        assert_eq!(
            invalid.validate(),
            Err(FeatureValidationError::OutsideUnitInterval(
                "semantic_similarity"
            ))
        );
        let invalid = RecommendationFeatures {
            topic_overlap: 1.01,
            ..RecommendationFeatures::ZERO
        };
        assert_eq!(
            invalid.validate(),
            Err(FeatureValidationError::OutsideUnitInterval("topic_overlap"))
        );
    }
}
