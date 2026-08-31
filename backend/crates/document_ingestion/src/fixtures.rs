use domain::{DocumentBlockKind, PaperId, ProcessingGeneration};

use crate::{BenchmarkGroundTruth, ParseInput, ParsePayload};

pub struct BenchmarkFixture {
    pub id: &'static str,
    pub input: ParseInput,
    pub expected: BenchmarkGroundTruth,
}

#[must_use]
pub fn grobid_smoke_fixture(
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> BenchmarkFixture {
    BenchmarkFixture {
        id: "grobid_nested_citation_v1",
        input: ParseInput {
            paper_id,
            generation,
            arxiv_version: 1,
            payload: ParsePayload::GrobidTei(
                include_str!("../fixtures/grobid_nested_citation_v1.tei.xml").to_owned(),
            ),
        },
        expected: BenchmarkGroundTruth {
            block_kinds: vec![
                DocumentBlockKind::Heading,
                DocumentBlockKind::Paragraph,
                DocumentBlockKind::Heading,
                DocumentBlockKind::Paragraph,
            ],
            citation_span_count: 1,
            figure_count: 0,
            table_count: 0,
            equation_count: 0,
        },
    }
}
