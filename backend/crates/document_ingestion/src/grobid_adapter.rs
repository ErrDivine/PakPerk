use async_trait::async_trait;
use domain::NormalizedDocument;

use crate::{
    ParseError, ParseInput, ParsePayload, ScholarlyDocumentParser,
    adapter::{valid_parser_version, validate_input_scope},
    normalize::normalize_grobid_paper,
};

#[derive(Debug, Clone)]
pub struct GrobidAdapter {
    parser_version: String,
}

impl GrobidAdapter {
    pub fn new(parser_version: impl Into<String>) -> Result<Self, ParseError> {
        let parser_version = parser_version.into();
        if !valid_parser_version(&parser_version) {
            return Err(ParseError::InvalidInput("parser version"));
        }
        Ok(Self { parser_version })
    }
}

#[async_trait]
impl ScholarlyDocumentParser for GrobidAdapter {
    fn parser_id(&self) -> &'static str {
        "grobid"
    }

    fn parser_version(&self) -> String {
        self.parser_version.clone()
    }

    async fn parse(&self, input: ParseInput) -> Result<NormalizedDocument, ParseError> {
        validate_input_scope(&input)?;
        let ParsePayload::GrobidTei(tei) = input.payload else {
            return Err(ParseError::InvalidInput("GROBID requires TEI XML"));
        };
        let parsed = document_model::parse_tei_document(&tei)?;
        let document = normalize_grobid_paper(
            input.paper_id,
            input.generation,
            input.arxiv_version,
            self.parser_id(),
            &self.parser_version,
            &parsed,
        )?;
        document.validate()?;
        Ok(document)
    }
}

#[cfg(test)]
mod tests {
    use domain::{
        EquationConfidenceStatus, FigureExtractionStatus, InlineSpanKind, TableExtractionStatus,
    };
    use uuid::Uuid;

    use super::*;

    #[tokio::test]
    async fn normalizes_visual_objects_without_claiming_an_image_derivative() {
        let paper_id = Uuid::now_v7();
        let document = GrobidAdapter::new("0.9.0")
            .unwrap()
            .parse(ParseInput {
                paper_id,
                generation: 2,
                arxiv_version: 3,
                payload: ParsePayload::GrobidTei(
                    r##"<TEI><text><body><div xml:id="results">
                      <head>Results</head>
                      <p coords="5,10,20,200,30">Compare <ref type="figure" target="#fig_1">Figure 1</ref>, <ref type="table" target="#tab_1">Table 1</ref>, and <ref type="formula" target="#eq_1">Equation 1</ref>.</p>
                      <figure xml:id="fig_1" coords="5,10,60,200,140"><label>Figure 1</label><figDesc>Trusted caption only.</figDesc><graphic/></figure>
                      <figure xml:id="tab_1" type="table" coords="6,10,60,200,140"><label>Table 1</label><figDesc>Scores.</figDesc><table><row><cell role="head">Model</cell><cell role="head">Score</cell></row><row><cell>A</cell><cell>9</cell></row></table></figure>
                      <formula xml:id="eq_1" coords="7,10,60,200,40"><label>(1)</label><math><mrow><mi>x</mi><mo>=</mo><mn>1</mn></mrow></math></formula>
                    </div></body></text></TEI>"##
                        .to_owned(),
                ),
            })
            .await
            .unwrap();

        assert_eq!(document.figures.len(), 1);
        let figure = &document.figures[0];
        assert_eq!(
            figure.extraction_status,
            FigureExtractionStatus::CaptionOnly
        );
        assert!(figure.asset_key.is_none());
        assert!(figure.width.is_none() && figure.height.is_none());
        assert_eq!(figure.source_locator.as_ref().unwrap().page_number, Some(5));
        assert!(
            figure
                .source_locator
                .as_ref()
                .unwrap()
                .bounding_box
                .is_none()
        );

        assert_eq!(document.tables.len(), 1);
        let table = &document.tables[0];
        assert_eq!(table.extraction_status, TableExtractionStatus::Ready);
        assert!(table.structure.rows[0].iter().all(|cell| cell.header));
        assert_eq!(table.plain_text, "Model\tScore\nA\t9");

        assert_eq!(document.equations.len(), 1);
        let equation = &document.equations[0];
        assert_eq!(
            equation.confidence_status,
            EquationConfidenceStatus::Supported
        );
        assert!(equation.mathml.as_deref().unwrap().contains("<mi>x</mi>"));
        assert!(equation.plain_text.as_deref().unwrap().contains('x'));

        let paragraph = document
            .blocks
            .iter()
            .find(|block| block.text.starts_with("Compare"))
            .unwrap();
        assert_eq!(paragraph.inline_spans.len(), 3);
        assert!(paragraph.inline_spans.iter().any(|span| {
            span.kind == InlineSpanKind::FigureReference
                && span.target_id.as_deref() == Some(&figure.id.to_string())
        }));
        assert!(paragraph.inline_spans.iter().any(|span| {
            span.kind == InlineSpanKind::TableReference
                && span.target_id.as_deref() == Some(&table.id.to_string())
        }));
        assert!(paragraph.inline_spans.iter().any(|span| {
            span.kind == InlineSpanKind::EquationReference
                && span.target_id.as_deref() == Some(&equation.id.to_string())
        }));
    }
}
