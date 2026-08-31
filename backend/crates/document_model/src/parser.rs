use std::{
    collections::{HashMap, HashSet},
    sync::OnceLock,
};

use domain::{
    ParsedCitationContext, ParsedCitationMarker, ParsedPaper, ParsedParagraph, ParsedReference,
    ParsedSection, SectionKind,
};
use quick_xml::{
    Reader, XmlVersion,
    events::{BytesStart, Event},
};
use regex::Regex;

use crate::{DocumentError, normalize_text};

#[derive(Debug, Clone, Copy)]
pub struct ParseLimits {
    pub maximum_bytes: usize,
    pub maximum_depth: usize,
    pub maximum_nodes: usize,
}

impl Default for ParseLimits {
    fn default() -> Self {
        Self {
            maximum_bytes: 64 * 1024 * 1024,
            maximum_depth: 256,
            maximum_nodes: 500_000,
        }
    }
}

#[derive(Debug, Clone)]
enum XmlContent {
    Text(String),
    Element(XmlElement),
}

#[derive(Debug, Clone)]
struct XmlElement {
    name: String,
    attributes: HashMap<String, String>,
    children: Vec<XmlContent>,
}

impl XmlElement {
    fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes.get(name).map(String::as_str)
    }

    fn direct_elements(&self) -> impl Iterator<Item = &Self> {
        self.children.iter().filter_map(|child| match child {
            XmlContent::Element(element) => Some(element),
            XmlContent::Text(_) => None,
        })
    }

    fn direct_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Self> {
        self.direct_elements()
            .filter(move |element| element.name == name)
    }
}

#[derive(Debug)]
struct InlineText {
    text: String,
    citations: Vec<CitationMarker>,
    object_references: Vec<ObjectReferenceMarker>,
}

#[derive(Debug)]
struct CitationMarker {
    targets: Vec<String>,
    marker: String,
    start_sentinel: Option<char>,
    end_sentinel: Option<char>,
}

#[derive(Debug)]
struct ObjectReferenceMarker {
    kind: ParsedTeiObjectKind,
    targets: Vec<String>,
    marker: String,
    start_sentinel: Option<char>,
    end_sentinel: Option<char>,
}

#[derive(Debug)]
struct NormalizedObjectReferenceMarker {
    kind: ParsedTeiObjectKind,
    targets: Vec<String>,
    marker: String,
    start: usize,
    end: usize,
}

#[derive(Debug, Clone, Copy)]
enum MarkerOwner {
    Citation(usize),
    Object(usize),
}

/// Parser-neutral visual-object metadata extracted from one TEI document.
///
/// Image bytes are deliberately absent. GROBID's TEI can identify a figure
/// and its caption, but that does not prove that a trustworthy, correctly
/// associated derivative exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiFigure {
    pub source_id: String,
    pub label: String,
    pub caption: String,
    pub caption_available: bool,
    pub page_number: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiTableCell {
    pub text: String,
    pub header: bool,
    pub row_span: u16,
    pub column_span: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiTable {
    pub source_id: String,
    pub label: String,
    pub caption: String,
    pub caption_available: bool,
    pub rows: Vec<Vec<ParsedTeiTableCell>>,
    pub plain_text: String,
    pub structure_complete: bool,
    pub page_number: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiEquation {
    pub source_id: String,
    pub label: Option<String>,
    pub latex: Option<String>,
    pub mathml: Option<String>,
    pub plain_text: Option<String>,
    pub page_number: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParsedTeiObjectKind {
    Figure,
    Table,
    Equation,
}

/// Exact reference location retained so normalization can link the paragraph
/// block to the generation-scoped visual-object UUID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiObjectReference {
    pub kind: ParsedTeiObjectKind,
    pub target_source_id: String,
    pub section_source_id: String,
    pub paragraph_ordinal: usize,
    pub start: usize,
    pub end: usize,
    pub marker: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedTeiDocument {
    pub paper: ParsedPaper,
    pub figures: Vec<ParsedTeiFigure>,
    pub tables: Vec<ParsedTeiTable>,
    pub equations: Vec<ParsedTeiEquation>,
    pub object_references: Vec<ParsedTeiObjectReference>,
}

pub fn parse_tei(xml: &str) -> Result<ParsedPaper, DocumentError> {
    parse_tei_with_limits(xml, ParseLimits::default())
}

pub fn parse_tei_with_limits(xml: &str, limits: ParseLimits) -> Result<ParsedPaper, DocumentError> {
    parse_tei_document_with_limits(xml, limits).map(|document| document.paper)
}

pub fn parse_tei_document(xml: &str) -> Result<ParsedTeiDocument, DocumentError> {
    parse_tei_document_with_limits(xml, ParseLimits::default())
}

pub fn parse_tei_document_with_limits(
    xml: &str,
    limits: ParseLimits,
) -> Result<ParsedTeiDocument, DocumentError> {
    if xml.trim().is_empty() {
        return Err(DocumentError::EmptyDocument);
    }
    if xml.len() > limits.maximum_bytes {
        return Err(DocumentError::DocumentTooLarge {
            maximum_bytes: limits.maximum_bytes,
        });
    }
    let root = build_tree(xml, limits)?;
    let title = document_title(&root);
    let body = find_descendant(&root, "body").ok_or(DocumentError::MissingBody)?;
    let references = extract_references(&root);
    let reference_ordinals = references
        .iter()
        .map(|reference| (reference.source_id.clone(), reference.ordinal))
        .collect::<HashMap<_, _>>();
    let reference_ids = references
        .iter()
        .map(|reference| reference.source_id.as_str())
        .collect::<HashSet<_>>();
    let mut sections = Vec::new();
    let mut contexts = Vec::new();
    let mut object_references = Vec::new();
    let mut occurrences = HashMap::new();

    let body_paragraphs = collect_paragraphs_excluding_divs(body);
    if !body_paragraphs.is_empty() {
        push_section(
            body,
            "body-root".into(),
            None,
            Some(SectionKind::Other),
            None,
            body_paragraphs,
            &mut sections,
            &mut contexts,
            &mut object_references,
            &mut occurrences,
            &reference_ordinals,
        );
    }
    walk_divisions(
        body,
        None,
        &mut sections,
        &mut contexts,
        &mut object_references,
        &mut occurrences,
        &reference_ordinals,
    );
    contexts.retain(|context| reference_ids.contains(context.reference_source_id.as_str()));

    let (figures, tables) = extract_figures_and_tables(body);
    let equations = extract_equations(body);
    Ok(ParsedTeiDocument {
        paper: ParsedPaper {
            title,
            sections,
            references,
            citation_contexts: contexts,
        },
        figures,
        tables,
        equations,
        object_references,
    })
}

fn build_tree(xml: &str, limits: ParseLimits) -> Result<XmlElement, DocumentError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut stack = vec![XmlElement {
        name: "__document__".into(),
        attributes: HashMap::new(),
        children: Vec::new(),
    }];
    let mut node_count = 0usize;

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                node_count += 1;
                if node_count > limits.maximum_nodes {
                    return Err(DocumentError::TooManyNodes {
                        maximum_nodes: limits.maximum_nodes,
                    });
                }
                if stack.len() >= limits.maximum_depth {
                    return Err(DocumentError::TooDeep {
                        maximum_depth: limits.maximum_depth,
                    });
                }
                stack.push(xml_element(&reader, &element)?);
            }
            Ok(Event::Empty(element)) => {
                node_count += 1;
                if node_count > limits.maximum_nodes {
                    return Err(DocumentError::TooManyNodes {
                        maximum_nodes: limits.maximum_nodes,
                    });
                }
                let element = xml_element(&reader, &element)?;
                stack
                    .last_mut()
                    .expect("document root remains on stack")
                    .children
                    .push(XmlContent::Element(element));
            }
            Ok(Event::Text(text)) => {
                let decoded = text
                    .decode()
                    .map_err(|error| DocumentError::InvalidXml(error.to_string()))?;
                let unescaped = quick_xml::escape::unescape(&decoded)
                    .map_err(|error| DocumentError::InvalidXml(error.to_string()))?;
                if !unescaped.is_empty() {
                    stack
                        .last_mut()
                        .expect("document root remains on stack")
                        .children
                        .push(XmlContent::Text(unescaped.into_owned()));
                }
            }
            Ok(Event::CData(text)) => {
                let decoded = text
                    .decode()
                    .map_err(|error| DocumentError::InvalidXml(error.to_string()))?;
                stack
                    .last_mut()
                    .expect("document root remains on stack")
                    .children
                    .push(XmlContent::Text(decoded.into_owned()));
            }
            Ok(Event::GeneralRef(reference)) => {
                let name = reference
                    .decode()
                    .map_err(|error| DocumentError::InvalidXml(error.to_string()))?;
                stack
                    .last_mut()
                    .expect("document root remains on stack")
                    .children
                    .push(XmlContent::Text(decode_entity_reference(&name)?));
            }
            Ok(Event::End(_)) => {
                if stack.len() <= 1 {
                    return Err(DocumentError::InvalidXml(
                        "unexpected closing element".into(),
                    ));
                }
                let completed = stack.pop().expect("checked stack length");
                stack
                    .last_mut()
                    .expect("document root remains on stack")
                    .children
                    .push(XmlContent::Element(completed));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {
                // External/entity declarations are not interpreted. quick-xml
                // only unescapes XML built-ins in the text branch above.
            }
            Err(error) => return Err(DocumentError::InvalidXml(error.to_string())),
        }
    }
    if stack.len() != 1 {
        return Err(DocumentError::InvalidXml(
            "unclosed element at end of document".into(),
        ));
    }
    Ok(stack.pop().expect("document root exists"))
}

fn xml_element(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
) -> Result<XmlElement, DocumentError> {
    let name = String::from_utf8_lossy(element.local_name().as_ref()).into_owned();
    let mut attributes = HashMap::new();
    for result in element.attributes().with_checks(false) {
        let attribute = result.map_err(|error| DocumentError::InvalidXml(error.to_string()))?;
        let key = String::from_utf8_lossy(attribute.key.local_name().as_ref()).into_owned();
        let value = attribute
            .decoded_and_normalized_value(XmlVersion::Implicit1_0, reader.decoder())
            .map_err(|error| DocumentError::InvalidXml(error.to_string()))?
            .into_owned();
        attributes.insert(key, value);
    }
    Ok(XmlElement {
        name,
        attributes,
        children: Vec::new(),
    })
}

fn decode_entity_reference(name: &str) -> Result<String, DocumentError> {
    let value = match name {
        "amp" => "&".into(),
        "lt" => "<".into(),
        "gt" => ">".into(),
        "apos" => "'".into(),
        "quot" => "\"".into(),
        value if value.starts_with("#x") => u32::from_str_radix(&value[2..], 16)
            .ok()
            .and_then(char::from_u32)
            .map(|character| character.to_string())
            .ok_or_else(|| DocumentError::InvalidXml("invalid numeric entity".into()))?,
        value if value.starts_with('#') => value[1..]
            .parse::<u32>()
            .ok()
            .and_then(char::from_u32)
            .map(|character| character.to_string())
            .ok_or_else(|| DocumentError::InvalidXml("invalid numeric entity".into()))?,
        _ => {
            return Err(DocumentError::InvalidXml(
                "custom XML entities are not supported".into(),
            ));
        }
    };
    Ok(value)
}

fn document_title(root: &XmlElement) -> Option<String> {
    fn walk(node: &XmlElement, inside_title_statement: bool) -> Option<String> {
        let inside_title_statement = inside_title_statement || node.name == "titleStmt";
        if inside_title_statement && node.name == "title" {
            let text = element_text(node);
            if !text.is_empty() {
                return Some(text);
            }
        }
        node.direct_elements()
            .find_map(|child| walk(child, inside_title_statement))
    }
    walk(root, false)
}

fn walk_divisions(
    node: &XmlElement,
    parent_source_id: Option<&str>,
    sections: &mut Vec<ParsedSection>,
    contexts: &mut Vec<ParsedCitationContext>,
    object_references: &mut Vec<ParsedTeiObjectReference>,
    occurrences: &mut HashMap<String, usize>,
    reference_ordinals: &HashMap<String, usize>,
) {
    for child in node.direct_elements() {
        if child.name == "div" {
            let ordinal = sections.len();
            let source_id = child
                .attribute("id")
                .map_or_else(|| format!("section-{ordinal}"), str::to_owned);
            let heading = child
                .direct_named("head")
                .next()
                .map(element_text)
                .filter(|value| !value.is_empty());
            let kind = classify_section(heading.as_deref(), child.attribute("type"));
            let paragraphs = collect_paragraphs_excluding_divs(child);
            push_section(
                child,
                source_id.clone(),
                parent_source_id.map(str::to_owned),
                Some(kind),
                heading,
                paragraphs,
                sections,
                contexts,
                object_references,
                occurrences,
                reference_ordinals,
            );
            walk_divisions(
                child,
                Some(&source_id),
                sections,
                contexts,
                object_references,
                occurrences,
                reference_ordinals,
            );
        } else {
            walk_divisions(
                child,
                parent_source_id,
                sections,
                contexts,
                object_references,
                occurrences,
                reference_ordinals,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn push_section(
    _node: &XmlElement,
    source_id: String,
    parent_source_id: Option<String>,
    explicit_kind: Option<SectionKind>,
    heading: Option<String>,
    paragraph_nodes: Vec<&XmlElement>,
    sections: &mut Vec<ParsedSection>,
    contexts: &mut Vec<ParsedCitationContext>,
    object_references: &mut Vec<ParsedTeiObjectReference>,
    occurrences: &mut HashMap<String, usize>,
    reference_ordinals: &HashMap<String, usize>,
) {
    let ordinal = sections.len();
    let kind = explicit_kind.unwrap_or_else(|| classify_section(heading.as_deref(), None));
    let mut paragraphs = Vec::new();
    for node in paragraph_nodes {
        let inline = inline_text(node);
        let (text, citations, normalized_object_references) =
            normalize_inline_text(&inline, reference_ordinals);
        if text.is_empty() || looks_like_running_artifact(&text) {
            continue;
        }
        let (page_start, page_end) = page_range(node);
        let paragraph_ordinal = paragraphs.len();
        for citation in inline.citations {
            for target in citation.targets {
                let occurrence = occurrences.entry(target.clone()).or_default();
                contexts.push(ParsedCitationContext {
                    reference_source_id: target,
                    section_source_id: source_id.clone(),
                    section_kind: kind,
                    section_heading: heading.clone(),
                    context_text: sentence_window(&text, &citation.marker),
                    page_number: page_start,
                    occurrence_ordinal: *occurrence,
                });
                *occurrence += 1;
            }
        }
        for reference in normalized_object_references {
            for target_source_id in reference.targets {
                object_references.push(ParsedTeiObjectReference {
                    kind: reference.kind,
                    target_source_id,
                    section_source_id: source_id.clone(),
                    paragraph_ordinal,
                    start: reference.start,
                    end: reference.end,
                    marker: reference.marker.clone(),
                });
            }
        }
        paragraphs.push(ParsedParagraph {
            ordinal: paragraph_ordinal,
            text,
            citations,
            page_start,
            page_end,
        });
    }
    let page_start = paragraphs.iter().filter_map(|p| p.page_start).min();
    let page_end = paragraphs.iter().filter_map(|p| p.page_end).max();
    // Preserve even heading-only divisions so hierarchy and introduction
    // descendants remain well defined.
    sections.push(ParsedSection {
        source_id,
        ordinal,
        parent_source_id,
        kind,
        heading,
        paragraphs,
        page_start,
        page_end,
    });
}

fn collect_paragraphs_excluding_divs(node: &XmlElement) -> Vec<&XmlElement> {
    fn walk<'a>(node: &'a XmlElement, root: bool, output: &mut Vec<&'a XmlElement>) {
        for child in node.direct_elements() {
            if child.name == "div" && !root {
                continue;
            }
            if child.name == "div" {
                continue;
            }
            if child.name == "p" {
                output.push(child);
            } else if !matches!(
                child.name.as_str(),
                "listBibl" | "biblStruct" | "figure" | "table"
            ) {
                walk(child, false, output);
            }
        }
    }
    let mut output = Vec::new();
    walk(node, true, &mut output);
    output
}

fn inline_text(node: &XmlElement) -> InlineText {
    fn walk(
        node: &XmlElement,
        text: &mut String,
        citations: &mut Vec<CitationMarker>,
        object_references: &mut Vec<ObjectReferenceMarker>,
    ) {
        if node.name == "ref" {
            let marker = element_text(node);
            if let Some(targets) = node.attribute("target") {
                let targets = targets
                    .split_whitespace()
                    .map(|target| target.trim_start_matches('#').to_owned())
                    .filter(|target| !target.is_empty())
                    .collect::<Vec<_>>();
                if !targets.is_empty() {
                    let marker_index = citations.len().saturating_add(object_references.len());
                    let (start_sentinel, end_sentinel) = citation_sentinels(marker_index)
                        .map_or((None, None), |(start, end)| (Some(start), Some(end)));
                    let annotated_marker = match (start_sentinel, end_sentinel) {
                        (Some(start), Some(end)) => format!("{start}{marker}{end}"),
                        _ => marker.clone(),
                    };
                    if node
                        .attribute("type")
                        .is_some_and(|kind| kind.eq_ignore_ascii_case("bibr"))
                    {
                        citations.push(CitationMarker {
                            targets,
                            marker: marker.clone(),
                            start_sentinel,
                            end_sentinel,
                        });
                        push_text(text, &annotated_marker);
                        return;
                    }
                    if let Some(kind) = parsed_object_reference_kind(node.attribute("type")) {
                        object_references.push(ObjectReferenceMarker {
                            kind,
                            targets,
                            marker: marker.clone(),
                            start_sentinel,
                            end_sentinel,
                        });
                        push_text(text, &annotated_marker);
                        return;
                    }
                }
            }
            push_text(text, &marker);
            return;
        }
        for child in &node.children {
            match child {
                XmlContent::Text(value) => push_text(text, value),
                XmlContent::Element(element) => {
                    walk(element, text, citations, object_references);
                }
            }
        }
    }
    let mut text = String::new();
    let mut citations = Vec::new();
    let mut object_references = Vec::new();
    walk(node, &mut text, &mut citations, &mut object_references);
    InlineText {
        text,
        citations,
        object_references,
    }
}

fn parsed_object_reference_kind(value: Option<&str>) -> Option<ParsedTeiObjectKind> {
    let value = value?.to_ascii_lowercase();
    if matches!(value.as_str(), "figure" | "fig") {
        Some(ParsedTeiObjectKind::Figure)
    } else if matches!(value.as_str(), "table" | "tab") {
        Some(ParsedTeiObjectKind::Table)
    } else if matches!(value.as_str(), "formula" | "equation" | "eq") {
        Some(ParsedTeiObjectKind::Equation)
    } else {
        None
    }
}

fn citation_sentinels(index: usize) -> Option<(char, char)> {
    const PRIVATE_USE_BASE: u32 = 0xF_0000;
    let offset = u32::try_from(index)
        .ok()
        .and_then(|value| value.checked_mul(2))
        .and_then(|value| PRIVATE_USE_BASE.checked_add(value))?;
    Some((char::from_u32(offset)?, char::from_u32(offset + 1)?))
}

fn normalize_inline_text(
    inline: &InlineText,
    reference_ordinals: &HashMap<String, usize>,
) -> (
    String,
    Vec<ParsedCitationMarker>,
    Vec<NormalizedObjectReferenceMarker>,
) {
    let normalized = normalize_text(&inline.text);
    let mut sentinels = HashMap::new();
    for (index, citation) in inline.citations.iter().enumerate() {
        if let Some(sentinel) = citation.start_sentinel {
            sentinels.insert(sentinel, (MarkerOwner::Citation(index), false));
        }
        if let Some(sentinel) = citation.end_sentinel {
            sentinels.insert(sentinel, (MarkerOwner::Citation(index), true));
        }
    }
    for (index, reference) in inline.object_references.iter().enumerate() {
        if let Some(sentinel) = reference.start_sentinel {
            sentinels.insert(sentinel, (MarkerOwner::Object(index), false));
        }
        if let Some(sentinel) = reference.end_sentinel {
            sentinels.insert(sentinel, (MarkerOwner::Object(index), true));
        }
    }
    let mut citation_starts = vec![None; inline.citations.len()];
    let mut citation_ends = vec![None; inline.citations.len()];
    let mut object_starts = vec![None; inline.object_references.len()];
    let mut object_ends = vec![None; inline.object_references.len()];
    let mut text = String::with_capacity(normalized.len());
    let mut scalar_offset = 0usize;
    for character in normalized.chars() {
        if let Some((owner, end)) = sentinels.get(&character).copied() {
            match (owner, end) {
                (MarkerOwner::Citation(index), false) => {
                    citation_starts[index] = Some(scalar_offset);
                }
                (MarkerOwner::Citation(index), true) => {
                    citation_ends[index] = Some(scalar_offset);
                }
                (MarkerOwner::Object(index), false) => {
                    object_starts[index] = Some(scalar_offset);
                }
                (MarkerOwner::Object(index), true) => {
                    object_ends[index] = Some(scalar_offset);
                }
            }
            continue;
        }
        text.push(character);
        scalar_offset += 1;
    }
    let citations = inline
        .citations
        .iter()
        .enumerate()
        .filter_map(|(index, citation)| {
            let start = citation_starts[index]?;
            let end = citation_ends[index]?;
            let reference_ordinals = citation
                .targets
                .iter()
                .filter_map(|target| reference_ordinals.get(target).copied())
                .collect::<Vec<_>>();
            (!reference_ordinals.is_empty()).then(|| ParsedCitationMarker {
                start,
                end,
                marker: citation.marker.clone(),
                reference_ordinals,
            })
        })
        .collect();
    let object_references = inline
        .object_references
        .iter()
        .enumerate()
        .filter_map(|(index, reference)| {
            Some(NormalizedObjectReferenceMarker {
                kind: reference.kind,
                targets: reference.targets.clone(),
                marker: reference.marker.clone(),
                start: object_starts[index]?,
                end: object_ends[index]?,
            })
        })
        .collect();
    (text, citations, object_references)
}

fn element_text(node: &XmlElement) -> String {
    fn walk(node: &XmlElement, output: &mut String) {
        for child in &node.children {
            match child {
                XmlContent::Text(text) => push_text(output, text),
                XmlContent::Element(element) => walk(element, output),
            }
        }
    }
    let mut output = String::new();
    walk(node, &mut output);
    normalize_text(&output)
}

fn push_text(output: &mut String, value: &str) {
    if !output.is_empty()
        && !output.ends_with(char::is_whitespace)
        && !value.starts_with(char::is_whitespace)
    {
        output.push(' ');
    }
    output.push_str(value);
}

fn page_range(node: &XmlElement) -> (Option<u32>, Option<u32>) {
    fn walk(node: &XmlElement, pages: &mut Vec<u32>) {
        if let Some(coordinates) = node.attribute("coords") {
            for group in coordinates.split(';') {
                if let Some(page) = group.split(',').next().and_then(|value| value.parse().ok()) {
                    pages.push(page);
                }
            }
        }
        if node.name == "pb"
            && let Some(page) = node.attribute("n").and_then(|value| value.parse().ok())
        {
            pages.push(page);
        }
        for child in node.direct_elements() {
            walk(child, pages);
        }
    }
    let mut pages = Vec::new();
    walk(node, &mut pages);
    (pages.iter().copied().min(), pages.iter().copied().max())
}

fn extract_figures_and_tables(body: &XmlElement) -> (Vec<ParsedTeiFigure>, Vec<ParsedTeiTable>) {
    let mut nodes = Vec::new();
    collect_named(body, &["figure"], &mut nodes);
    let mut figures = Vec::new();
    let mut tables = Vec::new();
    let mut source_ids = HashSet::new();
    for node in nodes {
        let table_node = find_descendant(node, "table");
        let is_table = table_node.is_some()
            || node
                .attribute("type")
                .is_some_and(|value| value.eq_ignore_ascii_case("table"));
        if is_table {
            let ordinal = tables.len();
            if let Some(table) = extract_table(node, table_node, ordinal, &mut source_ids) {
                tables.push(table);
            }
        } else {
            let ordinal = figures.len();
            figures.push(extract_figure(node, ordinal, &mut source_ids));
        }
    }
    (figures, tables)
}

fn extract_figure(
    node: &XmlElement,
    ordinal: usize,
    source_ids: &mut HashSet<String>,
) -> ParsedTeiFigure {
    let source_id = visual_source_id(node, "figure", ordinal, source_ids);
    let label = visual_label(node, "Figure", ordinal);
    let caption = visual_caption(node);
    let caption_available = caption.is_some();
    ParsedTeiFigure {
        source_id,
        label: label.clone(),
        caption: caption.unwrap_or(label),
        caption_available,
        page_number: page_range(node).0,
    }
}

fn extract_table(
    figure_node: &XmlElement,
    table_node: Option<&XmlElement>,
    ordinal: usize,
    source_ids: &mut HashSet<String>,
) -> Option<ParsedTeiTable> {
    let table_node = table_node.unwrap_or(figure_node);
    let source_id = visual_source_id(figure_node, "table", ordinal, source_ids);
    let label = visual_label(figure_node, "Table", ordinal);
    let caption = visual_caption(figure_node);
    let caption_available = caption.is_some();
    let mut structure_complete = true;
    let mut rows = Vec::new();
    for row in descendants_named(table_node, "row") {
        let mut cells = Vec::new();
        for cell in row.direct_named("cell") {
            let (row_span, row_span_valid) = table_span(cell, &["rows", "rowspan"]);
            let (column_span, column_span_valid) = table_span(cell, &["cols", "colspan"]);
            structure_complete &= row_span_valid && column_span_valid;
            cells.push(ParsedTeiTableCell {
                text: element_text(cell),
                header: table_cell_is_header(cell),
                row_span,
                column_span,
            });
        }
        if cells.is_empty() {
            structure_complete = false;
        } else {
            rows.push(cells);
        }
    }
    let mut plain_text = rows
        .iter()
        .map(|row| {
            row.iter()
                .map(|cell| cell.text.as_str())
                .collect::<Vec<_>>()
                .join("\t")
        })
        .collect::<Vec<_>>()
        .join("\n");
    if plain_text.is_empty() {
        plain_text = element_text(table_node);
        structure_complete = false;
    }
    for note in figure_node.direct_named("note") {
        let note = element_text(note);
        if !note.is_empty() {
            if !plain_text.is_empty() {
                plain_text.push('\n');
            }
            plain_text.push_str(&note);
        }
    }
    if plain_text.is_empty() {
        return None;
    }
    Some(ParsedTeiTable {
        source_id,
        label: label.clone(),
        caption: caption.unwrap_or(label),
        caption_available,
        rows,
        plain_text,
        structure_complete,
        page_number: page_range(figure_node).0,
    })
}

fn extract_equations(body: &XmlElement) -> Vec<ParsedTeiEquation> {
    let mut nodes = Vec::new();
    collect_named(body, &["formula"], &mut nodes);
    let mut equations = Vec::new();
    let mut source_ids = HashSet::new();
    for node in nodes {
        let ordinal = equations.len();
        let label = node
            .direct_named("label")
            .next()
            .map(element_text)
            .filter(|value| valid_optional_label(value, 128));
        let math = find_descendant(node, "math");
        let mathml = math.and_then(sanitized_mathml);
        let latex = math.and_then(extract_latex_annotation).or_else(|| {
            node.attribute("notation")
                .filter(|value| {
                    value.eq_ignore_ascii_case("tex") || value.eq_ignore_ascii_case("latex")
                })
                .map(|_| element_text_excluding(node, &["label"]))
                .filter(|value| !value.is_empty())
        });
        let plain_text = math
            .map(element_text)
            .filter(|value| !value.is_empty())
            .or_else(|| {
                let text = element_text_excluding(node, &["label"]);
                (!text.is_empty()).then_some(text)
            });
        if latex.is_none() && mathml.is_none() && plain_text.is_none() {
            continue;
        }
        equations.push(ParsedTeiEquation {
            source_id: visual_source_id(node, "equation", ordinal, &mut source_ids),
            label,
            latex,
            mathml,
            plain_text,
            page_number: page_range(node).0,
        });
    }
    equations
}

fn visual_source_id(
    node: &XmlElement,
    prefix: &str,
    ordinal: usize,
    source_ids: &mut HashSet<String>,
) -> String {
    let candidate = node
        .attribute("id")
        .map(normalize_text)
        .filter(|value| {
            valid_optional_label(value, 200)
                && !value.contains(['/', '\\'])
                && !value.contains("..")
        })
        .unwrap_or_else(|| format!("{prefix}-{ordinal}"));
    if source_ids.insert(candidate.clone()) {
        candidate
    } else {
        let fallback = format!("{prefix}-{ordinal}");
        source_ids.insert(fallback.clone());
        fallback
    }
}

fn visual_label(node: &XmlElement, kind: &str, ordinal: usize) -> String {
    node.direct_named("label")
        .next()
        .map(element_text)
        .filter(|value| valid_optional_label(value, 128))
        .unwrap_or_else(|| format!("{kind} {}", ordinal.saturating_add(1)))
}

fn visual_caption(node: &XmlElement) -> Option<String> {
    node.direct_named("figDesc")
        .chain(node.direct_named("head"))
        .map(element_text)
        .find(|value| !value.is_empty())
}

fn table_span(node: &XmlElement, names: &[&str]) -> (u16, bool) {
    let Some(value) = names.iter().find_map(|name| node.attribute(name)) else {
        return (1, true);
    };
    value
        .parse::<u16>()
        .ok()
        .filter(|value| (1..=1_000).contains(value))
        .map_or((1, false), |value| (value, true))
}

fn table_cell_is_header(node: &XmlElement) -> bool {
    ["role", "type", "rend"]
        .iter()
        .filter_map(|name| node.attribute(name))
        .any(|value| value.to_ascii_lowercase().contains("head"))
}

fn valid_optional_label(value: &str, maximum: usize) -> bool {
    let count = value.chars().count();
    count > 0 && count <= maximum && !value.contains('\0') && value == value.trim()
}

fn element_text_excluding(node: &XmlElement, excluded: &[&str]) -> String {
    fn walk(node: &XmlElement, excluded: &[&str], output: &mut String) {
        for child in &node.children {
            match child {
                XmlContent::Text(text) => push_text(output, text),
                XmlContent::Element(element) if !excluded.contains(&element.name.as_str()) => {
                    walk(element, excluded, output);
                }
                XmlContent::Element(_) => {}
            }
        }
    }
    let mut output = String::new();
    walk(node, excluded, &mut output);
    normalize_text(&output)
}

fn extract_latex_annotation(math: &XmlElement) -> Option<String> {
    descendants_named(math, "annotation")
        .into_iter()
        .find(|annotation| {
            annotation.attribute("encoding").is_some_and(|encoding| {
                matches!(
                    encoding.to_ascii_lowercase().as_str(),
                    "application/x-tex" | "application/x-latex" | "tex" | "latex"
                )
            })
        })
        .map(element_text)
        .filter(|value| !value.is_empty())
}

fn sanitized_mathml(math: &XmlElement) -> Option<String> {
    const ALLOWED_ELEMENTS: &[&str] = &[
        "annotation",
        "math",
        "merror",
        "mfenced",
        "mfrac",
        "mi",
        "mmultiscripts",
        "mn",
        "mo",
        "mover",
        "mpadded",
        "mphantom",
        "mprescripts",
        "mroot",
        "mrow",
        "ms",
        "mspace",
        "msqrt",
        "mstyle",
        "msub",
        "msubsup",
        "msup",
        "mtable",
        "mtd",
        "mtext",
        "mtr",
        "munder",
        "munderover",
        "none",
        "semantics",
    ];
    const ALLOWED_ATTRIBUTES: &[&str] = &[
        "alttext",
        "columnalign",
        "columnspan",
        "display",
        "encoding",
        "fence",
        "linethickness",
        "mathvariant",
        "rowalign",
        "rowspan",
        "separator",
        "stretchy",
    ];
    fn write_node(
        node: &XmlElement,
        output: &mut String,
        elements: &[&str],
        attributes: &[&str],
    ) -> bool {
        if !elements.contains(&node.name.as_str()) {
            return false;
        }
        output.push('<');
        output.push_str(&node.name);
        let mut allowed = node
            .attributes
            .iter()
            .filter(|(name, _)| attributes.contains(&name.as_str()))
            .collect::<Vec<_>>();
        allowed.sort_by_key(|(name, _)| name.as_str());
        for (name, value) in allowed {
            output.push(' ');
            output.push_str(name);
            output.push_str("=\"");
            push_xml_escaped(output, value);
            output.push('"');
        }
        output.push('>');
        for child in &node.children {
            match child {
                XmlContent::Text(text) => push_xml_escaped(output, text),
                XmlContent::Element(element) => {
                    if !write_node(element, output, elements, attributes) {
                        return false;
                    }
                }
            }
            if output.len() > 500_000 {
                return false;
            }
        }
        output.push_str("</");
        output.push_str(&node.name);
        output.push('>');
        true
    }
    let mut output = String::new();
    write_node(math, &mut output, ALLOWED_ELEMENTS, ALLOWED_ATTRIBUTES).then_some(output)
}

fn push_xml_escaped(output: &mut String, value: &str) {
    for character in value.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&apos;"),
            value => output.push(value),
        }
    }
}

fn extract_references(root: &XmlElement) -> Vec<ParsedReference> {
    let mut bibliography_nodes = Vec::new();
    collect_named(root, &["biblStruct", "bibl"], &mut bibliography_nodes);
    bibliography_nodes
        .into_iter()
        .enumerate()
        .map(|(ordinal, node)| {
            let source_id = node
                .attribute("id")
                .map_or_else(|| format!("reference-{ordinal}"), str::to_owned);
            let raw_text = find_descendant_matching(node, "note", |candidate| {
                candidate
                    .attribute("type")
                    .is_some_and(|kind| kind.eq_ignore_ascii_case("raw_reference"))
            })
            .map(element_text)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| element_text(node));
            let title = preferred_reference_title(node);
            let authors = descendants_named(node, "author")
                .into_iter()
                .map(element_text)
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>();
            let year = descendants_named(node, "date")
                .into_iter()
                .find_map(|date| {
                    date.attribute("when")
                        .and_then(extract_year)
                        .or_else(|| extract_year(&element_text(date)))
                })
                .or_else(|| extract_year(&raw_text));
            let doi = descendants_named(node, "idno")
                .into_iter()
                .find(|id| {
                    id.attribute("type")
                        .is_some_and(|kind| kind.eq_ignore_ascii_case("doi"))
                })
                .map(element_text)
                .filter(|value| !value.is_empty());
            let url = descendants_named(node, "ptr")
                .into_iter()
                .find_map(|pointer| pointer.attribute("target").map(str::to_owned))
                .or_else(|| {
                    descendants_named(node, "ref")
                        .into_iter()
                        .find_map(|reference| {
                            reference
                                .attribute("target")
                                .filter(|target| target.starts_with("http"))
                                .map(str::to_owned)
                        })
                });
            let arxiv_id = url
                .as_deref()
                .and_then(extract_arxiv_identifier)
                .or_else(|| extract_arxiv_identifier(&raw_text));
            ParsedReference {
                source_id,
                ordinal,
                raw_text,
                title,
                authors,
                year,
                doi,
                url,
                arxiv_id,
            }
        })
        .collect()
}

fn preferred_reference_title(node: &XmlElement) -> Option<String> {
    let titles = descendants_named(node, "title");
    titles
        .iter()
        .find(|title| title.attribute("level").is_some_and(|level| level == "a"))
        .or_else(|| titles.first())
        .map(|title| element_text(title))
        .filter(|value| !value.is_empty())
}

fn collect_named<'a>(node: &'a XmlElement, names: &[&str], output: &mut Vec<&'a XmlElement>) {
    if names.contains(&node.name.as_str()) {
        output.push(node);
    }
    for child in node.direct_elements() {
        collect_named(child, names, output);
    }
}

fn descendants_named<'a>(node: &'a XmlElement, name: &str) -> Vec<&'a XmlElement> {
    let mut output = Vec::new();
    collect_named(node, &[name], &mut output);
    output
}

fn find_descendant<'a>(node: &'a XmlElement, name: &str) -> Option<&'a XmlElement> {
    if node.name == name {
        return Some(node);
    }
    node.direct_elements()
        .find_map(|child| find_descendant(child, name))
}

fn find_descendant_matching<'a, F>(
    node: &'a XmlElement,
    name: &str,
    predicate: F,
) -> Option<&'a XmlElement>
where
    F: Copy + Fn(&XmlElement) -> bool,
{
    if node.name == name && predicate(node) {
        return Some(node);
    }
    node.direct_elements()
        .find_map(|child| find_descendant_matching(child, name, predicate))
}

fn extract_year(input: &str) -> Option<i32> {
    year_regex()
        .find(input)
        .and_then(|value| value.as_str().parse().ok())
}

fn extract_arxiv_identifier(input: &str) -> Option<String> {
    arxiv_regex()
        .captures(input)
        .and_then(|captures| captures.name("id"))
        .map(|value| value.as_str().trim_end_matches(".pdf").to_owned())
}

fn sentence_window(text: &str, marker: &str) -> String {
    let marker_range = (!marker.is_empty())
        .then(|| text.find(marker))
        .flatten()
        .map(|position| {
            (
                position,
                position.saturating_add(marker.len()).min(text.len()),
            )
        });
    let (position, marker_end) = marker_range.unwrap_or((0, 0));
    let start = text[..position]
        .rfind(['.', '?', '!'])
        .map_or(0, |index| index + 1);
    // Citation labels frequently contain abbreviations such as "et al.".
    // Searching from the marker start mistakes that internal period for the
    // sentence boundary and discards the relationship-bearing clause.
    let tail = &text[marker_end..];
    let end = tail
        .find(['.', '?', '!'])
        .map_or(text.len(), |index| marker_end + index + 1);
    let sentence = text[start..end].trim();
    if sentence.chars().count() <= 600 {
        sentence.to_owned()
    } else {
        sentence.chars().take(600).collect()
    }
}

fn looks_like_running_artifact(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.len() <= 4 && trimmed.chars().all(|character| character.is_ascii_digit())
}

pub fn classify_section(heading: Option<&str>, type_hint: Option<&str>) -> SectionKind {
    let raw_heading = heading.unwrap_or_default().trim();
    let combined =
        format!("{} {}", type_hint.unwrap_or_default(), raw_heading).to_ascii_lowercase();
    let normalized = heading_prefix_regex().replace(&combined, "");
    let normalized = normalized.trim();
    if normalized.contains("introduction") {
        SectionKind::Introduction
    } else if normalized.contains("related work") || normalized.contains("prior work") {
        SectionKind::RelatedWork
    } else if normalized.contains("background") || normalized.contains("preliminar") {
        SectionKind::Background
    } else if normalized.contains("limitation") {
        SectionKind::Limitation
    } else if normalized.contains("discussion") {
        SectionKind::Discussion
    } else if normalized.contains("conclusion") {
        SectionKind::Conclusion
    } else if normalized.contains("result")
        || normalized.contains("finding")
        || normalized.starts_with("effect of ")
    {
        SectionKind::Result
    } else if normalized.contains("experiment")
        || normalized.contains("evaluation")
        || normalized.contains("ablation")
        || normalized.contains("benchmark")
        || normalized.contains("dataset")
        || matches!(
            normalized,
            "glue" | "squad" | "squad v1.1" | "squad v2.0" | "swag"
        )
    {
        SectionKind::Experiment
    } else if normalized.contains("method")
        || normalized.contains("approach")
        || normalized.contains("architecture")
        || normalized.contains("model")
        || normalized.contains("pre-training")
        || normalized.contains("pretraining")
        || normalized.contains("fine-tuning")
        || normalized.contains("finetuning")
        || normalized.contains("training procedure")
        || normalized.contains("implementation")
        || normalized.contains("objective")
        || normalized.contains("masked language model")
        || normalized.contains("masking")
        || normalized.contains("next sentence prediction")
        || normalized.contains("input and output format")
        || normalized == "training"
        || normalized.starts_with("training with ")
        || normalized.contains("corpus")
        || normalized.starts_with("retriever")
        || looks_like_model_acronym(raw_heading)
    {
        SectionKind::Method
    } else if normalized.contains("appendix") || normalized.starts_with("supplement") {
        SectionKind::Appendix
    } else if normalized.contains("acknowledg") {
        SectionKind::Acknowledgment
    } else if normalized.contains("reference") || normalized.contains("bibliograph") {
        SectionKind::References
    } else if normalized.contains("abstract") {
        SectionKind::Abstract
    } else {
        SectionKind::Other
    }
}

fn looks_like_model_acronym(heading: &str) -> bool {
    let compact = heading
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect::<String>();
    if !(2..=16).contains(&compact.len()) {
        return false;
    }
    let letters = compact
        .chars()
        .filter(char::is_ascii_alphabetic)
        .collect::<Vec<_>>();
    if letters.is_empty() {
        return false;
    }
    let uppercase = letters
        .iter()
        .filter(|character| character.is_ascii_uppercase())
        .count();
    uppercase == letters.len()
        || (heading.split_whitespace().count() == 1
            && uppercase >= 2
            && uppercase.saturating_mul(5) >= letters.len().saturating_mul(2))
}

fn heading_prefix_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"^\s*(?:(?:\d+(?:\.\d+)*)|(?:[ivxlcdm]+))[\s.:\-]+")
            .expect("heading prefix regex is valid")
    })
}

fn year_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"\b(?:18|19|20|21)\d{2}\b").expect("year regex is valid"))
}

fn arxiv_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r"(?i)(?:arxiv:\s*|arxiv\.org/(?:abs|pdf)/)?(?P<id>(?:\d{4}\.\d{4,5}|[a-z][a-z0-9.-]*/\d{7})(?:v\d+)?)(?:\.pdf)?",
        )
        .expect("arXiv extraction regex is valid")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_sections_references_and_contexts_from_fixture() {
        let paper = parse_tei(include_str!("../fixtures/sample.tei.xml")).unwrap();
        assert_eq!(paper.title.as_deref(), Some("Fixture Paper"));
        assert_eq!(paper.sections.len(), 4);
        assert_eq!(paper.sections[0].kind, SectionKind::Introduction);
        assert_eq!(paper.sections[0].page_start, Some(1));
        assert_eq!(
            paper.sections[1].parent_source_id.as_deref(),
            Some("sec-intro")
        );
        let introduction_paragraph = &paper.sections[0].paragraphs[0];
        assert!(introduction_paragraph.text.contains("[1]"));
        let marker = &introduction_paragraph.citations[0];
        assert_eq!(marker.marker, "[1]");
        assert_eq!(marker.reference_ordinals, [0]);
        assert_eq!(
            introduction_paragraph
                .text
                .chars()
                .skip(marker.start)
                .take(marker.end - marker.start)
                .collect::<String>(),
            "[1]"
        );
        assert!(
            !introduction_paragraph
                .text
                .chars()
                .any(|character| ('\u{F0000}'..='\u{FFFFD}').contains(&character))
        );
        assert_eq!(paper.references.len(), 2);
        assert_eq!(paper.references[0].source_id, "b0");
        assert_eq!(
            paper.references[0].title.as_deref(),
            Some("Foundational Attention")
        );
        assert_eq!(paper.references[0].year, Some(2017));
        assert_eq!(
            paper.references[0].doi.as_deref(),
            Some("10.1000/foundation")
        );
        assert_eq!(
            paper.references[0].arxiv_id.as_deref(),
            Some("1706.03762v7")
        );
        assert_eq!(paper.citation_contexts.len(), 2);
        assert_eq!(paper.citation_contexts[0].reference_source_id, "b0");
        assert_eq!(
            paper.citation_contexts[0].section_kind,
            SectionKind::Introduction
        );
    }

    #[test]
    fn extracts_visual_metadata_structure_math_and_exact_object_references() {
        let xml = r##"
            <TEI xmlns="http://www.tei-c.org/ns/1.0">
              <text><body><div xml:id="methods">
                <head>Methods</head>
                <p coords="2,10,20,300,40">See
                  <ref type="figure" target="#fig_0">Figure 1</ref>,
                  <ref type="table" target="#tab_0">Table 1</ref>, and
                  <ref type="formula" target="#eq_0">Equation 1</ref>.
                </p>
                <figure xml:id="fig_0" coords="2,10,50,300,180">
                  <label>Figure 1</label>
                  <figDesc>System architecture.</figDesc>
                  <graphic type="bitmap"/>
                </figure>
                <figure xml:id="tab_0" type="table" coords="3,10,40,300,200">
                  <label>Table 1</label>
                  <figDesc>Evaluation results.</figDesc>
                  <table>
                    <row><cell role="head">Metric</cell><cell role="head">Value</cell></row>
                    <row><cell rows="2">Accuracy</cell><cell>0.95</cell></row>
                  </table>
                  <note>Higher is better.</note>
                </figure>
                <formula xml:id="eq_0" coords="4,20,30,200,40">
                  <label>(1)</label>
                  <math display="block"><semantics><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow><annotation encoding="application/x-tex">E=mc^2</annotation></semantics></math>
                </formula>
              </div></body></text>
            </TEI>
        "##;
        let document = parse_tei_document(xml).unwrap();
        assert_eq!(document.figures.len(), 1);
        assert_eq!(document.figures[0].source_id, "fig_0");
        assert_eq!(document.figures[0].caption, "System architecture.");
        assert_eq!(document.figures[0].page_number, Some(2));

        assert_eq!(document.tables.len(), 1);
        let table = &document.tables[0];
        assert_eq!(table.rows.len(), 2);
        assert!(table.rows[0][0].header);
        assert_eq!(table.rows[1][0].row_span, 2);
        assert_eq!(table.rows[1][0].column_span, 1);
        assert!(table.plain_text.contains("Metric\tValue"));
        assert!(table.plain_text.contains("Higher is better."));

        assert_eq!(document.equations.len(), 1);
        let equation = &document.equations[0];
        assert_eq!(equation.label.as_deref(), Some("(1)"));
        assert_eq!(equation.latex.as_deref(), Some("E=mc^2"));
        assert!(equation.mathml.as_deref().is_some_and(|value| {
            value.starts_with("<math display=\"block\">")
                && value.contains("<msup><mi>c</mi><mn>2</mn></msup>")
        }));
        assert!(equation.plain_text.as_deref().is_some_and(|value| {
            value.contains('E') && value.contains('=') && value.contains('2')
        }));

        assert_eq!(document.object_references.len(), 3);
        let paragraph = &document.paper.sections[0].paragraphs[0];
        for reference in &document.object_references {
            assert_eq!(reference.section_source_id, "methods");
            assert_eq!(reference.paragraph_ordinal, 0);
            assert_eq!(
                paragraph
                    .text
                    .chars()
                    .skip(reference.start)
                    .take(reference.end - reference.start)
                    .collect::<String>(),
                reference.marker
            );
        }
    }

    #[test]
    fn citation_window_ignores_periods_inside_the_marker() {
        let text = "We follow the original procedure (Devlin et al., 2019) and remove the auxiliary loss. The next sentence is unrelated.";
        assert_eq!(
            sentence_window(text, "(Devlin et al., 2019)"),
            "We follow the original procedure (Devlin et al., 2019) and remove the auxiliary loss."
        );
    }

    #[test]
    fn limits_nesting_depth() {
        let xml = "<TEI><text><body><div><div><p>x</p></div></div></body></text></TEI>";
        let error = parse_tei_with_limits(
            xml,
            ParseLimits {
                maximum_depth: 4,
                ..ParseLimits::default()
            },
        )
        .unwrap_err();
        assert!(matches!(error, DocumentError::TooDeep { .. }));
    }

    #[test]
    fn classifies_numbered_headings() {
        assert_eq!(
            classify_section(Some("I. Introduction and Motivation"), None),
            SectionKind::Introduction
        );
        assert_eq!(
            classify_section(Some("4.2 Experimental Results"), None),
            SectionKind::Result
        );
    }

    #[test]
    fn classifies_paper_specific_method_and_benchmark_headings() {
        for heading in [
            "BERT",
            "RoBERTa",
            "Pre-training BERT",
            "A.2 Pre-training Procedure",
            "Next Sentence Prediction",
            "Static vs. Dynamic Masking",
            "Training with large batches",
            "Input and Output Format",
            "The Colossal Clean Crawled Corpus",
        ] {
            assert_eq!(
                classify_section(Some(heading), None),
                SectionKind::Method,
                "{heading}"
            );
        }
        for heading in ["GLUE", "SQuAD v2.0", "Ablation Studies"] {
            assert_eq!(
                classify_section(Some(heading), None),
                SectionKind::Experiment,
                "{heading}"
            );
        }
        assert_eq!(
            classify_section(Some("Effect of Model Size"), None),
            SectionKind::Result
        );
    }

    #[test]
    fn rejects_custom_entities_in_untrusted_tei() {
        let xml = r#"<!DOCTYPE TEI [<!ENTITY injected "ignored">]>
            <TEI><text><body><div><head>Introduction</head><p>&injected;</p></div></body></text></TEI>"#;
        let error = parse_tei(xml).unwrap_err();
        assert!(matches!(error, DocumentError::InvalidXml(_)));
    }
}
