//! `pakperk-worker recover-pdf`: runs page-image recovery on one local PDF
//! without a database, GROBID, or arXiv, and prints what would be stored.
//!
//! It exists for trying the vision model and judging transcription quality on a
//! real paper before `LLM_VISION_RECOVERY_ENABLED` is switched on. It talks to
//! the configured model provider, so it spends tokens like a real recovery.

use std::{
    collections::HashMap, fmt::Write as _, io::Write as _, path::Path, sync::Arc, time::Instant,
};

use anyhow::{Context as _, Result, bail};
use domain::ParsedPaper;
use llm_provider::{DocumentVisionProvider, OpenAiCompatibleProvider};
use uuid::Uuid;

use crate::{
    config::openai_compatible_from_process_env,
    recovery::RecoveryScope,
    vision_recovery::{ChildRenderer, recover_from_pages},
};

pub(crate) async fn run(pdf: &Path, markdown: Option<&Path>) -> Result<()> {
    if !pdf.is_file() {
        bail!("{} is not a file", pdf.display());
    }
    let config = openai_compatible_from_process_env()
        .context("invalid model configuration for recover-pdf")?;
    let Some(vision_model) = config.vision_model.clone() else {
        bail!("recover-pdf requires LLM_VISION_MODEL");
    };
    let provider: Arc<dyn DocumentVisionProvider> = Arc::new(
        OpenAiCompatibleProvider::new(config).context("could not build the model provider")?,
    );
    let renderer = ChildRenderer::current().context("could not locate the worker executable")?;
    let scope = RecoveryScope {
        paper_id: Uuid::now_v7(),
        generation: 1,
        arxiv_version: 1,
    };

    eprintln!(
        "transcribing {} with `{vision_model}`; this calls the model provider once per page",
        pdf.display()
    );
    let started = Instant::now();
    let outcome = recover_from_pages(&renderer, &provider, scope, pdf)
        .await
        .map_err(|error| anyhow::anyhow!("recovery failed ({}): {error:?}", error.kind()))?;

    let paper = &outcome.paper;
    let paragraphs = paper
        .sections
        .iter()
        .map(|section| section.paragraphs.len())
        .sum::<usize>();
    println!("pages transcribed: {}", outcome.provider_calls);
    println!(
        "model:             {}",
        outcome.model_id.as_deref().unwrap_or("unknown")
    );
    println!(
        "tokens in / out:   {} / {}",
        outcome.input_tokens, outcome.output_tokens
    );
    println!("elapsed:           {:.1}s", started.elapsed().as_secs_f64());
    println!(
        "provenance:        {} {}",
        outcome.document.parser_id, outcome.document.parser_version
    );
    println!(
        "title:             {}",
        paper.title.as_deref().unwrap_or("(none found)")
    );
    println!(
        "introduction:      {} ({} paragraphs, fallback: {})",
        outcome
            .introduction
            .heading
            .as_deref()
            .unwrap_or("(untitled)"),
        outcome.introduction.paragraphs.len(),
        outcome.introduction.detection.used_fallback
    );
    println!("sections:          {}", paper.sections.len());
    println!("paragraphs:        {paragraphs}");
    println!("references:        {}", paper.references.len());
    println!("\noutline:");
    for (depth, section) in section_depths(paper) {
        println!(
            "{}{} ({} paragraphs)",
            "  ".repeat(depth),
            section.heading.as_deref().unwrap_or("(untitled)"),
            section.paragraphs.len()
        );
    }

    if let Some(path) = markdown {
        // Never overwrite a file the person did not name for this run.
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .with_context(|| format!("could not create {}", path.display()))?;
        file.write_all(to_markdown(paper).as_bytes())
            .with_context(|| format!("could not write {}", path.display()))?;
        println!("\nfull transcription written to {}", path.display());
    } else {
        println!("\npass --markdown <new file> to write the full transcription");
    }
    Ok(())
}

/// Sections with their nesting depth, in document order.
fn section_depths(paper: &ParsedPaper) -> Vec<(usize, &domain::ParsedSection)> {
    let parents = paper
        .sections
        .iter()
        .map(|section| {
            (
                section.source_id.as_str(),
                section.parent_source_id.as_deref(),
            )
        })
        .collect::<HashMap<_, _>>();
    paper
        .sections
        .iter()
        .map(|section| {
            let mut depth = 0;
            let mut parent = section.parent_source_id.as_deref();
            while let Some(id) = parent
                && depth < 8
            {
                depth += 1;
                parent = parents.get(id).copied().flatten();
            }
            (depth, section)
        })
        .collect()
}

fn to_markdown(paper: &ParsedPaper) -> String {
    let mut markdown = String::new();
    if let Some(title) = &paper.title {
        let _ = writeln!(markdown, "# {title}\n");
    }
    for (depth, section) in section_depths(paper) {
        if let Some(heading) = &section.heading {
            let _ = writeln!(markdown, "{} {heading}\n", "#".repeat(depth + 2));
        }
        for paragraph in &section.paragraphs {
            let _ = writeln!(markdown, "{}\n", paragraph.text);
        }
    }
    if !paper.references.is_empty() {
        markdown.push_str("## References (as transcribed)\n\n");
        for reference in &paper.references {
            let _ = writeln!(markdown, "- {}", reference.raw_text);
        }
    }
    markdown
}

#[cfg(test)]
mod tests {
    use domain::{ParsedParagraph, ParsedReference, ParsedSection, SectionKind};

    use super::*;

    fn section(id: &str, parent: Option<&str>, heading: &str, text: &str) -> ParsedSection {
        ParsedSection {
            source_id: id.to_owned(),
            ordinal: 0,
            parent_source_id: parent.map(str::to_owned),
            kind: SectionKind::Other,
            heading: Some(heading.to_owned()),
            paragraphs: vec![ParsedParagraph {
                ordinal: 0,
                text: text.to_owned(),
                citations: Vec::new(),
                page_start: None,
                page_end: None,
            }],
            page_start: None,
            page_end: None,
        }
    }

    fn paper() -> ParsedPaper {
        ParsedPaper {
            title: Some("A Title".to_owned()),
            sections: vec![
                section("s0", None, "1 Introduction", "Intro text."),
                section("s1", Some("s0"), "1.1 Scope", "Scope text."),
                section("s2", Some("s1"), "1.1.1 Detail", "Detail text."),
            ],
            references: vec![ParsedReference {
                source_id: "r0".to_owned(),
                ordinal: 0,
                raw_text: "[1] An entry.".to_owned(),
                title: None,
                authors: Vec::new(),
                year: None,
                doi: None,
                url: None,
                arxiv_id: None,
            }],
            citation_contexts: Vec::new(),
        }
    }

    #[test]
    fn the_outline_nests_by_parent() {
        let paper = paper();
        assert_eq!(
            section_depths(&paper)
                .into_iter()
                .map(|(depth, section)| (depth, section.heading.clone().unwrap()))
                .collect::<Vec<_>>(),
            [
                (0, "1 Introduction".to_owned()),
                (1, "1.1 Scope".to_owned()),
                (2, "1.1.1 Detail".to_owned())
            ]
        );
    }

    #[test]
    fn markdown_carries_title_nested_headings_text_and_references() {
        let markdown = to_markdown(&paper());
        assert!(markdown.starts_with("# A Title\n"));
        assert!(markdown.contains("## 1 Introduction\n\nIntro text."));
        assert!(markdown.contains("### 1.1 Scope\n\nScope text."));
        assert!(markdown.contains("#### 1.1.1 Detail\n\nDetail text."));
        assert!(markdown.contains("- [1] An entry."));
    }
}
