use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration};

pub const VERSION_DIFF_ALGORITHM_VERSION: &str = "stable-key-content-similarity-v2";
pub const VERSION_DIFF_SCHEMA_VERSION: &str = "paper-version-diff-v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VersionDiffStatus {
    Pending,
    Ready,
    Partial,
    Failed,
}

impl VersionDiffStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Ready => "ready",
            Self::Partial => "partial",
            Self::Failed => "failed",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "pending" => Self::Pending,
            "ready" => Self::Ready,
            "partial" => Self::Partial,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VersionDiffItemKind {
    Metadata,
    Section,
    Block,
    Figure,
    Table,
    Equation,
    PassportField,
    Reference,
    AnnotationAnchor,
}

impl VersionDiffItemKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Metadata => "metadata",
            Self::Section => "section",
            Self::Block => "block",
            Self::Figure => "figure",
            Self::Table => "table",
            Self::Equation => "equation",
            Self::PassportField => "passport_field",
            Self::Reference => "reference",
            Self::AnnotationAnchor => "annotation_anchor",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "metadata" => Self::Metadata,
            "section" => Self::Section,
            "block" => Self::Block,
            "figure" => Self::Figure,
            "table" => Self::Table,
            "equation" => Self::Equation,
            "passport_field" => Self::PassportField,
            "reference" => Self::Reference,
            "annotation_anchor" => Self::AnnotationAnchor,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VersionChangeType {
    Added,
    Removed,
    Modified,
    Moved,
}

impl VersionChangeType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Added => "added",
            Self::Removed => "removed",
            Self::Modified => "modified",
            Self::Moved => "moved",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "added" => Self::Added,
            "removed" => Self::Removed,
            "modified" => Self::Modified,
            "moved" => Self::Moved,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiffConfidenceStatus {
    Supported,
    Uncertain,
    Unavailable,
}

impl DiffConfidenceStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Uncertain => "uncertain",
            Self::Unavailable => "unavailable",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "supported" => Self::Supported,
            "uncertain" => Self::Uncertain,
            "unavailable" => Self::Unavailable,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParserIdentity {
    pub parser_id: String,
    pub parser_version: String,
}

impl ParserIdentity {
    fn validate(&self) -> bool {
        valid_label(&self.parser_id, 64) && valid_label(&self.parser_version, 128)
    }
}

/// One retained, source-identifiable document generation. The arXiv version is
/// persisted with the generation and is never inferred from generation order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentVersionManifest {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub arxiv_version: u32,
    pub schema_version: String,
    pub parser: ParserIdentity,
    pub document_hash: String,
    pub is_current: bool,
    pub created_at: DateTime<Utc>,
}

impl DocumentVersionManifest {
    pub fn validate(&self) -> Result<(), VersionDiffValidationError> {
        if self.paper_id.is_nil()
            || self.generation <= 0
            || self.arxiv_version == 0
            || !valid_label(&self.schema_version, 64)
            || !self.parser.validate()
            || !valid_hash(&self.document_hash)
        {
            return Err(VersionDiffValidationError::InvalidManifest);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionDiffSummary {
    pub added: u32,
    pub removed: u32,
    pub modified: u32,
    pub moved: u32,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VersionDiffItem {
    pub id: Uuid,
    pub ordinal: u32,
    pub kind: VersionDiffItemKind,
    pub old_object_id: Option<Uuid>,
    pub new_object_id: Option<Uuid>,
    pub change_type: VersionChangeType,
    pub similarity: Option<f32>,
    pub old_content_hash: Option<String>,
    pub new_content_hash: Option<String>,
    pub confidence_status: DiffConfidenceStatus,
}

impl VersionDiffItem {
    pub fn validate(&self) -> Result<(), VersionDiffValidationError> {
        let ids_valid = match self.change_type {
            VersionChangeType::Added => {
                self.old_object_id.is_none() && self.new_object_id.is_some()
            }
            VersionChangeType::Removed => {
                self.old_object_id.is_some() && self.new_object_id.is_none()
            }
            VersionChangeType::Modified | VersionChangeType::Moved => {
                self.old_object_id.is_some() && self.new_object_id.is_some()
            }
        };
        if self.id.is_nil()
            || !ids_valid
            || self
                .similarity
                .is_some_and(|value| !value.is_finite() || !(0.0..=1.0).contains(&value))
            || self
                .old_content_hash
                .as_deref()
                .is_some_and(|value| !valid_hash(value))
            || self
                .new_content_hash
                .as_deref()
                .is_some_and(|value| !valid_hash(value))
        {
            return Err(VersionDiffValidationError::InvalidItem);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaperVersionDiff {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub from_generation: ProcessingGeneration,
    pub to_generation: ProcessingGeneration,
    pub from_arxiv_version: u32,
    pub to_arxiv_version: u32,
    pub algorithm_version: String,
    pub schema_version: String,
    pub from_parser: ParserIdentity,
    pub to_parser: ParserIdentity,
    pub parser_change_uncertainty: bool,
    pub status: VersionDiffStatus,
    pub summary: VersionDiffSummary,
    pub failure_code: Option<String>,
    pub items: Vec<VersionDiffItem>,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

impl PaperVersionDiff {
    pub fn validate(&self) -> Result<(), VersionDiffValidationError> {
        if self.id.is_nil()
            || self.paper_id.is_nil()
            || self.from_generation <= 0
            || self.to_generation <= self.from_generation
            || self.from_arxiv_version == 0
            || self.to_arxiv_version <= self.from_arxiv_version
            || !valid_label(&self.algorithm_version, 64)
            || !valid_label(&self.schema_version, 64)
            || !self.from_parser.validate()
            || !self.to_parser.validate()
            || (matches!(self.status, VersionDiffStatus::Pending) == self.completed_at.is_some())
            || (matches!(self.status, VersionDiffStatus::Failed) != self.failure_code.is_some())
            || self
                .failure_code
                .as_deref()
                .is_some_and(|code| !valid_failure_code(code))
            || self.summary.warnings.len() > 32
            || self
                .summary
                .warnings
                .iter()
                .any(|warning| !valid_label(warning, 500))
        {
            return Err(VersionDiffValidationError::InvalidHeader);
        }
        let parser_changed = self.from_parser != self.to_parser;
        if parser_changed && !self.parser_change_uncertainty {
            return Err(VersionDiffValidationError::MissingParserUncertainty);
        }
        let mut ordinals = HashSet::new();
        for item in &self.items {
            item.validate()?;
            if !ordinals.insert(item.ordinal) {
                return Err(VersionDiffValidationError::InvalidItem);
            }
        }
        let counts = self.items.iter().fold([0_u32; 4], |mut counts, item| {
            let index = match item.change_type {
                VersionChangeType::Added => 0,
                VersionChangeType::Removed => 1,
                VersionChangeType::Modified => 2,
                VersionChangeType::Moved => 3,
            };
            counts[index] = counts[index].saturating_add(1);
            counts
        });
        if counts
            != [
                self.summary.added,
                self.summary.removed,
                self.summary.modified,
                self.summary.moved,
            ]
        {
            return Err(VersionDiffValidationError::SummaryMismatch);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DiffBlock<'a> {
    pub id: Uuid,
    pub stable_key: &'a str,
    pub content_hash: &'a str,
    /// Internal comparison material used only to compute a bounded similarity
    /// score. It is never copied into the persisted diff artifact.
    pub comparison_text: Option<&'a str>,
    pub ordinal: u32,
}

/// Deterministic structural baseline. It does not infer intent or emit full
/// paper text; modified items retain hashes for source-linked inspection.
#[allow(clippy::too_many_lines)] // Keeps the ordered matching phases visible as one audit unit.
pub fn align_document_blocks(
    old: &[DiffBlock<'_>],
    new: &[DiffBlock<'_>],
    parser_changed: bool,
) -> Result<(VersionDiffSummary, Vec<VersionDiffItem>), VersionDiffValidationError> {
    validate_blocks(old)?;
    validate_blocks(new)?;
    let old_by_key = old
        .iter()
        .map(|block| (block.stable_key, block))
        .collect::<HashMap<_, _>>();
    let new_by_key = new
        .iter()
        .map(|block| (block.stable_key, block))
        .collect::<HashMap<_, _>>();
    let mut matched_old = HashSet::new();
    let mut matched_new = HashSet::new();
    let mut items = Vec::new();

    for (key, old_block) in &old_by_key {
        let Some(new_block) = new_by_key.get(key) else {
            continue;
        };
        matched_old.insert(old_block.id);
        matched_new.insert(new_block.id);
        if old_block.content_hash == new_block.content_hash {
            if old_block.ordinal != new_block.ordinal {
                items.push(diff_item(
                    old_block,
                    new_block,
                    VersionChangeType::Moved,
                    parser_changed,
                ));
            }
        } else {
            items.push(diff_item(
                old_block,
                new_block,
                VersionChangeType::Modified,
                parser_changed,
            ));
        }
    }

    let unmatched_old = old
        .iter()
        .filter(|block| !matched_old.contains(&block.id))
        .collect::<Vec<_>>();
    let unmatched_new = new
        .iter()
        .filter(|block| !matched_new.contains(&block.id))
        .collect::<Vec<_>>();
    let mut new_by_hash: HashMap<&str, Vec<&DiffBlock<'_>>> = HashMap::new();
    for block in &unmatched_new {
        new_by_hash
            .entry(block.content_hash)
            .or_default()
            .push(block);
    }
    for old_block in unmatched_old {
        let moved = new_by_hash
            .get_mut(old_block.content_hash)
            .and_then(|candidates| pop_unmatched_candidate(candidates, &matched_new));
        if let Some(new_block) = moved {
            matched_new.insert(new_block.id);
            items.push(diff_item(
                old_block,
                new_block,
                VersionChangeType::Moved,
                parser_changed,
            ));
        } else if let Some((new_block, similarity)) =
            best_similarity_match(old_block, &unmatched_new, &matched_new)
        {
            matched_new.insert(new_block.id);
            let mut item = diff_item(
                old_block,
                new_block,
                VersionChangeType::Modified,
                parser_changed,
            );
            item.similarity = Some(similarity);
            items.push(item);
        } else {
            items.push(VersionDiffItem {
                id: Uuid::now_v7(),
                ordinal: 0,
                kind: VersionDiffItemKind::Block,
                old_object_id: Some(old_block.id),
                new_object_id: None,
                change_type: VersionChangeType::Removed,
                similarity: None,
                old_content_hash: Some(old_block.content_hash.to_owned()),
                new_content_hash: None,
                confidence_status: confidence(parser_changed),
            });
        }
    }
    for new_block in new.iter().filter(|block| !matched_new.contains(&block.id)) {
        items.push(VersionDiffItem {
            id: Uuid::now_v7(),
            ordinal: 0,
            kind: VersionDiffItemKind::Block,
            old_object_id: None,
            new_object_id: Some(new_block.id),
            change_type: VersionChangeType::Added,
            similarity: None,
            old_content_hash: None,
            new_content_hash: Some(new_block.content_hash.to_owned()),
            confidence_status: confidence(parser_changed),
        });
    }
    items.sort_by_key(|item| {
        (
            item.change_type as u8,
            item.old_object_id,
            item.new_object_id,
        )
    });
    for (ordinal, item) in items.iter_mut().enumerate() {
        item.ordinal =
            u32::try_from(ordinal).map_err(|_| VersionDiffValidationError::TooManyItems)?;
    }
    let summary = VersionDiffSummary {
        added: count_change(&items, VersionChangeType::Added),
        removed: count_change(&items, VersionChangeType::Removed),
        modified: count_change(&items, VersionChangeType::Modified),
        moved: count_change(&items, VersionChangeType::Moved),
        warnings: if parser_changed {
            vec!["Parser changes may cause apparent structural differences.".to_owned()]
        } else {
            Vec::new()
        },
    };
    Ok((summary, items))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum VersionDiffValidationError {
    #[error("version diff header is invalid")]
    InvalidHeader,
    #[error("version diff item is invalid")]
    InvalidItem,
    #[error("version diff summary does not match its items")]
    SummaryMismatch,
    #[error("parser change is missing uncertainty labeling")]
    MissingParserUncertainty,
    #[error("document blocks are invalid or ambiguous")]
    InvalidBlocks,
    #[error("version diff contains too many items")]
    TooManyItems,
    #[error("document version manifest is invalid")]
    InvalidManifest,
}

fn validate_blocks(blocks: &[DiffBlock<'_>]) -> Result<(), VersionDiffValidationError> {
    if blocks.len() > 1_000_000
        || blocks.iter().any(|block| {
            block.id.is_nil()
                || !valid_label(block.stable_key, 128)
                || !valid_hash(block.content_hash)
        })
        || blocks
            .iter()
            .map(|block| block.id)
            .collect::<HashSet<_>>()
            .len()
            != blocks.len()
        || blocks
            .iter()
            .map(|block| block.stable_key)
            .collect::<HashSet<_>>()
            .len()
            != blocks.len()
    {
        return Err(VersionDiffValidationError::InvalidBlocks);
    }
    Ok(())
}

fn diff_item(
    old: &DiffBlock<'_>,
    new: &DiffBlock<'_>,
    change_type: VersionChangeType,
    parser_changed: bool,
) -> VersionDiffItem {
    VersionDiffItem {
        id: Uuid::now_v7(),
        ordinal: 0,
        kind: VersionDiffItemKind::Block,
        old_object_id: Some(old.id),
        new_object_id: Some(new.id),
        change_type,
        similarity: Some(if old.content_hash == new.content_hash {
            1.0
        } else {
            content_similarity(old.comparison_text, new.comparison_text).unwrap_or(0.0)
        }),
        old_content_hash: Some(old.content_hash.to_owned()),
        new_content_hash: Some(new.content_hash.to_owned()),
        confidence_status: confidence(parser_changed),
    }
}

fn pop_unmatched_candidate<'a>(
    candidates: &mut Vec<&'a DiffBlock<'a>>,
    matched_new: &HashSet<Uuid>,
) -> Option<&'a DiffBlock<'a>> {
    while let Some(candidate) = candidates.pop() {
        if !matched_new.contains(&candidate.id) {
            return Some(candidate);
        }
    }
    None
}

fn best_similarity_match<'a>(
    old: &DiffBlock<'_>,
    candidates: &[&'a DiffBlock<'a>],
    matched_new: &HashSet<Uuid>,
) -> Option<(&'a DiffBlock<'a>, f32)> {
    const MIN_SIMILARITY: f32 = 0.62;
    const MAX_ORDINAL_DISTANCE: u32 = 64;
    candidates
        .iter()
        .copied()
        .filter(|candidate| {
            !matched_new.contains(&candidate.id)
                && old.ordinal.abs_diff(candidate.ordinal) <= MAX_ORDINAL_DISTANCE
        })
        .filter_map(|candidate| {
            content_similarity(old.comparison_text, candidate.comparison_text)
                .map(|similarity| (candidate, similarity))
        })
        .filter(|(_, similarity)| *similarity >= MIN_SIMILARITY)
        .max_by(|(left, left_score), (right, right_score)| {
            left_score
                .total_cmp(right_score)
                .then_with(|| right.id.cmp(&left.id))
        })
}

fn content_similarity(old: Option<&str>, new: Option<&str>) -> Option<f32> {
    const MAX_TOKENS: usize = 4_096;
    const MAX_TOKEN_SCALARS: usize = 64;
    let tokens = |value: &str| {
        value
            .split(|character: char| !character.is_alphanumeric())
            .filter(|token| !token.is_empty())
            .take(MAX_TOKENS)
            .map(|token| {
                token
                    .chars()
                    .take(MAX_TOKEN_SCALARS)
                    .flat_map(char::to_lowercase)
                    .collect::<String>()
            })
            .collect::<HashSet<_>>()
    };
    let old = tokens(old?);
    let new = tokens(new?);
    if old.is_empty() || new.is_empty() {
        return None;
    }
    let intersection = u16::try_from(old.intersection(&new).count()).ok()?;
    let token_count = u16::try_from(old.len() + new.len()).ok()?;
    Some((2.0 * f32::from(intersection)) / f32::from(token_count))
}

const fn confidence(parser_changed: bool) -> DiffConfidenceStatus {
    if parser_changed {
        DiffConfidenceStatus::Uncertain
    } else {
        DiffConfidenceStatus::Supported
    }
}

fn count_change(items: &[VersionDiffItem], change: VersionChangeType) -> u32 {
    u32::try_from(
        items
            .iter()
            .filter(|item| item.change_type == change)
            .count(),
    )
    .unwrap_or(u32::MAX)
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_label(value: &str, maximum: usize) -> bool {
    value == value.trim() && !value.is_empty() && value.chars().count() <= maximum
}

fn valid_failure_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn block_alignment_distinguishes_modified_moved_added_and_removed() {
        let old_ids = [Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7()];
        let new_ids = [Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7()];
        let old = [
            DiffBlock {
                id: old_ids[0],
                stable_key: "intro:0",
                content_hash: A,
                comparison_text: None,
                ordinal: 0,
            },
            DiffBlock {
                id: old_ids[1],
                stable_key: "method:0",
                content_hash: A,
                comparison_text: None,
                ordinal: 1,
            },
            DiffBlock {
                id: old_ids[2],
                stable_key: "removed:0",
                content_hash: B,
                comparison_text: None,
                ordinal: 2,
            },
        ];
        let new = [
            DiffBlock {
                id: new_ids[0],
                stable_key: "intro:0",
                content_hash: B,
                comparison_text: None,
                ordinal: 0,
            },
            DiffBlock {
                id: new_ids[1],
                stable_key: "renamed:0",
                content_hash: A,
                comparison_text: None,
                ordinal: 2,
            },
            DiffBlock {
                id: new_ids[2],
                stable_key: "added:0",
                content_hash: A,
                comparison_text: None,
                ordinal: 3,
            },
        ];
        let (summary, items) = align_document_blocks(&old, &new, true).unwrap();
        assert_eq!(summary.modified, 1);
        assert_eq!(summary.moved, 1);
        assert_eq!(summary.removed, 1);
        assert_eq!(summary.added, 1);
        assert!(
            items
                .iter()
                .all(|item| item.confidence_status == DiffConfidenceStatus::Uncertain)
        );
        assert!(!summary.warnings.is_empty());
    }

    #[test]
    fn block_alignment_uses_bounded_content_similarity_after_key_changes() {
        let old = [DiffBlock {
            id: Uuid::now_v7(),
            stable_key: "method:old:0",
            content_hash: A,
            comparison_text: Some(
                "We train the model with Adam for twenty epochs on the benchmark dataset.",
            ),
            ordinal: 12,
        }];
        let new = [DiffBlock {
            id: Uuid::now_v7(),
            stable_key: "experiments:new:0",
            content_hash: B,
            comparison_text: Some(
                "We train the revised model with Adam for twenty epochs on the benchmark dataset.",
            ),
            ordinal: 15,
        }];

        let (summary, items) = align_document_blocks(&old, &new, false).unwrap();
        assert_eq!(summary.modified, 1);
        assert_eq!(summary.added, 0);
        assert_eq!(summary.removed, 0);
        assert_eq!(items.len(), 1);
        assert!(items[0].similarity.is_some_and(|score| score > 0.8));
    }

    #[test]
    fn parser_changes_require_an_explicit_uncertainty_flag() {
        let diff = PaperVersionDiff {
            id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            from_generation: 1,
            to_generation: 2,
            from_arxiv_version: 1,
            to_arxiv_version: 2,
            algorithm_version: VERSION_DIFF_ALGORITHM_VERSION.to_owned(),
            schema_version: VERSION_DIFF_SCHEMA_VERSION.to_owned(),
            from_parser: ParserIdentity {
                parser_id: "grobid".to_owned(),
                parser_version: "0.9.0".to_owned(),
            },
            to_parser: ParserIdentity {
                parser_id: "docling".to_owned(),
                parser_version: "2.0".to_owned(),
            },
            parser_change_uncertainty: false,
            status: VersionDiffStatus::Ready,
            summary: VersionDiffSummary {
                added: 0,
                removed: 0,
                modified: 0,
                moved: 0,
                warnings: Vec::new(),
            },
            failure_code: None,
            items: Vec::new(),
            created_at: Utc::now(),
            completed_at: Some(Utc::now()),
        };
        assert_eq!(
            diff.validate(),
            Err(VersionDiffValidationError::MissingParserUncertainty)
        );
    }

    #[test]
    fn retained_manifest_requires_an_explicit_source_version() {
        let mut manifest = DocumentVersionManifest {
            paper_id: Uuid::now_v7(),
            generation: 4,
            arxiv_version: 3,
            schema_version: "document-blocks-v1".to_owned(),
            parser: ParserIdentity {
                parser_id: "grobid".to_owned(),
                parser_version: "0.9.0".to_owned(),
            },
            document_hash: A.to_owned(),
            is_current: true,
            created_at: Utc::now(),
        };
        manifest.validate().unwrap();
        manifest.arxiv_version = 0;
        assert_eq!(
            manifest.validate(),
            Err(VersionDiffValidationError::InvalidManifest)
        );
    }

    #[test]
    fn persisted_names_round_trip_fail_closed() {
        for status in [
            VersionDiffStatus::Pending,
            VersionDiffStatus::Ready,
            VersionDiffStatus::Partial,
            VersionDiffStatus::Failed,
        ] {
            assert_eq!(VersionDiffStatus::parse(status.as_str()), Some(status));
        }
        assert_eq!(VersionDiffStatus::parse("complete"), None);
        assert_eq!(
            VersionDiffItemKind::parse("annotation_anchor"),
            Some(VersionDiffItemKind::AnnotationAnchor)
        );
        assert_eq!(VersionChangeType::parse("rewritten"), None);
        assert_eq!(DiffConfidenceStatus::parse("certain"), None);
    }
}
