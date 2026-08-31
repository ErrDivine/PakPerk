use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{FeatureValidationError, RecommendationFeatures};

pub const SCORING_POLICY_VERSION_V1: &str = "weighted_v1";

/// Versioned, inspectable weights. Positive signals and penalties are kept in
/// separate named fields so monotonicity is directly testable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScoringPolicy {
    pub version: String,
    pub semantic: f32,
    pub topic: f32,
    pub follow: f32,
    pub graph: f32,
    pub recency: f32,
    pub novelty: f32,
    pub metadata_completeness: f32,
    pub seen_penalty: f32,
    pub negative_penalty: f32,
}

impl Default for ScoringPolicy {
    fn default() -> Self {
        Self {
            version: SCORING_POLICY_VERSION_V1.to_owned(),
            semantic: 0.30,
            topic: 0.20,
            follow: 0.25,
            graph: 0.15,
            recency: 0.15,
            novelty: 0.10,
            metadata_completeness: 0.05,
            seen_penalty: 0.30,
            negative_penalty: 1.0,
        }
    }
}

impl ScoringPolicy {
    pub fn validate(&self) -> Result<(), ScoringPolicyError> {
        if self.version != SCORING_POLICY_VERSION_V1 {
            return Err(ScoringPolicyError::UnsupportedVersion);
        }
        for weight in [
            self.semantic,
            self.topic,
            self.follow,
            self.graph,
            self.recency,
            self.novelty,
            self.metadata_completeness,
            self.seen_penalty,
            self.negative_penalty,
        ] {
            if !weight.is_finite() || !(0.0..=4.0).contains(&weight) {
                return Err(ScoringPolicyError::InvalidWeight);
            }
        }
        Ok(())
    }

    pub fn score(&self, features: RecommendationFeatures) -> Result<f32, ScoringPolicyError> {
        self.validate()?;
        features.validate()?;
        Ok(self.semantic.mul_add(
            features.semantic_similarity,
            self.topic.mul_add(
                features.topic_overlap,
                self.follow.mul_add(
                    features.explicit_follow,
                    self.graph.mul_add(
                        features.citation_affinity,
                        self.recency.mul_add(
                            features.recency,
                            self.novelty.mul_add(
                                features.novelty,
                                self.metadata_completeness.mul_add(
                                    features.metadata_completeness,
                                    -(self.seen_penalty * features.repeat_exposure)
                                        - (self.negative_penalty * features.negative_feedback),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
        ))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ScoringPolicyError {
    #[error("unsupported recommendation scoring version")]
    UnsupportedVersion,
    #[error("recommendation scoring weight is invalid")]
    InvalidWeight,
    #[error(transparent)]
    InvalidFeature(#[from] FeatureValidationError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_allowlisted_signal_is_monotonic_in_the_documented_direction() {
        let policy = ScoringPolicy::default();
        let baseline = policy.score(RecommendationFeatures::ZERO).unwrap();
        for positive in [
            RecommendationFeatures {
                semantic_similarity: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                topic_overlap: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                explicit_follow: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                citation_affinity: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                recency: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                novelty: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                metadata_completeness: 1.0,
                ..RecommendationFeatures::ZERO
            },
        ] {
            assert!(policy.score(positive).unwrap() >= baseline);
        }
        for penalty in [
            RecommendationFeatures {
                repeat_exposure: 1.0,
                ..RecommendationFeatures::ZERO
            },
            RecommendationFeatures {
                negative_feedback: 1.0,
                ..RecommendationFeatures::ZERO
            },
        ] {
            assert!(policy.score(penalty).unwrap() <= baseline);
        }
    }
}
