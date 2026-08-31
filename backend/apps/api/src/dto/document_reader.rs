use std::collections::{HashMap, HashSet};

use db::{CurrentDocument, DocumentBlockPage, VisualObjectReference};
use domain::{
    DefinitionConfidenceStatus, DefinitionSourceType, DefinitionStatus, DocumentBlock,
    DocumentBlockKind, DocumentEquation, DocumentFigure, DocumentOutlineEntry,
    DocumentProvenanceSummary, DocumentTable, DocumentTermDetails, EquationConfidenceStatus,
    FigureExtractionStatus, InlineSpan, InlineSpanKind, NormalizedBoundingBox, SourceLocator,
    TableCell, TableExtractionStatus, TableStructure, TermKind,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::format_timestamp;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DocumentBlocksParams {
    pub(crate) cursor: Option<String>,
    pub(crate) section: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DocumentTermsParams {
    pub(crate) block_id: Option<Uuid>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentProvenanceResponse {
    pub(crate) arxiv_version: u32,
    pub(crate) parser_id: String,
    pub(crate) parser_version: String,
    pub(crate) schema_version: String,
    pub(crate) document_hash: String,
    #[schema(value_type = String, format = DateTime)]
    pub(crate) generated_at: String,
}

impl From<DocumentProvenanceSummary> for DocumentProvenanceResponse {
    fn from(value: DocumentProvenanceSummary) -> Self {
        Self {
            arxiv_version: value.arxiv_version,
            parser_id: value.parser_id,
            parser_version: value.parser_version,
            schema_version: value.schema_version,
            document_hash: value.document_hash,
            generated_at: format_timestamp(value.generated_at),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DocumentBlockKindResponse {
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

impl From<DocumentBlockKind> for DocumentBlockKindResponse {
    fn from(value: DocumentBlockKind) -> Self {
        match value {
            DocumentBlockKind::Heading => Self::Heading,
            DocumentBlockKind::Paragraph => Self::Paragraph,
            DocumentBlockKind::ListItem => Self::ListItem,
            DocumentBlockKind::Quote => Self::Quote,
            DocumentBlockKind::TheoremDefinition => Self::TheoremDefinition,
            DocumentBlockKind::Caption => Self::Caption,
            DocumentBlockKind::EquationContext => Self::EquationContext,
            DocumentBlockKind::TableContext => Self::TableContext,
            DocumentBlockKind::FigureContext => Self::FigureContext,
            DocumentBlockKind::Footnote => Self::Footnote,
            DocumentBlockKind::Other => Self::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum InlineSpanKindResponse {
    BibliographyReference,
    FigureReference,
    TableReference,
    EquationReference,
    Footnote,
    Term,
    Symbol,
    ExternalResource,
}

impl From<InlineSpanKind> for InlineSpanKindResponse {
    fn from(value: InlineSpanKind) -> Self {
        match value {
            InlineSpanKind::BibliographyReference => Self::BibliographyReference,
            InlineSpanKind::FigureReference => Self::FigureReference,
            InlineSpanKind::TableReference => Self::TableReference,
            InlineSpanKind::EquationReference => Self::EquationReference,
            InlineSpanKind::Footnote => Self::Footnote,
            InlineSpanKind::Term => Self::Term,
            InlineSpanKind::Symbol => Self::Symbol,
            InlineSpanKind::ExternalResource => Self::ExternalResource,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct InlineSpanResponse {
    pub(crate) kind: InlineSpanKindResponse,
    pub(crate) start: u32,
    pub(crate) end: u32,
    pub(crate) target_id: Option<String>,
    pub(crate) label: Option<String>,
}

impl From<InlineSpan> for InlineSpanResponse {
    fn from(value: InlineSpan) -> Self {
        Self {
            kind: value.kind.into(),
            start: value.start,
            end: value.end,
            target_id: value.target_id,
            label: value.label,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct BoundingBoxResponse {
    pub(crate) left: f32,
    pub(crate) top: f32,
    pub(crate) width: f32,
    pub(crate) height: f32,
}

impl From<NormalizedBoundingBox> for BoundingBoxResponse {
    fn from(value: NormalizedBoundingBox) -> Self {
        Self {
            left: value.left,
            top: value.top,
            width: value.width,
            height: value.height,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct SourceLocatorResponse {
    pub(crate) source_element_id: Option<String>,
    pub(crate) page_number: Option<u32>,
    pub(crate) bounding_box: Option<BoundingBoxResponse>,
}

impl From<SourceLocator> for SourceLocatorResponse {
    fn from(value: SourceLocator) -> Self {
        Self {
            source_element_id: value.source_element_id,
            page_number: value.page_number,
            bounding_box: value.bounding_box.map(Into::into),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentBlockResponse {
    pub(crate) id: Uuid,
    pub(crate) stable_key: String,
    pub(crate) ordinal: u32,
    pub(crate) section_path: Vec<String>,
    pub(crate) kind: DocumentBlockKindResponse,
    pub(crate) text: String,
    pub(crate) page_start: Option<u32>,
    pub(crate) page_end: Option<u32>,
    pub(crate) source_locator: Option<SourceLocatorResponse>,
    pub(crate) content_hash: String,
    pub(crate) inline_spans: Vec<InlineSpanResponse>,
}

impl From<DocumentBlock> for DocumentBlockResponse {
    fn from(value: DocumentBlock) -> Self {
        Self {
            id: value.id,
            stable_key: value.stable_key,
            ordinal: value.ordinal,
            section_path: value.section_path,
            kind: value.kind.into(),
            text: value.text,
            page_start: value.page_start,
            page_end: value.page_end,
            source_locator: value.source_locator.map(Into::into),
            content_hash: value.content_hash,
            inline_spans: value.inline_spans.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentOutlineEntryResponse {
    pub(crate) block_id: Uuid,
    pub(crate) stable_key: String,
    pub(crate) ordinal: u32,
    pub(crate) section_path: Vec<String>,
    pub(crate) heading: String,
    pub(crate) page_start: Option<u32>,
    pub(crate) page_end: Option<u32>,
}

impl From<DocumentOutlineEntry> for DocumentOutlineEntryResponse {
    fn from(value: DocumentOutlineEntry) -> Self {
        Self {
            block_id: value.block_id,
            stable_key: value.stable_key,
            ordinal: value.ordinal,
            section_path: value.section_path,
            heading: value.heading,
            page_start: value.page_start,
            page_end: value.page_end,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentOutlineEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<DocumentOutlineEntryResponse>,
}

impl From<CurrentDocument<Vec<DocumentOutlineEntry>>> for DocumentOutlineEnvelope {
    fn from(value: CurrentDocument<Vec<DocumentOutlineEntry>>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct DocumentBlocksEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<DocumentBlockResponse>,
    pub(crate) next_cursor: Option<String>,
}

impl From<CurrentDocument<DocumentBlockPage>> for DocumentBlocksEnvelope {
    fn from(value: CurrentDocument<DocumentBlockPage>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.items.into_iter().map(Into::into).collect(),
            next_cursor: value.value.next_cursor,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FigureExtractionStatusResponse {
    Ready,
    CaptionOnly,
    Uncertain,
    Unavailable,
}

impl From<FigureExtractionStatus> for FigureExtractionStatusResponse {
    fn from(value: FigureExtractionStatus) -> Self {
        match value {
            FigureExtractionStatus::Ready => Self::Ready,
            FigureExtractionStatus::CaptionOnly => Self::CaptionOnly,
            FigureExtractionStatus::Uncertain => Self::Uncertain,
            FigureExtractionStatus::Unavailable => Self::Unavailable,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct FigureResponse {
    pub(crate) id: Uuid,
    pub(crate) label: String,
    pub(crate) ordinal: u32,
    pub(crate) caption: String,
    pub(crate) page_number: Option<u32>,
    pub(crate) asset_available: bool,
    pub(crate) asset_requestable: bool,
    pub(crate) asset_url: Option<String>,
    pub(crate) width: Option<u32>,
    pub(crate) height: Option<u32>,
    pub(crate) extraction_status: FigureExtractionStatusResponse,
    pub(crate) content_hash: String,
    pub(crate) source_locator: Option<SourceLocatorResponse>,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) referenced_by: Vec<VisualObjectReferenceResponse>,
}

impl From<DocumentFigure> for FigureResponse {
    fn from(value: DocumentFigure) -> Self {
        Self {
            id: value.id,
            label: value.label,
            ordinal: value.ordinal,
            caption: value.caption,
            page_number: value.page_number,
            // `From` is deliberately caption-only. Only the route-aware
            // builder below may advertise the authenticated delivery URL.
            asset_available: false,
            asset_requestable: false,
            asset_url: None,
            width: value.width,
            height: value.height,
            extraction_status: value.extraction_status.into(),
            content_hash: value.content_hash,
            source_locator: value.source_locator.map(Into::into),
            source_block_ids: Vec::new(),
            referenced_by: Vec::new(),
        }
    }
}

impl FigureResponse {
    fn with_references(
        value: DocumentFigure,
        references: &mut HashMap<Uuid, Vec<VisualObjectReference>>,
        asset_delivery_available: bool,
        asset_delivery_requestable: bool,
    ) -> Self {
        let id = value.id;
        let paper_id = value.paper_id;
        let generation = value.generation;
        let asset_revision = value.asset_key.as_deref().and_then(|key| {
            crate::visual_assets::VisualAssetStore::figure_revision(key, paper_id, generation, id)
        });
        let asset_requestable = asset_delivery_requestable && asset_revision.is_some();
        let asset_available = asset_delivery_available && asset_requestable;
        let mut response = Self::from(value);
        response.asset_available = asset_available;
        response.asset_requestable = asset_requestable;
        response.asset_url = asset_revision.filter(|_| asset_requestable).map(|revision| {
            format!(
                "/v1/papers/{paper_id}/figures/{id}/asset?generation={generation}&revision={revision}"
            )
        });
        (response.source_block_ids, response.referenced_by) =
            take_visual_references(id, references);
        response
    }

    pub(crate) fn with_reference_list(
        value: DocumentFigure,
        references: Vec<VisualObjectReference>,
        asset_delivery_available: bool,
        asset_delivery_requestable: bool,
    ) -> Self {
        let mut references = group_visual_references(references);
        Self::with_references(
            value,
            &mut references,
            asset_delivery_available,
            asset_delivery_requestable,
        )
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct FiguresEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<FigureResponse>,
}

impl From<CurrentDocument<Vec<DocumentFigure>>> for FiguresEnvelope {
    fn from(value: CurrentDocument<Vec<DocumentFigure>>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.into_iter().map(Into::into).collect(),
        }
    }
}

impl FiguresEnvelope {
    pub(crate) fn with_references(
        value: CurrentDocument<Vec<DocumentFigure>>,
        references: Vec<VisualObjectReference>,
        available_assets: &HashSet<Uuid>,
        requestable_assets: &HashSet<Uuid>,
    ) -> Self {
        let mut references = group_visual_references(references);
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value
                .value
                .into_iter()
                .map(|figure| {
                    let asset_available = available_assets.contains(&figure.id);
                    let asset_requestable = requestable_assets.contains(&figure.id);
                    FigureResponse::with_references(
                        figure,
                        &mut references,
                        asset_available,
                        asset_requestable,
                    )
                })
                .collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct FigureEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) item: FigureResponse,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TableCellResponse {
    pub(crate) text: String,
    pub(crate) header: bool,
    pub(crate) row_span: u16,
    pub(crate) column_span: u16,
}

impl From<TableCell> for TableCellResponse {
    fn from(value: TableCell) -> Self {
        Self {
            text: value.text,
            header: value.header,
            row_span: value.row_span,
            column_span: value.column_span,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TableStructureResponse {
    pub(crate) schema_version: String,
    pub(crate) rows: Vec<Vec<TableCellResponse>>,
}

impl From<TableStructure> for TableStructureResponse {
    fn from(value: TableStructure) -> Self {
        Self {
            schema_version: value.schema_version,
            rows: value
                .rows
                .into_iter()
                .map(|row| row.into_iter().map(Into::into).collect())
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TableExtractionStatusResponse {
    Ready,
    Partial,
    Uncertain,
    Unavailable,
}

impl From<TableExtractionStatus> for TableExtractionStatusResponse {
    fn from(value: TableExtractionStatus) -> Self {
        match value {
            TableExtractionStatus::Ready => Self::Ready,
            TableExtractionStatus::Partial => Self::Partial,
            TableExtractionStatus::Uncertain => Self::Uncertain,
            TableExtractionStatus::Unavailable => Self::Unavailable,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TableResponse {
    pub(crate) id: Uuid,
    pub(crate) label: String,
    pub(crate) ordinal: u32,
    pub(crate) caption: String,
    pub(crate) page_number: Option<u32>,
    pub(crate) structure: TableStructureResponse,
    pub(crate) plain_text: String,
    pub(crate) extraction_status: TableExtractionStatusResponse,
    pub(crate) content_hash: String,
    pub(crate) source_locator: Option<SourceLocatorResponse>,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) referenced_by: Vec<VisualObjectReferenceResponse>,
}

impl From<DocumentTable> for TableResponse {
    fn from(value: DocumentTable) -> Self {
        Self {
            id: value.id,
            label: value.label,
            ordinal: value.ordinal,
            caption: value.caption,
            page_number: value.page_number,
            structure: value.structure.into(),
            plain_text: value.plain_text,
            extraction_status: value.extraction_status.into(),
            content_hash: value.content_hash,
            source_locator: value.source_locator.map(Into::into),
            source_block_ids: Vec::new(),
            referenced_by: Vec::new(),
        }
    }
}

impl TableResponse {
    fn with_references(
        value: DocumentTable,
        references: &mut HashMap<Uuid, Vec<VisualObjectReference>>,
    ) -> Self {
        let id = value.id;
        let mut response = Self::from(value);
        (response.source_block_ids, response.referenced_by) =
            take_visual_references(id, references);
        response
    }

    pub(crate) fn with_reference_list(
        value: DocumentTable,
        references: Vec<VisualObjectReference>,
    ) -> Self {
        let mut references = group_visual_references(references);
        Self::with_references(value, &mut references)
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TablesEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<TableResponse>,
}

impl From<CurrentDocument<Vec<DocumentTable>>> for TablesEnvelope {
    fn from(value: CurrentDocument<Vec<DocumentTable>>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.into_iter().map(Into::into).collect(),
        }
    }
}

impl TablesEnvelope {
    pub(crate) fn with_references(
        value: CurrentDocument<Vec<DocumentTable>>,
        references: Vec<VisualObjectReference>,
    ) -> Self {
        let mut references = group_visual_references(references);
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value
                .value
                .into_iter()
                .map(|table| TableResponse::with_references(table, &mut references))
                .collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TableEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) item: TableResponse,
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EquationConfidenceStatusResponse {
    Supported,
    Partial,
    Uncertain,
    Unavailable,
}

impl From<EquationConfidenceStatus> for EquationConfidenceStatusResponse {
    fn from(value: EquationConfidenceStatus) -> Self {
        match value {
            EquationConfidenceStatus::Supported => Self::Supported,
            EquationConfidenceStatus::Partial => Self::Partial,
            EquationConfidenceStatus::Uncertain => Self::Uncertain,
            EquationConfidenceStatus::Unavailable => Self::Unavailable,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct EquationResponse {
    pub(crate) id: Uuid,
    pub(crate) label: Option<String>,
    pub(crate) ordinal: u32,
    pub(crate) latex: Option<String>,
    pub(crate) mathml: Option<String>,
    pub(crate) plain_text: Option<String>,
    pub(crate) context_block_id: Option<Uuid>,
    pub(crate) page_number: Option<u32>,
    pub(crate) confidence_status: EquationConfidenceStatusResponse,
    pub(crate) content_hash: String,
    pub(crate) source_locator: Option<SourceLocatorResponse>,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) referenced_by: Vec<VisualObjectReferenceResponse>,
}

impl From<DocumentEquation> for EquationResponse {
    fn from(value: DocumentEquation) -> Self {
        Self {
            id: value.id,
            label: value.label,
            ordinal: value.ordinal,
            latex: value.latex,
            mathml: value.mathml,
            plain_text: value.plain_text,
            context_block_id: value.context_block_id,
            page_number: value.page_number,
            confidence_status: value.confidence_status.into(),
            content_hash: value.content_hash,
            source_locator: value.source_locator.map(Into::into),
            source_block_ids: Vec::new(),
            referenced_by: Vec::new(),
        }
    }
}

impl EquationResponse {
    fn with_references(
        value: DocumentEquation,
        references: &mut HashMap<Uuid, Vec<VisualObjectReference>>,
    ) -> Self {
        let id = value.id;
        let mut response = Self::from(value);
        (response.source_block_ids, response.referenced_by) =
            take_visual_references(id, references);
        response
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct EquationsEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<EquationResponse>,
}

impl From<CurrentDocument<Vec<DocumentEquation>>> for EquationsEnvelope {
    fn from(value: CurrentDocument<Vec<DocumentEquation>>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.into_iter().map(Into::into).collect(),
        }
    }
}

impl EquationsEnvelope {
    pub(crate) fn with_references(
        value: CurrentDocument<Vec<DocumentEquation>>,
        references: Vec<VisualObjectReference>,
    ) -> Self {
        let mut references = group_visual_references(references);
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value
                .value
                .into_iter()
                .map(|equation| EquationResponse::with_references(equation, &mut references))
                .collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct VisualObjectReferenceResponse {
    pub(crate) block_id: Uuid,
    pub(crate) start_offset: u32,
    pub(crate) end_offset: u32,
    pub(crate) marker: Option<String>,
    pub(crate) context: String,
    pub(crate) section_path: Vec<String>,
    pub(crate) page_number: Option<u32>,
}

fn group_visual_references(
    references: Vec<VisualObjectReference>,
) -> HashMap<Uuid, Vec<VisualObjectReference>> {
    let mut grouped = HashMap::new();
    for reference in references {
        grouped
            .entry(reference.object_id)
            .or_insert_with(Vec::new)
            .push(reference);
    }
    grouped
}

fn take_visual_references(
    object_id: Uuid,
    references: &mut HashMap<Uuid, Vec<VisualObjectReference>>,
) -> (Vec<Uuid>, Vec<VisualObjectReferenceResponse>) {
    let references = references.remove(&object_id).unwrap_or_default();
    let mut seen = HashSet::new();
    let source_block_ids = references
        .iter()
        .filter_map(|reference| {
            seen.insert(reference.block_id)
                .then_some(reference.block_id)
        })
        .collect();
    let referenced_by = references
        .into_iter()
        .map(|reference| VisualObjectReferenceResponse {
            block_id: reference.block_id,
            start_offset: reference.start_offset,
            end_offset: reference.end_offset,
            marker: reference.marker,
            context: reference.context,
            section_path: reference.section_path,
            page_number: reference.page_number,
        })
        .collect();
    (source_block_ids, referenced_by)
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TermKindResponse {
    Term,
    Acronym,
    Symbol,
    Method,
    Dataset,
}

impl From<TermKind> for TermKindResponse {
    fn from(value: TermKind) -> Self {
        match value {
            TermKind::Term => Self::Term,
            TermKind::Acronym => Self::Acronym,
            TermKind::Symbol => Self::Symbol,
            TermKind::Method => Self::Method,
            TermKind::Dataset => Self::Dataset,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TermOccurrenceResponse {
    pub(crate) block_id: Uuid,
    pub(crate) start_offset: u32,
    pub(crate) end_offset: u32,
    pub(crate) occurrence_ordinal: u32,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TermDefinitionResponse {
    pub(crate) id: Uuid,
    pub(crate) source_type: DefinitionSourceTypeResponse,
    pub(crate) source_block_ids: Vec<Uuid>,
    pub(crate) definition: String,
    pub(crate) model_id: Option<String>,
    pub(crate) prompt_version: Option<String>,
    pub(crate) confidence_status: DefinitionConfidenceStatusResponse,
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DefinitionStatusResponse {
    Available,
    NotFound,
    NotApplicable,
    Uncertain,
}

impl From<DefinitionStatus> for DefinitionStatusResponse {
    fn from(value: DefinitionStatus) -> Self {
        match value {
            DefinitionStatus::Available => Self::Available,
            DefinitionStatus::NotFound => Self::NotFound,
            DefinitionStatus::NotApplicable => Self::NotApplicable,
            DefinitionStatus::Uncertain => Self::Uncertain,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DefinitionSourceTypeResponse {
    CurrentPaper,
    CitedPaper,
    Glossary,
    Generated,
}

impl From<DefinitionSourceType> for DefinitionSourceTypeResponse {
    fn from(value: DefinitionSourceType) -> Self {
        match value {
            DefinitionSourceType::CurrentPaper => Self::CurrentPaper,
            DefinitionSourceType::CitedPaper => Self::CitedPaper,
            DefinitionSourceType::Glossary => Self::Glossary,
            DefinitionSourceType::Generated => Self::Generated,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DefinitionConfidenceStatusResponse {
    Supported,
    Inferred,
    Uncertain,
}

impl From<DefinitionConfidenceStatus> for DefinitionConfidenceStatusResponse {
    fn from(value: DefinitionConfidenceStatus) -> Self {
        match value {
            DefinitionConfidenceStatus::Supported => Self::Supported,
            DefinitionConfidenceStatus::Inferred => Self::Inferred,
            DefinitionConfidenceStatus::Uncertain => Self::Uncertain,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TermResponse {
    pub(crate) id: Uuid,
    pub(crate) normalized_term: String,
    pub(crate) display_term: String,
    pub(crate) kind: TermKindResponse,
    pub(crate) canonical_topic_id: Option<Uuid>,
    pub(crate) definition_status: DefinitionStatusResponse,
    pub(crate) occurrences: Vec<TermOccurrenceResponse>,
    pub(crate) definitions: Vec<TermDefinitionResponse>,
}

impl From<DocumentTermDetails> for TermResponse {
    fn from(value: DocumentTermDetails) -> Self {
        Self {
            id: value.term.id,
            normalized_term: value.term.normalized_term,
            display_term: value.term.display_term,
            kind: value.term.kind.into(),
            canonical_topic_id: value.term.canonical_topic_id,
            definition_status: value.term.definition_status.into(),
            occurrences: value
                .occurrences
                .into_iter()
                .map(|occurrence| TermOccurrenceResponse {
                    block_id: occurrence.block_id,
                    start_offset: occurrence.start_offset,
                    end_offset: occurrence.end_offset,
                    occurrence_ordinal: occurrence.occurrence_ordinal,
                })
                .collect(),
            definitions: value
                .definitions
                .into_iter()
                .map(|definition| TermDefinitionResponse {
                    id: definition.id,
                    source_type: definition.source_type.into(),
                    source_block_ids: definition.source_block_ids,
                    definition: definition.definition,
                    model_id: definition.model_id,
                    prompt_version: definition.prompt_version,
                    confidence_status: definition.confidence_status.into(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub(crate) struct TermsEnvelope {
    pub(crate) paper_id: Uuid,
    pub(crate) generation: i32,
    pub(crate) provenance: DocumentProvenanceResponse,
    pub(crate) items: Vec<TermResponse>,
}

impl From<CurrentDocument<Vec<DocumentTermDetails>>> for TermsEnvelope {
    fn from(value: CurrentDocument<Vec<DocumentTermDetails>>) -> Self {
        Self {
            paper_id: value.paper_id,
            generation: value.generation,
            provenance: value.provenance.into(),
            items: value.value.into_iter().map(Into::into).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::content_hash;

    #[test]
    fn figure_dto_does_not_claim_unwired_asset_delivery_or_leak_private_storage() {
        let figure_id = Uuid::now_v7();
        let block_id = Uuid::now_v7();
        let response = FigureResponse::with_reference_list(
            DocumentFigure {
                id: figure_id,
                paper_id: Uuid::now_v7(),
                generation: 3,
                label: "Figure 1".to_owned(),
                ordinal: 0,
                caption: "Fixture caption".to_owned(),
                page_number: Some(2),
                asset_key: Some("private/parser/output/figure-1.webp".to_owned()),
                width: Some(640),
                height: Some(480),
                extraction_status: FigureExtractionStatus::Ready,
                content_hash: content_hash("fixture image bytes"),
                source_locator: Some(SourceLocator {
                    source_element_id: Some("fig-1".to_owned()),
                    legacy_section_ordinal: Some(4),
                    page_number: Some(2),
                    bounding_box: None,
                }),
            },
            vec![VisualObjectReference {
                object_id: figure_id,
                block_id,
                start_offset: 4,
                end_offset: 12,
                marker: Some("Figure 1".to_owned()),
                context: "See Figure 1 for the architecture.".to_owned(),
                section_path: vec!["Methods".to_owned()],
                page_number: Some(2),
            }],
            false,
            false,
        );
        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["asset_available"], false);
        assert_eq!(value["asset_requestable"], false);
        assert!(value["asset_url"].is_null());
        assert_eq!(value["source_block_ids"], serde_json::json!([block_id]));
        assert_eq!(value["referenced_by"][0]["block_id"], block_id.to_string());
        assert_eq!(
            value["referenced_by"][0]["context"],
            "See Figure 1 for the architecture."
        );
        assert!(value.get("asset_key").is_none());
        assert!(
            value["source_locator"]
                .get("legacy_section_ordinal")
                .is_none()
        );
        assert!(!value.to_string().contains("private/parser/output"));
    }

    #[test]
    fn configured_delivery_exposes_only_a_generation_fenced_api_url() {
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        let revision = "a".repeat(64);
        let response = FigureResponse::with_reference_list(
            DocumentFigure {
                id: figure_id,
                paper_id,
                generation: 3,
                label: "Figure 1".to_owned(),
                ordinal: 0,
                caption: "Fixture caption".to_owned(),
                page_number: Some(2),
                asset_key: Some(format!(
                    "generated/{paper_id}/g3/{figure_id}/set-{revision}/large.png"
                )),
                width: Some(640),
                height: Some(480),
                extraction_status: FigureExtractionStatus::Ready,
                content_hash: content_hash("fixture image bytes"),
                source_locator: None,
            },
            Vec::new(),
            true,
            true,
        );
        let value = serde_json::to_value(response).unwrap();

        assert_eq!(value["asset_available"], true);
        assert_eq!(value["asset_requestable"], true);
        assert_eq!(
            value["asset_url"],
            format!(
                "/v1/papers/{paper_id}/figures/{figure_id}/asset?generation=3&revision={revision}"
            )
        );
        assert!(!value.to_string().contains("generated/"));
    }

    #[test]
    fn document_queries_reject_unknown_fields() {
        assert!(
            serde_json::from_value::<DocumentBlocksParams>(serde_json::json!({
                "limit": 10,
                "account_id": Uuid::now_v7()
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<DocumentTermsParams>(serde_json::json!({
                "block_id": Uuid::now_v7(),
                "generation": 1
            }))
            .is_err()
        );
    }
}
