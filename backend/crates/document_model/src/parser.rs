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
}

#[derive(Debug)]
struct CitationMarker {
    targets: Vec<String>,
    marker: String,
    start_sentinel: Option<char>,
    end_sentinel: Option<char>,
}

pub fn parse_tei(xml: &str) -> Result<ParsedPaper, DocumentError> {
    parse_tei_with_limits(xml, ParseLimits::default())
}

pub fn parse_tei_with_limits(xml: &str, limits: ParseLimits) -> Result<ParsedPaper, DocumentError> {
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
            &mut occurrences,
            &reference_ordinals,
        );
    }
    walk_divisions(
        body,
        None,
        &mut sections,
        &mut contexts,
        &mut occurrences,
        &reference_ordinals,
    );
    contexts.retain(|context| reference_ids.contains(context.reference_source_id.as_str()));

    Ok(ParsedPaper {
        title,
        sections,
        references,
        citation_contexts: contexts,
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
                occurrences,
                reference_ordinals,
            );
            walk_divisions(
                child,
                Some(&source_id),
                sections,
                contexts,
                occurrences,
                reference_ordinals,
            );
        } else {
            walk_divisions(
                child,
                parent_source_id,
                sections,
                contexts,
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
    occurrences: &mut HashMap<String, usize>,
    reference_ordinals: &HashMap<String, usize>,
) {
    let ordinal = sections.len();
    let kind = explicit_kind.unwrap_or_else(|| classify_section(heading.as_deref(), None));
    let mut paragraphs = Vec::new();
    for node in paragraph_nodes {
        let inline = inline_text(node);
        let (text, citations) = normalize_inline_text(&inline, reference_ordinals);
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
    fn walk(node: &XmlElement, text: &mut String, citations: &mut Vec<CitationMarker>) {
        if node.name == "ref"
            && node
                .attribute("type")
                .is_some_and(|kind| kind.eq_ignore_ascii_case("bibr"))
        {
            let marker = element_text(node);
            if let Some(targets) = node.attribute("target") {
                let targets = targets
                    .split_whitespace()
                    .map(|target| target.trim_start_matches('#').to_owned())
                    .filter(|target| !target.is_empty())
                    .collect::<Vec<_>>();
                if !targets.is_empty() {
                    let marker_index = citations.len();
                    let (start_sentinel, end_sentinel) = citation_sentinels(marker_index)
                        .map_or((None, None), |(start, end)| (Some(start), Some(end)));
                    let annotated_marker = match (start_sentinel, end_sentinel) {
                        (Some(start), Some(end)) => format!("{start}{marker}{end}"),
                        _ => marker.clone(),
                    };
                    citations.push(CitationMarker {
                        targets,
                        marker: marker.clone(),
                        start_sentinel,
                        end_sentinel,
                    });
                    push_text(text, &annotated_marker);
                    return;
                }
            }
            push_text(text, &marker);
            return;
        }
        for child in &node.children {
            match child {
                XmlContent::Text(value) => push_text(text, value),
                XmlContent::Element(element) => walk(element, text, citations),
            }
        }
    }
    let mut text = String::new();
    let mut citations = Vec::new();
    walk(node, &mut text, &mut citations);
    InlineText { text, citations }
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
) -> (String, Vec<ParsedCitationMarker>) {
    let normalized = normalize_text(&inline.text);
    let sentinels = inline
        .citations
        .iter()
        .enumerate()
        .flat_map(|(index, citation)| {
            citation
                .start_sentinel
                .map(|sentinel| (sentinel, (index, false)))
                .into_iter()
                .chain(
                    citation
                        .end_sentinel
                        .map(|sentinel| (sentinel, (index, true))),
                )
        })
        .collect::<HashMap<_, _>>();
    let mut starts = vec![None; inline.citations.len()];
    let mut ends = vec![None; inline.citations.len()];
    let mut text = String::with_capacity(normalized.len());
    let mut scalar_offset = 0usize;
    for character in normalized.chars() {
        if let Some((index, end)) = sentinels.get(&character).copied() {
            if end {
                ends[index] = Some(scalar_offset);
            } else {
                starts[index] = Some(scalar_offset);
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
            let start = starts[index]?;
            let end = ends[index]?;
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
    (text, citations)
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
