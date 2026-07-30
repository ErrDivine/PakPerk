use std::collections::HashMap;

use domain::{IntroductionDetection, ParsedPaper, ParsedParagraph, ParsedSection, SectionKind};

use crate::DocumentError;

#[derive(Debug, Clone, PartialEq)]
pub struct DetectedIntroduction {
    pub heading: Option<String>,
    pub paragraphs: Vec<ParsedParagraph>,
    pub source_section_ids: Vec<String>,
    pub detection: IntroductionDetection,
}

pub fn detect_introduction(paper: &ParsedPaper) -> Result<DetectedIntroduction, DocumentError> {
    let candidate = best_heading_candidate(&paper.sections)
        .map(|(section, confidence)| (section, confidence, false))
        .or_else(|| {
            paper
                .sections
                .iter()
                .find(|section| is_substantial_fallback(section))
                .map(|section| (section, 0.45, true))
        })
        .ok_or(DocumentError::IntroductionNotFound)?;
    let (root, confidence, used_fallback) = candidate;
    let parent_by_id = paper
        .sections
        .iter()
        .map(|section| {
            (
                section.source_id.as_str(),
                section.parent_source_id.as_deref(),
            )
        })
        .collect::<HashMap<_, _>>();
    let included = paper
        .sections
        .iter()
        .filter(|section| {
            section.source_id == root.source_id
                || is_descendant(section, &root.source_id, &parent_by_id)
        })
        .collect::<Vec<_>>();
    let source_section_ids = included
        .iter()
        .map(|section| section.source_id.clone())
        .collect();
    let mut paragraphs = included
        .into_iter()
        .flat_map(|section| section.paragraphs.iter().cloned())
        .collect::<Vec<_>>();
    for (ordinal, paragraph) in paragraphs.iter_mut().enumerate() {
        paragraph.ordinal = ordinal;
    }
    if paragraphs.is_empty()
        || paragraphs
            .iter()
            .map(|paragraph| paragraph.text.chars().count())
            .sum::<usize>()
            < 80
    {
        return Err(DocumentError::IntroductionNotFound);
    }
    Ok(DetectedIntroduction {
        heading: root.heading.clone(),
        paragraphs,
        source_section_ids,
        detection: IntroductionDetection {
            confidence,
            used_fallback,
        },
    })
}

fn best_heading_candidate(sections: &[ParsedSection]) -> Option<(&ParsedSection, f32)> {
    sections
        .iter()
        .filter_map(|section| {
            let heading = section.heading.as_deref()?;
            heading_confidence(heading).map(|confidence| (section, confidence))
        })
        .max_by(|(left_section, left_score), (right_section, right_score)| {
            left_score
                .total_cmp(right_score)
                .then_with(|| right_section.ordinal.cmp(&left_section.ordinal))
        })
        .or_else(|| {
            sections
                .iter()
                .find(|section| section.kind == SectionKind::Introduction)
                .map(|section| (section, 0.9))
        })
}

fn heading_confidence(heading: &str) -> Option<f32> {
    let mut normalized = heading
        .trim()
        .trim_matches(|character: char| character.is_ascii_punctuation())
        .to_ascii_lowercase();
    let first_word = normalized
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .trim_matches(|character: char| {
            character.is_ascii_digit()
                || matches!(character, '.' | ':' | '-' | '(' | ')' | 'i' | 'v' | 'x')
        });
    if first_word.is_empty()
        && let Some((_, rest)) = normalized.split_once(char::is_whitespace)
    {
        normalized = rest.trim().to_owned();
    }
    let normalized = normalized.trim();
    if normalized == "introduction" {
        Some(0.99)
    } else if normalized == "introduction and motivation"
        || normalized == "introduction & motivation"
    {
        Some(0.97)
    } else if normalized.starts_with("introduction") || normalized.ends_with(" introduction") {
        Some(0.94)
    } else {
        None
    }
}

fn is_descendant(
    section: &ParsedSection,
    root_id: &str,
    parent_by_id: &HashMap<&str, Option<&str>>,
) -> bool {
    let mut current = section.parent_source_id.as_deref();
    let mut remaining = parent_by_id.len();
    while let Some(parent) = current {
        if parent == root_id {
            return true;
        }
        current = parent_by_id.get(parent).copied().flatten();
        if remaining == 0 {
            break;
        }
        remaining -= 1;
    }
    false
}

fn is_substantial_fallback(section: &ParsedSection) -> bool {
    !matches!(
        section.kind,
        SectionKind::Abstract
            | SectionKind::Acknowledgment
            | SectionKind::References
            | SectionKind::Appendix
    ) && section
        .paragraphs
        .iter()
        .map(|paragraph| paragraph.text.chars().count())
        .sum::<usize>()
        >= 200
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse_tei;

    #[test]
    fn includes_only_nested_introduction_subsections() {
        let paper = parse_tei(include_str!("../fixtures/sample.tei.xml")).unwrap();
        let introduction = detect_introduction(&paper).unwrap();
        assert_eq!(
            introduction.source_section_ids,
            ["sec-intro", "sec-motivation"]
        );
        assert_eq!(introduction.paragraphs.len(), 2);
        assert!((introduction.detection.confidence - 0.99).abs() < f32::EPSILON);
        assert!(!introduction.detection.used_fallback);
    }

    #[test]
    fn falls_back_to_first_substantial_body_section() {
        let paragraph = "A substantial opening body paragraph. ".repeat(10);
        let paper = ParsedPaper {
            title: None,
            sections: vec![ParsedSection {
                source_id: "s0".into(),
                ordinal: 0,
                parent_source_id: None,
                kind: SectionKind::Other,
                heading: Some("Overview".into()),
                paragraphs: vec![ParsedParagraph {
                    ordinal: 0,
                    text: paragraph,
                    citations: Vec::new(),
                    page_start: Some(1),
                    page_end: Some(1),
                }],
                page_start: Some(1),
                page_end: Some(1),
            }],
            references: Vec::new(),
            citation_contexts: Vec::new(),
        };
        let introduction = detect_introduction(&paper).unwrap();
        assert!(introduction.detection.used_fallback);
        assert!((introduction.detection.confidence - 0.45).abs() < f32::EPSILON);
    }
}
