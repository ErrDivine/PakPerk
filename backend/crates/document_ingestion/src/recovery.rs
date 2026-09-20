//! Model-assisted recovery of documents whose primary parser output could not
//! be normalized.
//!
//! Text recovery: text from the primary parser is split into numbered segments
//! by deterministic code, a model classifies those segments (heading, noise,
//! continuation, reference), and this module rebuilds a document from the
//! classification. Every word of such a document is copied from the source
//! segments; the model cannot add, rewrite, or reorder text.
//!
//! Page-image recovery: a vision model transcribes rendered pages into blocks.
//! Those blocks become segments and a classification, so both paths share one
//! assembler and its guards, but the words are model-authored and the document
//! is labelled accordingly.

use document_model::{ParsedTeiDocument, classify_section, normalize_text};
use domain::{
    NormalizedDocument, PaperId, ParsedPaper, ParsedParagraph, ParsedReference, ParsedSection,
    ProcessingGeneration, RECOVERY_MAX_HEADING_LEVEL, RECOVERY_MAX_SEGMENT_SCALARS,
    RECOVERY_MAX_SEGMENTS, RECOVERY_MAX_SOURCE_SCALARS, RECOVERY_PREVIEW_SCALARS,
    RecoveryAnnotation, RecoveryHeading, RecoveryRange, RecoverySegment, RecoverySource,
    TranscribedBlockKind, TranscribedPage, VISION_MAX_SEGMENTS,
};

use crate::{ParseError, normalize::normalize_grobid_paper};

/// Elements whose start and end begin a new paragraph in the recovered text.
const BLOCK_ELEMENTS: [&str; 17] = [
    "text", "front", "body", "back", "div", "head", "p", "figure", "figDesc", "table", "row",
    "list", "item", "listBibl", "abstract", "title", "note",
];
/// Header elements that only carry software stamps and licence boilerplate.
const SKIPPED_ELEMENTS: [&str; 3] = ["encodingDesc", "revisionDesc", "publicationStmt"];
/// A "heading" longer than this is a mislabeled paragraph.
const MAX_HEADING_SCALARS: usize = 200;
const MAX_TITLE_SCALARS: usize = 500;

/// Best-effort plain text of a TEI document. It tolerates malformed XML, which
/// is the point: this runs precisely when the strict parser has given up.
/// Paragraph-level elements become blank-line separated blocks, and each
/// bibliography entry becomes one block.
#[must_use]
pub fn tei_to_plain_text(tei: &str) -> String {
    let mut output = String::with_capacity(tei.len() / 2);
    let mut rest = tei;
    let mut skipped: Option<(&str, usize)> = None;
    let mut bibliography_depth = 0_usize;
    while let Some(open) = rest.find('<') {
        if skipped.is_none() {
            push_collapsed(&mut output, &decode_entities(&rest[..open]));
        }
        rest = &rest[open..];
        if let Some(after) = rest.strip_prefix("<!--") {
            rest = after.find("-->").map_or("", |end| &after[end + 3..]);
            continue;
        }
        if let Some(after) = rest.strip_prefix("<![CDATA[") {
            let (data, tail) = after
                .find("]]>")
                .map_or((after, ""), |end| (&after[..end], &after[end + 3..]));
            if skipped.is_none() {
                push_collapsed(&mut output, data);
            }
            rest = tail;
            continue;
        }
        let Some(close) = rest.find('>') else {
            rest = "";
            break;
        };
        let tag = &rest[1..close];
        rest = &rest[close + 1..];
        if tag.starts_with(['?', '!']) {
            continue;
        }
        let closing = tag.starts_with('/');
        let self_closing = tag.ends_with('/');
        let name = local_element_name(tag);
        if let Some((skipped_name, depth)) = skipped.as_mut() {
            if name == *skipped_name {
                if closing {
                    *depth -= 1;
                } else if !self_closing {
                    *depth += 1;
                }
                if *depth == 0 {
                    skipped = None;
                }
            }
            continue;
        }
        if !closing && !self_closing && SKIPPED_ELEMENTS.contains(&name) {
            skipped = Some((name, 1));
            continue;
        }
        if name == "biblStruct" {
            // One bibliography entry is one block, however its fields nest.
            output.push_str("\n\n");
            if closing {
                bibliography_depth = bibliography_depth.saturating_sub(1);
            } else if !self_closing {
                bibliography_depth += 1;
            }
        } else if bibliography_depth > 0 {
            if closing || self_closing {
                output.push(' ');
            }
        } else if BLOCK_ELEMENTS.contains(&name) {
            output.push_str("\n\n");
        } else if closing && matches!(name, "s" | "cell") {
            output.push(' ');
        }
    }
    if skipped.is_none() {
        push_collapsed(&mut output, &decode_entities(rest));
    }
    // Tag handlers add separators without knowing their neighbours; tidy each
    // line so the output is deterministic regardless of markup layout.
    output
        .split('\n')
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

fn local_element_name(tag: &str) -> &str {
    let name = tag.trim_start_matches('/').trim_start();
    let name = name
        .split(|character: char| character.is_whitespace() || character == '/')
        .next()
        .unwrap_or_default();
    name.rsplit(':').next().unwrap_or(name)
}

fn decode_entities(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(ampersand) = rest.find('&') {
        output.push_str(&rest[..ampersand]);
        rest = &rest[ampersand..];
        let decoded = rest
            .find(';')
            .filter(|semicolon| *semicolon <= 10)
            .and_then(|semicolon| decode_entity(&rest[1..semicolon]).map(|c| (c, semicolon)));
        if let Some((character, semicolon)) = decoded {
            output.push(character);
            rest = &rest[semicolon + 1..];
        } else {
            output.push('&');
            rest = &rest[1..];
        }
    }
    output.push_str(rest);
    output
}

fn decode_entity(name: &str) -> Option<char> {
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => {
            let digits = name.strip_prefix('#')?;
            let code = if let Some(hex) = digits.strip_prefix(['x', 'X']) {
                u32::from_str_radix(hex, 16).ok()?
            } else {
                digits.parse().ok()?
            };
            char::from_u32(code)
        }
    }
}

/// Collapses whitespace runs to one space while keeping a boundary space, so
/// `<hi>foo</hi> bar` never glues into `foobar`. Only explicit block markers
/// produce line breaks.
fn push_collapsed(output: &mut String, text: &str) {
    if text.is_empty() {
        return;
    }
    if text.starts_with(char::is_whitespace) {
        output.push(' ');
    }
    let mut words = text.split_whitespace();
    if let Some(first) = words.next() {
        output.push_str(first);
        for word in words {
            output.push(' ');
            output.push_str(word);
        }
        if text.ends_with(char::is_whitespace) {
            output.push(' ');
        }
    }
}

/// One numbered piece of source text. `text` is the full segment; the model
/// only ever sees [`SourceSegment::preview`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceSegment {
    pub index: u32,
    pub text: String,
}

impl SourceSegment {
    /// Whitespace-collapsed, length-bounded text for the model.
    #[must_use]
    pub fn preview(&self) -> RecoverySegment {
        let collapsed = self.text.split_whitespace().collect::<Vec<_>>().join(" ");
        let text = if collapsed.chars().count() > RECOVERY_PREVIEW_SCALARS {
            let mut truncated = collapsed
                .chars()
                .take(RECOVERY_PREVIEW_SCALARS - 1)
                .collect::<String>();
            truncated.push('…');
            truncated
        } else {
            collapsed
        };
        RecoverySegment {
            index: self.index,
            text,
        }
    }
}

/// Splits text into blank-line separated segments. Segments without any
/// letter or digit are dropped, control characters become spaces, and very
/// long blocks are cut at whitespace. Fails closed on oversized input rather
/// than silently recovering only part of a document.
pub fn split_source_segments(text: &str) -> Result<Vec<SourceSegment>, ParseError> {
    if text.chars().take(RECOVERY_MAX_SOURCE_SCALARS + 1).count() > RECOVERY_MAX_SOURCE_SCALARS {
        return Err(ParseError::InvalidInput("recovery source is too large"));
    }
    let mut segments = Vec::new();
    let mut block = String::new();
    for line in text.lines().chain(std::iter::once("")) {
        let line = line
            .chars()
            .map(|character| {
                if character.is_control() {
                    ' '
                } else {
                    character
                }
            })
            .collect::<String>();
        let line = line.trim();
        if line.is_empty() {
            push_block(&mut segments, &block)?;
            block.clear();
        } else {
            if !block.is_empty() {
                block.push('\n');
            }
            block.push_str(line);
        }
    }
    Ok(segments)
}

fn push_block(segments: &mut Vec<SourceSegment>, block: &str) -> Result<(), ParseError> {
    let mut remaining = block;
    while !remaining.is_empty() {
        let piece = match remaining.char_indices().nth(RECOVERY_MAX_SEGMENT_SCALARS) {
            None => remaining,
            Some((limit, _)) => {
                let cut = remaining[..limit]
                    .rfind(char::is_whitespace)
                    .filter(|cut| *cut > 0)
                    .unwrap_or(limit);
                &remaining[..cut]
            }
        };
        remaining = remaining[piece.len()..].trim_start();
        let piece = piece.trim();
        if !piece.chars().any(char::is_alphanumeric) {
            continue;
        }
        if segments.len() >= RECOVERY_MAX_SEGMENTS {
            return Err(ParseError::InvalidInput(
                "recovery source has too many segments",
            ));
        }
        segments.push(SourceSegment {
            index: u32::try_from(segments.len()).map_err(|_| ParseError::InvalidOutput)?,
            text: piece.to_owned(),
        });
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Paragraph,
    Continuation,
    Reference,
    ReferenceContinuation,
    Heading(u8),
    Title,
    Noise,
}

/// A document rebuilt from a classification, in both persisted shapes.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveredDocument {
    pub paper: ParsedPaper,
    pub document: NormalizedDocument,
}

/// Rebuilds a document from source segments and a classification.
///
/// Overlapping labels resolve deterministically: title, then heading, then
/// noise, then bibliography, then continuation. Indexes outside the segment
/// list are ignored. The result is rejected unless it keeps at least one body
/// paragraph and at least a fifth of the source text, so a classification that
/// discards nearly everything cannot produce a hollow document. `source` sets
/// the parser identity recorded in the document's provenance.
pub fn assemble_recovered_document(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    arxiv_version: u32,
    source: RecoverySource,
    segments: &[SourceSegment],
    annotation: &RecoveryAnnotation,
) -> Result<RecoveredDocument, ParseError> {
    if paper_id.is_nil() || generation <= 0 || arxiv_version == 0 {
        return Err(ParseError::InvalidInput("paper scope"));
    }
    let mut builder = DocumentBuilder::default();
    for (segment, role) in segments.iter().zip(classify(segments.len(), annotation)) {
        builder.push(role, &segment.text);
    }
    let source_scalars = segments
        .iter()
        .map(|segment| segment.text.chars().count())
        .sum::<usize>();
    if builder.paragraph_count == 0 || builder.kept_scalars.saturating_mul(5) < source_scalars {
        return Err(ParseError::InvalidOutput);
    }
    let parsed = ParsedTeiDocument {
        paper: ParsedPaper {
            title: builder.title,
            sections: builder.sections,
            references: builder.references,
            citation_contexts: Vec::new(),
        },
        figures: Vec::new(),
        tables: Vec::new(),
        equations: Vec::new(),
        object_references: Vec::new(),
    };
    let document = normalize_grobid_paper(
        paper_id,
        generation,
        arxiv_version,
        source.parser_id(),
        source.parser_version(),
        &parsed,
    )?;
    document.validate()?;
    Ok(RecoveredDocument {
        paper: parsed.paper,
        document,
    })
}

/// Rebuilds a document from page transcriptions, in page and reading order.
///
/// Each transcribed block becomes a segment and its kind becomes the sparse
/// classification that text recovery uses, so both paths share one assembler
/// and its guards. The document is labelled [`RecoverySource::PageImages`]:
/// unlike text recovery, its words were written by a model.
pub fn assemble_transcribed_document(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    arxiv_version: u32,
    pages: &[TranscribedPage],
) -> Result<RecoveredDocument, ParseError> {
    let (segments, annotation) = segments_from_pages(pages)?;
    assemble_recovered_document(
        paper_id,
        generation,
        arxiv_version,
        RecoverySource::PageImages,
        &segments,
        &annotation,
    )
}

fn close_bibliography(bibliography: &mut Option<(u32, u32)>, annotation: &mut RecoveryAnnotation) {
    if let Some((start, end)) = bibliography.take() {
        annotation
            .reference_ranges
            .push(RecoveryRange { start, end });
    }
}

fn segments_from_pages(
    pages: &[TranscribedPage],
) -> Result<(Vec<SourceSegment>, RecoveryAnnotation), ParseError> {
    let mut segments = Vec::new();
    let mut annotation = RecoveryAnnotation::default();
    // The bibliography being built: its first and last entry. It stays open
    // across skipped page furniture and ends at the next block of prose.
    let mut bibliography: Option<(u32, u32)> = None;
    for block in pages.iter().flat_map(|page| &page.blocks) {
        // Like the text splitter, drop debris without a letter or digit.
        if !block.text.chars().any(char::is_alphanumeric) {
            continue;
        }
        if segments.len() >= VISION_MAX_SEGMENTS {
            return Err(ParseError::InvalidInput(
                "transcription has too many blocks",
            ));
        }
        let index = u32::try_from(segments.len()).map_err(|_| ParseError::InvalidOutput)?;
        segments.push(SourceSegment {
            index,
            text: block.text.clone(),
        });
        if !matches!(
            block.kind,
            TranscribedBlockKind::Skip | TranscribedBlockKind::Reference
        ) {
            close_bibliography(&mut bibliography, &mut annotation);
        }
        match block.kind {
            TranscribedBlockKind::Skip => annotation.noise_segments.push(index),
            TranscribedBlockKind::Reference => {
                bibliography =
                    Some(bibliography.map_or((index, index), |(start, _)| (start, index)));
                if block.continues_previous {
                    annotation.continuation_segments.push(index);
                }
            }
            TranscribedBlockKind::Title => {
                // A second "title" is a running header the model mislabelled.
                if annotation.title_segment.is_none() {
                    annotation.title_segment = Some(index);
                } else {
                    annotation.noise_segments.push(index);
                }
            }
            TranscribedBlockKind::Heading => annotation.headings.push(RecoveryHeading {
                segment: index,
                level: block
                    .level
                    .unwrap_or(1)
                    .clamp(1, RECOVERY_MAX_HEADING_LEVEL),
            }),
            TranscribedBlockKind::Paragraph => {
                if block.continues_previous {
                    annotation.continuation_segments.push(index);
                }
            }
        }
    }
    close_bibliography(&mut bibliography, &mut annotation);
    Ok((segments, annotation))
}

/// Accumulates kept segments in document order.
#[derive(Default)]
struct DocumentBuilder {
    title: Option<String>,
    sections: Vec<ParsedSection>,
    /// `(heading level, section index)` of the currently open section chain.
    open_levels: Vec<(u8, usize)>,
    references: Vec<ParsedReference>,
    last_was_paragraph: bool,
    last_was_reference: bool,
    kept_scalars: usize,
    paragraph_count: usize,
}

impl DocumentBuilder {
    fn push(&mut self, role: Role, raw: &str) {
        let text = normalize_text(raw);
        if text.is_empty() {
            return;
        }
        match role {
            Role::Noise => {}
            Role::Title => {
                self.title = Some(text.chars().take(MAX_TITLE_SCALARS).collect());
                self.last_was_paragraph = false;
                self.last_was_reference = false;
            }
            Role::Heading(level)
                if text.chars().count() <= MAX_HEADING_SCALARS
                    && !self.repeats_sibling_heading(&text, level) =>
            {
                self.kept_scalars += text.chars().count();
                self.open_section(Some(text), level);
                self.last_was_paragraph = false;
                self.last_was_reference = false;
            }
            Role::Reference | Role::ReferenceContinuation => {
                self.push_reference(text, raw, role == Role::ReferenceContinuation);
            }
            // A heading that is implausibly long, or that repeats a sibling's, falls
            // through as a paragraph.
            Role::Paragraph | Role::Continuation | Role::Heading(_) => {
                self.push_paragraph(text, raw, role == Role::Continuation);
            }
        }
    }

    fn push_reference(&mut self, text: String, raw: &str, continuation: bool) {
        if continuation
            && self.last_was_reference
            && let Some(previous) = self.references.last_mut()
        {
            previous.raw_text = normalize_text(&format!("{}\n{raw}", previous.raw_text));
        } else {
            let ordinal = self.references.len();
            self.references.push(ParsedReference {
                source_id: format!("recovered-reference-{ordinal}"),
                ordinal,
                raw_text: text,
                title: None,
                authors: Vec::new(),
                year: None,
                doi: None,
                url: None,
                arxiv_id: None,
            });
        }
        self.last_was_paragraph = false;
        self.last_was_reference = true;
    }

    fn push_paragraph(&mut self, text: String, raw: &str, continuation: bool) {
        let section_index = match self.open_levels.last() {
            Some(&(_, index)) => index,
            None => self.open_section(None, 1),
        };
        let paragraphs = &mut self.sections[section_index].paragraphs;
        if continuation
            && self.last_was_paragraph
            && let Some(previous) = paragraphs.last_mut()
        {
            let merged = normalize_text(&format!("{}\n{raw}", previous.text));
            self.kept_scalars += merged
                .chars()
                .count()
                .saturating_sub(previous.text.chars().count());
            previous.text = merged;
        } else {
            self.kept_scalars += text.chars().count();
            paragraphs.push(ParsedParagraph {
                ordinal: paragraphs.len(),
                text,
                citations: Vec::new(),
                page_start: None,
                page_end: None,
            });
            self.paragraph_count += 1;
        }
        self.last_was_paragraph = true;
        self.last_was_reference = false;
    }

    /// Whether a section titled `text` at `level` would repeat the heading of a
    /// sibling. In a model-classified document a repeat is nearly always a
    /// running header or a run-in label, so it is kept as a paragraph instead of
    /// opening a second section with the same title. This is a quality choice:
    /// the shared normalizer disambiguates repeated block keys, so a repeated
    /// heading would still validate.
    fn repeats_sibling_heading(&self, text: &str, level: u8) -> bool {
        let parent = self
            .open_levels
            .iter()
            .rev()
            .find(|(open, _)| *open < level)
            .map(|(_, index)| self.sections[*index].source_id.as_str());
        let wanted = text.to_lowercase();
        self.sections.iter().any(|section| {
            section.parent_source_id.as_deref() == parent
                && section
                    .heading
                    .as_deref()
                    .is_some_and(|heading| heading.to_lowercase() == wanted)
        })
    }

    /// Opens a section under the nearest shallower open section.
    fn open_section(&mut self, heading: Option<String>, level: u8) -> usize {
        while self
            .open_levels
            .last()
            .is_some_and(|(open, _)| *open >= level)
        {
            self.open_levels.pop();
        }
        let parent_source_id = self
            .open_levels
            .last()
            .map(|(_, index)| self.sections[*index].source_id.clone());
        let ordinal = self.sections.len();
        self.sections.push(ParsedSection {
            source_id: format!("recovered-section-{ordinal}"),
            ordinal,
            parent_source_id,
            kind: classify_section(heading.as_deref(), None),
            heading,
            paragraphs: Vec::new(),
            page_start: None,
            page_end: None,
        });
        self.open_levels.push((level, ordinal));
        ordinal
    }
}

fn classify(count: usize, annotation: &RecoveryAnnotation) -> Vec<Role> {
    let position = |index: u32| usize::try_from(index).ok().filter(|index| *index < count);
    let mut in_reference = vec![false; count];
    for range in &annotation.reference_ranges {
        if let (Some(start), Some(end)) = (position(range.start), position(range.end)) {
            in_reference[start..=end.max(start)].fill(true);
        }
    }
    let mut is_continuation = vec![false; count];
    for index in annotation
        .continuation_segments
        .iter()
        .filter_map(|i| position(*i))
    {
        is_continuation[index] = true;
    }
    let mut roles = in_reference
        .iter()
        .zip(&is_continuation)
        .map(|pair| match pair {
            (true, true) => Role::ReferenceContinuation,
            (true, false) => Role::Reference,
            (false, true) => Role::Continuation,
            (false, false) => Role::Paragraph,
        })
        .collect::<Vec<_>>();
    for index in annotation
        .noise_segments
        .iter()
        .filter_map(|i| position(*i))
    {
        roles[index] = Role::Noise;
    }
    for heading in &annotation.headings {
        if let Some(index) = position(heading.segment) {
            roles[index] = Role::Heading(heading.level);
        }
    }
    if let Some(index) = annotation.title_segment.and_then(position) {
        roles[index] = Role::Title;
    }
    roles
}

#[cfg(test)]
mod tests {
    use document_model::detect_introduction;
    use domain::{DocumentBlockKind, RECOVERY_PARSER_ID, RECOVERY_PARSER_VERSION, SectionKind};
    use uuid::Uuid;

    use super::*;

    /// Malformed on purpose: the closing `</TEI>` is missing and a stray
    /// entity-like `&` appears, so the strict parser would reject it.
    const MALFORMED_TEI: &str = r##"<?xml version="1.0"?>
<TEI xmlns="http://www.tei-c.org/ns/1.0"><teiHeader><fileDesc>
<titleStmt><title>Recovered Paper</title></titleStmt>
<publicationStmt><p>Licence boilerplate that must be skipped</p></publicationStmt>
</fileDesc><encodingDesc><appInfo>GROBID stamp that must be skipped</appInfo></encodingDesc></teiHeader>
<text><body>
<div><head n="1">1 Introduction</head>
<p>We study robust reading of scientific papers on small screens, and we explain <ref type="bibr" target="#b0">[1]</ref> why document structure matters &amp; how to keep it.</p>
<p>A second paragraph ends with a hyphenated represen-</p>
<p>tation across a page break.</p>
<p>Page 3</p>
</div>
<div><head n="2">2 Method</head>
<p><s>The method is simple.</s><s>Second sentence.</s><s>Third one.</s></p>
</div></body>
<back><listBibl>
<biblStruct xml:id="b0"><analytic><author><persName><forename>Ashish</forename><surname>Vaswani</surname></persName></author><title level="a">Attention</title></analytic></biblStruct>
</listBibl></back></text>"##;

    fn scope() -> (PaperId, i32, u32) {
        (Uuid::now_v7(), 1, 1)
    }

    fn malformed_segments() -> Vec<SourceSegment> {
        split_source_segments(&tei_to_plain_text(MALFORMED_TEI)).unwrap()
    }

    fn malformed_annotation() -> RecoveryAnnotation {
        RecoveryAnnotation {
            title_segment: Some(0),
            headings: vec![
                RecoveryHeading {
                    segment: 1,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 6,
                    level: 1,
                },
            ],
            noise_segments: vec![5],
            continuation_segments: vec![4],
            reference_ranges: vec![RecoveryRange { start: 8, end: 8 }],
        }
    }

    #[test]
    fn plain_text_skips_boilerplate_decodes_entities_and_keeps_blocks_apart() {
        let text = tei_to_plain_text(MALFORMED_TEI);
        assert!(!text.contains("boilerplate"));
        assert!(!text.contains("GROBID stamp"));
        assert!(text.contains("why document structure matters & how to keep it."));
        assert!(text.contains("The method is simple. Second sentence. Third one."));
        assert!(text.contains("[1]"));
        let blocks = text
            .split("\n\n")
            .map(str::trim)
            .filter(|b| !b.is_empty())
            .collect::<Vec<_>>();
        assert_eq!(blocks[0], "Recovered Paper");
        assert_eq!(blocks[1], "1 Introduction");
        assert!(blocks.contains(&"A second paragraph ends with a hyphenated represen-"));
        assert_eq!(blocks.last().copied(), Some("Ashish Vaswani Attention"));
    }

    #[test]
    fn plain_text_handles_namespaced_tags_cdata_comments_and_unterminated_tags() {
        let text = tei_to_plain_text(
            "<t:text><t:body><t:div><t:head>Intro</t:head><!-- <p>hidden</p> --><t:p>a<![CDATA[ <b> ]]>b &#955; &#x3b1; &bogus; &amp;</t:p></t:div><t:p>tail <unterminated",
        );
        assert!(text.contains("Intro"));
        assert!(!text.contains("hidden"));
        assert!(text.contains("a <b> b λ α &bogus; &"), "{text:?}");
        assert!(!text.contains("unterminated"));
        assert_eq!(tei_to_plain_text(""), "");
        assert_eq!(tei_to_plain_text("no markup at all"), "no markup at all");
    }

    #[test]
    fn segments_split_on_blank_lines_and_drop_debris() {
        let segments = split_source_segments(
            "Title line\n\n  \u{c}\n\nFirst para line one\nline two\n\n---\n\n\u{0}Second\u{7} para\n",
        )
        .unwrap();
        let texts = segments.iter().map(|s| s.text.as_str()).collect::<Vec<_>>();
        assert_eq!(
            texts,
            [
                "Title line",
                "First para line one\nline two",
                "Second  para"
            ]
        );
        assert_eq!(
            segments.iter().map(|s| s.index).collect::<Vec<_>>(),
            [0, 1, 2]
        );
    }

    #[test]
    fn long_blocks_are_cut_at_whitespace_and_previews_are_bounded() {
        let long = "word ".repeat(RECOVERY_MAX_SEGMENT_SCALARS / 2);
        let segments = split_source_segments(&long).unwrap();
        assert!(segments.len() >= 2);
        assert!(
            segments
                .iter()
                .all(|s| s.text.chars().count() <= RECOVERY_MAX_SEGMENT_SCALARS)
        );
        assert!(
            segments
                .iter()
                .all(|s| !s.text.starts_with(' ') && !s.text.ends_with(' '))
        );
        let preview = segments[0].preview();
        assert_eq!(preview.text.chars().count(), RECOVERY_PREVIEW_SCALARS);
        assert!(preview.text.ends_with('…'));
        assert_eq!(
            SourceSegment {
                index: 3,
                text: "a\n  b\tc".into()
            }
            .preview(),
            RecoverySegment {
                index: 3,
                text: "a b c".into()
            }
        );
    }

    #[test]
    fn oversized_sources_fail_closed() {
        let many = "para\n\n".repeat(RECOVERY_MAX_SEGMENTS + 1);
        assert!(matches!(
            split_source_segments(&many),
            Err(ParseError::InvalidInput(
                "recovery source has too many segments"
            ))
        ));
        let huge = "x".repeat(RECOVERY_MAX_SOURCE_SCALARS + 1);
        assert!(matches!(
            split_source_segments(&huge),
            Err(ParseError::InvalidInput("recovery source is too large"))
        ));
    }

    #[test]
    fn rebuilds_a_valid_document_from_a_malformed_tei_and_a_classification() {
        let segments = malformed_segments();
        assert_eq!(segments.len(), 9, "{segments:#?}");
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &malformed_annotation(),
        )
        .unwrap();

        let paper = &recovered.paper;
        assert_eq!(paper.title.as_deref(), Some("Recovered Paper"));
        assert_eq!(paper.sections.len(), 2);
        assert_eq!(paper.sections[0].heading.as_deref(), Some("1 Introduction"));
        assert_eq!(paper.sections[0].kind, SectionKind::Introduction);
        assert_eq!(
            paper.sections[0].paragraphs.len(),
            2,
            "continuation merges, noise drops"
        );
        assert_eq!(
            paper.sections[0].paragraphs[1].text,
            "A second paragraph ends with a hyphenated representation across a page break."
        );
        assert_eq!(
            paper.sections[1].paragraphs[0].text,
            "The method is simple. Second sentence. Third one."
        );
        assert_eq!(paper.references.len(), 1);
        assert_eq!(paper.references[0].raw_text, "Ashish Vaswani Attention");
        assert!(paper.citation_contexts.is_empty());

        // The recovered structure must satisfy the same downstream gates as a
        // GROBID document.
        let introduction = detect_introduction(paper).unwrap();
        assert_eq!(introduction.source_section_ids, ["recovered-section-0"]);

        let document = &recovered.document;
        document.validate().unwrap();
        assert_eq!(document.parser_id, RECOVERY_PARSER_ID);
        assert_eq!(document.parser_version, RECOVERY_PARSER_VERSION);
        assert_eq!(document.paper_id, paper_id);
        let kinds = document
            .blocks
            .iter()
            .map(|block| block.kind)
            .collect::<Vec<_>>();
        assert_eq!(
            kinds,
            [
                DocumentBlockKind::Heading,
                DocumentBlockKind::Paragraph,
                DocumentBlockKind::Paragraph,
                DocumentBlockKind::Heading,
                DocumentBlockKind::Paragraph,
            ]
        );
        assert!(document.figures.is_empty() && document.tables.is_empty());
    }

    #[test]
    fn every_recovered_word_comes_from_the_source_text() {
        let segments = malformed_segments();
        let source = segments
            .iter()
            .map(|s| s.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let source_words = source
            .split_whitespace()
            .flat_map(|word| word.split('-'))
            .collect::<std::collections::HashSet<_>>();
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &malformed_annotation(),
        )
        .unwrap();
        for block in &recovered.document.blocks {
            for word in block
                .text
                .split_whitespace()
                .flat_map(|word| word.split('-'))
            {
                // The only text transformation is dehyphenating a page-break split.
                assert!(
                    source_words.contains(word) || word == "representation",
                    "recovered word {word:?} is not in the source"
                );
            }
        }
    }

    #[test]
    fn heading_levels_build_a_section_tree() {
        let segments = split_source_segments(
            "Abstract\n\nAn abstract long enough to matter for the ratio.\n\n1 Introduction\n\nIntro text that is comfortably long enough.\n\n1.1 Motivation\n\nMotivation text that is comfortably long enough.\n\n1.2 Scope\n\nScope text that is comfortably long enough.\n\n2 Method\n\nMethod text that is comfortably long enough.",
        )
        .unwrap();
        let annotation = RecoveryAnnotation {
            headings: [(0, 1), (2, 1), (4, 2), (6, 2), (8, 1)]
                .into_iter()
                .map(|(segment, level)| RecoveryHeading { segment, level })
                .collect(),
            ..RecoveryAnnotation::default()
        };
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &annotation,
        )
        .unwrap();
        let sections = &recovered.paper.sections;
        assert_eq!(sections.len(), 5);
        assert_eq!(sections[0].kind, SectionKind::Abstract);
        assert_eq!(
            sections[2].parent_source_id.as_deref(),
            Some("recovered-section-1")
        );
        assert_eq!(
            sections[3].parent_source_id.as_deref(),
            Some("recovered-section-1")
        );
        assert_eq!(sections[4].parent_source_id, None);
        let introduction = detect_introduction(&recovered.paper).unwrap();
        assert_eq!(
            introduction.source_section_ids,
            [
                "recovered-section-1",
                "recovered-section-2",
                "recovered-section-3"
            ]
        );
    }

    #[test]
    fn text_before_the_first_heading_gets_an_untitled_root_section() {
        let segments = split_source_segments(
            "Body text before any heading that is comfortably long enough to keep.\n\n1 Introduction\n\nIntroduction text that is comfortably long enough.",
        )
        .unwrap();
        let annotation = RecoveryAnnotation {
            headings: vec![RecoveryHeading {
                segment: 1,
                level: 1,
            }],
            ..RecoveryAnnotation::default()
        };
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &annotation,
        )
        .unwrap();
        assert_eq!(recovered.paper.sections[0].heading, None);
        assert_eq!(recovered.paper.sections[0].paragraphs.len(), 1);
        assert_eq!(
            recovered.paper.sections[1].heading.as_deref(),
            Some("1 Introduction")
        );
    }

    #[test]
    fn overlapping_labels_resolve_by_precedence_and_stray_indexes_are_ignored() {
        let segments = split_source_segments(
            "Paper Title Words\n\n1 Introduction\n\nBody text that is comfortably long enough to keep around.\n\nReferences\n\nSmith. A reference entry.",
        )
        .unwrap();
        let annotation = RecoveryAnnotation {
            title_segment: Some(0),
            // The title is also (wrongly) a heading and noise; the heading is
            // also inside the bibliography range.
            headings: vec![
                RecoveryHeading {
                    segment: 0,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 1,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 3,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 99,
                    level: 1,
                },
            ],
            noise_segments: vec![0, 99],
            continuation_segments: vec![99],
            reference_ranges: vec![
                RecoveryRange { start: 3, end: 4 },
                RecoveryRange { start: 90, end: 95 },
            ],
        };
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &annotation,
        )
        .unwrap();
        assert_eq!(recovered.paper.title.as_deref(), Some("Paper Title Words"));
        assert_eq!(
            recovered
                .paper
                .sections
                .iter()
                .map(|s| s.heading.as_deref())
                .collect::<Vec<_>>(),
            [Some("1 Introduction"), Some("References")]
        );
        assert_eq!(recovered.paper.references.len(), 1);
        assert_eq!(
            recovered.paper.references[0].raw_text,
            "Smith. A reference entry."
        );
    }

    #[test]
    fn implausibly_long_headings_and_orphan_continuations_become_paragraphs() {
        let long_heading = "word ".repeat(80);
        let segments = split_source_segments(&format!(
            "starts mid sentence and has no predecessor at all\n\n{long_heading}\n\nAn ordinary paragraph that is comfortably long enough to keep."
        ))
        .unwrap();
        let annotation = RecoveryAnnotation {
            headings: vec![RecoveryHeading {
                segment: 1,
                level: 1,
            }],
            continuation_segments: vec![0],
            ..RecoveryAnnotation::default()
        };
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &annotation,
        )
        .unwrap();
        assert_eq!(recovered.paper.sections.len(), 1);
        assert_eq!(recovered.paper.sections[0].heading, None);
        assert_eq!(recovered.paper.sections[0].paragraphs.len(), 3);
    }

    #[test]
    fn hollow_classifications_are_rejected() {
        let segments = malformed_segments();
        let (paper_id, generation, version) = scope();
        let everything_is_noise = RecoveryAnnotation {
            noise_segments: (0..9).collect(),
            ..RecoveryAnnotation::default()
        };
        let everything_is_references = RecoveryAnnotation {
            reference_ranges: vec![RecoveryRange { start: 0, end: 8 }],
            ..RecoveryAnnotation::default()
        };
        for annotation in [everything_is_noise, everything_is_references] {
            assert!(matches!(
                assemble_recovered_document(
                    paper_id,
                    generation,
                    version,
                    RecoverySource::TeiText,
                    &segments,
                    &annotation
                ),
                Err(ParseError::InvalidOutput)
            ));
        }
        // One tiny kept paragraph out of a large source is also hollow.
        let mut noisy = (0..40)
            .map(|index| format!("Discarded debris paragraph number {index} with padding text."))
            .collect::<Vec<_>>();
        noisy.push("Kept.".to_owned());
        let segments = split_source_segments(&noisy.join("\n\n")).unwrap();
        let annotation = RecoveryAnnotation {
            noise_segments: (0..40).collect(),
            ..RecoveryAnnotation::default()
        };
        assert!(matches!(
            assemble_recovered_document(
                paper_id,
                generation,
                version,
                RecoverySource::TeiText,
                &segments,
                &annotation
            ),
            Err(ParseError::InvalidOutput)
        ));
    }

    #[test]
    fn scope_is_validated() {
        let segments = malformed_segments();
        let annotation = malformed_annotation();
        assert!(
            assemble_recovered_document(
                Uuid::nil(),
                1,
                1,
                RecoverySource::TeiText,
                &segments,
                &annotation
            )
            .is_err()
        );
        assert!(
            assemble_recovered_document(
                Uuid::now_v7(),
                0,
                1,
                RecoverySource::TeiText,
                &segments,
                &annotation
            )
            .is_err()
        );
        assert!(
            assemble_recovered_document(
                Uuid::now_v7(),
                1,
                0,
                RecoverySource::TeiText,
                &segments,
                &annotation
            )
            .is_err()
        );
    }

    #[test]
    fn consecutive_reference_lines_merge_only_when_marked_as_continuations() {
        let segments = split_source_segments(
            "1 Introduction\n\nIntroduction text that is comfortably long enough to keep.\n\nReferences\n\nSmith, J. A very long reference title that\n\nwraps onto a second column line. 2020.\n\nDoe, J. Another reference. 2021.",
        )
        .unwrap();
        let annotation = RecoveryAnnotation {
            headings: vec![
                RecoveryHeading {
                    segment: 0,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 2,
                    level: 1,
                },
            ],
            continuation_segments: vec![4],
            reference_ranges: vec![RecoveryRange { start: 3, end: 5 }],
            ..RecoveryAnnotation::default()
        };
        let (paper_id, generation, version) = scope();
        let recovered = assemble_recovered_document(
            paper_id,
            generation,
            version,
            RecoverySource::TeiText,
            &segments,
            &annotation,
        )
        .unwrap();
        let raw = recovered
            .paper
            .references
            .iter()
            .map(|r| r.raw_text.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            raw,
            [
                "Smith, J. A very long reference title that wraps onto a second column line. 2020.",
                "Doe, J. Another reference. 2021."
            ]
        );
    }

    fn block(
        kind: TranscribedBlockKind,
        level: Option<u8>,
        continues_previous: bool,
        text: &str,
    ) -> domain::TranscribedBlock {
        domain::TranscribedBlock {
            kind,
            level,
            continues_previous,
            text: text.to_owned(),
        }
    }

    fn title(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Title, None, false, text)
    }

    fn heading(level: u8, text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Heading, Some(level), false, text)
    }

    fn prose(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Paragraph, None, false, text)
    }

    fn continued(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Paragraph, None, true, text)
    }

    fn entry(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Reference, None, false, text)
    }

    fn continued_entry(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Reference, None, true, text)
    }

    fn skip(text: &str) -> domain::TranscribedBlock {
        block(TranscribedBlockKind::Skip, None, false, text)
    }

    fn pages(pages: Vec<Vec<domain::TranscribedBlock>>) -> Vec<TranscribedPage> {
        pages
            .into_iter()
            .enumerate()
            .map(|(index, blocks)| TranscribedPage {
                number: u32::try_from(index + 1).unwrap(),
                blocks,
            })
            .collect()
    }

    fn scanned_paper() -> Vec<TranscribedPage> {
        pages(vec![
            vec![
                title("Densely Connected Networks"),
                skip("Gao Huang Cornell University"),
                heading(1, "Abstract"),
                prose(
                    "Recent work has shown that convolutional networks can be substantially deeper, more accurate, and efficient to train.",
                ),
                heading(1, "1. Introduction"),
                prose(
                    "Convolutional neural networks have become the dominant approach for visual object recognition and the original LeNet5 consisted of",
                ),
                skip("1"),
            ],
            vec![
                skip("arXiv:1608.06993v5 [cs.CV] 28 Jan 2018"),
                continued(
                    "5 layers while VGG featured 19 and only last year Highway Networks surpassed the 100-layer barrier.",
                ),
                heading(1, "2. Related Work"),
                heading(2, "2.1 Skip connections"),
                prose(
                    "Highway networks bypass signal from one layer to the next via identity connections.",
                ),
                skip("2"),
            ],
            vec![
                heading(1, "References"),
                entry("[1] G. Huang, Y. Sun. Deep networks with stochastic depth. 2016."),
                skip("3"),
                entry("[2] K. He, X. Zhang. Deep residual learning for image"),
                continued_entry("recognition. 2016."),
                prose("Appendix text that follows the bibliography."),
                entry("[3] A late entry. 2017."),
            ],
        ])
    }

    #[test]
    fn transcribed_pages_build_a_valid_document_labelled_as_model_authored() {
        let (paper_id, generation, version) = scope();
        let recovered =
            assemble_transcribed_document(paper_id, generation, version, &scanned_paper()).unwrap();

        assert_eq!(recovered.document.parser_id, "llm-vision-recovery");
        assert_eq!(recovered.document.parser_version, "llm-vision-recovery-v1");
        let paper = &recovered.paper;
        assert_eq!(paper.title.as_deref(), Some("Densely Connected Networks"));
        assert_eq!(
            paper
                .sections
                .iter()
                .map(|section| section.heading.as_deref().unwrap())
                .collect::<Vec<_>>(),
            [
                "Abstract",
                "1. Introduction",
                "2. Related Work",
                "2.1 Skip connections",
                "References"
            ]
        );
        assert_eq!(paper.sections[1].kind, SectionKind::Introduction);
        assert_eq!(
            paper.sections[3].parent_source_id.as_deref(),
            Some(paper.sections[2].source_id.as_str()),
            "a level-2 heading nests under the level-1 heading before it"
        );
        assert!(
            paper.sections[1].paragraphs[0]
                .text
                .contains("consisted of 5 layers while VGG featured 19"),
            "a paragraph continued on the next page is one paragraph: {}",
            paper.sections[1].paragraphs[0].text
        );
        let everything = paper
            .sections
            .iter()
            .flat_map(|section| section.paragraphs.iter().map(|p| p.text.as_str()))
            .collect::<Vec<_>>()
            .join("\n");
        for furniture in ["Cornell", "arXiv:1608", "Gao Huang"] {
            assert!(!everything.contains(furniture), "{furniture} was skipped");
        }

        let entries = paper
            .references
            .iter()
            .map(|reference| reference.raw_text.as_str())
            .collect::<Vec<_>>();
        assert_eq!(entries.len(), 3, "{entries:?}");
        assert!(
            entries[1].ends_with("image recognition. 2016."),
            "{}",
            entries[1]
        );
        assert!(
            entries[2].starts_with("[3]"),
            "prose ended the bibliography"
        );
        assert!(
            everything.contains("Appendix text that follows the bibliography."),
            "prose after the bibliography stays prose"
        );
        detect_introduction(paper).expect("the introduction is found like a GROBID document's");
    }

    #[test]
    fn a_second_title_and_stray_heading_levels_are_handled_defensively() {
        let (paper_id, generation, version) = scope();
        let recovered = assemble_transcribed_document(
            paper_id,
            generation,
            version,
            &pages(vec![vec![
                title("The Real Title"),
                title("Running header mislabelled as a title"),
                heading(1, "1 Introduction"),
                heading(9, "1.1 Far too deep"),
                prose("Body text under the deepest heading, long enough to be kept."),
            ]]),
        )
        .unwrap();
        let paper = &recovered.paper;
        assert_eq!(paper.title.as_deref(), Some("The Real Title"));
        assert_eq!(paper.sections.len(), 2);
        assert_eq!(
            paper.sections[1].parent_source_id.as_deref(),
            Some(paper.sections[0].source_id.as_str())
        );
    }

    #[test]
    fn transcriptions_that_keep_almost_nothing_are_rejected() {
        let (paper_id, generation, version) = scope();
        let junk = "page furniture and captions ".repeat(40);
        let hollow = pages(vec![vec![prose("A short paragraph."), skip(&junk)]]);
        assert!(matches!(
            assemble_transcribed_document(paper_id, generation, version, &hollow),
            Err(ParseError::InvalidOutput)
        ));

        let only_skipped = pages(vec![vec![skip("Header text"), skip("Footer text")]]);
        assert!(matches!(
            assemble_transcribed_document(paper_id, generation, version, &only_skipped),
            Err(ParseError::InvalidOutput)
        ));
        assert!(matches!(
            assemble_transcribed_document(paper_id, generation, version, &[]),
            Err(ParseError::InvalidOutput)
        ));
    }

    #[test]
    fn debris_is_dropped_and_the_block_count_fails_closed() {
        let (paper_id, generation, version) = scope();
        let with_debris = pages(vec![vec![
            prose("....."),
            prose("A real paragraph of prose that stays in the document."),
            prose("— 12 —"),
        ]]);
        let (segments, _) = segments_from_pages(&with_debris).unwrap();
        assert_eq!(
            segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<Vec<_>>(),
            [
                "A real paragraph of prose that stays in the document.",
                "— 12 —"
            ],
            "only blocks without any letter or digit are debris"
        );

        let too_many = pages(vec![
            (0..=VISION_MAX_SEGMENTS)
                .map(|index| prose(&format!("paragraph {index}")))
                .collect(),
        ]);
        assert!(matches!(
            assemble_transcribed_document(paper_id, generation, version, &too_many),
            Err(ParseError::InvalidInput(_))
        ));
    }

    #[test]
    fn a_heading_that_repeats_a_sibling_is_kept_as_a_paragraph_not_a_failure() {
        let (paper_id, generation, version) = scope();
        let recovered = assemble_transcribed_document(
            paper_id,
            generation,
            version,
            &pages(vec![
                vec![
                    heading(1, "1 Introduction"),
                    prose("We study robust reading of scientific papers on small screens, and explain why structure matters."),
                    heading(1, "Discussion"),
                    prose("The first discussion paragraph is a real paragraph of prose."),
                ],
                vec![
                    // A running header that the model mistook for a heading.
                    heading(1, "discussion"),
                    prose("The second discussion paragraph continues after the page break."),
                    heading(2, "Discussion"),
                    prose("Under a different parent the same words are a legitimate subsection."),
                ],
            ]),
        )
        .expect("repeated headings must not fail the whole document");
        let paper = &recovered.paper;
        assert_eq!(
            paper
                .sections
                .iter()
                .map(|section| section.heading.as_deref().unwrap())
                .collect::<Vec<_>>(),
            ["1 Introduction", "Discussion", "Discussion"],
            "the repeated sibling became text; the nested one is a real section"
        );
        assert_eq!(paper.sections[1].paragraphs.len(), 3);
        assert_eq!(paper.sections[1].paragraphs[1].text, "discussion");
        assert_eq!(
            paper.sections[2].parent_source_id.as_deref(),
            Some(paper.sections[1].source_id.as_str())
        );
    }

    #[test]
    fn the_scope_is_validated_for_transcriptions_too() {
        assert!(assemble_transcribed_document(Uuid::nil(), 1, 1, &scanned_paper()).is_err());
        assert!(assemble_transcribed_document(Uuid::now_v7(), 0, 1, &scanned_paper()).is_err());
    }
}
