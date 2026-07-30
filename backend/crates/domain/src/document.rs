use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{PaperId, ProcessingGeneration};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SectionKind {
    Abstract,
    Introduction,
    Background,
    RelatedWork,
    Method,
    Experiment,
    Result,
    Discussion,
    Limitation,
    Conclusion,
    Appendix,
    Acknowledgment,
    References,
    #[default]
    Other,
}

impl SectionKind {
    #[must_use]
    pub const fn is_later_section(self) -> bool {
        matches!(
            self,
            Self::Background
                | Self::RelatedWork
                | Self::Method
                | Self::Experiment
                | Self::Result
                | Self::Discussion
                | Self::Limitation
                | Self::Conclusion
                | Self::Appendix
        )
    }

    #[must_use]
    pub const fn is_chat_indexable(self) -> bool {
        self.is_later_section() || matches!(self, Self::Introduction)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedCitationMarker {
    /// Unicode-scalar offset in the normalized paragraph text.
    pub start: usize,
    /// Exclusive Unicode-scalar offset in the normalized paragraph text.
    pub end: usize,
    pub marker: String,
    pub reference_ordinals: Vec<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedParagraph {
    pub ordinal: usize,
    pub text: String,
    /// Inline bibliography markers retained from the parser. Older persisted
    /// paragraph JSON omitted this field, so it must remain backward-compatible.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub citations: Vec<ParsedCitationMarker>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedSection {
    /// Stable within a single parsed document; derived from the TEI `xml:id`
    /// when present, otherwise assigned deterministically.
    pub source_id: String,
    pub ordinal: usize,
    pub parent_source_id: Option<String>,
    pub kind: SectionKind,
    pub heading: Option<String>,
    pub paragraphs: Vec<ParsedParagraph>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedReference {
    pub source_id: String,
    pub ordinal: usize,
    pub raw_text: String,
    pub title: Option<String>,
    pub authors: Vec<String>,
    pub year: Option<i32>,
    pub doi: Option<String>,
    pub url: Option<String>,
    pub arxiv_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedCitationContext {
    pub reference_source_id: String,
    pub section_source_id: String,
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    pub context_text: String,
    pub page_number: Option<u32>,
    pub occurrence_ordinal: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedPaper {
    pub title: Option<String>,
    pub sections: Vec<ParsedSection>,
    pub references: Vec<ParsedReference>,
    pub citation_contexts: Vec<ParsedCitationContext>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct IntroductionDetection {
    pub confidence: f32,
    pub used_fallback: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntroductionCitationReference {
    pub paper_id: PaperId,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntroductionCitation {
    /// Unicode-scalar offsets let non-Rust clients split text safely even when
    /// content before a marker contains multibyte characters.
    pub start: usize,
    pub end: usize,
    pub marker: String,
    pub references: Vec<IntroductionCitationReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntroductionParagraph {
    pub ordinal: usize,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heading: Option<String>,
    /// Only resolved references are published. An absent entry intentionally
    /// leaves the marker readable as ordinary paragraph text.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub citations: Vec<IntroductionCitation>,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Introduction {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub heading: Option<String>,
    pub paragraphs: Vec<IntroductionParagraph>,
    pub detection: IntroductionDetection,
    pub original_pdf_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chunk {
    pub id: Uuid,
    pub paper_id: PaperId,
    pub section_id: Uuid,
    pub generation: ProcessingGeneration,
    pub ordinal: usize,
    pub section_kind: SectionKind,
    pub section_heading: Option<String>,
    pub text: String,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub token_count: usize,
}
