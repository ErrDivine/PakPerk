use std::sync::Arc;

use domain::{Chunk, PaperId, ParsedParagraph, ParsedSection, ProcessingGeneration};
use uuid::Uuid;

use crate::RetrievalError;

pub trait ChunkSizer: Send + Sync {
    fn token_count(&self, text: &str) -> usize;
}

/// Provider-independent approximation suitable until a model tokenizer is
/// configured. Four Unicode scalar values per token is deliberately
/// conservative for English scientific prose.
#[derive(Debug, Clone, Copy)]
pub struct CharacterChunkSizer {
    pub characters_per_token: usize,
}

impl Default for CharacterChunkSizer {
    fn default() -> Self {
        Self {
            characters_per_token: 4,
        }
    }
}

impl ChunkSizer for CharacterChunkSizer {
    fn token_count(&self, text: &str) -> usize {
        let characters = text.chars().count();
        characters.div_ceil(self.characters_per_token.max(1))
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ChunkingConfig {
    pub target_tokens: usize,
    pub maximum_tokens: usize,
    pub overlap_tokens: usize,
}

impl Default for ChunkingConfig {
    fn default() -> Self {
        Self {
            target_tokens: 750,
            maximum_tokens: 900,
            overlap_tokens: 100,
        }
    }
}

pub struct ParagraphChunker {
    config: ChunkingConfig,
    sizer: Arc<dyn ChunkSizer>,
}

impl std::fmt::Debug for ParagraphChunker {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ParagraphChunker")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

impl ParagraphChunker {
    pub fn new(config: ChunkingConfig, sizer: Arc<dyn ChunkSizer>) -> Result<Self, RetrievalError> {
        if config.target_tokens == 0
            || config.maximum_tokens < config.target_tokens
            || config.overlap_tokens >= config.maximum_tokens
        {
            return Err(RetrievalError::InvalidConfiguration(
                "expected 0 < target <= maximum and overlap < maximum".into(),
            ));
        }
        Ok(Self { config, sizer })
    }

    pub fn approximate(config: ChunkingConfig) -> Result<Self, RetrievalError> {
        Self::new(config, Arc::new(CharacterChunkSizer::default()))
    }

    /// Chunk one section. Calling one section at a time makes it impossible for
    /// the chunker to blend unrelated section kinds.
    pub fn chunk_section(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        section_id: Uuid,
        section: &ParsedSection,
    ) -> Vec<Chunk> {
        let mut pieces = Vec::new();
        for paragraph in &section.paragraphs {
            if self.sizer.token_count(&paragraph.text) <= self.config.maximum_tokens {
                pieces.push(Piece::from_paragraph(paragraph));
            } else {
                pieces.extend(self.split_long_paragraph(paragraph));
            }
        }

        let mut groups: Vec<Vec<Piece>> = Vec::new();
        let mut current: Vec<Piece> = Vec::new();
        for piece in pieces {
            let candidate = join_pieces(
                current
                    .iter()
                    .map(|existing| existing.text.as_str())
                    .chain(std::iter::once(piece.text.as_str())),
            );
            if !current.is_empty()
                && self.sizer.token_count(&candidate) > self.config.maximum_tokens
            {
                groups.push(std::mem::take(&mut current));
            }
            current.push(piece);
            let current_text = join_pieces(current.iter().map(|existing| existing.text.as_str()));
            if self.sizer.token_count(&current_text) >= self.config.target_tokens {
                groups.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            groups.push(current);
        }

        groups
            .into_iter()
            .enumerate()
            .filter_map(|(ordinal, group)| {
                let text = join_pieces(group.iter().map(|piece| piece.text.as_str()));
                if text.is_empty() {
                    return None;
                }
                let page_start = group.iter().filter_map(|piece| piece.page_start).min();
                let page_end = group.iter().filter_map(|piece| piece.page_end).max();
                Some(Chunk {
                    id: Uuid::now_v7(),
                    paper_id,
                    section_id,
                    generation,
                    ordinal,
                    section_kind: section.kind,
                    section_heading: section.heading.clone(),
                    token_count: self.sizer.token_count(&text),
                    text,
                    page_start,
                    page_end,
                })
            })
            .collect()
    }

    fn split_long_paragraph(&self, paragraph: &ParsedParagraph) -> Vec<Piece> {
        let words = paragraph.text.split_whitespace().collect::<Vec<_>>();
        let mut pieces = Vec::new();
        let mut start = 0usize;
        while start < words.len() {
            let mut end = start + 1;
            while end <= words.len() {
                let candidate = words[start..end].join(" ");
                if self.sizer.token_count(&candidate) > self.config.maximum_tokens {
                    end -= 1;
                    break;
                }
                if end == words.len() {
                    break;
                }
                end += 1;
            }
            end = end.max(start + 1).min(words.len());
            let text = words[start..end].join(" ");
            pieces.push(Piece {
                text,
                page_start: paragraph.page_start,
                page_end: paragraph.page_end,
            });
            if end == words.len() {
                break;
            }
            let mut next_start = end;
            while next_start > start {
                let overlap = words[next_start - 1..end].join(" ");
                if self.sizer.token_count(&overlap) > self.config.overlap_tokens {
                    break;
                }
                next_start -= 1;
            }
            // Ensure forward progress even when an unusual sizer reports zero.
            start = next_start.max(start + 1);
        }
        pieces
    }
}

#[derive(Debug)]
struct Piece {
    text: String,
    page_start: Option<u32>,
    page_end: Option<u32>,
}

impl Piece {
    fn from_paragraph(paragraph: &ParsedParagraph) -> Self {
        Self {
            text: paragraph.text.clone(),
            page_start: paragraph.page_start,
            page_end: paragraph.page_end,
        }
    }
}

fn join_pieces<'a>(pieces: impl Iterator<Item = &'a str>) -> String {
    pieces
        .filter(|piece| !piece.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

#[cfg(test)]
mod tests {
    use domain::SectionKind;

    use super::*;

    fn section(paragraphs: Vec<String>) -> ParsedSection {
        ParsedSection {
            source_id: "method".into(),
            ordinal: 0,
            parent_source_id: None,
            kind: SectionKind::Method,
            heading: Some("3 Method".into()),
            paragraphs: paragraphs
                .into_iter()
                .enumerate()
                .map(|(ordinal, text)| ParsedParagraph {
                    ordinal,
                    text,
                    citations: Vec::new(),
                    page_start: Some(u32::try_from(ordinal).unwrap() + 4),
                    page_end: Some(u32::try_from(ordinal).unwrap() + 4),
                })
                .collect(),
            page_start: Some(4),
            page_end: Some(5),
        }
    }

    #[test]
    fn keeps_paragraphs_and_section_metadata() {
        let chunker = ParagraphChunker::new(
            ChunkingConfig {
                target_tokens: 10,
                maximum_tokens: 15,
                overlap_tokens: 2,
            },
            Arc::new(CharacterChunkSizer {
                characters_per_token: 1,
            }),
        )
        .unwrap();
        let paper_id = Uuid::new_v4();
        let section_id = Uuid::new_v4();
        let chunks = chunker.chunk_section(
            paper_id,
            3,
            section_id,
            &section(vec!["alpha beta".into(), "gamma delta".into()]),
        );
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].text, "alpha beta");
        assert_eq!(chunks[1].text, "gamma delta");
        assert_eq!(chunks[1].paper_id, paper_id);
        assert_eq!(chunks[1].generation, 3);
        assert_eq!(chunks[1].section_kind, SectionKind::Method);
        assert_eq!(chunks[1].page_start, Some(5));
    }

    #[test]
    fn splits_long_paragraph_with_bounded_overlap() {
        let chunker = ParagraphChunker::new(
            ChunkingConfig {
                target_tokens: 5,
                maximum_tokens: 5,
                overlap_tokens: 2,
            },
            Arc::new(WordSizer),
        )
        .unwrap();
        let chunks = chunker.chunk_section(
            Uuid::new_v4(),
            1,
            Uuid::new_v4(),
            &section(vec!["one two three four five six seven eight".into()]),
        );
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].text, "one two three four five");
        assert!(chunks[1].text.starts_with("four five"));
        assert!(chunks.iter().all(|chunk| chunk.token_count <= 5));
    }

    struct WordSizer;

    impl ChunkSizer for WordSizer {
        fn token_count(&self, text: &str) -> usize {
            text.split_whitespace().count()
        }
    }
}
