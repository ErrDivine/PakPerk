use std::time::Duration;

use crate::ResearchProfilePolicyError;

pub const MAX_CATEGORIES_PER_SOURCE: usize = 32;
pub const MAX_TOPICS_PER_SOURCE: usize = 64;
pub const MAX_AUTHORS_PER_SOURCE: usize = 64;
pub const MAX_CLEANUP_BATCH: u32 = 10_000;
pub const PROFILE_OPERATION_RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const MAX_MUTATION_WINDOW: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const MAX_OPERATION_RETENTION: Duration = Duration::from_secs(90 * 24 * 60 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResearchProfilePolicy {
    mutation_limit: u32,
    mutation_window: Duration,
    operation_retention: Duration,
}

impl ResearchProfilePolicy {
    pub fn new(
        mutation_limit: u32,
        mutation_window: Duration,
        operation_retention: Duration,
    ) -> Result<Self, ResearchProfilePolicyError> {
        if mutation_limit == 0 {
            return Err(ResearchProfilePolicyError::InvalidMutationLimit);
        }
        if mutation_window < Duration::from_secs(1) || mutation_window > MAX_MUTATION_WINDOW {
            return Err(ResearchProfilePolicyError::InvalidMutationWindow);
        }
        if operation_retention < Duration::from_secs(24 * 60 * 60)
            || operation_retention > MAX_OPERATION_RETENTION
        {
            return Err(ResearchProfilePolicyError::InvalidOperationRetention);
        }
        Ok(Self {
            mutation_limit,
            mutation_window,
            operation_retention,
        })
    }

    #[must_use]
    pub const fn mutation_limit(self) -> u32 {
        self.mutation_limit
    }

    #[must_use]
    pub const fn mutation_window(self) -> Duration {
        self.mutation_window
    }

    #[must_use]
    pub const fn operation_retention(self) -> Duration {
        self.operation_retention
    }
}

impl Default for ResearchProfilePolicy {
    fn default() -> Self {
        Self::new(
            120,
            Duration::from_secs(60 * 60),
            PROFILE_OPERATION_RETENTION,
        )
        .expect("fixed research-profile policy must remain valid")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_is_bounded_and_privacy_retention_is_finite() {
        let policy = ResearchProfilePolicy::default();
        assert_eq!(policy.mutation_limit(), 120);
        assert_eq!(policy.operation_retention(), PROFILE_OPERATION_RETENTION);
        assert!(
            ResearchProfilePolicy::new(0, Duration::from_secs(1), PROFILE_OPERATION_RETENTION)
                .is_err()
        );
        assert!(
            ResearchProfilePolicy::new(1, Duration::ZERO, PROFILE_OPERATION_RETENTION).is_err()
        );
        assert!(
            ResearchProfilePolicy::new(1, Duration::from_secs(1), Duration::from_secs(60)).is_err()
        );
    }
}
