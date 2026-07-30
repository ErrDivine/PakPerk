use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::{PaperId, ProcessingGeneration};

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
        if !self.metadata || ((self.chat || self.connections) && !self.introduction) {
            return false;
        }
        match stage {
            ProcessingStage::NotRequested
            | ProcessingStage::Queued
            | ProcessingStage::FetchingLicense
            | ProcessingStage::FetchingPdf
            | ProcessingStage::ParsingPdf => !self.introduction && !self.chat && !self.connections,
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
            }
            .valid_for_stage(ProcessingStage::IndexingChat)
        );
        assert!(
            Capabilities {
                metadata: true,
                introduction: true,
                chat: true,
                connections: false,
            }
            .valid_for_stage(ProcessingStage::ResolvingReferences)
        );
        assert!(
            !Capabilities {
                metadata: true,
                introduction: false,
                chat: true,
                connections: false,
            }
            .valid_for_stage(ProcessingStage::IndexingChat)
        );
        assert!(!Capabilities::metadata_only().valid_for_stage(ProcessingStage::Ready));
    }
}
