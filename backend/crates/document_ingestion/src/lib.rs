//! Parser-independent ingestion boundary for normalized scholarly documents.
//!
//! GROBID remains the default baseline. The Docling adapter is compile-time
//! gated, additionally requires an explicit runtime enable, and never becomes
//! the default through this crate.

mod adapter;
#[cfg(feature = "docling-experimental")]
mod docling_adapter;
pub mod fixtures;
mod grobid_adapter;
mod normalize;
mod quality;
mod recovery;

pub use adapter::{
    ParseError, ParseInput, ParsePayload, ParserSelection, ScholarlyDocumentParser, default_parser,
    select_parser,
};
#[cfg(feature = "docling-experimental")]
pub use docling_adapter::DoclingAdapter;
pub use grobid_adapter::GrobidAdapter;
pub use quality::{
    BenchmarkGroundTruth, BenchmarkMetrics, BenchmarkResult, DocumentQualityReport,
    evaluate_benchmark, evaluate_quality, run_benchmark,
};
pub use recovery::{
    RecoveredDocument, SourceSegment, assemble_recovered_document, assemble_transcribed_document,
    split_source_segments, tei_to_plain_text,
};
