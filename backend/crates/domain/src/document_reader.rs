use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use unicode_normalization::UnicodeNormalization as _;
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration};

pub const DOCUMENT_SCHEMA_VERSION: &str = "document-blocks-v1";
pub const TABLE_STRUCTURE_SCHEMA_VERSION: &str = "table-grid-v1";
const MAX_BLOCK_SCALARS: usize = 1_000_000;
const MAX_SECTION_DEPTH: usize = 32;
const MAX_INLINE_SPANS: usize = 20_000;
const MAX_BLOCKS: usize = 200_000;
pub const MAX_DOCUMENT_FIGURES: usize = 2_048;
pub const MAX_DOCUMENT_TABLES: usize = 2_048;
pub const MAX_DOCUMENT_EQUATIONS: usize = 4_096;
pub const MAX_VISUAL_ASSET_DIMENSION: u32 = 4_096;
pub const MAX_VISUAL_ASSET_PIXELS: u64 = 16 * 1024 * 1024;
pub const MAX_TABLE_ROWS: usize = 512;
pub const MAX_TABLE_COLUMNS: usize = 64;
pub const MAX_TABLE_CELLS: usize = 8_192;
pub const MAX_TABLE_CELL_SCALARS: usize = 16_000;
pub const MAX_TABLE_PLAIN_TEXT_SCALARS: usize = 64_000;
const MAX_TERMS: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DocumentBlockKind {
    Heading,
    Paragraph,
    ListItem,
    Quote,
    TheoremDefinition,
    Caption,
    EquationContext,
    TableContext,
    FigureContext,
    Footnote,
    Other,
}

impl DocumentBlockKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Heading => "heading",
            Self::Paragraph => "paragraph",
            Self::ListItem => "list_item",
            Self::Quote => "quote",
            Self::TheoremDefinition => "theorem_definition",
            Self::Caption => "caption",
            Self::EquationContext => "equation_context",
            Self::TableContext => "table_context",
            Self::FigureContext => "figure_context",
            Self::Footnote => "footnote",
            Self::Other => "other",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "heading" => Self::Heading,
            "paragraph" => Self::Paragraph,
            "list_item" => Self::ListItem,
            "quote" => Self::Quote,
            "theorem_definition" => Self::TheoremDefinition,
            "caption" => Self::Caption,
            "equation_context" => Self::EquationContext,
            "table_context" => Self::TableContext,
            "figure_context" => Self::FigureContext,
            "footnote" => Self::Footnote,
            "other" => Self::Other,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InlineSpanKind {
    BibliographyReference,
    FigureReference,
    TableReference,
    EquationReference,
    Footnote,
    Term,
    Symbol,
    ExternalResource,
}

impl InlineSpanKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BibliographyReference => "bibliography_reference",
            Self::FigureReference => "figure_reference",
            Self::TableReference => "table_reference",
            Self::EquationReference => "equation_reference",
            Self::Footnote => "footnote",
            Self::Term => "term",
            Self::Symbol => "symbol",
            Self::ExternalResource => "external_resource",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InlineSpan {
    pub kind: InlineSpanKind,
    /// Inclusive Unicode-scalar offset.
    pub start: u32,
    /// Exclusive Unicode-scalar offset.
    pub end: u32,
    pub target_id: Option<String>,
    pub label: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NormalizedBoundingBox {
    pub left: f32,
    pub top: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceLocator {
    /// Parser-owned element identifier, never a filesystem path.
    pub source_element_id: Option<String>,
    /// Legacy section ordinal used to link an additive block back to
    /// `paper_sections` during the compatibility window.
    pub legacy_section_ordinal: Option<u32>,
    pub page_number: Option<u32>,
    pub bounding_box: Option<NormalizedBoundingBox>,
}

impl SourceLocator {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        if self.source_element_id.as_deref().is_some_and(|value| {
            !valid_bounded_label(value, 256) || value.contains(['/', '\\']) || value.contains("..")
        }) {
            return Err(DocumentValidationError::InvalidSourceLocator);
        }
        if self.page_number == Some(0) {
            return Err(DocumentValidationError::InvalidSourceLocator);
        }
        if let Some(bounds) = self.bounding_box {
            let values = [bounds.left, bounds.top, bounds.width, bounds.height];
            if values.iter().any(|value| !value.is_finite())
                || bounds.left < 0.0
                || bounds.top < 0.0
                || bounds.width <= 0.0
                || bounds.height <= 0.0
                || bounds.left + bounds.width > 1.0
                || bounds.top + bounds.height > 1.0
                || self.page_number.is_none()
            {
                return Err(DocumentValidationError::InvalidSourceLocator);
            }
        }
        if self.source_element_id.is_none()
            && self.legacy_section_ordinal.is_none()
            && self.page_number.is_none()
        {
            return Err(DocumentValidationError::InvalidSourceLocator);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentBlock {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub stable_key: String,
    pub ordinal: u32,
    pub section_path: Vec<String>,
    pub kind: DocumentBlockKind,
    pub text: String,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub source_locator: Option<SourceLocator>,
    pub content_hash: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub inline_spans: Vec<InlineSpan>,
}

impl DocumentBlock {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        validate_scope(self.id, self.paper_id, self.generation)?;
        let scalar_count = self.text.chars().count();
        if scalar_count == 0
            || scalar_count > MAX_BLOCK_SCALARS
            || self.text.trim().is_empty()
            || self.text.contains('\0')
            || !valid_hash(&self.content_hash)
            || self.content_hash != content_hash(&self.text)
            || !valid_stable_key(&self.stable_key)
            || self.section_path.len() > MAX_SECTION_DEPTH
            || self
                .section_path
                .iter()
                .any(|component| !valid_bounded_label(component, 512))
            || self.inline_spans.len() > MAX_INLINE_SPANS
            || invalid_page_range(self.page_start, self.page_end)
        {
            return Err(DocumentValidationError::InvalidBlock);
        }
        if let Some(locator) = &self.source_locator {
            locator.validate()?;
        }
        for span in &self.inline_spans {
            validate_span(span, scalar_count)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FigureExtractionStatus {
    Ready,
    CaptionOnly,
    Uncertain,
    Unavailable,
}

impl FigureExtractionStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::CaptionOnly => "caption_only",
            Self::Uncertain => "uncertain",
            Self::Unavailable => "unavailable",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "ready" => Self::Ready,
            "caption_only" => Self::CaptionOnly,
            "uncertain" => Self::Uncertain,
            "unavailable" => Self::Unavailable,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentFigure {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub label: String,
    pub ordinal: u32,
    pub caption: String,
    pub page_number: Option<u32>,
    /// Internal object-store key. API DTOs must not expose it directly.
    pub asset_key: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub extraction_status: FigureExtractionStatus,
    pub content_hash: String,
    pub source_locator: Option<SourceLocator>,
}

impl DocumentFigure {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        validate_scope(self.id, self.paper_id, self.generation)?;
        let has_complete_asset = self.asset_key.is_some() && self.width.is_some();
        let dimensions_are_safe = match (self.width, self.height) {
            (Some(width), Some(height)) => valid_visual_asset_dimensions(width, height),
            (None, None) => true,
            _ => false,
        };
        let asset_state_is_honest = match self.extraction_status {
            FigureExtractionStatus::Ready => has_complete_asset,
            FigureExtractionStatus::CaptionOnly
            | FigureExtractionStatus::Uncertain
            | FigureExtractionStatus::Unavailable => {
                self.asset_key.is_none() && self.width.is_none() && self.height.is_none()
            }
        };
        if !valid_bounded_label(&self.label, 128)
            || !valid_text(&self.caption, 100_000)
            || self.page_number == Some(0)
            || self.width == Some(0)
            || self.height == Some(0)
            || self.width.is_some() != self.height.is_some()
            || !dimensions_are_safe
            || self
                .asset_key
                .as_deref()
                .is_some_and(|key| !valid_visual_asset_key(key))
            || !valid_hash(&self.content_hash)
            || !asset_state_is_honest
        {
            return Err(DocumentValidationError::InvalidFigure);
        }
        if let Some(locator) = &self.source_locator {
            locator.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TableExtractionStatus {
    Ready,
    Partial,
    Uncertain,
    Unavailable,
}

impl TableExtractionStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Partial => "partial",
            Self::Uncertain => "uncertain",
            Self::Unavailable => "unavailable",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "ready" => Self::Ready,
            "partial" => Self::Partial,
            "uncertain" => Self::Uncertain,
            "unavailable" => Self::Unavailable,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TableCell {
    pub text: String,
    pub header: bool,
    pub row_span: u16,
    pub column_span: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TableStructure {
    pub schema_version: String,
    pub rows: Vec<Vec<TableCell>>,
}

impl TableStructure {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        if self.schema_version != TABLE_STRUCTURE_SCHEMA_VERSION
            || self.rows.len() > MAX_TABLE_ROWS
            || self.rows.iter().flatten().count() > MAX_TABLE_CELLS
            || self.rows.iter().any(|row| row.len() > MAX_TABLE_COLUMNS)
            || self.rows.iter().any(|row| {
                row.iter()
                    .map(|cell| usize::from(cell.column_span))
                    .sum::<usize>()
                    > MAX_TABLE_COLUMNS
            })
            || self.rows.iter().flatten().any(|cell| {
                cell.row_span == 0
                    || cell.column_span == 0
                    || usize::from(cell.row_span) > MAX_TABLE_ROWS
                    || usize::from(cell.column_span) > MAX_TABLE_COLUMNS
                    || cell.text.chars().count() > MAX_TABLE_CELL_SCALARS
                    || cell.text.contains('\0')
            })
        {
            return Err(DocumentValidationError::InvalidTable);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentTable {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub label: String,
    pub ordinal: u32,
    pub caption: String,
    pub page_number: Option<u32>,
    pub structure: TableStructure,
    pub plain_text: String,
    pub extraction_status: TableExtractionStatus,
    pub content_hash: String,
    pub source_locator: Option<SourceLocator>,
}

impl DocumentTable {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        validate_scope(self.id, self.paper_id, self.generation)?;
        self.structure.validate()?;
        if !valid_bounded_label(&self.label, 128)
            || !valid_text(&self.caption, 100_000)
            || !valid_text(&self.plain_text, MAX_TABLE_PLAIN_TEXT_SCALARS)
            || self.page_number == Some(0)
            || !valid_hash(&self.content_hash)
        {
            return Err(DocumentValidationError::InvalidTable);
        }
        if let Some(locator) = &self.source_locator {
            locator.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EquationConfidenceStatus {
    Supported,
    Partial,
    Uncertain,
    Unavailable,
}

impl EquationConfidenceStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Partial => "partial",
            Self::Uncertain => "uncertain",
            Self::Unavailable => "unavailable",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "supported" => Self::Supported,
            "partial" => Self::Partial,
            "uncertain" => Self::Uncertain,
            "unavailable" => Self::Unavailable,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentEquation {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub label: Option<String>,
    pub ordinal: u32,
    pub latex: Option<String>,
    pub mathml: Option<String>,
    pub plain_text: Option<String>,
    pub context_block_id: Option<Uuid>,
    pub page_number: Option<u32>,
    pub confidence_status: EquationConfidenceStatus,
    pub content_hash: String,
    pub source_locator: Option<SourceLocator>,
}

impl DocumentEquation {
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        validate_scope(self.id, self.paper_id, self.generation)?;
        if self
            .label
            .as_deref()
            .is_some_and(|value| !valid_bounded_label(value, 128))
            || self
                .latex
                .as_deref()
                .is_some_and(|value| !valid_text(value, 100_000))
            || self
                .mathml
                .as_deref()
                .is_some_and(|value| !valid_text(value, 500_000))
            || self
                .plain_text
                .as_deref()
                .is_some_and(|value| !valid_text(value, 100_000))
            || (self.latex.is_none()
                && self.mathml.is_none()
                && self.plain_text.is_none()
                && self.context_block_id.is_none())
            || self.page_number == Some(0)
            || !valid_hash(&self.content_hash)
        {
            return Err(DocumentValidationError::InvalidEquation);
        }
        if let Some(locator) = &self.source_locator {
            locator.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TermKind {
    Term,
    Acronym,
    Symbol,
    Method,
    Dataset,
}

impl TermKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Term => "term",
            Self::Acronym => "acronym",
            Self::Symbol => "symbol",
            Self::Method => "method",
            Self::Dataset => "dataset",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "term" => Self::Term,
            "acronym" => Self::Acronym,
            "symbol" => Self::Symbol,
            "method" => Self::Method,
            "dataset" => Self::Dataset,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DefinitionStatus {
    Available,
    NotFound,
    NotApplicable,
    Uncertain,
}

impl DefinitionStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::NotFound => "not_found",
            Self::NotApplicable => "not_applicable",
            Self::Uncertain => "uncertain",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "available" => Self::Available,
            "not_found" => Self::NotFound,
            "not_applicable" => Self::NotApplicable,
            "uncertain" => Self::Uncertain,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentTerm {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub normalized_term: String,
    pub display_term: String,
    pub kind: TermKind,
    pub canonical_topic_id: Option<Uuid>,
    pub definition_status: DefinitionStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TermOccurrence {
    pub term_id: Uuid,
    pub block_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub start_offset: u32,
    pub end_offset: u32,
    pub occurrence_ordinal: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DefinitionSourceType {
    CurrentPaper,
    CitedPaper,
    Glossary,
    Generated,
}

impl DefinitionSourceType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CurrentPaper => "current_paper",
            Self::CitedPaper => "cited_paper",
            Self::Glossary => "glossary",
            Self::Generated => "generated",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "current_paper" => Self::CurrentPaper,
            "cited_paper" => Self::CitedPaper,
            "glossary" => Self::Glossary,
            "generated" => Self::Generated,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DefinitionConfidenceStatus {
    Supported,
    Inferred,
    Uncertain,
}

impl DefinitionConfidenceStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Inferred => "inferred",
            Self::Uncertain => "uncertain",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "supported" => Self::Supported,
            "inferred" => Self::Inferred,
            "uncertain" => Self::Uncertain,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TermDefinition {
    pub id: Uuid,
    pub term_id: Uuid,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub source_type: DefinitionSourceType,
    pub source_block_ids: Vec<Uuid>,
    pub definition: String,
    pub model_id: Option<String>,
    pub prompt_version: Option<String>,
    pub confidence_status: DefinitionConfidenceStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentTermDetails {
    #[serde(flatten)]
    pub term: DocumentTerm,
    pub occurrences: Vec<TermOccurrence>,
    pub definitions: Vec<TermDefinition>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NormalizedDocument {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    /// Source manifestation version. Persistence must verify this against the
    /// authoritative paper row while holding the generation publication lock.
    pub arxiv_version: u32,
    pub schema_version: String,
    pub parser_id: String,
    pub parser_version: String,
    pub blocks: Vec<DocumentBlock>,
    pub figures: Vec<DocumentFigure>,
    pub tables: Vec<DocumentTable>,
    pub equations: Vec<DocumentEquation>,
    pub terms: Vec<DocumentTerm>,
    pub term_occurrences: Vec<TermOccurrence>,
    pub term_definitions: Vec<TermDefinition>,
}

impl NormalizedDocument {
    #[allow(clippy::too_many_lines)]
    pub fn validate(&self) -> Result<(), DocumentValidationError> {
        if self.paper_id.is_nil()
            || self.generation <= 0
            || self.arxiv_version == 0
            || self.arxiv_version > 2_147_483_647
            || self.schema_version != DOCUMENT_SCHEMA_VERSION
            || !valid_bounded_label(&self.parser_id, 64)
            || !valid_bounded_label(&self.parser_version, 128)
            || self.blocks.is_empty()
            || self.blocks.len() > MAX_BLOCKS
            || self.figures.len() > MAX_DOCUMENT_FIGURES
            || self.tables.len() > MAX_DOCUMENT_TABLES
            || self.equations.len() > MAX_DOCUMENT_EQUATIONS
            || self.terms.len() > MAX_TERMS
        {
            return Err(DocumentValidationError::InvalidManifest);
        }

        let mut block_ids = HashSet::new();
        let mut block_ordinals = HashSet::new();
        let mut stable_keys = HashSet::new();
        let mut blocks_by_id = HashMap::new();
        for block in &self.blocks {
            require_document_scope(self, block.paper_id, block.generation)?;
            block.validate()?;
            if !block_ids.insert(block.id)
                || !block_ordinals.insert(block.ordinal)
                || !stable_keys.insert(block.stable_key.as_str())
            {
                return Err(DocumentValidationError::DuplicateArtifact);
            }
            blocks_by_id.insert(block.id, block);
        }

        validate_object_set(self, &self.figures, |value| {
            value.validate()?;
            Ok((value.id, value.paper_id, value.generation, value.ordinal))
        })?;
        validate_object_set(self, &self.tables, |value| {
            value.validate()?;
            Ok((value.id, value.paper_id, value.generation, value.ordinal))
        })?;
        validate_object_set(self, &self.equations, |value| {
            value.validate()?;
            if value
                .context_block_id
                .is_some_and(|block_id| !blocks_by_id.contains_key(&block_id))
            {
                return Err(DocumentValidationError::CrossScopeReference);
            }
            Ok((value.id, value.paper_id, value.generation, value.ordinal))
        })?;

        let mut term_ids = HashSet::new();
        let mut term_keys = HashSet::new();
        for term in &self.terms {
            require_document_scope(self, term.paper_id, term.generation)?;
            validate_scope(term.id, term.paper_id, term.generation)?;
            if normalize_term(&term.display_term) != term.normalized_term
                || term.normalized_term.chars().count() > 512
                || !term_ids.insert(term.id)
                || !term_keys.insert((term.normalized_term.as_str(), term.kind))
            {
                return Err(DocumentValidationError::InvalidTerm);
            }
        }

        let mut occurrence_keys = HashSet::new();
        for occurrence in &self.term_occurrences {
            require_document_scope(self, occurrence.paper_id, occurrence.generation)?;
            let block = blocks_by_id
                .get(&occurrence.block_id)
                .ok_or(DocumentValidationError::CrossScopeReference)?;
            if !term_ids.contains(&occurrence.term_id)
                || occurrence.start_offset >= occurrence.end_offset
                || usize::try_from(occurrence.end_offset)
                    .map_or(true, |end| end > block.text.chars().count())
                || !occurrence_keys.insert((
                    occurrence.term_id,
                    occurrence.block_id,
                    occurrence.occurrence_ordinal,
                ))
            {
                return Err(DocumentValidationError::InvalidTermOccurrence);
            }
        }

        let mut definition_ids = HashSet::new();
        for definition in &self.term_definitions {
            require_document_scope(self, definition.paper_id, definition.generation)?;
            validate_scope(definition.id, definition.paper_id, definition.generation)?;
            if !definition_ids.insert(definition.id)
                || !term_ids.contains(&definition.term_id)
                || !valid_text(&definition.definition, 100_000)
                || definition.source_block_ids.len() > 64
                || definition
                    .source_block_ids
                    .iter()
                    .collect::<HashSet<_>>()
                    .len()
                    != definition.source_block_ids.len()
                || definition
                    .source_block_ids
                    .iter()
                    .any(|block_id| !blocks_by_id.contains_key(block_id))
                || (definition.source_type != DefinitionSourceType::Generated
                    && definition.source_block_ids.is_empty())
                || definition
                    .model_id
                    .as_deref()
                    .is_some_and(|value| !valid_bounded_label(value, 128))
                || definition
                    .prompt_version
                    .as_deref()
                    .is_some_and(|value| !valid_bounded_label(value, 128))
            {
                return Err(DocumentValidationError::InvalidTermDefinition);
            }
        }
        Ok(())
    }

    #[must_use]
    pub fn document_hash(&self) -> String {
        let mut hasher = Sha256::new();
        hash_part(&mut hasher, b"pakperk/normalized-document/v2");
        hash_part(&mut hasher, &self.arxiv_version.to_be_bytes());
        hash_part(&mut hasher, self.schema_version.as_bytes());
        hash_part(&mut hasher, self.parser_id.as_bytes());
        hash_part(&mut hasher, self.parser_version.as_bytes());

        let mut blocks = self.blocks.iter().collect::<Vec<_>>();
        blocks.sort_by_key(|block| block.ordinal);
        for block in blocks {
            hash_part(&mut hasher, block.stable_key.as_bytes());
            hash_part(&mut hasher, block.content_hash.as_bytes());
        }
        for hash in sorted_object_hashes(&self.figures, |value| {
            (value.ordinal, value.content_hash.as_str())
        }) {
            hash_part(&mut hasher, hash.as_bytes());
        }
        for hash in sorted_object_hashes(&self.tables, |value| {
            (value.ordinal, value.content_hash.as_str())
        }) {
            hash_part(&mut hasher, hash.as_bytes());
        }
        for hash in sorted_object_hashes(&self.equations, |value| {
            (value.ordinal, value.content_hash.as_str())
        }) {
            hash_part(&mut hasher, hash.as_bytes());
        }

        let block_keys = self
            .blocks
            .iter()
            .map(|block| (block.id, block.stable_key.as_str()))
            .collect::<HashMap<_, _>>();
        let mut term_fingerprints = HashMap::new();
        let mut sorted_term_fingerprints = Vec::with_capacity(self.terms.len());
        for term in &self.terms {
            let fingerprint = term_fingerprint(term);
            term_fingerprints.insert(term.id, fingerprint.clone());
            sorted_term_fingerprints.push(fingerprint);
        }
        sorted_term_fingerprints.sort_unstable();
        hash_part(&mut hasher, b"terms");
        for fingerprint in sorted_term_fingerprints {
            hash_part(&mut hasher, fingerprint.as_bytes());
        }

        let mut occurrence_fingerprints = self
            .term_occurrences
            .iter()
            .map(|occurrence| occurrence_fingerprint(occurrence, &term_fingerprints, &block_keys))
            .collect::<Vec<_>>();
        occurrence_fingerprints.sort_unstable();
        hash_part(&mut hasher, b"term-occurrences");
        for fingerprint in occurrence_fingerprints {
            hash_part(&mut hasher, fingerprint.as_bytes());
        }

        let mut definition_fingerprints = self
            .term_definitions
            .iter()
            .map(|definition| definition_fingerprint(definition, &term_fingerprints, &block_keys))
            .collect::<Vec<_>>();
        definition_fingerprints.sort_unstable();
        hash_part(&mut hasher, b"term-definitions");
        for fingerprint in definition_fingerprints {
            hash_part(&mut hasher, fingerprint.as_bytes());
        }
        hex_digest(hasher.finalize())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentProvenanceSummary {
    pub arxiv_version: u32,
    pub parser_id: String,
    pub parser_version: String,
    pub schema_version: String,
    pub document_hash: String,
    pub generated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentOutlineEntry {
    pub block_id: Uuid,
    pub stable_key: String,
    pub ordinal: u32,
    pub section_path: Vec<String>,
    pub heading: String,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DocumentValidationError {
    #[error("document manifest is invalid")]
    InvalidManifest,
    #[error("document artifact scope is invalid")]
    InvalidScope,
    #[error("document block is invalid")]
    InvalidBlock,
    #[error("inline span offsets or target are invalid")]
    InvalidInlineSpan,
    #[error("source locator is invalid")]
    InvalidSourceLocator,
    #[error("figure artifact is invalid")]
    InvalidFigure,
    #[error("table artifact is invalid")]
    InvalidTable,
    #[error("equation artifact is invalid")]
    InvalidEquation,
    #[error("term artifact is invalid")]
    InvalidTerm,
    #[error("term occurrence is invalid")]
    InvalidTermOccurrence,
    #[error("term definition is invalid")]
    InvalidTermDefinition,
    #[error("artifact IDs, ordinals, or stable keys are duplicated")]
    DuplicateArtifact,
    #[error("artifact reference crosses paper or generation scope")]
    CrossScopeReference,
}

#[must_use]
pub fn normalize_document_text(value: &str) -> String {
    value
        .nfkc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[must_use]
pub fn normalize_term(value: &str) -> String {
    normalize_document_text(value).to_lowercase()
}

#[must_use]
pub fn content_hash(value: &str) -> String {
    let normalized = normalize_document_text(value);
    hex_digest(Sha256::digest(normalized.as_bytes()))
}

#[must_use]
pub fn stable_block_key(
    section_path: &[String],
    kind: DocumentBlockKind,
    local_ordinal: u32,
    text: &str,
) -> String {
    let mut hasher = Sha256::new();
    hash_part(&mut hasher, b"pakperk/stable-block/v1");
    for component in section_path {
        hash_part(
            &mut hasher,
            normalize_document_text(component).to_lowercase().as_bytes(),
        );
    }
    hash_part(&mut hasher, kind.as_str().as_bytes());
    hash_part(&mut hasher, &local_ordinal.to_be_bytes());
    hash_part(&mut hasher, content_hash(text).as_bytes());
    format!("blk_v1_{}", hex_digest(hasher.finalize()))
}

fn term_fingerprint(term: &DocumentTerm) -> String {
    let mut hasher = Sha256::new();
    hash_part(&mut hasher, b"term/v1");
    hash_part(&mut hasher, term.normalized_term.as_bytes());
    hash_part(
        &mut hasher,
        normalize_document_text(&term.display_term).as_bytes(),
    );
    hash_part(&mut hasher, term.kind.as_str().as_bytes());
    hash_part(&mut hasher, term.definition_status.as_str().as_bytes());
    hash_optional_bytes(
        &mut hasher,
        term.canonical_topic_id
            .as_ref()
            .map(|topic_id| topic_id.as_bytes().as_slice()),
    );
    hex_digest(hasher.finalize())
}

fn occurrence_fingerprint(
    occurrence: &TermOccurrence,
    term_fingerprints: &HashMap<Uuid, String>,
    block_keys: &HashMap<Uuid, &str>,
) -> String {
    let mut hasher = Sha256::new();
    hash_part(&mut hasher, b"term-occurrence/v1");
    hash_reference(
        &mut hasher,
        term_fingerprints.get(&occurrence.term_id),
        occurrence.term_id,
    );
    hash_reference(
        &mut hasher,
        block_keys.get(&occurrence.block_id),
        occurrence.block_id,
    );
    hash_part(&mut hasher, &occurrence.start_offset.to_be_bytes());
    hash_part(&mut hasher, &occurrence.end_offset.to_be_bytes());
    hash_part(&mut hasher, &occurrence.occurrence_ordinal.to_be_bytes());
    hex_digest(hasher.finalize())
}

fn definition_fingerprint(
    definition: &TermDefinition,
    term_fingerprints: &HashMap<Uuid, String>,
    block_keys: &HashMap<Uuid, &str>,
) -> String {
    let mut hasher = Sha256::new();
    hash_part(&mut hasher, b"term-definition/v1");
    hash_reference(
        &mut hasher,
        term_fingerprints.get(&definition.term_id),
        definition.term_id,
    );
    hash_part(&mut hasher, definition.source_type.as_str().as_bytes());
    let mut source_keys = definition
        .source_block_ids
        .iter()
        .map(|block_id| {
            block_keys
                .get(block_id)
                .map_or_else(|| block_id.simple().to_string(), ToString::to_string)
        })
        .collect::<Vec<_>>();
    source_keys.sort_unstable();
    for source_key in source_keys {
        hash_part(&mut hasher, source_key.as_bytes());
    }
    hash_part(&mut hasher, content_hash(&definition.definition).as_bytes());
    hash_optional_bytes(
        &mut hasher,
        definition.model_id.as_ref().map(String::as_bytes),
    );
    hash_optional_bytes(
        &mut hasher,
        definition.prompt_version.as_ref().map(String::as_bytes),
    );
    hash_part(
        &mut hasher,
        definition.confidence_status.as_str().as_bytes(),
    );
    hex_digest(hasher.finalize())
}

fn hash_reference<T: AsRef<str>>(hasher: &mut Sha256, value: Option<&T>, fallback: Uuid) {
    if let Some(value) = value {
        hash_part(hasher, value.as_ref().as_bytes());
    } else {
        hash_part(hasher, fallback.as_bytes());
    }
}

fn hash_optional_bytes(hasher: &mut Sha256, value: Option<&[u8]>) {
    match value {
        Some(value) => {
            hash_part(hasher, b"some");
            hash_part(hasher, value);
        }
        None => hash_part(hasher, b"none"),
    }
}

fn validate_span(span: &InlineSpan, scalar_count: usize) -> Result<(), DocumentValidationError> {
    let start =
        usize::try_from(span.start).map_err(|_| DocumentValidationError::InvalidInlineSpan)?;
    let end = usize::try_from(span.end).map_err(|_| DocumentValidationError::InvalidInlineSpan)?;
    let target_required = matches!(
        span.kind,
        InlineSpanKind::BibliographyReference
            | InlineSpanKind::FigureReference
            | InlineSpanKind::TableReference
            | InlineSpanKind::EquationReference
            | InlineSpanKind::Footnote
            | InlineSpanKind::ExternalResource
    );
    if start >= end
        || end > scalar_count
        || span
            .target_id
            .as_deref()
            .is_some_and(|value| !valid_bounded_label(value, 512))
        || (target_required && span.target_id.is_none())
        || span
            .label
            .as_deref()
            .is_some_and(|value| !valid_bounded_label(value, 512))
    {
        return Err(DocumentValidationError::InvalidInlineSpan);
    }
    Ok(())
}

fn validate_scope(
    id: Uuid,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<(), DocumentValidationError> {
    if id.is_nil() || paper_id.is_nil() || generation <= 0 {
        return Err(DocumentValidationError::InvalidScope);
    }
    Ok(())
}

fn require_document_scope(
    document: &NormalizedDocument,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<(), DocumentValidationError> {
    if paper_id != document.paper_id || generation != document.generation {
        return Err(DocumentValidationError::CrossScopeReference);
    }
    Ok(())
}

fn validate_object_set<T>(
    document: &NormalizedDocument,
    values: &[T],
    mut validate: impl FnMut(
        &T,
    ) -> Result<
        (Uuid, PaperId, ProcessingGeneration, u32),
        DocumentValidationError,
    >,
) -> Result<(), DocumentValidationError> {
    let mut ids = HashSet::new();
    let mut ordinals = HashSet::new();
    for value in values {
        let (id, paper_id, generation, ordinal) = validate(value)?;
        require_document_scope(document, paper_id, generation)?;
        if !ids.insert(id) || !ordinals.insert(ordinal) {
            return Err(DocumentValidationError::DuplicateArtifact);
        }
    }
    Ok(())
}

fn sorted_object_hashes<'a, T>(
    values: &'a [T],
    fields: impl FnMut(&'a T) -> (u32, &'a str),
) -> Vec<&'a str> {
    let mut values = values.iter().map(fields).collect::<Vec<_>>();
    values.sort_by_key(|(ordinal, _)| *ordinal);
    values.into_iter().map(|(_, hash)| hash).collect()
}

fn hash_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    hasher.update(value);
}

fn hex_digest(bytes: impl AsRef<[u8]>) -> String {
    let mut output = String::with_capacity(64);
    for byte in bytes.as_ref() {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn valid_stable_key(value: &str) -> bool {
    value.strip_prefix("blk_v1_").is_some_and(valid_hash)
}

fn valid_bounded_label(value: &str, maximum: usize) -> bool {
    let scalar_count = value.chars().count();
    scalar_count > 0
        && scalar_count <= maximum
        && value == value.trim()
        && !value.contains('\0')
        && !value
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\t'))
}

fn valid_text(value: &str, maximum: usize) -> bool {
    let scalar_count = value.chars().count();
    scalar_count > 0 && scalar_count <= maximum && !value.trim().is_empty() && !value.contains('\0')
}

fn valid_visual_asset_key(key: &str) -> bool {
    valid_bounded_label(key, 512)
        && !key.contains(['\\', '\0'])
        && key.split('/').all(|segment| {
            !segment.is_empty()
                && segment != "."
                && segment != ".."
                && segment.chars().all(|character| {
                    character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_')
                })
        })
}

#[must_use]
pub fn valid_visual_asset_dimensions(width: u32, height: u32) -> bool {
    width > 0
        && height > 0
        && width <= MAX_VISUAL_ASSET_DIMENSION
        && height <= MAX_VISUAL_ASSET_DIMENSION
        && u64::from(width) * u64::from(height) <= MAX_VISUAL_ASSET_PIXELS
}

fn invalid_page_range(start: Option<u32>, end: Option<u32>) -> bool {
    start == Some(0)
        || end == Some(0)
        || matches!((start, end), (Some(start), Some(end)) if end < start)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(text: &str) -> DocumentBlock {
        let section_path = vec!["Introduction".to_owned()];
        DocumentBlock {
            id: Uuid::now_v7(),
            paper_id: Uuid::now_v7(),
            generation: 1,
            stable_key: stable_block_key(&section_path, DocumentBlockKind::Paragraph, 0, text),
            ordinal: 0,
            section_path,
            kind: DocumentBlockKind::Paragraph,
            text: text.to_owned(),
            page_start: Some(1),
            page_end: Some(1),
            source_locator: Some(SourceLocator {
                source_element_id: Some("intro-p0".to_owned()),
                legacy_section_ordinal: Some(0),
                page_number: Some(1),
                bounding_box: None,
            }),
            content_hash: content_hash(text),
            inline_spans: Vec::new(),
        }
    }

    #[test]
    fn hashes_normalized_text_and_stable_keys_deterministically() {
        assert_eq!(
            content_hash("A  method\nworks"),
            content_hash("A method works")
        );
        let path = vec![" Méthod ".to_owned()];
        assert_eq!(
            stable_block_key(&path, DocumentBlockKind::Paragraph, 2, "value"),
            stable_block_key(&path, DocumentBlockKind::Paragraph, 2, "value")
        );
        assert_ne!(
            stable_block_key(&path, DocumentBlockKind::Paragraph, 2, "value"),
            stable_block_key(&path, DocumentBlockKind::Paragraph, 3, "value")
        );
    }

    #[test]
    fn inline_offsets_are_unicode_scalar_offsets() {
        let mut value = block("α😀 citation");
        value.inline_spans.push(InlineSpan {
            kind: InlineSpanKind::BibliographyReference,
            start: 2,
            end: 3,
            target_id: Some("reference:0".to_owned()),
            label: Some("citation".to_owned()),
        });
        assert!(value.validate().is_ok());
        value.inline_spans[0].end = 99;
        assert_eq!(
            value.validate(),
            Err(DocumentValidationError::InvalidInlineSpan)
        );
    }

    #[test]
    fn source_locator_rejects_parser_paths_and_invalid_boxes() {
        let locator = SourceLocator {
            source_element_id: Some("../../private/file".to_owned()),
            legacy_section_ordinal: None,
            page_number: Some(1),
            bounding_box: None,
        };
        assert_eq!(
            locator.validate(),
            Err(DocumentValidationError::InvalidSourceLocator)
        );
    }

    #[test]
    fn figure_asset_keys_are_relative_and_component_bounded() {
        assert!(valid_visual_asset_key("papers/fixture/figure-1.webp"));
        for key in [
            "/absolute/figure.webp",
            "../private/figure.webp",
            "paper//figure.webp",
            "paper\\figure.webp",
            "paper/<script>.webp",
        ] {
            assert!(!valid_visual_asset_key(key), "accepted unsafe key: {key}");
        }
    }

    #[test]
    fn visual_asset_dimensions_have_a_decoded_pixel_ceiling() {
        assert!(valid_visual_asset_dimensions(4_096, 4_096));
        assert!(!valid_visual_asset_dimensions(4_097, 1));
        assert!(!valid_visual_asset_dimensions(100_000, 100_000));
    }

    #[test]
    fn structured_tables_reject_mobile_hostile_shapes_before_delivery() {
        let cell = TableCell {
            text: "bounded".to_owned(),
            header: false,
            row_span: 1,
            column_span: 1,
        };
        let too_wide = TableStructure {
            schema_version: TABLE_STRUCTURE_SCHEMA_VERSION.to_owned(),
            rows: vec![vec![cell.clone(); MAX_TABLE_COLUMNS + 1]],
        };
        assert_eq!(
            too_wide.validate(),
            Err(DocumentValidationError::InvalidTable)
        );
        let too_many_rows = TableStructure {
            schema_version: TABLE_STRUCTURE_SCHEMA_VERSION.to_owned(),
            rows: vec![vec![cell]; MAX_TABLE_ROWS + 1],
        };
        assert_eq!(
            too_many_rows.validate(),
            Err(DocumentValidationError::InvalidTable)
        );
    }

    #[test]
    fn normalized_document_rejects_visual_lists_above_the_mobile_contract() {
        let block = block("Bounded visual list");
        let paper_id = block.paper_id;
        let generation = block.generation;
        let figures = (0..=MAX_DOCUMENT_FIGURES)
            .map(|ordinal| DocumentFigure {
                id: Uuid::now_v7(),
                paper_id,
                generation,
                label: format!("Figure {}", ordinal + 1),
                ordinal: u32::try_from(ordinal).unwrap(),
                caption: "Caption-only bounded fixture".to_owned(),
                page_number: Some(1),
                asset_key: None,
                width: None,
                height: None,
                extraction_status: FigureExtractionStatus::CaptionOnly,
                content_hash: content_hash(&format!("figure-{ordinal}")),
                source_locator: None,
            })
            .collect();
        let document = NormalizedDocument {
            paper_id,
            generation,
            arxiv_version: 1,
            schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
            parser_id: "fixture".to_owned(),
            parser_version: "1".to_owned(),
            blocks: vec![block],
            figures,
            tables: Vec::new(),
            equations: Vec::new(),
            terms: Vec::new(),
            term_occurrences: Vec::new(),
            term_definitions: Vec::new(),
        };

        assert_eq!(
            document.validate(),
            Err(DocumentValidationError::InvalidManifest)
        );
    }

    #[test]
    fn normalized_document_binds_hashes_to_an_explicit_source_version() {
        let block = block("Versioned content");
        let block_id = block.id;
        let paper_id = block.paper_id;
        let generation = block.generation;
        let term_id = Uuid::now_v7();
        let mut document = NormalizedDocument {
            paper_id,
            generation,
            arxiv_version: 1,
            schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
            parser_id: "grobid".to_owned(),
            parser_version: "fixture-v1".to_owned(),
            blocks: vec![block],
            figures: Vec::new(),
            tables: Vec::new(),
            equations: Vec::new(),
            terms: vec![DocumentTerm {
                id: term_id,
                paper_id,
                generation,
                normalized_term: "versioned".to_owned(),
                display_term: "Versioned".to_owned(),
                kind: TermKind::Term,
                canonical_topic_id: None,
                definition_status: DefinitionStatus::Available,
            }],
            term_occurrences: vec![TermOccurrence {
                term_id,
                block_id,
                paper_id,
                generation,
                start_offset: 0,
                end_offset: 9,
                occurrence_ordinal: 0,
            }],
            term_definitions: vec![TermDefinition {
                id: Uuid::now_v7(),
                term_id,
                paper_id,
                generation,
                source_type: DefinitionSourceType::CurrentPaper,
                source_block_ids: vec![block_id],
                definition: "A source-bound fixture definition.".to_owned(),
                model_id: None,
                prompt_version: None,
                confidence_status: DefinitionConfidenceStatus::Supported,
            }],
        };
        document.validate().unwrap();
        let version_one_hash = document.document_hash();
        document.term_definitions[0].definition =
            "A materially different grounded definition.".to_owned();
        assert_ne!(document.document_hash(), version_one_hash);
        document.term_definitions[0].definition = "A source-bound fixture definition.".to_owned();
        document.arxiv_version = 2;
        document.validate().unwrap();
        assert_ne!(document.document_hash(), version_one_hash);
        document.arxiv_version = 0;
        assert_eq!(
            document.validate(),
            Err(DocumentValidationError::InvalidManifest)
        );
    }
}
