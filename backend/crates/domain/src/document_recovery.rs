//! Shared contracts for model-assisted document recovery.
//!
//! There are two recovery paths, and they differ in how much the model is
//! trusted:
//!
//! * **Text recovery** runs when the primary parser's output cannot be turned
//!   into a valid document. Deterministic code splits that output into numbered
//!   segments and a model only *classifies* them (heading, noise, continuation,
//!   reference). The model never authors, quotes, or corrects document text, so
//!   every word of a recovered document is a word the primary parser produced.
//! * **Page-image recovery** runs when the primary parser produced no usable
//!   text at all. A vision model reads rendered page images and *transcribes*
//!   them, so the text of such a document is model-authored. Its provenance says
//!   so, and nothing downstream may treat it as parser output.

/// Closed adapter identity recorded in document provenance and parser metrics.
pub const RECOVERY_PARSER_ID: &str = "llm-recovery";
/// Bumped whenever segmentation, classification semantics, or assembly change.
pub const RECOVERY_PARSER_VERSION: &str = "llm-recovery-v1";

/// Closed adapter identity of documents transcribed from page images.
pub const VISION_PARSER_ID: &str = "llm-vision-recovery";
/// Bumped whenever the transcription contract, prompt, or assembly change.
pub const VISION_PARSER_VERSION: &str = "llm-vision-recovery-v1";
/// Most pages transcribed for one document. A longer PDF fails closed instead
/// of silently losing its tail.
pub const VISION_MAX_PAGES: usize = 40;
/// Most blocks accepted from one page transcription.
pub const VISION_MAX_BLOCKS_PER_PAGE: usize = 300;
/// Most Unicode scalars accepted from one page transcription. A dense
/// two-column page holds roughly a fifth of this.
pub const VISION_MAX_PAGE_SCALARS: usize = 30_000;
/// Most blocks accepted for one document.
pub const VISION_MAX_SEGMENTS: usize = 6_000;

/// Most segments one provider call classifies.
pub const RECOVERY_WINDOW_SEGMENTS: usize = 300;
/// Most segments accepted for one document (six provider calls).
pub const RECOVERY_MAX_SEGMENTS: usize = 1_800;
/// Unicode scalars of each segment shown to the model. Headings and the start
/// of a paragraph are enough to classify a segment.
pub const RECOVERY_PREVIEW_SCALARS: usize = 240;
/// Longest single segment kept; longer text is split before classification.
pub const RECOVERY_MAX_SEGMENT_SCALARS: usize = 6_000;
/// Longest source text accepted for one document.
pub const RECOVERY_MAX_SOURCE_SCALARS: usize = 2_000_000;
/// Deepest heading level a classification may assign.
pub const RECOVERY_MAX_HEADING_LEVEL: u8 = 4;

/// Why the primary parser failed. Closed and content-free, so it is safe to
/// place in prompts, logs, and metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryFailureHint {
    InvalidTei,
    MissingBody,
    NoIntroduction,
    InvalidOutput,
    /// The parser answered with an empty or non-UTF-8 document.
    NoOutput,
    /// The parser rejected the PDF itself (an HTTP 4xx answer).
    RejectedInput,
    /// The parser could not be reached or kept failing until the job's final
    /// attempt.
    Unavailable,
}

impl RecoveryFailureHint {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidTei => "invalid_tei",
            Self::MissingBody => "missing_body",
            Self::NoIntroduction => "no_introduction",
            Self::InvalidOutput => "invalid_output",
            Self::NoOutput => "no_output",
            Self::RejectedInput => "rejected_input",
            Self::Unavailable => "unavailable",
        }
    }

    /// Fixed sentence for the model prompt; never derived from document text.
    #[must_use]
    pub const fn description(self) -> &'static str {
        match self {
            Self::InvalidTei => "the extracted XML was malformed",
            Self::MissingBody => "the extracted XML contained no body text",
            Self::NoIntroduction => "no introduction section could be identified",
            Self::InvalidOutput => "the extracted structure failed validation",
            Self::NoOutput => "the parser returned no output",
            Self::RejectedInput => "the parser rejected the PDF",
            Self::Unavailable => "the parser was unavailable",
        }
    }
}

/// Which recovery path produced a document. Closed, so document provenance and
/// parser metrics stay enumerable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoverySource {
    /// Segments of the text the primary parser extracted, classified by a model.
    TeiText,
    /// Page images transcribed by a vision-capable model.
    PageImages,
}

impl RecoverySource {
    #[must_use]
    pub const fn parser_id(self) -> &'static str {
        match self {
            Self::TeiText => RECOVERY_PARSER_ID,
            Self::PageImages => VISION_PARSER_ID,
        }
    }

    #[must_use]
    pub const fn parser_version(self) -> &'static str {
        match self {
            Self::TeiText => RECOVERY_PARSER_VERSION,
            Self::PageImages => VISION_PARSER_VERSION,
        }
    }
}

/// One numbered piece of extracted text as shown to the model. `text` is a
/// bounded preview, never the full segment, and is untrusted document data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoverySegment {
    pub index: u32,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecoveryHeading {
    pub segment: u32,
    /// 1 for a top-level section up to [`RECOVERY_MAX_HEADING_LEVEL`].
    pub level: u8,
}

/// Inclusive segment range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecoveryRange {
    pub start: u32,
    pub end: u32,
}

/// Sparse classification of segments. Every segment that is not listed is an
/// ordinary body paragraph.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecoveryAnnotation {
    pub title_segment: Option<u32>,
    pub headings: Vec<RecoveryHeading>,
    /// Running headers, page numbers, affiliations, and other non-prose debris.
    pub noise_segments: Vec<u32>,
    /// Segments that continue the previous paragraph across a column or page break.
    pub continuation_segments: Vec<u32>,
    pub reference_ranges: Vec<RecoveryRange>,
}

impl RecoveryAnnotation {
    /// Combines the classification of another window. Windows cover disjoint
    /// segment ranges, so lists concatenate; the earliest title wins.
    pub fn absorb(&mut self, other: Self) {
        if self.title_segment.is_none() {
            self.title_segment = other.title_segment;
        }
        self.headings.extend(other.headings);
        self.noise_segments.extend(other.noise_segments);
        self.continuation_segments
            .extend(other.continuation_segments);
        self.reference_ranges.extend(other.reference_ranges);
    }
}

/// What a transcribed block is. Anything that is not running prose, a heading,
/// the title, or a bibliography entry is `Skip`: page furniture, author blocks,
/// captions, figure and table content, footnotes, and display equations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscribedBlockKind {
    Title,
    Heading,
    Paragraph,
    Reference,
    Skip,
}

/// One block of text a vision model read from a page, in reading order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscribedBlock {
    pub kind: TranscribedBlockKind,
    /// Heading depth, 1 up to [`RECOVERY_MAX_HEADING_LEVEL`]. `None` for every
    /// other kind.
    pub level: Option<u8>,
    /// The block begins mid-sentence: it continues the previous paragraph or
    /// bibliography entry across a page or column break.
    pub continues_previous: bool,
    pub text: String,
}

/// The transcription of one page. Pages are 1-based and supplied in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscribedPage {
    pub number: u32,
    pub blocks: Vec<TranscribedBlock>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_sources_have_distinct_stable_identities() {
        assert_eq!(RecoverySource::TeiText.parser_id(), RECOVERY_PARSER_ID);
        assert_eq!(
            RecoverySource::TeiText.parser_version(),
            RECOVERY_PARSER_VERSION
        );
        assert_eq!(RecoverySource::PageImages.parser_id(), VISION_PARSER_ID);
        assert_eq!(
            RecoverySource::PageImages.parser_version(),
            VISION_PARSER_VERSION
        );
        assert_ne!(
            RecoverySource::TeiText.parser_id(),
            RecoverySource::PageImages.parser_id()
        );
        // The persisted columns are `char_length BETWEEN 1 AND 64` / `1 AND 128`.
        for source in [RecoverySource::TeiText, RecoverySource::PageImages] {
            assert!((1..=64).contains(&source.parser_id().len()));
            assert!((1..=128).contains(&source.parser_version().len()));
        }
    }

    #[test]
    fn absorb_concatenates_windows_and_keeps_the_earliest_title() {
        let mut first = RecoveryAnnotation {
            title_segment: Some(1),
            headings: vec![RecoveryHeading {
                segment: 2,
                level: 1,
            }],
            noise_segments: vec![0],
            ..RecoveryAnnotation::default()
        };
        first.absorb(RecoveryAnnotation {
            title_segment: Some(400),
            headings: vec![RecoveryHeading {
                segment: 305,
                level: 2,
            }],
            continuation_segments: vec![310],
            reference_ranges: vec![RecoveryRange {
                start: 500,
                end: 520,
            }],
            ..RecoveryAnnotation::default()
        });
        assert_eq!(first.title_segment, Some(1));
        assert_eq!(first.headings.len(), 2);
        assert_eq!(first.noise_segments, [0]);
        assert_eq!(first.continuation_segments, [310]);
        assert_eq!(first.reference_ranges.len(), 1);
    }

    #[test]
    fn failure_hints_are_stable_closed_labels() {
        for hint in [
            RecoveryFailureHint::InvalidTei,
            RecoveryFailureHint::MissingBody,
            RecoveryFailureHint::NoIntroduction,
            RecoveryFailureHint::InvalidOutput,
            RecoveryFailureHint::NoOutput,
            RecoveryFailureHint::RejectedInput,
            RecoveryFailureHint::Unavailable,
        ] {
            assert!(
                hint.as_str()
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c == '_')
            );
            assert!(!hint.description().is_empty());
        }
    }
}
