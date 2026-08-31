use std::time::Duration;

use crate::DiscoverySearchPolicyError;

const MAX_QUERY_CHARS_HARD: usize = 300;
const MAX_RESULTS_HARD: u32 = 50;
const MAX_SAVED_SEARCHES_HARD: u32 = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiscoverySearchPolicy {
    minimum_query_chars: usize,
    maximum_query_chars: usize,
    maximum_results: u32,
    maximum_saved_searches: u32,
    mutation_limit: u32,
    mutation_window: Duration,
}

impl DiscoverySearchPolicy {
    pub fn new(
        minimum_query_chars: usize,
        maximum_query_chars: usize,
        maximum_results: u32,
        maximum_saved_searches: u32,
        mutation_limit: u32,
        mutation_window: Duration,
    ) -> Result<Self, DiscoverySearchPolicyError> {
        if minimum_query_chars < 2
            || maximum_query_chars > MAX_QUERY_CHARS_HARD
            || minimum_query_chars > maximum_query_chars
        {
            return Err(DiscoverySearchPolicyError::InvalidQueryBounds);
        }
        if maximum_results == 0 || maximum_results > MAX_RESULTS_HARD {
            return Err(DiscoverySearchPolicyError::InvalidResultBounds);
        }
        if maximum_saved_searches == 0 || maximum_saved_searches > MAX_SAVED_SEARCHES_HARD {
            return Err(DiscoverySearchPolicyError::InvalidSavedSearchLimit);
        }
        if mutation_limit == 0
            || mutation_window < Duration::from_secs(1)
            || mutation_window > Duration::from_secs(24 * 60 * 60)
        {
            return Err(DiscoverySearchPolicyError::InvalidMutationPolicy);
        }
        Ok(Self {
            minimum_query_chars,
            maximum_query_chars,
            maximum_results,
            maximum_saved_searches,
            mutation_limit,
            mutation_window,
        })
    }

    #[must_use]
    pub const fn minimum_query_chars(self) -> usize {
        self.minimum_query_chars
    }

    #[must_use]
    pub const fn maximum_query_chars(self) -> usize {
        self.maximum_query_chars
    }

    #[must_use]
    pub const fn maximum_results(self) -> u32 {
        self.maximum_results
    }

    #[must_use]
    pub const fn maximum_saved_searches(self) -> u32 {
        self.maximum_saved_searches
    }

    #[must_use]
    pub const fn mutation_limit(self) -> u32 {
        self.mutation_limit
    }

    #[must_use]
    pub const fn mutation_window(self) -> Duration {
        self.mutation_window
    }
}

impl Default for DiscoverySearchPolicy {
    fn default() -> Self {
        Self::new(2, 300, 50, 50, 60, Duration::from_secs(60 * 60))
            .expect("fixed discovery-search policy must remain valid")
    }
}
