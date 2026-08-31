use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{PaperId, ProcessingGeneration};

/// Auditable provenance for demand-driven document preparation.
///
/// This enum is deliberately closed: metadata surfaces such as imports,
/// reading-feed prefetch, recommendations, notifications, and Abstract-card
/// rendering cannot be represented as an approved trigger. Callers must carry
/// one of these values through every downstream document job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreparationTriggerKind {
    IntroductionTransition,
    InspectEvidence,
    ExplicitPrepare,
    ApprovedReprocessing,
    /// Additive migration default for jobs inserted by a rolling-deploy pod
    /// that predates trigger provenance. New code must never select it.
    LegacyIntroductionTransition,
}

impl PreparationTriggerKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::IntroductionTransition => "introduction_transition",
            Self::InspectEvidence => "inspect_evidence",
            Self::ExplicitPrepare => "explicit_prepare",
            Self::ApprovedReprocessing => "approved_reprocessing",
            Self::LegacyIntroductionTransition => "legacy_introduction_transition",
        }
    }

    /// Only deliberate reader actions may cross the public API boundary.
    #[must_use]
    pub const fn is_public_user_trigger(self) -> bool {
        matches!(
            self,
            Self::IntroductionTransition | Self::InspectEvidence | Self::ExplicitPrepare
        )
    }

    /// Rolling-deploy compatibility rows may be consumed, but new code must
    /// always provide provenance that identifies a deliberate current action.
    #[must_use]
    pub const fn is_approved_for_new_enqueue(self) -> bool {
        !matches!(self, Self::LegacyIntroductionTransition)
    }
}

impl fmt::Display for PreparationTriggerKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for PreparationTriggerKind {
    type Err = PreparationTriggerKindParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "introduction_transition" => Ok(Self::IntroductionTransition),
            "inspect_evidence" => Ok(Self::InspectEvidence),
            "explicit_prepare" => Ok(Self::ExplicitPrepare),
            "approved_reprocessing" => Ok(Self::ApprovedReprocessing),
            "legacy_introduction_transition" => Ok(Self::LegacyIntroductionTransition),
            _ => Err(PreparationTriggerKindParseError),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unknown or unapproved preparation trigger")]
pub struct PreparationTriggerKindParseError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[allow(clippy::struct_excessive_bools)] // Mirrors the stable capability-oriented API contract.
pub struct Capabilities {
    #[serde(default = "default_true")]
    pub metadata: bool,
    #[serde(default)]
    pub introduction: bool,
    #[serde(default)]
    pub chat: bool,
    #[serde(default)]
    pub connections: bool,
    #[serde(default)]
    pub visual_objects: bool,
    #[serde(default)]
    pub terms: bool,
    #[serde(default)]
    pub semantic_facets: bool,
    #[serde(default)]
    pub paper_passport: bool,
}

impl Default for Capabilities {
    fn default() -> Self {
        Self::metadata_only()
    }
}

const fn default_true() -> bool {
    true
}

impl Capabilities {
    #[must_use]
    pub const fn metadata_only() -> Self {
        Self {
            metadata: true,
            introduction: false,
            chat: false,
            connections: false,
            visual_objects: false,
            terms: false,
            semantic_facets: false,
            paper_passport: false,
        }
    }

    #[must_use]
    pub const fn all_ready(self) -> bool {
        self.metadata && self.introduction && self.chat && self.connections
    }

    /// Checks the externally visible dependency/order contract. Later
    /// capabilities may never be published before Introduction, and a stage
    /// that advertises progress past parsing must expose the corresponding
    /// committed capability.
    #[must_use]
    pub const fn valid_for_stage(self, stage: ProcessingStage) -> bool {
        let any_enrichment =
            self.visual_objects || self.terms || self.semantic_facets || self.paper_passport;
        if !self.metadata
            || ((self.chat || self.connections || any_enrichment) && !self.introduction)
            || (self.semantic_facets && !self.terms)
            || (self.paper_passport && !self.semantic_facets)
        {
            return false;
        }
        match stage {
            ProcessingStage::NotRequested
            | ProcessingStage::Queued
            | ProcessingStage::FetchingLicense
            | ProcessingStage::FetchingPdf
            | ProcessingStage::ParsingPdf => {
                !self.introduction && !self.chat && !self.connections && !any_enrichment
            }
            ProcessingStage::IntroductionReady => {
                self.introduction && !self.chat && !self.connections
            }
            ProcessingStage::IndexingChat => self.introduction && !self.chat,
            ProcessingStage::ResolvingReferences => self.introduction && !self.connections,
            ProcessingStage::Ready => self.all_ready(),
            ProcessingStage::FailedRetryable | ProcessingStage::FailedTerminal => true,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverallProcessingState {
    #[default]
    NotRequested,
    Processing,
    Ready,
    Failed,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingStage {
    #[default]
    NotRequested,
    Queued,
    FetchingLicense,
    FetchingPdf,
    ParsingPdf,
    IntroductionReady,
    IndexingChat,
    ResolvingReferences,
    Ready,
    FailedRetryable,
    FailedTerminal,
}

impl ProcessingStage {
    #[must_use]
    pub const fn is_running(self) -> bool {
        matches!(
            self,
            Self::Queued
                | Self::FetchingLicense
                | Self::FetchingPdf
                | Self::ParsingPdf
                | Self::IntroductionReady
                | Self::IndexingChat
                | Self::ResolvingReferences
        )
    }

    #[must_use]
    pub const fn is_failed(self) -> bool {
        matches!(self, Self::FailedRetryable | Self::FailedTerminal)
    }

    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Ready | Self::FailedRetryable | Self::FailedTerminal
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCategory {
    ExternalTemporary,
    ExternalPermanent,
    ParserTemporary,
    ParserDocument,
    ModelTemporary,
    Validation,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessingError {
    pub category: FailureCategory,
    pub code: String,
    /// Safe, user-readable detail. Provider payloads and filesystem paths must
    /// never be stored here.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessingState {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub overall_state: OverallProcessingState,
    pub stage: ProcessingStage,
    pub capabilities: Capabilities,
    pub retryable: bool,
    pub last_error: Option<ProcessingError>,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub parser_version: Option<String>,
    pub embedding_model: Option<String>,
    pub summary_model: Option<String>,
}

impl ProcessingState {
    #[must_use]
    pub const fn is_ready(&self) -> bool {
        matches!(self.stage, ProcessingStage::Ready) && self.capabilities.all_ready()
    }

    #[must_use]
    pub const fn is_running(&self) -> bool {
        self.stage.is_running()
    }

    #[must_use]
    pub const fn failed(&self) -> bool {
        self.stage.is_failed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn processing_stages_have_stable_snake_case_wire_names() {
        assert_eq!(
            serde_json::to_string(&ProcessingStage::FetchingPdf).unwrap(),
            "\"fetching_pdf\""
        );
        assert_eq!(
            serde_json::from_str::<ProcessingStage>("\"failed_retryable\"").unwrap(),
            ProcessingStage::FailedRetryable
        );
    }

    #[test]
    fn preparation_triggers_reject_metadata_only_origins() {
        for denied in [
            "manual_import",
            "queue_save",
            "reading_feed_prefetch",
            "recommendation_generation",
            "abstract_display",
            "notification_evaluation",
        ] {
            assert!(
                denied.parse::<PreparationTriggerKind>().is_err(),
                "accepted forbidden origin {denied}"
            );
        }
    }

    #[test]
    fn public_preparation_triggers_are_an_explicit_subset() {
        assert!(PreparationTriggerKind::IntroductionTransition.is_public_user_trigger());
        assert!(PreparationTriggerKind::InspectEvidence.is_public_user_trigger());
        assert!(PreparationTriggerKind::ExplicitPrepare.is_public_user_trigger());
        assert!(!PreparationTriggerKind::ApprovedReprocessing.is_public_user_trigger());
        assert!(!PreparationTriggerKind::LegacyIntroductionTransition.is_public_user_trigger());
        assert!(PreparationTriggerKind::ApprovedReprocessing.is_approved_for_new_enqueue());
        assert!(
            !PreparationTriggerKind::LegacyIntroductionTransition.is_approved_for_new_enqueue()
        );
        assert_eq!(
            PreparationTriggerKind::IntroductionTransition.to_string(),
            "introduction_transition"
        );
    }

    #[test]
    fn omitted_capabilities_default_to_metadata_only() {
        let capabilities: Capabilities = serde_json::from_str("{}").unwrap();
        assert_eq!(capabilities, Capabilities::metadata_only());
        assert!(!capabilities.all_ready());
    }

    #[test]
    fn stage_business_helpers_distinguish_running_and_terminal() {
        assert!(ProcessingStage::IndexingChat.is_running());
        assert!(!ProcessingStage::Ready.is_running());
        assert!(ProcessingStage::Ready.is_terminal());
        assert!(ProcessingStage::FailedTerminal.is_failed());
    }

    #[test]
    fn capabilities_enforce_publication_dependencies_and_stage_order() {
        assert!(Capabilities::metadata_only().valid_for_stage(ProcessingStage::NotRequested));
        assert!(
            Capabilities {
                metadata: true,
                introduction: true,
                chat: false,
                connections: true,
                visual_objects: false,
                terms: false,
                semantic_facets: false,
                paper_passport: false,
            }
            .valid_for_stage(ProcessingStage::IndexingChat)
        );
        assert!(
            Capabilities {
                metadata: true,
                introduction: true,
                chat: true,
                connections: false,
                visual_objects: false,
                terms: false,
                semantic_facets: false,
                paper_passport: false,
            }
            .valid_for_stage(ProcessingStage::ResolvingReferences)
        );
        assert!(
            !Capabilities {
                metadata: true,
                introduction: false,
                chat: true,
                connections: false,
                visual_objects: false,
                terms: false,
                semantic_facets: false,
                paper_passport: false,
            }
            .valid_for_stage(ProcessingStage::IndexingChat)
        );
        assert!(!Capabilities::metadata_only().valid_for_stage(ProcessingStage::Ready));
    }
}
