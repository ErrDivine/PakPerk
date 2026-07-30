use std::sync::OnceLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;

/// Normalize extracted Unicode while preserving paragraph and citation
/// semantics. Line-end hyphens are joined only for lower-case word fragments.
#[must_use]
pub fn normalize_text(input: &str) -> String {
    let normalized = input.nfkc().collect::<String>();
    let dehyphenated = line_hyphen_regex().replace_all(&normalized, "${left}${right}");
    dehyphenated
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_owned()
}

fn line_hyphen_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?P<left>\p{Ll}{2,})-\s*\r?\n\s*(?P<right>\p{Ll}{2,})")
            .expect("dehyphenation regex is valid")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_confident_line_hyphenation_but_preserves_compounds() {
        assert_eq!(normalize_text("represen-\n tation"), "representation");
        assert_eq!(normalize_text("state-of-the-art"), "state-of-the-art");
        assert_eq!(normalize_text("Section 3-\nD"), "Section 3- D");
    }
}
