use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResolutionSignals {
    /// All continuous signals are expected in the inclusive 0–1 range.
    pub title_similarity: f32,
    pub author_overlap: f32,
    pub year_agreement: f32,
    pub identifier_or_doi_support: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchDecision {
    AutoLink,
    Ambiguous,
    Unresolved,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KeyReferenceSignals {
    pub normalized_citation_frequency: f32,
    pub introduction_frequency: f32,
    pub early_occurrence: f32,
    pub title_abstract_similarity: f32,
}

#[must_use]
pub fn normalize_title(title: &str) -> String {
    let folded = title
        .nfkc()
        .flat_map(char::to_lowercase)
        .collect::<String>();
    let without_tex_commands = remove_tex_commands(&folded);
    without_tex_commands
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn remove_tex_commands(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut characters = value.chars().peekable();
    while let Some(character) = characters.next() {
        if character != '\\' {
            output.push(character);
            continue;
        }
        if characters.peek().is_some_and(|next| next.is_alphabetic()) {
            while characters.peek().is_some_and(|next| next.is_alphabetic()) {
                characters.next();
            }
        } else {
            // TeX single-character escape: keep the escaped literal but remove
            // the control backslash.
            if let Some(literal) = characters.next() {
                output.push(literal);
            }
        }
        output.push(' ');
    }
    output
}

#[must_use]
pub fn resolution_confidence(signals: ResolutionSignals) -> f32 {
    0.60 * clamp_signal(signals.title_similarity)
        + 0.20 * clamp_signal(signals.author_overlap)
        + 0.10 * clamp_signal(signals.year_agreement)
        + 0.10 * clamp_signal(signals.identifier_or_doi_support)
}

/// Apply the plan's precision-first penalty for short or generic titles before
/// scoring a fuzzy local/title-search match. Exact arXiv IDs should bypass
/// title matching entirely.
#[must_use]
pub fn resolution_confidence_for_title(title: &str, mut signals: ResolutionSignals) -> f32 {
    signals.title_similarity *= title_specificity(&normalize_title(title));
    resolution_confidence(signals)
}

#[must_use]
pub fn resolution_decision(signals: ResolutionSignals) -> MatchDecision {
    let confidence = resolution_confidence(signals);
    if confidence >= 0.90 {
        MatchDecision::AutoLink
    } else if confidence >= 0.80 {
        MatchDecision::Ambiguous
    } else {
        MatchDecision::Unresolved
    }
}

#[must_use]
pub fn resolution_decision_for_title(title: &str, signals: ResolutionSignals) -> MatchDecision {
    let confidence = resolution_confidence_for_title(title, signals);
    if confidence >= 0.90 {
        MatchDecision::AutoLink
    } else if confidence >= 0.80 {
        MatchDecision::Ambiguous
    } else {
        MatchDecision::Unresolved
    }
}

#[must_use]
pub fn title_specificity(normalized_title: &str) -> f32 {
    let words = normalized_title.split_whitespace().collect::<Vec<_>>();
    if words.is_empty() {
        return 0.0;
    }
    let length_factor = match words.len() {
        0..=2 => 0.55,
        3..=4 => 0.8,
        _ => 1.0,
    };
    let generic_words = words
        .iter()
        .filter(|word| {
            matches!(
                **word,
                "a" | "an"
                    | "the"
                    | "new"
                    | "study"
                    | "analysis"
                    | "approach"
                    | "method"
                    | "model"
                    | "overview"
                    | "survey"
            )
        })
        .count();
    if generic_words == words.len() {
        length_factor * 0.6
    } else {
        length_factor
    }
}

#[must_use]
pub fn key_reference_score(signals: KeyReferenceSignals) -> f32 {
    0.40 * clamp_signal(signals.normalized_citation_frequency)
        + 0.30 * clamp_signal(signals.introduction_frequency)
        + 0.20 * clamp_signal(signals.early_occurrence)
        + 0.10 * clamp_signal(signals.title_abstract_similarity)
}

fn clamp_signal(signal: f32) -> f32 {
    if signal.is_finite() {
        signal.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_unicode_punctuation_and_tex_artifacts() {
        assert_eq!(
            normalize_title(" “BERT: \\textbf{Pre-Training} 2.0” "),
            "bert pre training 2 0"
        );
    }

    #[test]
    fn applies_precision_first_resolution_thresholds() {
        let exact = ResolutionSignals {
            title_similarity: 1.0,
            author_overlap: 1.0,
            year_agreement: 1.0,
            identifier_or_doi_support: 1.0,
        };
        assert_eq!(resolution_decision(exact), MatchDecision::AutoLink);
        let title_only = ResolutionSignals {
            title_similarity: 1.0,
            author_overlap: 0.0,
            year_agreement: 0.0,
            identifier_or_doi_support: 0.0,
        };
        assert_eq!(resolution_decision(title_only), MatchDecision::Unresolved);
    }

    #[test]
    fn computes_key_reference_formula() {
        let score = key_reference_score(KeyReferenceSignals {
            normalized_citation_frequency: 1.0,
            introduction_frequency: 1.0,
            early_occurrence: 0.5,
            title_abstract_similarity: 0.0,
        });
        assert!((score - 0.8).abs() < f32::EPSILON);
    }

    #[test]
    fn penalizes_short_generic_titles_for_fuzzy_matching() {
        let signals = ResolutionSignals {
            title_similarity: 1.0,
            author_overlap: 0.8,
            year_agreement: 1.0,
            identifier_or_doi_support: 0.0,
        };
        assert!(
            resolution_confidence_for_title("A New Method", signals)
                < resolution_confidence_for_title(
                    "Paragraph Aware Hybrid Retrieval for Scientific Papers",
                    signals,
                )
        );
        assert_eq!(
            resolution_decision_for_title("A New Method", signals),
            MatchDecision::Unresolved
        );
    }
}
