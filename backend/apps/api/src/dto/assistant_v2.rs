use domain::{
    AssistantAnswer, AssistantAnswerStatus, AssistantAnswerStyle, AssistantClaim,
    AssistantClaimSupport, AssistantEvidenceFeedback, AssistantEvidenceFeedbackType,
    AssistantEvidenceReference, AssistantRequest, AssistantScope, AssistantScopeKind,
    AssistantTextSelection, ProvenanceRecord, SectionKind,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantScopeKindBody {
    Paper,
    Section,
    Selection,
    Figure,
    Table,
    Equation,
    PassportField,
}

impl From<AssistantScopeKindBody> for AssistantScopeKind {
    fn from(value: AssistantScopeKindBody) -> Self {
        match value {
            AssistantScopeKindBody::Paper => Self::Paper,
            AssistantScopeKindBody::Section => Self::Section,
            AssistantScopeKindBody::Selection => Self::Selection,
            AssistantScopeKindBody::Figure => Self::Figure,
            AssistantScopeKindBody::Table => Self::Table,
            AssistantScopeKindBody::Equation => Self::Equation,
            AssistantScopeKindBody::PassportField => Self::PassportField,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantAnswerStyleBody {
    Concise,
    Detailed,
    Beginner,
    Expert,
}

impl From<AssistantAnswerStyleBody> for AssistantAnswerStyle {
    fn from(value: AssistantAnswerStyleBody) -> Self {
        match value {
            AssistantAnswerStyleBody::Concise => Self::Concise,
            AssistantAnswerStyleBody::Detailed => Self::Detailed,
            AssistantAnswerStyleBody::Beginner => Self::Beginner,
            AssistantAnswerStyleBody::Expert => Self::Expert,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantSectionKindBody {
    Abstract,
    Introduction,
    Background,
    RelatedWork,
    Method,
    Experiment,
    Result,
    Discussion,
    Limitation,
    Conclusion,
    Appendix,
    Acknowledgment,
    References,
    Other,
}

impl From<AssistantSectionKindBody> for SectionKind {
    fn from(value: AssistantSectionKindBody) -> Self {
        match value {
            AssistantSectionKindBody::Abstract => Self::Abstract,
            AssistantSectionKindBody::Introduction => Self::Introduction,
            AssistantSectionKindBody::Background => Self::Background,
            AssistantSectionKindBody::RelatedWork => Self::RelatedWork,
            AssistantSectionKindBody::Method => Self::Method,
            AssistantSectionKindBody::Experiment => Self::Experiment,
            AssistantSectionKindBody::Result => Self::Result,
            AssistantSectionKindBody::Discussion => Self::Discussion,
            AssistantSectionKindBody::Limitation => Self::Limitation,
            AssistantSectionKindBody::Conclusion => Self::Conclusion,
            AssistantSectionKindBody::Appendix => Self::Appendix,
            AssistantSectionKindBody::Acknowledgment => Self::Acknowledgment,
            AssistantSectionKindBody::References => Self::References,
            AssistantSectionKindBody::Other => Self::Other,
        }
    }
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AssistantSelectionBody {
    pub(crate) block_id: Uuid,
    pub(crate) start: u32,
    pub(crate) end: u32,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AssistantScopeBody {
    pub(crate) kind: AssistantScopeKindBody,
    #[serde(default)]
    pub(crate) section_kinds: Vec<AssistantSectionKindBody>,
    #[serde(default)]
    pub(crate) object_ids: Vec<Uuid>,
    pub(crate) selection: Option<AssistantSelectionBody>,
    pub(crate) passport_field: Option<String>,
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AssistantRequestBody {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) question: String,
    pub(crate) scope: AssistantScopeBody,
    pub(crate) answer_style: AssistantAnswerStyleBody,
    pub(crate) thread_id: Option<Uuid>,
}

impl std::fmt::Debug for AssistantRequestBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssistantRequestBody")
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("question", &"[REDACTED]")
            .field("scope", &self.scope)
            .field("answer_style", &self.answer_style)
            .field("thread_id", &self.thread_id)
            .finish()
    }
}

impl AssistantRequestBody {
    pub(crate) fn into_domain(self, path_paper_id: Uuid) -> Result<AssistantRequest, &'static str> {
        if self.paper_id != path_paper_id {
            return Err("path and body paper IDs differ");
        }
        let request = AssistantRequest {
            paper_id: path_paper_id,
            generation: self.generation,
            question: self.question,
            scope: AssistantScope {
                kind: self.scope.kind.into(),
                section_kinds: self
                    .scope
                    .section_kinds
                    .into_iter()
                    .map(Into::into)
                    .collect(),
                object_ids: self.scope.object_ids,
                selection: self
                    .scope
                    .selection
                    .map(|selection| AssistantTextSelection {
                        block_id: selection.block_id,
                        start: selection.start,
                        end: selection.end,
                    }),
                passport_field: self.scope.passport_field,
            },
            answer_style: self.answer_style.into(),
            thread_id: self.thread_id,
        };
        request
            .validate()
            .map_err(|_| "assistant request is invalid")?;
        Ok(request)
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantAnswerStatusResponse {
    Supported,
    Partial,
    NotFound,
}

impl From<AssistantAnswerStatus> for AssistantAnswerStatusResponse {
    fn from(value: AssistantAnswerStatus) -> Self {
        match value {
            AssistantAnswerStatus::Supported => Self::Supported,
            AssistantAnswerStatus::Partial => Self::Partial,
            AssistantAnswerStatus::NotFound => Self::NotFound,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantClaimSupportResponse {
    Direct,
    Inferred,
}

impl From<AssistantClaimSupport> for AssistantClaimSupportResponse {
    fn from(value: AssistantClaimSupport) -> Self {
        match value {
            AssistantClaimSupport::Direct => Self::Direct,
            AssistantClaimSupport::Inferred => Self::Inferred,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AssistantEvidenceResponse {
    pub(crate) block_id: Uuid,
    pub(crate) start: u32,
    pub(crate) end: u32,
    pub(crate) page_start: Option<u32>,
    pub(crate) section: Option<String>,
}

impl From<AssistantEvidenceReference> for AssistantEvidenceResponse {
    fn from(value: AssistantEvidenceReference) -> Self {
        Self {
            block_id: value.block_id,
            start: value.start,
            end: value.end,
            page_start: value.page_start,
            section: value.section,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AssistantClaimResponse {
    pub(crate) text: String,
    pub(crate) support: AssistantClaimSupportResponse,
    pub(crate) evidence: Vec<AssistantEvidenceResponse>,
}

impl From<AssistantClaim> for AssistantClaimResponse {
    fn from(value: AssistantClaim) -> Self {
        Self {
            text: value.text,
            support: value.support.into(),
            evidence: value.evidence.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AssistantAnswerEnvelope {
    pub(crate) thread_id: Uuid,
    pub(crate) response_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) answer: String,
    pub(crate) status: AssistantAnswerStatusResponse,
    pub(crate) claims: Vec<AssistantClaimResponse>,
    #[schema(max_items = 1)]
    pub(crate) limitations: Vec<String>,
    pub(crate) provenance_id: Uuid,
    pub(crate) model_id: Option<String>,
    pub(crate) prompt_version: String,
}

impl AssistantAnswerEnvelope {
    #[must_use]
    pub(crate) fn new(
        thread_id: Uuid,
        response_id: Uuid,
        generation: i32,
        value: AssistantAnswer,
    ) -> Self {
        Self {
            thread_id,
            response_id,
            generation,
            answer: value.answer,
            status: value.status.into(),
            claims: value.claims.into_iter().map(Into::into).collect(),
            limitations: value.limitations,
            provenance_id: value.provenance_id,
            model_id: value.model_id,
            prompt_version: value.prompt_version,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantEvidenceFeedbackTypeBody {
    IncorrectCitation,
    EvidenceDoesNotSupportClaim,
    MissingEvidence,
    IncorrectSupportLabel,
    IncorrectSourceLocation,
}

impl From<AssistantEvidenceFeedbackTypeBody> for AssistantEvidenceFeedbackType {
    fn from(value: AssistantEvidenceFeedbackTypeBody) -> Self {
        match value {
            AssistantEvidenceFeedbackTypeBody::IncorrectCitation => Self::IncorrectCitation,
            AssistantEvidenceFeedbackTypeBody::EvidenceDoesNotSupportClaim => {
                Self::EvidenceDoesNotSupportClaim
            }
            AssistantEvidenceFeedbackTypeBody::MissingEvidence => Self::MissingEvidence,
            AssistantEvidenceFeedbackTypeBody::IncorrectSupportLabel => Self::IncorrectSupportLabel,
            AssistantEvidenceFeedbackTypeBody::IncorrectSourceLocation => {
                Self::IncorrectSourceLocation
            }
        }
    }
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct AssistantEvidenceFeedbackBody {
    pub(crate) operation_id: Uuid,
    pub(crate) paper_id: Uuid,
    #[schema(minimum = 1)]
    pub(crate) generation: i32,
    pub(crate) thread_id: Uuid,
    pub(crate) response_id: Uuid,
    pub(crate) provenance_id: Uuid,
    pub(crate) feedback_type: AssistantEvidenceFeedbackTypeBody,
    #[schema(maximum = 15)]
    pub(crate) claim_index: Option<u8>,
    pub(crate) evidence_block_id: Option<Uuid>,
    #[schema(max_length = 1000)]
    pub(crate) detail: Option<String>,
}

impl std::fmt::Debug for AssistantEvidenceFeedbackBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssistantEvidenceFeedbackBody")
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

impl AssistantEvidenceFeedbackBody {
    pub(crate) fn into_domain(
        self,
        path_paper_id: Uuid,
    ) -> Result<AssistantEvidenceFeedback, &'static str> {
        if self.paper_id != path_paper_id {
            return Err("path and body paper IDs differ");
        }
        let value = AssistantEvidenceFeedback {
            operation_id: self.operation_id,
            paper_id: path_paper_id,
            generation: self.generation,
            thread_id: self.thread_id,
            response_id: self.response_id,
            provenance_id: self.provenance_id,
            feedback_type: self.feedback_type.into(),
            claim_index: self.claim_index,
            evidence_block_id: self.evidence_block_id,
            detail: self.detail,
        };
        value
            .validate()
            .map_err(|_| "assistant evidence feedback is invalid")?;
        Ok(value)
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssistantEvidenceFeedbackStatusResponse {
    Stored,
    Replayed,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AssistantEvidenceFeedbackEnvelope {
    pub(crate) feedback_id: Uuid,
    pub(crate) status: AssistantEvidenceFeedbackStatusResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct AssistantProvenanceEnvelope {
    pub(crate) id: Uuid,
    pub(crate) artifact_type: String,
    pub(crate) artifact_id: Uuid,
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) activity_type: String,
    pub(crate) parser_id: Option<String>,
    pub(crate) parser_version: Option<String>,
    pub(crate) model_provider: Option<String>,
    pub(crate) model_id: Option<String>,
    pub(crate) prompt_or_schema_version: Option<String>,
    pub(crate) input_entity_ids: Vec<Uuid>,
    #[schema(value_type = Object)]
    pub(crate) parameters: serde_json::Value,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) created_at: String,
    pub(crate) superseded_by: Option<Uuid>,
}

impl TryFrom<ProvenanceRecord> for AssistantProvenanceEnvelope {
    type Error = serde_json::Error;

    fn try_from(value: ProvenanceRecord) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value.id,
            artifact_type: value.artifact_type.as_str().to_owned(),
            artifact_id: value.artifact_id,
            paper_id: value.paper_id,
            generation: value.generation,
            activity_type: value.activity_type.as_str().to_owned(),
            parser_id: value.parser_id,
            parser_version: value.parser_version,
            model_provider: value.model_provider,
            model_id: value.model_id,
            prompt_or_schema_version: value.prompt_or_schema_version,
            input_entity_ids: value.input_entity_ids,
            parameters: serde_json::to_value(value.parameters)?,
            created_at: super::format_timestamp(value.created_at),
            superseded_by: value.superseded_by,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_paper_id_is_authoritative_and_debug_redacts_question() {
        let paper_id = Uuid::now_v7();
        let body = AssistantRequestBody {
            paper_id: Uuid::now_v7(),
            generation: 1,
            question: "PRIVATE QUESTION".to_owned(),
            scope: AssistantScopeBody {
                kind: AssistantScopeKindBody::Paper,
                section_kinds: Vec::new(),
                object_ids: Vec::new(),
                selection: None,
                passport_field: None,
            },
            answer_style: AssistantAnswerStyleBody::Concise,
            thread_id: None,
        };
        assert!(!format!("{body:?}").contains("PRIVATE QUESTION"));
        assert!(body.into_domain(paper_id).is_err());
    }

    #[test]
    fn feedback_dto_is_path_bound_shape_checked_and_debug_redacted() {
        let paper_id = Uuid::now_v7();
        let private_detail = "PRIVATE EVIDENCE CORRECTION";
        let body = AssistantEvidenceFeedbackBody {
            operation_id: Uuid::now_v7(),
            paper_id,
            generation: 2,
            thread_id: Uuid::now_v7(),
            response_id: Uuid::now_v7(),
            provenance_id: Uuid::now_v7(),
            feedback_type: AssistantEvidenceFeedbackTypeBody::IncorrectCitation,
            claim_index: Some(0),
            evidence_block_id: Some(Uuid::now_v7()),
            detail: Some(private_detail.to_owned()),
        };
        let debug = format!("{body:?}");
        assert!(!debug.contains(private_detail));
        assert!(debug.contains("[REDACTED]"));
        let feedback = body.into_domain(paper_id).unwrap();
        assert_eq!(feedback.paper_id, paper_id);

        let mismatched = AssistantEvidenceFeedbackBody {
            operation_id: Uuid::now_v7(),
            paper_id,
            generation: 2,
            thread_id: Uuid::now_v7(),
            response_id: Uuid::now_v7(),
            provenance_id: Uuid::now_v7(),
            feedback_type: AssistantEvidenceFeedbackTypeBody::MissingEvidence,
            claim_index: None,
            evidence_block_id: None,
            detail: None,
        };
        assert!(mismatched.into_domain(Uuid::now_v7()).is_err());

        let malformed = AssistantEvidenceFeedbackBody {
            operation_id: Uuid::now_v7(),
            paper_id,
            generation: 2,
            thread_id: Uuid::now_v7(),
            response_id: Uuid::now_v7(),
            provenance_id: Uuid::now_v7(),
            feedback_type: AssistantEvidenceFeedbackTypeBody::IncorrectSupportLabel,
            claim_index: None,
            evidence_block_id: None,
            detail: None,
        };
        assert!(malformed.into_domain(paper_id).is_err());
    }

    #[test]
    fn answer_and_feedback_envelopes_expose_stable_receipt_identifiers() {
        let thread_id = Uuid::now_v7();
        let response_id = Uuid::now_v7();
        let provenance_id = Uuid::now_v7();
        let answer = AssistantAnswerEnvelope::new(
            thread_id,
            response_id,
            4,
            AssistantAnswer {
                answer: "Not found in this paper.".to_owned(),
                status: AssistantAnswerStatus::NotFound,
                claims: Vec::new(),
                limitations: Vec::new(),
                provenance_id,
                model_id: None,
                provider_request_id: None,
                prompt_version: "assistant.v2".to_owned(),
            },
        );
        let answer_json = serde_json::to_value(answer).unwrap();
        assert_eq!(answer_json["thread_id"], thread_id.to_string());
        assert_eq!(answer_json["response_id"], response_id.to_string());
        assert_eq!(answer_json["provenance_id"], provenance_id.to_string());

        let feedback_id = Uuid::now_v7();
        let receipt = serde_json::to_value(AssistantEvidenceFeedbackEnvelope {
            feedback_id,
            status: AssistantEvidenceFeedbackStatusResponse::Replayed,
        })
        .unwrap();
        assert_eq!(receipt["feedback_id"], feedback_id.to_string());
        assert_eq!(receipt["status"], "replayed");
    }
}
