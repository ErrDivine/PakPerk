use thiserror::Error;

use crate::RecommendationMode;

/// Discovery preference policy only. Queue eligibility is intentionally not a
/// parameter, preventing callers from treating this crate as queue authority.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiscoveryPolicy {
    pub personalization_enabled: bool,
    pub preferred_mode: RecommendationMode,
}

impl DiscoveryPolicy {
    pub fn selected_mode(self) -> Result<RecommendationMode, DiscoveryPolicyError> {
        if self.preferred_mode == RecommendationMode::ForYou && !self.personalization_enabled {
            return Err(DiscoveryPolicyError::PersonalizationDisabled);
        }
        Ok(self.preferred_mode)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum DiscoveryPolicyError {
    #[error("personalized discovery is disabled")]
    PersonalizationDisabled,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabling_personalization_removes_only_for_you() {
        for mode in [
            RecommendationMode::Recent,
            RecommendationMode::Following,
            RecommendationMode::Explore,
        ] {
            assert_eq!(
                DiscoveryPolicy {
                    personalization_enabled: false,
                    preferred_mode: mode,
                }
                .selected_mode(),
                Ok(mode)
            );
        }
        assert_eq!(
            DiscoveryPolicy {
                personalization_enabled: false,
                preferred_mode: RecommendationMode::ForYou,
            }
            .selected_mode(),
            Err(DiscoveryPolicyError::PersonalizationDisabled)
        );
    }
}
