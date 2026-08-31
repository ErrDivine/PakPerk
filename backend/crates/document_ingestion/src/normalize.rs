use std::collections::{HashMap, HashSet};

use document_model::{ParsedTeiDocument, ParsedTeiObjectKind};
use domain::{
    DOCUMENT_SCHEMA_VERSION, DocumentBlock, DocumentBlockKind, DocumentEquation, DocumentFigure,
    DocumentTable, EquationConfidenceStatus, FigureExtractionStatus, InlineSpan, InlineSpanKind,
    NormalizedDocument, PaperId, ParsedSection, ProcessingGeneration, SourceLocator,
    TABLE_STRUCTURE_SCHEMA_VERSION, TableCell, TableExtractionStatus, TableStructure, content_hash,
    normalize_document_text, stable_block_key,
};
use uuid::Uuid;

use crate::ParseError;

pub(crate) fn normalize_grobid_paper(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    arxiv_version: u32,
    parser_id: &str,
    parser_version: &str,
    parsed: &ParsedTeiDocument,
) -> Result<NormalizedDocument, ParseError> {
    let mut blocks = normalize_blocks(paper_id, generation, &parsed.paper.sections)?;
    let figures = normalize_figures(paper_id, generation, parsed)?;
    let tables = normalize_tables(paper_id, generation, parsed)?;
    let equations = normalize_equations(paper_id, generation, parsed)?;
    attach_object_references(parsed, &figures, &tables, &equations, &mut blocks)?;
    Ok(NormalizedDocument {
        paper_id,
        generation,
        arxiv_version,
        schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
        parser_id: parser_id.to_owned(),
        parser_version: parser_version.to_owned(),
        blocks,
        figures,
        tables,
        equations,
        terms: Vec::new(),
        term_occurrences: Vec::new(),
        term_definitions: Vec::new(),
    })
}

fn normalize_blocks(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    parsed_sections: &[ParsedSection],
) -> Result<Vec<DocumentBlock>, ParseError> {
    let sections = parsed_sections
        .iter()
        .map(|section| (section.source_id.as_str(), section))
        .collect::<HashMap<_, _>>();
    let mut blocks = Vec::new();
    let mut global_ordinal = 0_u32;
    for section in parsed_sections {
        let section_path = section_path(section, &sections)?;
        if let Some(heading) = section
            .heading
            .as_deref()
            .map(normalize_document_text)
            .filter(|heading| !heading.is_empty())
        {
            blocks.push(make_block(
                paper_id,
                generation,
                global_ordinal,
                0,
                DocumentBlockKind::Heading,
                heading,
                section,
                &section_path,
                Vec::new(),
                section.page_start,
                section.page_end,
                "heading",
            )?);
            global_ordinal = global_ordinal
                .checked_add(1)
                .ok_or(ParseError::InvalidOutput)?;
        }
        for paragraph in &section.paragraphs {
            let text = normalize_document_text(&paragraph.text);
            if text.is_empty() {
                continue;
            }
            let inline_spans = paragraph
                .citations
                .iter()
                .map(|citation| {
                    Ok(InlineSpan {
                        kind: InlineSpanKind::BibliographyReference,
                        start: u32::try_from(citation.start)
                            .map_err(|_| ParseError::InvalidOutput)?,
                        end: u32::try_from(citation.end).map_err(|_| ParseError::InvalidOutput)?,
                        target_id: Some(format!(
                            "references:{}",
                            citation
                                .reference_ordinals
                                .iter()
                                .map(usize::to_string)
                                .collect::<Vec<_>>()
                                .join(",")
                        )),
                        label: Some(citation.marker.clone()),
                    })
                })
                .collect::<Result<Vec<_>, ParseError>>()?;
            let local_ordinal = u32::try_from(paragraph.ordinal)
                .map_err(|_| ParseError::InvalidOutput)?
                .checked_add(1)
                .ok_or(ParseError::InvalidOutput)?;
            blocks.push(make_block(
                paper_id,
                generation,
                global_ordinal,
                local_ordinal,
                DocumentBlockKind::Paragraph,
                text,
                section,
                &section_path,
                inline_spans,
                paragraph.page_start,
                paragraph.page_end,
                &format!("paragraph-{}", paragraph.ordinal),
            )?);
            global_ordinal = global_ordinal
                .checked_add(1)
                .ok_or(ParseError::InvalidOutput)?;
        }
    }
    Ok(blocks)
}

fn normalize_figures(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    parsed: &ParsedTeiDocument,
) -> Result<Vec<DocumentFigure>, ParseError> {
    parsed
        .figures
        .iter()
        .enumerate()
        .map(|(ordinal, figure)| {
            Ok(DocumentFigure {
                id: Uuid::now_v7(),
                paper_id,
                generation,
                label: figure.label.clone(),
                ordinal: u32::try_from(ordinal).map_err(|_| ParseError::InvalidOutput)?,
                caption: figure.caption.clone(),
                page_number: figure.page_number,
                asset_key: None,
                width: None,
                height: None,
                extraction_status: if figure.caption_available {
                    FigureExtractionStatus::CaptionOnly
                } else {
                    FigureExtractionStatus::Unavailable
                },
                content_hash: visual_content_hash(
                    "figure",
                    &[&figure.label, &figure.caption, &figure.source_id],
                ),
                source_locator: Some(visual_source_locator(&figure.source_id, figure.page_number)),
            })
        })
        .collect()
}

fn normalize_tables(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    parsed: &ParsedTeiDocument,
) -> Result<Vec<DocumentTable>, ParseError> {
    parsed
        .tables
        .iter()
        .enumerate()
        .map(|(ordinal, table)| {
            let rows = table
                .rows
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|cell| TableCell {
                            text: cell.text.clone(),
                            header: cell.header,
                            row_span: cell.row_span,
                            column_span: cell.column_span,
                        })
                        .collect()
                })
                .collect();
            Ok(DocumentTable {
                id: Uuid::now_v7(),
                paper_id,
                generation,
                label: table.label.clone(),
                ordinal: u32::try_from(ordinal).map_err(|_| ParseError::InvalidOutput)?,
                caption: table.caption.clone(),
                page_number: table.page_number,
                structure: TableStructure {
                    schema_version: TABLE_STRUCTURE_SCHEMA_VERSION.to_owned(),
                    rows,
                },
                plain_text: table.plain_text.clone(),
                extraction_status: if table.structure_complete && table.caption_available {
                    TableExtractionStatus::Ready
                } else {
                    TableExtractionStatus::Partial
                },
                content_hash: visual_content_hash(
                    "table",
                    &[
                        &table.label,
                        &table.caption,
                        &table.plain_text,
                        &table.source_id,
                    ],
                ),
                source_locator: Some(visual_source_locator(&table.source_id, table.page_number)),
            })
        })
        .collect()
}

fn normalize_equations(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    parsed: &ParsedTeiDocument,
) -> Result<Vec<DocumentEquation>, ParseError> {
    parsed
        .equations
        .iter()
        .enumerate()
        .map(|(ordinal, equation)| {
            let mut hash_parts = vec![equation.source_id.as_str()];
            hash_parts.extend(equation.label.as_deref());
            hash_parts.extend(equation.latex.as_deref());
            hash_parts.extend(equation.mathml.as_deref());
            hash_parts.extend(equation.plain_text.as_deref());
            Ok(DocumentEquation {
                id: Uuid::now_v7(),
                paper_id,
                generation,
                label: equation.label.clone(),
                ordinal: u32::try_from(ordinal).map_err(|_| ParseError::InvalidOutput)?,
                latex: equation.latex.clone(),
                mathml: equation.mathml.clone(),
                plain_text: equation.plain_text.clone(),
                context_block_id: None,
                page_number: equation.page_number,
                confidence_status: if equation.latex.is_some() || equation.mathml.is_some() {
                    EquationConfidenceStatus::Supported
                } else {
                    EquationConfidenceStatus::Partial
                },
                content_hash: visual_content_hash("equation", &hash_parts),
                source_locator: Some(visual_source_locator(
                    &equation.source_id,
                    equation.page_number,
                )),
            })
        })
        .collect()
}

fn attach_object_references(
    parsed: &ParsedTeiDocument,
    figures: &[DocumentFigure],
    tables: &[DocumentTable],
    equations: &[DocumentEquation],
    blocks: &mut [DocumentBlock],
) -> Result<(), ParseError> {
    let figure_ids = parsed
        .figures
        .iter()
        .zip(figures)
        .map(|(parsed, normalized)| (parsed.source_id.as_str(), normalized.id))
        .collect::<HashMap<_, _>>();
    let table_ids = parsed
        .tables
        .iter()
        .zip(tables)
        .map(|(parsed, normalized)| (parsed.source_id.as_str(), normalized.id))
        .collect::<HashMap<_, _>>();
    let equation_ids = parsed
        .equations
        .iter()
        .zip(equations)
        .map(|(parsed, normalized)| (parsed.source_id.as_str(), normalized.id))
        .collect::<HashMap<_, _>>();
    let block_indices = blocks
        .iter()
        .enumerate()
        .filter_map(|(index, block)| {
            block
                .source_locator
                .as_ref()?
                .source_element_id
                .as_deref()
                .map(|source_id| (source_id.to_owned(), index))
        })
        .collect::<HashMap<_, _>>();
    for reference in &parsed.object_references {
        let Some(target_id) = (match reference.kind {
            ParsedTeiObjectKind::Figure => figure_ids.get(reference.target_source_id.as_str()),
            ParsedTeiObjectKind::Table => table_ids.get(reference.target_source_id.as_str()),
            ParsedTeiObjectKind::Equation => equation_ids.get(reference.target_source_id.as_str()),
        }) else {
            // A parser reference without a corresponding trustworthy object is
            // ordinary readable text, not an actionable object link.
            continue;
        };
        let block_source_id = format!(
            "{}:paragraph-{}",
            reference.section_source_id, reference.paragraph_ordinal
        );
        let Some(block_index) = block_indices.get(&block_source_id).copied() else {
            continue;
        };
        let kind = match reference.kind {
            ParsedTeiObjectKind::Figure => InlineSpanKind::FigureReference,
            ParsedTeiObjectKind::Table => InlineSpanKind::TableReference,
            ParsedTeiObjectKind::Equation => InlineSpanKind::EquationReference,
        };
        blocks[block_index].inline_spans.push(InlineSpan {
            kind,
            start: u32::try_from(reference.start).map_err(|_| ParseError::InvalidOutput)?,
            end: u32::try_from(reference.end).map_err(|_| ParseError::InvalidOutput)?,
            target_id: Some(target_id.to_string()),
            label: Some(reference.marker.clone()),
        });
    }
    for block in blocks {
        block
            .inline_spans
            .sort_by_key(|span| (span.start, span.end));
    }
    Ok(())
}

fn visual_source_locator(source_id: &str, page_number: Option<u32>) -> SourceLocator {
    SourceLocator {
        source_element_id: Some(source_id.to_owned()),
        legacy_section_ordinal: None,
        page_number,
        // GROBID coordinates use absolute PDF units. Without authoritative
        // page dimensions they cannot be represented as normalized bounds.
        bounding_box: None,
    }
}

fn visual_content_hash(kind: &str, parts: &[&str]) -> String {
    let mut canonical = String::from(kind);
    for part in parts {
        canonical.push('\u{1f}');
        canonical.push_str(part);
    }
    content_hash(&canonical)
}

#[allow(clippy::too_many_arguments)]
fn make_block(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    ordinal: u32,
    local_ordinal: u32,
    kind: DocumentBlockKind,
    text: String,
    section: &ParsedSection,
    section_path: &[String],
    inline_spans: Vec<InlineSpan>,
    page_start: Option<u32>,
    page_end: Option<u32>,
    element_suffix: &str,
) -> Result<DocumentBlock, ParseError> {
    let legacy_section_ordinal =
        u32::try_from(section.ordinal).map_err(|_| ParseError::InvalidOutput)?;
    Ok(DocumentBlock {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        stable_key: stable_block_key(section_path, kind, local_ordinal, &text),
        ordinal,
        section_path: section_path.to_vec(),
        kind,
        content_hash: content_hash(&text),
        text,
        page_start,
        page_end,
        source_locator: Some(SourceLocator {
            source_element_id: Some(format!("{}:{element_suffix}", section.source_id)),
            legacy_section_ordinal: Some(legacy_section_ordinal),
            page_number: page_start,
            bounding_box: None,
        }),
        inline_spans,
    })
}

fn section_path(
    section: &ParsedSection,
    sections: &HashMap<&str, &ParsedSection>,
) -> Result<Vec<String>, ParseError> {
    fn visit(
        section: &ParsedSection,
        sections: &HashMap<&str, &ParsedSection>,
        visiting: &mut HashSet<String>,
        path: &mut Vec<String>,
        depth: usize,
    ) -> Result<(), ParseError> {
        if depth > 32 || !visiting.insert(section.source_id.clone()) {
            return Err(ParseError::InvalidOutput);
        }
        if let Some(parent) = section
            .parent_source_id
            .as_deref()
            .and_then(|parent| sections.get(parent).copied())
        {
            visit(parent, sections, visiting, path, depth + 1)?;
        }
        let component = section
            .heading
            .as_deref()
            .map(normalize_document_text)
            .filter(|heading| !heading.is_empty())
            .unwrap_or_else(|| section_label(section));
        path.push(component);
        visiting.remove(&section.source_id);
        Ok(())
    }

    let mut path = Vec::new();
    visit(section, sections, &mut HashSet::new(), &mut path, 0)?;
    Ok(path)
}

fn section_label(section: &ParsedSection) -> String {
    format!("{:?}-{}", section.kind, section.ordinal).to_lowercase()
}
