use async_trait::async_trait;
use domain::{
    DOCUMENT_SCHEMA_VERSION, DocumentBlock, DocumentBlockKind, NormalizedDocument, SourceLocator,
    content_hash, normalize_document_text, stable_block_key,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    ParseError, ParseInput, ParsePayload, ScholarlyDocumentParser,
    adapter::{valid_parser_version, validate_input_scope},
};

#[derive(Debug, Clone)]
pub struct DoclingAdapter {
    parser_version: String,
    runtime_enabled: bool,
}

impl DoclingAdapter {
    pub fn new(
        parser_version: impl Into<String>,
        runtime_enabled: bool,
    ) -> Result<Self, ParseError> {
        let parser_version = parser_version.into();
        if !valid_parser_version(&parser_version) {
            return Err(ParseError::InvalidInput("parser version"));
        }
        Ok(Self {
            parser_version,
            runtime_enabled,
        })
    }
}

#[async_trait]
impl ScholarlyDocumentParser for DoclingAdapter {
    fn parser_id(&self) -> &'static str {
        "docling-experimental"
    }

    fn parser_version(&self) -> String {
        self.parser_version.clone()
    }

    async fn parse(&self, input: ParseInput) -> Result<NormalizedDocument, ParseError> {
        if !self.runtime_enabled {
            return Err(ParseError::AdapterDisabled("docling"));
        }
        validate_input_scope(&input)?;
        let ParsePayload::DoclingJson(json) = input.payload else {
            return Err(ParseError::InvalidInput("Docling requires normalized JSON"));
        };
        let raw: RawDoclingDocument =
            serde_json::from_str(&json).map_err(|_| ParseError::InvalidOutput)?;
        if raw.schema_version != "docling-normalized-v1" || raw.blocks.is_empty() {
            return Err(ParseError::InvalidOutput);
        }
        let mut blocks = Vec::with_capacity(raw.blocks.len());
        for (index, raw) in raw.blocks.into_iter().enumerate() {
            let text = normalize_document_text(&raw.text);
            let ordinal = u32::try_from(index).map_err(|_| ParseError::InvalidOutput)?;
            let kind = raw.kind.into_domain();
            let page_start = raw.page;
            blocks.push(DocumentBlock {
                id: Uuid::now_v7(),
                paper_id: input.paper_id,
                generation: input.generation,
                stable_key: stable_block_key(&raw.section_path, kind, raw.local_ordinal, &text),
                ordinal,
                section_path: raw.section_path,
                kind,
                content_hash: content_hash(&text),
                text,
                page_start,
                page_end: page_start,
                source_locator: raw
                    .source_element_id
                    .map(|source_element_id| SourceLocator {
                        source_element_id: Some(source_element_id),
                        legacy_section_ordinal: None,
                        page_number: page_start,
                        bounding_box: None,
                    }),
                inline_spans: Vec::new(),
            });
        }
        let document = NormalizedDocument {
            paper_id: input.paper_id,
            generation: input.generation,
            arxiv_version: input.arxiv_version,
            schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
            parser_id: self.parser_id().to_owned(),
            parser_version: self.parser_version.clone(),
            blocks,
            figures: Vec::new(),
            tables: Vec::new(),
            equations: Vec::new(),
            terms: Vec::new(),
            term_occurrences: Vec::new(),
            term_definitions: Vec::new(),
        };
        document.validate()?;
        Ok(document)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawDoclingDocument {
    schema_version: String,
    blocks: Vec<RawDoclingBlock>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawDoclingBlock {
    kind: RawBlockKind,
    text: String,
    #[serde(default)]
    section_path: Vec<String>,
    local_ordinal: u32,
    page: Option<u32>,
    source_element_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RawBlockKind {
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

impl RawBlockKind {
    const fn into_domain(self) -> DocumentBlockKind {
        match self {
            Self::Heading => DocumentBlockKind::Heading,
            Self::Paragraph => DocumentBlockKind::Paragraph,
            Self::ListItem => DocumentBlockKind::ListItem,
            Self::Quote => DocumentBlockKind::Quote,
            Self::TheoremDefinition => DocumentBlockKind::TheoremDefinition,
            Self::Caption => DocumentBlockKind::Caption,
            Self::EquationContext => DocumentBlockKind::EquationContext,
            Self::TableContext => DocumentBlockKind::TableContext,
            Self::FigureContext => DocumentBlockKind::FigureContext,
            Self::Footnote => DocumentBlockKind::Footnote,
            Self::Other => DocumentBlockKind::Other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn runtime_gate_is_fail_closed() {
        let parser = DoclingAdapter::new("experimental", false).unwrap();
        let result = parser
            .parse(ParseInput {
                paper_id: Uuid::now_v7(),
                generation: 1,
                arxiv_version: 1,
                payload: ParsePayload::DoclingJson(
                    r#"{"schema_version":"docling-normalized-v1","blocks":[]}"#.to_owned(),
                ),
            })
            .await;
        assert!(matches!(
            result,
            Err(ParseError::AdapterDisabled("docling"))
        ));
    }
}
