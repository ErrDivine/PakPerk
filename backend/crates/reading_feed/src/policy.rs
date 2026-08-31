use std::time::Duration;

use crate::ReadingFeedPolicyError;

pub const READING_FEED_CURSOR_POLICY_VERSION: u16 = 1;
const MAX_CATEGORY_BYTES: usize = 32;

/// Bounded request and cursor policy shared by every transport adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadingFeedPolicy {
    default_limit: u32,
    max_limit: u32,
    cursor_ttl: Duration,
}

impl ReadingFeedPolicy {
    pub fn new(
        default_limit: u32,
        max_limit: u32,
        cursor_ttl: Duration,
    ) -> Result<Self, ReadingFeedPolicyError> {
        if default_limit == 0 || max_limit == 0 || default_limit > max_limit {
            return Err(ReadingFeedPolicyError::InvalidPageLimits);
        }
        if cursor_ttl.is_zero() || chrono::Duration::from_std(cursor_ttl).is_err() {
            return Err(ReadingFeedPolicyError::InvalidCursorTtl);
        }
        Ok(Self {
            default_limit,
            max_limit,
            cursor_ttl,
        })
    }

    pub fn page_limit(&self, requested: Option<u32>) -> Result<u32, ReadingFeedPolicyError> {
        let limit = requested.unwrap_or(self.default_limit);
        if limit == 0 || limit > self.max_limit {
            return Err(ReadingFeedPolicyError::InvalidPageLimit);
        }
        Ok(limit)
    }

    pub fn category(
        &self,
        requested: Option<&str>,
    ) -> Result<Option<String>, ReadingFeedPolicyError> {
        requested
            .map(|category| {
                if valid_category(category) {
                    Ok(category.to_owned())
                } else {
                    Err(ReadingFeedPolicyError::InvalidCategory)
                }
            })
            .transpose()
    }

    #[must_use]
    pub const fn cursor_ttl(&self) -> Duration {
        self.cursor_ttl
    }

    #[must_use]
    pub const fn default_limit(&self) -> u32 {
        self.default_limit
    }

    #[must_use]
    pub const fn max_limit(&self) -> u32 {
        self.max_limit
    }
}

fn valid_category(category: &str) -> bool {
    let Some((archive, subject)) = category.split_once('.') else {
        return false;
    };
    !archive.is_empty()
        && !subject.is_empty()
        && category.len() <= MAX_CATEGORY_BYTES
        && archive.bytes().all(|byte| byte.is_ascii_lowercase())
        && subject
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_bounds_limits_and_categories() {
        let policy = ReadingFeedPolicy::new(20, 50, Duration::from_secs(86_400)).unwrap();
        assert_eq!(policy.page_limit(None), Ok(20));
        assert_eq!(policy.page_limit(Some(50)), Ok(50));
        assert_eq!(
            policy.page_limit(Some(51)),
            Err(ReadingFeedPolicyError::InvalidPageLimit)
        );
        assert_eq!(policy.category(Some("cs.AI")), Ok(Some("cs.AI".into())));
        assert_eq!(
            policy.category(Some("https://arxiv.org")),
            Err(ReadingFeedPolicyError::InvalidCategory)
        );
    }

    #[test]
    fn policy_rejects_unsafe_configuration() {
        assert_eq!(
            ReadingFeedPolicy::new(0, 50, Duration::from_secs(1)),
            Err(ReadingFeedPolicyError::InvalidPageLimits)
        );
        assert_eq!(
            ReadingFeedPolicy::new(20, 10, Duration::from_secs(1)),
            Err(ReadingFeedPolicyError::InvalidPageLimits)
        );
        assert_eq!(
            ReadingFeedPolicy::new(20, 50, Duration::ZERO),
            Err(ReadingFeedPolicyError::InvalidCursorTtl)
        );
    }
}
