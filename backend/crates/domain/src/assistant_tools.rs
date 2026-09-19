//! Closed, read-only operations over a caller-authorized paper scope.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{AssistantScopeKind, SectionKind};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "name",
    content = "arguments",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum AssistantTool {
    SearchPaperEvidence(SearchPaperEvidence),
    GetPaperOutline(PaperOutline),
    ReadPaperBlocks(ReadPaperBlocks),
    GetObjectEvidence(ObjectEvidence),
    GetCitationContext(CitationEvidence),
}

impl std::fmt::Debug for AssistantTool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AssistantTool")
            .field("name", &self.name())
            .finish_non_exhaustive()
    }
}

impl AssistantTool {
    #[must_use]
    pub const fn name(&self) -> &'static str {
        match self {
            Self::SearchPaperEvidence(_) => "search_paper_evidence",
            Self::GetPaperOutline(_) => "get_paper_outline",
            Self::ReadPaperBlocks(_) => "read_paper_blocks",
            Self::GetObjectEvidence(_) => "get_object_evidence",
            Self::GetCitationContext(_) => "get_citation_context",
        }
    }

    #[must_use]
    pub fn is_valid(&self) -> bool {
        match self {
            Self::SearchPaperEvidence(args) => {
                !args.query.trim().is_empty()
                    && args.query.chars().count() <= 500
                    && !args.query.contains('\0')
                    && (1..=6).contains(&args.limit)
                    && args.section_kinds.len() <= 12
                    && args.section_kinds.iter().collect::<HashSet<_>>().len()
                        == args.section_kinds.len()
            }
            Self::GetPaperOutline(args) => (1..=40).contains(&args.limit),
            Self::ReadPaperBlocks(args) => {
                (1..=4).contains(&args.block_ids.len())
                    && args.block_ids.iter().all(|id| !id.is_nil())
                    && args.block_ids.iter().collect::<HashSet<_>>().len() == args.block_ids.len()
                    && args.neighbors <= 1
            }
            Self::GetObjectEvidence(args) => !args.object_id.is_nil(),
            Self::GetCitationContext(args) => {
                !args.reference_id.is_nil() && (1..=6).contains(&args.limit)
            }
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SearchPaperEvidence {
    pub query: String,
    #[serde(default)]
    pub section_kinds: Vec<SectionKind>,
    #[serde(default = "default_search_limit")]
    pub limit: u32,
}

const fn default_search_limit() -> u32 {
    4
}
const fn default_outline_limit() -> u32 {
    20
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaperOutline {
    #[serde(default = "default_outline_limit")]
    pub limit: u32,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadPaperBlocks {
    pub block_ids: Vec<Uuid>,
    #[serde(default)]
    pub neighbors: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantObjectKind {
    Figure,
    Table,
    Equation,
}

impl AssistantObjectKind {
    #[must_use]
    pub const fn scope(self) -> AssistantScopeKind {
        match self {
            Self::Figure => AssistantScopeKind::Figure,
            Self::Table => AssistantScopeKind::Table,
            Self::Equation => AssistantScopeKind::Equation,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObjectEvidence {
    pub object_id: Uuid,
    pub kind: AssistantObjectKind,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationEvidence {
    pub reference_id: Uuid,
    #[serde(default = "default_search_limit")]
    pub limit: u32,
}
