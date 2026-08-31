use std::collections::HashSet;

use domain::{DocumentBlockKind, InlineSpanKind, NormalizedDocument};

use crate::{ParseError, ParseInput, ScholarlyDocumentParser};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentQualityReport {
    pub valid: bool,
    pub block_count: u32,
    pub heading_count: u32,
    pub paragraph_count: u32,
    pub citation_span_count: u32,
    pub figure_count: u32,
    pub table_count: u32,
    pub equation_count: u32,
    pub page_mapped_blocks: u32,
    pub page_mapping_basis_points: u16,
    pub duplicate_content_hashes: u32,
    pub ordinal_inversions: u32,
    pub replacement_character_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BenchmarkGroundTruth {
    pub block_kinds: Vec<DocumentBlockKind>,
    pub citation_span_count: u32,
    pub figure_count: u32,
    pub table_count: u32,
    pub equation_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BenchmarkMetrics {
    pub block_count_absolute_error: u32,
    pub block_kind_order_exact: bool,
    pub citation_count_absolute_error: u32,
    pub figure_count_absolute_error: u32,
    pub table_count_absolute_error: u32,
    pub equation_count_absolute_error: u32,
    pub block_count_precision_basis_points: u16,
    pub block_count_recall_basis_points: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BenchmarkResult {
    pub fixture_id: String,
    pub parser_id: String,
    pub parser_version: String,
    pub quality: DocumentQualityReport,
    pub metrics: BenchmarkMetrics,
}

pub fn evaluate_quality(document: &NormalizedDocument) -> DocumentQualityReport {
    let valid = document.validate().is_ok();
    let block_count = bounded_count(document.blocks.len());
    let page_mapped_blocks = bounded_count(
        document
            .blocks
            .iter()
            .filter(|block| block.page_start.is_some())
            .count(),
    );
    let mut content_hashes = HashSet::new();
    let duplicate_content_hashes = bounded_count(
        document
            .blocks
            .iter()
            .filter(|block| !content_hashes.insert(block.content_hash.as_str()))
            .count(),
    );
    let ordinal_inversions = bounded_count(
        document
            .blocks
            .windows(2)
            .filter(|window| window[0].ordinal >= window[1].ordinal)
            .count(),
    );
    DocumentQualityReport {
        valid,
        block_count,
        heading_count: bounded_count(
            document
                .blocks
                .iter()
                .filter(|block| block.kind == DocumentBlockKind::Heading)
                .count(),
        ),
        paragraph_count: bounded_count(
            document
                .blocks
                .iter()
                .filter(|block| block.kind == DocumentBlockKind::Paragraph)
                .count(),
        ),
        citation_span_count: bounded_count(
            document
                .blocks
                .iter()
                .flat_map(|block| &block.inline_spans)
                .filter(|span| span.kind == InlineSpanKind::BibliographyReference)
                .count(),
        ),
        figure_count: bounded_count(document.figures.len()),
        table_count: bounded_count(document.tables.len()),
        equation_count: bounded_count(document.equations.len()),
        page_mapped_blocks,
        page_mapping_basis_points: ratio_basis_points(page_mapped_blocks, block_count),
        duplicate_content_hashes,
        ordinal_inversions,
        replacement_character_count: bounded_count(
            document
                .blocks
                .iter()
                .map(|block| block.text.matches('\u{fffd}').count())
                .sum(),
        ),
    }
}

pub fn evaluate_benchmark(
    document: &NormalizedDocument,
    expected: &BenchmarkGroundTruth,
) -> BenchmarkMetrics {
    let actual_kinds = document
        .blocks
        .iter()
        .map(|block| block.kind)
        .collect::<Vec<_>>();
    let actual_blocks = bounded_count(actual_kinds.len());
    let expected_blocks = bounded_count(expected.block_kinds.len());
    let quality = evaluate_quality(document);
    BenchmarkMetrics {
        block_count_absolute_error: actual_blocks.abs_diff(expected_blocks),
        block_kind_order_exact: actual_kinds == expected.block_kinds,
        citation_count_absolute_error: quality
            .citation_span_count
            .abs_diff(expected.citation_span_count),
        figure_count_absolute_error: quality.figure_count.abs_diff(expected.figure_count),
        table_count_absolute_error: quality.table_count.abs_diff(expected.table_count),
        equation_count_absolute_error: quality.equation_count.abs_diff(expected.equation_count),
        block_count_precision_basis_points: ratio_basis_points(
            actual_blocks.min(expected_blocks),
            actual_blocks,
        ),
        block_count_recall_basis_points: ratio_basis_points(
            actual_blocks.min(expected_blocks),
            expected_blocks,
        ),
    }
}

pub async fn run_benchmark(
    parser: &dyn ScholarlyDocumentParser,
    fixture_id: impl Into<String>,
    input: ParseInput,
    expected: &BenchmarkGroundTruth,
) -> Result<BenchmarkResult, ParseError> {
    let document = parser.parse(input).await?;
    Ok(BenchmarkResult {
        fixture_id: fixture_id.into(),
        parser_id: parser.parser_id().to_owned(),
        parser_version: parser.parser_version(),
        quality: evaluate_quality(&document),
        metrics: evaluate_benchmark(&document, expected),
    })
}

fn bounded_count(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

fn ratio_basis_points(numerator: u32, denominator: u32) -> u16 {
    if denominator == 0 {
        return if numerator == 0 { 10_000 } else { 0 };
    }
    let ratio = u64::from(numerator)
        .saturating_mul(10_000)
        .checked_div(u64::from(denominator))
        .unwrap_or_default()
        .min(10_000);
    u16::try_from(ratio).unwrap_or(10_000)
}

#[cfg(test)]
mod tests {
    use domain::PaperId;

    use super::*;
    use crate::{GrobidAdapter, fixtures::grobid_smoke_fixture};

    #[tokio::test]
    async fn fixture_metrics_are_deterministic_and_non_vacuous() {
        let fixture = grobid_smoke_fixture(PaperId::now_v7(), 1);
        let result = run_benchmark(
            &GrobidAdapter::new("0.9.0-crf").unwrap(),
            fixture.id,
            fixture.input,
            &fixture.expected,
        )
        .await
        .unwrap();
        assert!(result.quality.valid);
        assert_eq!(result.quality.block_count, 4);
        assert_eq!(result.quality.citation_span_count, 1);
        assert_eq!(result.metrics.block_count_absolute_error, 0);
        assert!(result.metrics.block_kind_order_exact);
        assert_eq!(result.metrics.block_count_precision_basis_points, 10_000);
        assert_eq!(result.metrics.block_count_recall_basis_points, 10_000);
    }
}
