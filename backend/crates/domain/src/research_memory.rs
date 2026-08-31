use std::collections::HashSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration};

pub const ANNOTATION_BODY_MAX_SCALARS: usize = 100_000;
pub const ANNOTATION_QUOTE_MAX_SCALARS: usize = 20_000;
pub const EVIDENCE_CARD_TITLE_MAX_SCALARS: usize = 500;
pub const MEMORY_TEXT_MAX_SCALARS: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReaderMode {
    Skim,
    Read,
    Inspect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReaderStage {
    Abstract,
    Introduction,
    Connections,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnnotationKind {
    Highlight,
    Note,
    Question,
    Evidence,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnnotationColorRole {
    Yellow,
    Blue,
    Green,
    Pink,
    Purple,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnnotationAnchorStatus {
    Anchored,
    Uncertain,
    Orphaned,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextQuotePositionSelector {
    pub exact: String,
    pub prefix: Option<String>,
    pub suffix: Option<String>,
    /// Inclusive Unicode-scalar offset.
    pub start: Option<u32>,
    /// Exclusive Unicode-scalar offset.
    pub end: Option<u32>,
}

impl TextQuotePositionSelector {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        if !valid_text(&self.exact, ANNOTATION_QUOTE_MAX_SCALARS)
            || self
                .prefix
                .as_deref()
                .is_some_and(|value| !valid_context(value))
            || self
                .suffix
                .as_deref()
                .is_some_and(|value| !valid_context(value))
            || !matches!((self.start, self.end), (None, None) | (Some(_), Some(_)))
            || matches!((self.start, self.end), (Some(start), Some(end)) if start >= end)
        {
            return Err(ResearchArtifactValidationError::InvalidSelector);
        }
        Ok(())
    }

    /// Exact block verification is mandatory whenever position offsets are
    /// present; byte offsets are never accepted as a substitute.
    pub fn validate_against(
        &self,
        block_text: &str,
    ) -> Result<(), ResearchArtifactValidationError> {
        self.validate()?;
        match (self.start, self.end) {
            (Some(start), Some(end))
                if scalar_slice(block_text, start, end).as_deref() != Some(self.exact.as_str()) =>
            {
                return Err(ResearchArtifactValidationError::SelectorDoesNotMatchBlock);
            }
            (None, None) if exact_scalar_ranges(block_text, &self.exact).is_empty() => {
                return Err(ResearchArtifactValidationError::SelectorDoesNotMatchBlock);
            }
            _ => {}
        }
        Ok(())
    }
}

impl std::fmt::Debug for TextQuotePositionSelector {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TextQuotePositionSelector")
            .field("exact", &"[REDACTED]")
            .field("prefix", &self.prefix.as_ref().map(|_| "[REDACTED]"))
            .field("suffix", &self.suffix.as_ref().map(|_| "[REDACTED]"))
            .field("start", &self.start)
            .field("end", &self.end)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnnotationWrite {
    pub id: Uuid,
    pub operation_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub block_id: Option<Uuid>,
    pub kind: AnnotationKind,
    pub body: Option<String>,
    pub color_role: Option<AnnotationColorRole>,
    pub selector: TextQuotePositionSelector,
    #[serde(default)]
    pub section_hint: Vec<String>,
    pub page_hint: Option<u32>,
    /// Zero creates a client-generated UUID; positive values are optimistic
    /// concurrency preconditions.
    pub base_revision: i64,
}

impl AnnotationWrite {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        if self.id.is_nil()
            || self.operation_id.is_nil()
            || self.paper_id.is_nil()
            || self.generation <= 0
            || self.block_id == Some(Uuid::nil())
            || self.base_revision < 0
            || self.page_hint == Some(0)
            || self.section_hint.len() > 32
            || self
                .section_hint
                .iter()
                .any(|value| !valid_label(value, 512))
            || self
                .body
                .as_deref()
                .is_some_and(|value| !valid_text(value, ANNOTATION_BODY_MAX_SCALARS))
            || (!matches!(self.kind, AnnotationKind::Highlight) && self.body.is_none())
        {
            return Err(ResearchArtifactValidationError::InvalidAnnotation);
        }
        self.selector.validate()
    }
}

impl std::fmt::Debug for AnnotationWrite {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AnnotationWrite")
            .field("id", &self.id)
            .field("operation_id", &self.operation_id)
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("block_id", &self.block_id)
            .field("kind", &self.kind)
            .field("body", &self.body.as_ref().map(|_| "[REDACTED]"))
            .field("color_role", &self.color_role)
            .field("selector", &self.selector)
            .field("section_hint_count", &self.section_hint.len())
            .field("page_hint", &self.page_hint)
            .field("base_revision", &self.base_revision)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Annotation {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub block_id: Option<Uuid>,
    pub kind: AnnotationKind,
    pub body: Option<String>,
    pub color_role: Option<AnnotationColorRole>,
    pub selector: Option<TextQuotePositionSelector>,
    pub section_hint: Vec<String>,
    pub page_hint: Option<u32>,
    pub anchor_status: AnnotationAnchorStatus,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnnotationConflict {
    pub conflict_id: Uuid,
    pub annotation_id: Uuid,
    pub attempted_operation_id: Uuid,
    pub base_revision: i64,
    pub server_revision: i64,
    pub attempted_body: Option<String>,
    pub server_body: Option<String>,
    pub created_at: DateTime<Utc>,
    pub resolution: Option<AnnotationConflictResolution>,
    pub merged_body: Option<String>,
    pub resolved_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnnotationConflictResolution {
    KeepServer,
    KeepAttempted,
    Merged,
    Dismissed,
}

impl AnnotationConflict {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        if self.conflict_id.is_nil()
            || self.annotation_id.is_nil()
            || self.attempted_operation_id.is_nil()
            || self.base_revision < 0
            || self.server_revision <= 0
            || self.attempted_body == self.server_body
            || self
                .attempted_body
                .as_deref()
                .is_some_and(|value| !valid_text(value, ANNOTATION_BODY_MAX_SCALARS))
            || self
                .server_body
                .as_deref()
                .is_some_and(|value| !valid_text(value, ANNOTATION_BODY_MAX_SCALARS))
            || self
                .merged_body
                .as_deref()
                .is_some_and(|value| !valid_text(value, ANNOTATION_BODY_MAX_SCALARS))
            || self.resolution.is_some() != self.resolved_at.is_some()
            || (self.resolution == Some(AnnotationConflictResolution::Merged))
                != self.merged_body.is_some()
            || self
                .resolved_at
                .is_some_and(|resolved_at| resolved_at < self.created_at)
        {
            return Err(ResearchArtifactValidationError::InvalidAnnotationConflict);
        }
        Ok(())
    }
}

impl std::fmt::Debug for AnnotationConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AnnotationConflict")
            .field("conflict_id", &self.conflict_id)
            .field("annotation_id", &self.annotation_id)
            .field("attempted_operation_id", &self.attempted_operation_id)
            .field("base_revision", &self.base_revision)
            .field("server_revision", &self.server_revision)
            .field(
                "attempted_body",
                &self.attempted_body.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "server_body",
                &self.server_body.as_ref().map(|_| "[REDACTED]"),
            )
            .field("created_at", &self.created_at)
            .field("resolution", &self.resolution)
            .field(
                "merged_body",
                &self.merged_body.as_ref().map(|_| "[REDACTED]"),
            )
            .field("resolved_at", &self.resolved_at)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceVerificationStatus {
    UserSelected,
    UserReviewed,
    Superseded,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceCardWrite {
    pub id: Uuid,
    pub operation_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub title: String,
    pub claim_or_question: Option<String>,
    pub user_note: Option<String>,
    #[serde(default)]
    pub source_block_ids: Vec<Uuid>,
    #[serde(default)]
    pub figure_ids: Vec<Uuid>,
    #[serde(default)]
    pub table_ids: Vec<Uuid>,
    #[serde(default)]
    pub citation_context_ids: Vec<Uuid>,
    pub verification_status: EvidenceVerificationStatus,
    pub base_revision: i64,
}

impl EvidenceCardWrite {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        let source_count = self
            .source_block_ids
            .len()
            .saturating_add(self.figure_ids.len())
            .saturating_add(self.table_ids.len())
            .saturating_add(self.citation_context_ids.len());
        if self.id.is_nil()
            || self.operation_id.is_nil()
            || self.paper_id.is_nil()
            || self.generation <= 0
            || self.base_revision < 0
            || !valid_text(&self.title, EVIDENCE_CARD_TITLE_MAX_SCALARS)
            || self
                .claim_or_question
                .as_deref()
                .is_some_and(|value| !valid_text(value, 10_000))
            || self
                .user_note
                .as_deref()
                .is_some_and(|value| !valid_text(value, ANNOTATION_BODY_MAX_SCALARS))
            || source_count == 0
            || source_count > 192
            || !unique_non_nil(&self.source_block_ids)
            || !unique_non_nil(&self.figure_ids)
            || !unique_non_nil(&self.table_ids)
            || !unique_non_nil(&self.citation_context_ids)
        {
            return Err(ResearchArtifactValidationError::InvalidEvidenceCard);
        }
        Ok(())
    }
}

impl std::fmt::Debug for EvidenceCardWrite {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EvidenceCardWrite")
            .field("id", &self.id)
            .field("operation_id", &self.operation_id)
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("title", &"[REDACTED]")
            .field(
                "claim_or_question",
                &self.claim_or_question.as_ref().map(|_| "[REDACTED]"),
            )
            .field("user_note", &self.user_note.as_ref().map(|_| "[REDACTED]"))
            .field(
                "source_count",
                &(self.source_block_ids.len()
                    + self.figure_ids.len()
                    + self.table_ids.len()
                    + self.citation_context_ids.len()),
            )
            .field("verification_status", &self.verification_status)
            .field("base_revision", &self.base_revision)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidenceCard {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub title: Option<String>,
    pub claim_or_question: Option<String>,
    pub user_note: Option<String>,
    pub source_block_ids: Vec<Uuid>,
    pub figure_ids: Vec<Uuid>,
    pub table_ids: Vec<Uuid>,
    pub citation_context_ids: Vec<Uuid>,
    pub verification_status: EvidenceVerificationStatus,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadingCheckpointWrite {
    pub operation_id: Uuid,
    pub base_revision: i64,
    pub generation: ProcessingGeneration,
    pub mode: ReaderMode,
    pub stage: ReaderStage,
    pub block_id: Option<Uuid>,
    pub scroll_fraction: Option<f32>,
    pub last_read_at: DateTime<Utc>,
}

impl ReadingCheckpointWrite {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        if self.operation_id.is_nil()
            || self.base_revision < 0
            || self.generation <= 0
            || self.block_id == Some(Uuid::nil())
            || self
                .scroll_fraction
                .is_some_and(|value| !value.is_finite() || !(0.0..=1.0).contains(&value))
        {
            return Err(ResearchArtifactValidationError::InvalidCheckpoint);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingCheckpoint {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub mode: ReaderMode,
    pub stage: ReaderStage,
    pub block_id: Option<Uuid>,
    pub scroll_fraction: Option<f32>,
    pub last_read_at: DateTime<Utc>,
    pub revision: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemorySourceType {
    Annotation,
    EvidenceCard,
    PassportField,
    UserQuestion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    Active,
    Snoozed,
    Retired,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryItemWrite {
    pub id: Uuid,
    pub operation_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub source_type: MemorySourceType,
    pub source_id: Uuid,
    pub prompt_text: Option<String>,
    pub answer_text: Option<String>,
    pub status: MemoryStatus,
    pub next_review_at: Option<DateTime<Utc>>,
    pub base_revision: i64,
}

impl MemoryItemWrite {
    pub fn validate(&self) -> Result<(), ResearchArtifactValidationError> {
        if self.id.is_nil()
            || self.operation_id.is_nil()
            || self.paper_id.is_nil()
            || self.source_id.is_nil()
            || self.generation <= 0
            || self.base_revision < 0
            || self
                .prompt_text
                .as_deref()
                .is_some_and(|value| !valid_text(value, 10_000))
            || self
                .answer_text
                .as_deref()
                .is_some_and(|value| !valid_text(value, MEMORY_TEXT_MAX_SCALARS))
            || (matches!(self.status, MemoryStatus::Snoozed) != self.next_review_at.is_some())
        {
            return Err(ResearchArtifactValidationError::InvalidMemoryItem);
        }
        Ok(())
    }
}

impl std::fmt::Debug for MemoryItemWrite {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MemoryItemWrite")
            .field("id", &self.id)
            .field("operation_id", &self.operation_id)
            .field("paper_id", &self.paper_id)
            .field("generation", &self.generation)
            .field("source_type", &self.source_type)
            .field("source_id", &self.source_id)
            .field(
                "prompt_text",
                &self.prompt_text.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "answer_text",
                &self.answer_text.as_ref().map(|_| "[REDACTED]"),
            )
            .field("status", &self.status)
            .field("next_review_at", &self.next_review_at)
            .field("base_revision", &self.base_revision)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryItem {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub source_type: MemorySourceType,
    pub source_id: Uuid,
    pub prompt_text: Option<String>,
    pub answer_text: Option<String>,
    pub status: MemoryStatus,
    pub next_review_at: Option<DateTime<Utc>>,
    pub review_count: u32,
    pub revision: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReanchorStrategy {
    StableBlockExact,
    QuoteContext,
    FuzzyHighThreshold,
    Manual,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReanchorResult {
    pub status: AnnotationAnchorStatus,
    pub strategy: Option<ReanchorStrategy>,
    pub target_block_id: Option<Uuid>,
    pub start: Option<u32>,
    pub end: Option<u32>,
    pub similarity: Option<f32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReanchorBlock<'a> {
    pub id: Uuid,
    pub stable_key: &'a str,
    pub section_path: &'a [String],
    pub text: &'a str,
}

/// Conservative baseline re-anchoring. Exact matches can be committed;
/// fuzzy candidates are only marked uncertain for explicit user review.
#[must_use]
pub fn reanchor_annotation(
    selector: &TextQuotePositionSelector,
    prior_stable_key: Option<&str>,
    section_hint: &[String],
    candidates: &[ReanchorBlock<'_>],
) -> ReanchorResult {
    if selector.validate().is_err() {
        return orphaned();
    }
    if let Some(stable_key) = prior_stable_key
        && let Some(result) = unique_exact_match(
            selector,
            candidates
                .iter()
                .filter(|candidate| candidate.stable_key == stable_key),
            ReanchorStrategy::StableBlockExact,
            false,
        )
    {
        return result;
    }
    if let Some(result) = unique_exact_match(
        selector,
        candidates.iter().filter(|candidate| {
            section_hint.is_empty() || candidate.section_path.starts_with(section_hint)
        }),
        ReanchorStrategy::QuoteContext,
        true,
    ) {
        return result;
    }

    let quote_words = normalized_words(&selector.exact);
    let mut fuzzy = candidates
        .iter()
        .map(|candidate| {
            let similarity = jaccard(&quote_words, &normalized_words(candidate.text));
            (similarity, candidate.id)
        })
        .filter(|(similarity, _)| *similarity >= 0.92)
        .collect::<Vec<_>>();
    fuzzy.sort_by(|left, right| {
        right
            .0
            .total_cmp(&left.0)
            .then_with(|| left.1.cmp(&right.1))
    });
    if let Some((similarity, block_id)) = fuzzy.first().copied()
        && fuzzy
            .get(1)
            .is_none_or(|(runner_up, _)| similarity - runner_up >= 0.05)
    {
        return ReanchorResult {
            status: AnnotationAnchorStatus::Uncertain,
            strategy: Some(ReanchorStrategy::FuzzyHighThreshold),
            target_block_id: Some(block_id),
            start: None,
            end: None,
            similarity: Some(similarity),
        };
    }
    orphaned()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ResearchArtifactValidationError {
    #[error("text selector is invalid")]
    InvalidSelector,
    #[error("text selector does not match the trusted block")]
    SelectorDoesNotMatchBlock,
    #[error("annotation is invalid")]
    InvalidAnnotation,
    #[error("annotation conflict is invalid")]
    InvalidAnnotationConflict,
    #[error("evidence card is invalid")]
    InvalidEvidenceCard,
    #[error("reading checkpoint is invalid")]
    InvalidCheckpoint,
    #[error("memory item is invalid")]
    InvalidMemoryItem,
}

fn unique_exact_match<'a>(
    selector: &TextQuotePositionSelector,
    candidates: impl Iterator<Item = &'a ReanchorBlock<'a>>,
    strategy: ReanchorStrategy,
    require_context: bool,
) -> Option<ReanchorResult> {
    let mut matches = candidates.flat_map(|candidate| {
        exact_scalar_ranges(candidate.text, &selector.exact)
            .into_iter()
            .filter(move |(start, end)| {
                !require_context || context_matches(candidate.text, selector, *start, *end)
            })
            .map(move |(start, end)| (candidate.id, start, end))
    });
    let first = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    Some(ReanchorResult {
        status: AnnotationAnchorStatus::Anchored,
        strategy: Some(strategy),
        target_block_id: Some(first.0),
        start: Some(first.1),
        end: Some(first.2),
        similarity: Some(1.0),
    })
}

fn context_matches(text: &str, selector: &TextQuotePositionSelector, start: u32, end: u32) -> bool {
    let chars = text.chars().collect::<Vec<_>>();
    let start = usize::try_from(start).unwrap_or(usize::MAX);
    let end = usize::try_from(end).unwrap_or(usize::MAX);
    if end > chars.len() {
        return false;
    }
    let prefix_matches = selector.prefix.as_deref().is_none_or(|prefix| {
        let expected = prefix.chars().collect::<Vec<_>>();
        start >= expected.len() && chars[start - expected.len()..start] == expected
    });
    let suffix_matches = selector.suffix.as_deref().is_none_or(|suffix| {
        let expected = suffix.chars().collect::<Vec<_>>();
        end.saturating_add(expected.len()) <= chars.len()
            && chars[end..end + expected.len()] == expected
    });
    prefix_matches && suffix_matches
}

fn exact_scalar_ranges(text: &str, exact: &str) -> Vec<(u32, u32)> {
    let haystack = text.chars().collect::<Vec<_>>();
    let needle = exact.chars().collect::<Vec<_>>();
    if needle.is_empty() || needle.len() > haystack.len() {
        return Vec::new();
    }
    haystack
        .windows(needle.len())
        .enumerate()
        .filter(|(_, window)| *window == needle.as_slice())
        .filter_map(|(start, _)| {
            Some((
                u32::try_from(start).ok()?,
                u32::try_from(start + needle.len()).ok()?,
            ))
        })
        .collect()
}

fn scalar_slice(value: &str, start: u32, end: u32) -> Option<String> {
    let start = usize::try_from(start).ok()?;
    let end = usize::try_from(end).ok()?;
    if start >= end {
        return None;
    }
    let selected = value
        .chars()
        .skip(start)
        .take(end - start)
        .collect::<String>();
    (selected.chars().count() == end - start).then_some(selected)
}

fn normalized_words(value: &str) -> HashSet<String> {
    value
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| word.chars().count() > 1)
        .map(str::to_lowercase)
        .collect()
}

fn jaccard(left: &HashSet<String>, right: &HashSet<String>) -> f32 {
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let intersection = u16::try_from(left.intersection(right).count()).unwrap_or(u16::MAX);
    let union = u16::try_from(left.union(right).count()).unwrap_or(u16::MAX);
    f32::from(intersection) / f32::from(union)
}

const fn orphaned() -> ReanchorResult {
    ReanchorResult {
        status: AnnotationAnchorStatus::Orphaned,
        strategy: None,
        target_block_id: None,
        start: None,
        end: None,
        similarity: None,
    }
}

fn unique_non_nil(values: &[Uuid]) -> bool {
    values.iter().all(|value| !value.is_nil())
        && values.iter().copied().collect::<HashSet<_>>().len() == values.len()
}

fn valid_text(value: &str, maximum: usize) -> bool {
    !value.trim().is_empty() && !value.contains('\0') && value.chars().count() <= maximum
}

fn valid_context(value: &str) -> bool {
    !value.is_empty() && !value.contains('\0') && value.chars().count() <= 2_000
}

fn valid_label(value: &str, maximum: usize) -> bool {
    value == value.trim() && valid_text(value, maximum)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selector_offsets_are_unicode_scalars_not_bytes() {
        let selector = TextQuotePositionSelector {
            exact: "方法".to_owned(),
            prefix: Some("🙂 ".to_owned()),
            suffix: Some(" works".to_owned()),
            start: Some(3),
            end: Some(5),
        };
        selector.validate_against("α🙂 方法 works").unwrap();
        assert_eq!(
            selector.validate_against("α🙂 wrong"),
            Err(ResearchArtifactValidationError::SelectorDoesNotMatchBlock)
        );
    }

    #[test]
    fn positionless_selector_still_requires_an_exact_source_quote() {
        let selector = TextQuotePositionSelector {
            exact: "trusted quote".to_owned(),
            prefix: None,
            suffix: None,
            start: None,
            end: None,
        };
        assert_eq!(
            selector.validate_against("different source text"),
            Err(ResearchArtifactValidationError::SelectorDoesNotMatchBlock)
        );
    }

    #[test]
    fn conflict_resolution_and_merged_body_are_coherent() {
        let created_at = Utc::now();
        let mut conflict = AnnotationConflict {
            conflict_id: Uuid::now_v7(),
            annotation_id: Uuid::now_v7(),
            attempted_operation_id: Uuid::now_v7(),
            base_revision: 1,
            server_revision: 2,
            attempted_body: Some("attempted".to_owned()),
            server_body: Some("server".to_owned()),
            created_at,
            resolution: Some(AnnotationConflictResolution::Merged),
            merged_body: Some("merged".to_owned()),
            resolved_at: Some(created_at),
        };
        conflict.validate().unwrap();
        conflict.resolution = Some(AnnotationConflictResolution::KeepServer);
        assert_eq!(
            conflict.validate(),
            Err(ResearchArtifactValidationError::InvalidAnnotationConflict)
        );
        conflict.merged_body = None;
        conflict.validate().unwrap();
    }

    #[test]
    fn private_write_debug_output_is_redacted() {
        let marker = "PRIVATE NOTE MARKER";
        let write = AnnotationWrite {
            id: Uuid::now_v7(),
            operation_id: Uuid::now_v7(),
            base_revision: 0,
            paper_id: Uuid::now_v7(),
            generation: 2,
            block_id: Some(Uuid::now_v7()),
            kind: AnnotationKind::Note,
            body: Some(marker.to_owned()),
            color_role: Some(AnnotationColorRole::Yellow),
            selector: TextQuotePositionSelector {
                exact: marker.to_owned(),
                prefix: None,
                suffix: None,
                start: Some(0),
                end: Some(19),
            },
            section_hint: Vec::new(),
            page_hint: None,
        };
        let debug = format!("{write:?}");
        assert!(!debug.contains(marker));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn exact_reanchor_commits_but_fuzzy_reanchor_requires_review() {
        let exact_selector = TextQuotePositionSelector {
            exact: "critical method".to_owned(),
            prefix: Some("the ".to_owned()),
            suffix: Some(" works".to_owned()),
            start: None,
            end: None,
        };
        let section = vec!["Methods".to_owned()];
        let exact_id = Uuid::now_v7();
        let exact_text = "the critical method works";
        let exact = [ReanchorBlock {
            id: exact_id,
            stable_key: "method:0",
            section_path: &section,
            text: exact_text,
        }];
        let result = reanchor_annotation(&exact_selector, Some("method:0"), &section, &exact);
        assert_eq!(result.status, AnnotationAnchorStatus::Anchored);
        assert_eq!(result.target_block_id, Some(exact_id));

        let fuzzy_selector = TextQuotePositionSelector {
            exact: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty".to_owned(),
            prefix: None,
            suffix: None,
            start: None,
            end: None,
        };
        let fuzzy_id = Uuid::now_v7();
        let fuzzy_text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen changed sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty";
        let fuzzy = [ReanchorBlock {
            id: fuzzy_id,
            stable_key: "changed:0",
            section_path: &section,
            text: fuzzy_text,
        }];
        let result = reanchor_annotation(&fuzzy_selector, None, &section, &fuzzy);
        assert_eq!(result.status, AnnotationAnchorStatus::Uncertain);
        assert_eq!(result.target_block_id, Some(fuzzy_id));
    }

    #[test]
    fn stable_block_exact_survives_changed_context_without_silently_using_wrong_block() {
        let selector = TextQuotePositionSelector {
            exact: "critical method".to_owned(),
            prefix: Some("the old ".to_owned()),
            suffix: Some(" worked".to_owned()),
            start: Some(8),
            end: Some(23),
        };
        let section = vec!["Methods".to_owned()];
        let stable_id = Uuid::now_v7();
        let distractor_id = Uuid::now_v7();
        let candidates = [
            ReanchorBlock {
                id: stable_id,
                stable_key: "methods:p0",
                section_path: &section,
                text: "a revised critical method now works",
            },
            ReanchorBlock {
                id: distractor_id,
                stable_key: "methods:p1",
                section_path: &section,
                text: "the old critical method worked",
            },
        ];

        let result = reanchor_annotation(&selector, Some("methods:p0"), &section, &candidates);

        assert_eq!(result.status, AnnotationAnchorStatus::Anchored);
        assert_eq!(result.strategy, Some(ReanchorStrategy::StableBlockExact));
        assert_eq!(result.target_block_id, Some(stable_id));
        assert_eq!((result.start, result.end), (Some(10), Some(25)));
    }

    #[test]
    fn quote_context_requires_a_unique_context_match_before_committing() {
        let selector = TextQuotePositionSelector {
            exact: "shared quote".to_owned(),
            prefix: Some("expected ".to_owned()),
            suffix: Some(" suffix".to_owned()),
            start: None,
            end: None,
        };
        let section = vec!["Results".to_owned()];
        let expected_id = Uuid::now_v7();
        let candidates = [
            ReanchorBlock {
                id: Uuid::now_v7(),
                stable_key: "results:p0",
                section_path: &section,
                text: "different shared quote context",
            },
            ReanchorBlock {
                id: expected_id,
                stable_key: "results:p1",
                section_path: &section,
                text: "expected shared quote suffix",
            },
        ];

        let result = reanchor_annotation(&selector, None, &section, &candidates);

        assert_eq!(result.status, AnnotationAnchorStatus::Anchored);
        assert_eq!(result.strategy, Some(ReanchorStrategy::QuoteContext));
        assert_eq!(result.target_block_id, Some(expected_id));
    }

    #[test]
    fn tied_fuzzy_candidates_never_move_an_annotation() {
        let selector = TextQuotePositionSelector {
            exact: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty".to_owned(),
            prefix: None,
            suffix: None,
            start: None,
            end: None,
        };
        let section = vec!["Discussion".to_owned()];
        let candidates = [
            ReanchorBlock {
                id: Uuid::from_u128(1),
                stable_key: "discussion:p0",
                section_path: &section,
                text: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen changed sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty",
            },
            ReanchorBlock {
                id: Uuid::from_u128(2),
                stable_key: "discussion:p1",
                section_path: &section,
                text: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen changed sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty",
            },
        ];

        let result = reanchor_annotation(&selector, None, &[], &candidates);

        assert_eq!(result.status, AnnotationAnchorStatus::Orphaned);
        assert_eq!(result.target_block_id, None);
    }

    #[test]
    fn checkpoint_contract_contains_position_not_library_authority() {
        let json = serde_json::to_value(ReadingCheckpointWrite {
            operation_id: Uuid::now_v7(),
            base_revision: 0,
            generation: 1,
            mode: ReaderMode::Read,
            stage: ReaderStage::Introduction,
            block_id: None,
            scroll_fraction: Some(0.5),
            last_read_at: Utc::now(),
        })
        .unwrap();
        for forbidden in ["library_state", "reviewed", "archived", "queue_eligible"] {
            assert!(json.get(forbidden).is_none());
        }
    }

    #[test]
    fn memory_schedule_is_explicit_and_state_closed() {
        let mut write = MemoryItemWrite {
            id: Uuid::now_v7(),
            operation_id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 1,
            source_type: MemorySourceType::Annotation,
            source_id: Uuid::now_v7(),
            prompt_text: None,
            answer_text: None,
            status: MemoryStatus::Snoozed,
            next_review_at: None,
            base_revision: 0,
        };
        assert_eq!(
            write.validate(),
            Err(ResearchArtifactValidationError::InvalidMemoryItem)
        );
        write.next_review_at = Some(Utc::now());
        write.validate().unwrap();
    }
}
