//! Content-safe policy boundaries and moderator operations.
//!
//! HTTP code never sends UGC directly to a provider. It passes a validated,
//! redacted-in-debug [`ModerationInput`] through [`ModerationPipeline`].

use std::{fmt, sync::Arc};

use async_trait::async_trait;
use domain::CommentBody;
use thiserror::Error;

mod service;

pub use db::AdminReportResolution;
pub use service::{
    AdminActor, InspectionReport, ModerationActionResult, ModerationInspection,
    ModerationQueuePage, ModerationQueueRecord, ModerationService, ModerationServiceError,
    ReportAgeMetrics, ReportQueuePage, ReportQueueRecord, ReportResolutionResult, UserStatusResult,
};

#[derive(Clone, PartialEq, Eq)]
pub struct ModerationInput {
    body: CommentBody,
}

impl ModerationInput {
    #[must_use]
    pub const fn new(body: CommentBody) -> Self {
        Self { body }
    }

    #[must_use]
    pub const fn body(&self) -> &CommentBody {
        &self.body
    }
}

impl fmt::Debug for ModerationInput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ModerationInput([redacted])")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModerationDecision {
    Publish,
    PendingReview { reason_code: ModerationReasonCode },
    Reject { reason_code: ModerationReasonCode },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ModerationReasonCode(String);

impl ModerationReasonCode {
    pub fn parse(value: impl Into<String>) -> Result<Self, ModerationError> {
        let value = value.into();
        if value.is_empty()
            || value.len() > 64
            || value.trim() != value
            || !value.bytes().all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'_' | b':' | b'-')
            })
        {
            return Err(ModerationError::InvalidReasonCode);
        }
        Ok(Self(value))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ModerationError {
    #[error("moderation provider is unavailable")]
    Unavailable,
    #[error("moderation provider returned an invalid decision")]
    InvalidDecision,
    #[error("moderation reason code is invalid")]
    InvalidReasonCode,
}

#[async_trait]
pub trait ContentModerator: Send + Sync {
    async fn evaluate(&self, input: ModerationInput)
    -> Result<ModerationDecision, ModerationError>;
}

/// Bounded deterministic checks which always run before an optional adapter.
/// The returned reason codes describe rules, never the matched content.
#[derive(Debug, Clone)]
pub struct RuleBasedModerator {
    maximum_repeated_character_run: usize,
    maximum_repeated_token_count: usize,
}

impl Default for RuleBasedModerator {
    fn default() -> Self {
        Self {
            maximum_repeated_character_run: 20,
            maximum_repeated_token_count: 12,
        }
    }
}

#[async_trait]
impl ContentModerator for RuleBasedModerator {
    async fn evaluate(
        &self,
        input: ModerationInput,
    ) -> Result<ModerationDecision, ModerationError> {
        let text = input.body().as_str();
        let lowercase = text.to_lowercase();

        if has_repeated_character_run(text, self.maximum_repeated_character_run)
            || has_repeated_token_spam(&lowercase, self.maximum_repeated_token_count)
            || ["buy now", "free followers", "crypto giveaway"]
                .iter()
                .any(|marker| lowercase.contains(marker))
        {
            return Ok(ModerationDecision::Reject {
                reason_code: ModerationReasonCode::parse("deterministic_spam")?,
            });
        }

        if [
            "doxx",
            "home address",
            "kill yourself",
            "sexual exploitation",
        ]
        .iter()
        .any(|marker| lowercase.contains(marker))
        {
            return Ok(ModerationDecision::PendingReview {
                reason_code: ModerationReasonCode::parse("deterministic_high_risk")?,
            });
        }

        Ok(ModerationDecision::Publish)
    }
}

fn has_repeated_character_run(text: &str, maximum: usize) -> bool {
    let mut previous = None;
    let mut run = 0_usize;
    for character in text.chars() {
        if Some(character) == previous {
            run += 1;
        } else {
            previous = Some(character);
            run = 1;
        }
        if run > maximum {
            return true;
        }
    }
    false
}

fn has_repeated_token_spam(text: &str, maximum: usize) -> bool {
    let mut previous = None;
    let mut run = 0_usize;
    for token in text.split_whitespace() {
        if Some(token) == previous {
            run += 1;
        } else {
            previous = Some(token);
            run = 1;
        }
        if run > maximum {
            return true;
        }
    }
    false
}

/// Deterministic policy plus an optional model/provider adapter. A configured
/// adapter outage is uncertainty and therefore becomes private review, never a
/// public fail-open. With no adapter configured, a deterministic low-risk pass
/// is sufficient for the v0.0 default.
#[derive(Clone)]
pub struct ModerationPipeline {
    rules: RuleBasedModerator,
    adapter: Option<Arc<dyn ContentModerator>>,
}

impl ModerationPipeline {
    #[must_use]
    pub const fn new(adapter: Option<Arc<dyn ContentModerator>>) -> Self {
        Self {
            rules: RuleBasedModerator {
                maximum_repeated_character_run: 20,
                maximum_repeated_token_count: 12,
            },
            adapter,
        }
    }
}

impl Default for ModerationPipeline {
    fn default() -> Self {
        Self::new(None)
    }
}

#[async_trait]
impl ContentModerator for ModerationPipeline {
    async fn evaluate(
        &self,
        input: ModerationInput,
    ) -> Result<ModerationDecision, ModerationError> {
        let deterministic = self.rules.evaluate(input.clone()).await?;
        if !matches!(deterministic, ModerationDecision::Publish) {
            return Ok(deterministic);
        }
        let Some(adapter) = &self.adapter else {
            return Ok(ModerationDecision::Publish);
        };
        match adapter.evaluate(input).await {
            Ok(decision) => Ok(decision),
            Err(_) => Ok(ModerationDecision::PendingReview {
                reason_code: ModerationReasonCode::parse("provider_unavailable")?,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct OfflineAdapter;

    #[async_trait]
    impl ContentModerator for OfflineAdapter {
        async fn evaluate(
            &self,
            _input: ModerationInput,
        ) -> Result<ModerationDecision, ModerationError> {
            Err(ModerationError::Unavailable)
        }
    }

    #[tokio::test]
    async fn deterministic_and_provider_failures_never_publish_risk() {
        let rules = ModerationPipeline::default();
        assert!(matches!(
            rules
                .evaluate(ModerationInput::new(
                    CommentBody::parse("A concise methodological observation.").unwrap()
                ))
                .await
                .unwrap(),
            ModerationDecision::Publish
        ));
        assert!(matches!(
            rules
                .evaluate(ModerationInput::new(
                    CommentBody::parse("home address should be exposed").unwrap()
                ))
                .await
                .unwrap(),
            ModerationDecision::PendingReview { .. }
        ));

        let guarded = ModerationPipeline::new(Some(Arc::new(OfflineAdapter)));
        assert!(matches!(
            guarded
                .evaluate(ModerationInput::new(
                    CommentBody::parse("A concise methodological observation.").unwrap()
                ))
                .await
                .unwrap(),
            ModerationDecision::PendingReview { .. }
        ));
    }

    #[test]
    fn inputs_are_redacted_from_debug() {
        let input = ModerationInput::new(CommentBody::parse("private body").unwrap());
        assert_eq!(format!("{input:?}"), "ModerationInput([redacted])");
    }
}
