use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration, SectionKind};

pub const ASSISTANT_QUESTION_MAX_SCALARS: usize = 500;
pub const ASSISTANT_ANSWER_MAX_SCALARS: usize = 6_000;
/// Claim text is the only provider-authored prose allowed in a supported or
/// partial rendered answer. Keeping the separator fixed lets every boundary
/// verify the redundant top-level `answer` without trying to classify prose.
pub const ASSISTANT_CLAIM_SEPARATOR: &str = "\n\n";
/// A claim-free answer is an explicit server-approved abstention, never free
/// provider prose that could smuggle an unsupported material statement.
pub const ASSISTANT_NOT_FOUND_ANSWER: &str = "Not found in this paper.";
/// Closed, non-factual status metadata for a partially supported answer.
/// Paper-specific caveats must be evidence-backed claims instead.
pub const ASSISTANT_PARTIAL_LIMITATION: &str =
    "Only claim-backed portions of the requested answer are shown.";
pub const ASSISTANT_SCOPE_MAX_OBJECTS: usize = 8;
pub const ASSISTANT_SCOPE_MAX_SECTIONS: usize = 12;
pub const ASSISTANT_FEEDBACK_DETAIL_MAX_SCALARS: usize = 1_000;
pub const ASSISTANT_FEEDBACK_MAX_CLAIMS: u8 = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantScopeKind {
    Paper,
    Section,
    Selection,
    Figure,
    Table,
    Equation,
    PassportField,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantAnswerStyle {
    Concise,
    Detailed,
    Beginner,
    Expert,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantTextSelection {
    pub block_id: Uuid,
    /// Inclusive Unicode-scalar offset.
    pub start: u32,
    /// Exclusive Unicode-scalar offset.
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantScope {
    pub kind: AssistantScopeKind,
    #[serde(default)]
    pub section_kinds: Vec<SectionKind>,
    #[serde(default)]
    pub object_ids: Vec<Uuid>,
    pub selection: Option<AssistantTextSelection>,
    pub passport_field: Option<String>,
}

impl AssistantScope {
    fn validate(&self) -> Result<(), AssistantRequestValidationError> {
        if self.section_kinds.len() > ASSISTANT_SCOPE_MAX_SECTIONS
            || self.object_ids.len() > ASSISTANT_SCOPE_MAX_OBJECTS
            || self.section_kinds.iter().collect::<HashSet<_>>().len() != self.section_kinds.len()
            || self.object_ids.iter().collect::<HashSet<_>>().len() != self.object_ids.len()
        {
            return Err(AssistantRequestValidationError::InvalidScope);
        }
        let valid = match self.kind {
            AssistantScopeKind::Paper => {
                self.section_kinds.is_empty()
                    && self.selection.is_none()
                    && self.passport_field.is_none()
                    && self.object_ids.is_empty()
            }
            AssistantScopeKind::Section => {
                !self.section_kinds.is_empty()
                    && self.object_ids.is_empty()
                    && self.selection.is_none()
                    && self.passport_field.is_none()
            }
            AssistantScopeKind::Selection => {
                self.section_kinds.is_empty()
                    && self.selection.as_ref().is_some_and(|selection| {
                        !selection.block_id.is_nil() && selection.start < selection.end
                    })
                    && self.object_ids.is_empty()
                    && self.passport_field.is_none()
            }
            AssistantScopeKind::Figure
            | AssistantScopeKind::Table
            | AssistantScopeKind::Equation => {
                self.section_kinds.is_empty()
                    && !self.object_ids.is_empty()
                    && self.object_ids.iter().all(|id| !id.is_nil())
                    && self.selection.is_none()
                    && self.passport_field.is_none()
            }
            AssistantScopeKind::PassportField => {
                self.section_kinds.is_empty()
                    && self.object_ids.is_empty()
                    && self.selection.is_none()
                    && self.passport_field.as_deref().is_some_and(valid_field_key)
            }
        };
        valid
            .then_some(())
            .ok_or(AssistantRequestValidationError::InvalidScope)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantRequest {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub question: String,
    pub scope: AssistantScope,
    pub answer_style: AssistantAnswerStyle,
    pub thread_id: Option<Uuid>,
}

impl AssistantRequest {
    pub fn validate(&self) -> Result<(), AssistantRequestValidationError> {
        let question = self.question.trim();
        if self.paper_id.is_nil()
            || self.generation <= 0
            || question.is_empty()
            || question.chars().count() > ASSISTANT_QUESTION_MAX_SCALARS
            || question.contains('\0')
            || self.thread_id.is_some_and(|id| id.is_nil())
        {
            return Err(AssistantRequestValidationError::InvalidQuestionOrGeneration);
        }
        self.scope.validate()
    }
}

impl std::fmt::Debug for AssistantRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssistantRequest")
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("question", &"[REDACTED]")
            .field("scope", &self.scope)
            .field("answer_style", &self.answer_style)
            .field("thread_id", &self.thread_id)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantAnswerStatus {
    Supported,
    Partial,
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantClaimSupport {
    Direct,
    Inferred,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantEvidenceReference {
    pub block_id: Uuid,
    /// Inclusive Unicode-scalar offset into the trusted block text.
    pub start: u32,
    /// Exclusive Unicode-scalar offset into the trusted block text.
    pub end: u32,
    pub page_start: Option<u32>,
    pub section: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantClaim {
    pub text: String,
    pub support: AssistantClaimSupport,
    pub evidence: Vec<AssistantEvidenceReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantAnswer {
    pub answer: String,
    pub status: AssistantAnswerStatus,
    pub claims: Vec<AssistantClaim>,
    #[serde(default)]
    pub limitations: Vec<String>,
    pub provenance_id: Uuid,
    pub model_id: Option<String>,
    pub provider_request_id: Option<String>,
    pub prompt_version: String,
}

impl AssistantAnswer {
    /// Verifies that all rendered answer prose is either a validated claim or
    /// the fixed claim-free abstention, and that no provider-authored field can
    /// introduce a link. Evidence navigation is supplied separately from
    /// trusted server records.
    #[must_use]
    pub fn has_valid_rendered_contract(&self) -> bool {
        canonical_assistant_answer(self.status, &self.claims)
            .is_some_and(|canonical| canonical == self.answer)
            && !assistant_text_contains_link(&self.answer)
            && self
                .claims
                .iter()
                .all(|claim| !assistant_text_contains_link(&claim.text))
            && self
                .limitations
                .iter()
                .all(|limitation| !assistant_text_contains_link(limitation))
            && assistant_limitations_are_canonical(self.status, &self.limitations)
    }
}

fn assistant_limitations_are_canonical(
    status: AssistantAnswerStatus,
    limitations: &[String],
) -> bool {
    match status {
        AssistantAnswerStatus::Partial => {
            limitations.len() == 1 && limitations[0] == ASSISTANT_PARTIAL_LIMITATION
        }
        AssistantAnswerStatus::Supported | AssistantAnswerStatus::NotFound => {
            limitations.is_empty()
        }
    }
}

/// Builds the sole valid rendered answer for a status/claim pair.
///
/// `partial` still requires at least one supported claim; a completely
/// unsupported response is represented by `not_found` and the fixed
/// abstention string.
#[must_use]
pub fn canonical_assistant_answer(
    status: AssistantAnswerStatus,
    claims: &[AssistantClaim],
) -> Option<String> {
    match status {
        AssistantAnswerStatus::Supported | AssistantAnswerStatus::Partial if !claims.is_empty() => {
            Some(
                claims
                    .iter()
                    .map(|claim| claim.text.as_str())
                    .collect::<Vec<_>>()
                    .join(ASSISTANT_CLAIM_SEPARATOR),
            )
        }
        AssistantAnswerStatus::NotFound if claims.is_empty() => {
            Some(ASSISTANT_NOT_FOUND_ANSWER.to_owned())
        }
        AssistantAnswerStatus::Supported
        | AssistantAnswerStatus::Partial
        | AssistantAnswerStatus::NotFound => None,
    }
}

/// Provider-authored links are not part of Assistant v2. This intentionally
/// rejects URL schemes, Markdown destinations, and common bare-web prefixes;
/// trusted source navigation travels in typed evidence metadata instead.
#[must_use]
pub fn assistant_text_contains_link(value: &str) -> bool {
    let lowercase = value.to_ascii_lowercase();
    [
        "://",
        "www.",
        "](",
        "mailto:",
        "tel:",
        "file:",
        "data:",
        "javascript:",
        "vbscript:",
    ]
    .iter()
    .any(|marker| lowercase.contains(marker))
}

/// Closed, evidence-specific quality labels. Generic sentiment is
/// intentionally absent so this signal cannot become a thumbs-up proxy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantEvidenceFeedbackType {
    IncorrectCitation,
    EvidenceDoesNotSupportClaim,
    MissingEvidence,
    IncorrectSupportLabel,
    IncorrectSourceLocation,
}

impl AssistantEvidenceFeedbackType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::IncorrectCitation => "incorrect_citation",
            Self::EvidenceDoesNotSupportClaim => "evidence_does_not_support_claim",
            Self::MissingEvidence => "missing_evidence",
            Self::IncorrectSupportLabel => "incorrect_support_label",
            Self::IncorrectSourceLocation => "incorrect_source_location",
        }
    }

    #[must_use]
    pub const fn requires_claim(self) -> bool {
        !matches!(self, Self::MissingEvidence)
    }

    #[must_use]
    pub const fn requires_evidence_block(self) -> bool {
        matches!(
            self,
            Self::IncorrectCitation
                | Self::EvidenceDoesNotSupportClaim
                | Self::IncorrectSourceLocation
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AssistantEvidenceFeedback {
    pub operation_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub thread_id: Uuid,
    pub response_id: Uuid,
    pub provenance_id: Uuid,
    pub feedback_type: AssistantEvidenceFeedbackType,
    pub claim_index: Option<u8>,
    pub evidence_block_id: Option<Uuid>,
    pub detail: Option<String>,
}

impl AssistantEvidenceFeedback {
    pub fn validate(&self) -> Result<(), AssistantFeedbackValidationError> {
        let detail_is_valid = self.detail.as_deref().is_none_or(|detail| {
            let trimmed = detail.trim();
            !trimmed.is_empty()
                && trimmed == detail
                && detail.chars().count() <= ASSISTANT_FEEDBACK_DETAIL_MAX_SCALARS
                && !detail.contains('\0')
        });
        if self.operation_id.is_nil()
            || self.paper_id.is_nil()
            || self.generation <= 0
            || self.thread_id.is_nil()
            || self.response_id.is_nil()
            || self.provenance_id.is_nil()
            || self
                .claim_index
                .is_some_and(|index| index >= ASSISTANT_FEEDBACK_MAX_CLAIMS)
            || self.evidence_block_id.is_some_and(|id| id.is_nil())
            || !detail_is_valid
        {
            return Err(AssistantFeedbackValidationError::InvalidFeedback);
        }
        if self.feedback_type.requires_claim() != self.claim_index.is_some()
            || self.feedback_type.requires_evidence_block() != self.evidence_block_id.is_some()
        {
            return Err(AssistantFeedbackValidationError::InvalidTargetShape);
        }
        Ok(())
    }
}

impl std::fmt::Debug for AssistantEvidenceFeedback {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssistantEvidenceFeedback")
            .field("operation_id", &self.operation_id)
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("thread_id", &self.thread_id)
            .field("response_id", &self.response_id)
            .field("provenance_id", &self.provenance_id)
            .field("feedback_type", &self.feedback_type)
            .field("claim_index", &self.claim_index)
            .field("evidence_block_id", &self.evidence_block_id)
            .field("detail", &self.detail.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AssistantFeedbackValidationError {
    #[error("assistant evidence feedback is invalid")]
    InvalidFeedback,
    #[error("assistant evidence feedback target does not match its category")]
    InvalidTargetShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AssistantRequestValidationError {
    #[error("assistant question or generation is invalid")]
    InvalidQuestionOrGeneration,
    #[error("assistant scope is invalid")]
    InvalidScope,
}

fn valid_field_key(value: &str) -> bool {
    let length = value.len();
    (1..=64).contains(&length)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rendered_answer_contract_is_claim_derived_link_free_and_abstains_explicitly() {
        let claims = vec![
            AssistantClaim {
                text: "First supported statement.".to_owned(),
                support: AssistantClaimSupport::Direct,
                evidence: Vec::new(),
            },
            AssistantClaim {
                text: "Second supported statement.".to_owned(),
                support: AssistantClaimSupport::Inferred,
                evidence: Vec::new(),
            },
        ];
        let mut answer = AssistantAnswer {
            answer: canonical_assistant_answer(AssistantAnswerStatus::Partial, &claims).unwrap(),
            status: AssistantAnswerStatus::Partial,
            claims,
            limitations: vec![ASSISTANT_PARTIAL_LIMITATION.to_owned()],
            provenance_id: Uuid::now_v7(),
            model_id: None,
            provider_request_id: None,
            prompt_version: "test".to_owned(),
        };
        assert_eq!(
            answer.answer,
            "First supported statement.\n\nSecond supported statement."
        );
        assert!(answer.has_valid_rendered_contract());

        answer.answer.push_str("\n\nUnsupported extra statement.");
        assert!(!answer.has_valid_rendered_contract());

        answer.answer = ASSISTANT_NOT_FOUND_ANSWER.to_owned();
        answer.status = AssistantAnswerStatus::NotFound;
        answer.claims.clear();
        answer.limitations.clear();
        assert!(answer.has_valid_rendered_contract());

        answer.limitations = vec!["See https://invented.example/source.".to_owned()];
        assert!(!answer.has_valid_rendered_contract());
        assert!(canonical_assistant_answer(AssistantAnswerStatus::Partial, &[]).is_none());
    }

    fn request(scope: AssistantScope) -> AssistantRequest {
        AssistantRequest {
            paper_id: Uuid::now_v7(),
            generation: 3,
            question: "What supports the main result?".to_owned(),
            scope,
            answer_style: AssistantAnswerStyle::Concise,
            thread_id: None,
        }
    }

    #[test]
    fn feedback_is_evidence_specific_bounded_and_redacted() {
        let mut feedback = AssistantEvidenceFeedback {
            operation_id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 3,
            thread_id: Uuid::now_v7(),
            response_id: Uuid::now_v7(),
            provenance_id: Uuid::now_v7(),
            feedback_type: AssistantEvidenceFeedbackType::EvidenceDoesNotSupportClaim,
            claim_index: Some(0),
            evidence_block_id: Some(Uuid::now_v7()),
            detail: Some("The cited range discusses a different outcome.".to_owned()),
        };
        feedback.validate().unwrap();
        assert!(!format!("{feedback:?}").contains("different outcome"));

        feedback.evidence_block_id = None;
        assert_eq!(
            feedback.validate(),
            Err(AssistantFeedbackValidationError::InvalidTargetShape)
        );

        feedback.feedback_type = AssistantEvidenceFeedbackType::MissingEvidence;
        feedback.claim_index = None;
        feedback.validate().unwrap();

        feedback.detail = Some("x".repeat(ASSISTANT_FEEDBACK_DETAIL_MAX_SCALARS + 1));
        assert_eq!(
            feedback.validate(),
            Err(AssistantFeedbackValidationError::InvalidFeedback)
        );
    }

    #[test]
    fn feedback_categories_enforce_closed_evidence_target_shapes() {
        for (feedback_type, claim_index, evidence_block_id) in [
            (AssistantEvidenceFeedbackType::MissingEvidence, None, None),
            (
                AssistantEvidenceFeedbackType::IncorrectSupportLabel,
                Some(0),
                None,
            ),
            (
                AssistantEvidenceFeedbackType::IncorrectCitation,
                Some(0),
                Some(Uuid::now_v7()),
            ),
            (
                AssistantEvidenceFeedbackType::EvidenceDoesNotSupportClaim,
                Some(0),
                Some(Uuid::now_v7()),
            ),
            (
                AssistantEvidenceFeedbackType::IncorrectSourceLocation,
                Some(0),
                Some(Uuid::now_v7()),
            ),
        ] {
            AssistantEvidenceFeedback {
                operation_id: Uuid::now_v7(),
                paper_id: Uuid::now_v7(),
                generation: 1,
                thread_id: Uuid::now_v7(),
                response_id: Uuid::now_v7(),
                provenance_id: Uuid::now_v7(),
                feedback_type,
                claim_index,
                evidence_block_id,
                detail: None,
            }
            .validate()
            .unwrap();
        }
    }

    #[test]
    fn scope_variants_are_closed_and_shape_checked() {
        let paper = AssistantScope {
            kind: AssistantScopeKind::Paper,
            section_kinds: Vec::new(),
            object_ids: Vec::new(),
            selection: None,
            passport_field: None,
        };
        request(paper).validate().unwrap();

        let malformed_paper = AssistantScope {
            kind: AssistantScopeKind::Paper,
            section_kinds: vec![SectionKind::Result],
            object_ids: Vec::new(),
            selection: None,
            passport_field: None,
        };
        assert_eq!(
            request(malformed_paper).validate(),
            Err(AssistantRequestValidationError::InvalidScope)
        );

        let invalid_selection = AssistantScope {
            kind: AssistantScopeKind::Selection,
            section_kinds: Vec::new(),
            object_ids: Vec::new(),
            selection: Some(AssistantTextSelection {
                block_id: Uuid::now_v7(),
                start: 8,
                end: 8,
            }),
            passport_field: None,
        };
        assert_eq!(
            request(invalid_selection).validate(),
            Err(AssistantRequestValidationError::InvalidScope)
        );
    }

    #[test]
    fn request_debug_redacts_the_private_question() {
        let private = "private question marker";
        let mut value = request(AssistantScope {
            kind: AssistantScopeKind::Paper,
            section_kinds: Vec::new(),
            object_ids: Vec::new(),
            selection: None,
            passport_field: None,
        });
        value.question = private.to_owned();
        let debug = format!("{value:?}");
        assert!(!debug.contains(private));
        assert!(debug.contains("[REDACTED]"));
    }
}
