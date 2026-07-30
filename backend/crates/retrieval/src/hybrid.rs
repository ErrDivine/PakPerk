use std::{
    collections::{HashMap, HashSet},
    num::NonZeroUsize,
};

use domain::{Chunk, PaperId, ProcessingGeneration, SectionKind};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::RetrievalError;

const KEYWORD_RRF_WEIGHT: f32 = 2.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RetrievalScope {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub chunk: Chunk,
    /// Larger is better. Rankings are recalculated defensively.
    pub score: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FusedHit {
    pub chunk: Chunk,
    pub combined_score: f32,
    pub vector_rank: Option<usize>,
    pub keyword_rank: Option<usize>,
}

#[derive(Debug, Clone, Copy)]
pub struct ContextSelectionConfig {
    pub maximum_chunks: NonZeroUsize,
    pub maximum_tokens: NonZeroUsize,
    pub duplicate_similarity: f32,
    /// Preserve a bounded lexical slice before filling the remaining context
    /// with the fused ranking. This keeps exact paper terminology available
    /// when a compact offline embedding produces a hash collision.
    pub reserved_keyword_chunks: usize,
}

impl Default for ContextSelectionConfig {
    fn default() -> Self {
        Self {
            maximum_chunks: NonZeroUsize::new(6).expect("six is non-zero"),
            maximum_tokens: NonZeroUsize::new(4_500).expect("4500 is non-zero"),
            duplicate_similarity: 0.82,
            reserved_keyword_chunks: 4,
        }
    }
}

/// Reciprocal-rank fusion with the plan's k=60 constant. Every hit is checked
/// against the requested paper and processing generation before it can enter
/// the result set.
pub fn hybrid_rank(
    scope: RetrievalScope,
    mut vector_hits: Vec<SearchHit>,
    mut keyword_hits: Vec<SearchHit>,
    limit: usize,
) -> Result<Vec<FusedHit>, RetrievalError> {
    validate_hits(scope, &vector_hits)?;
    validate_hits(scope, &keyword_hits)?;
    vector_hits.sort_by(|left, right| right.score.total_cmp(&left.score));
    keyword_hits.sort_by(|left, right| right.score.total_cmp(&left.score));

    let mut fused: HashMap<Uuid, FusedHit> = HashMap::new();
    for (index, hit) in vector_hits.into_iter().enumerate() {
        let rank = index + 1;
        let contribution = reciprocal_rank_contribution(rank);
        fused
            .entry(hit.chunk.id)
            .and_modify(|existing| {
                existing.combined_score += contribution;
                existing.vector_rank = Some(rank);
            })
            .or_insert(FusedHit {
                combined_score: contribution,
                vector_rank: Some(rank),
                keyword_rank: None,
                chunk: hit.chunk,
            });
    }
    for (index, hit) in keyword_hits.into_iter().enumerate() {
        let rank = index + 1;
        // Exact paper terminology is especially valuable in offline mode,
        // where the compact deterministic embedding is intentionally weak.
        // A bounded lexical weight keeps the method hybrid while preventing
        // hash collisions from displacing a first-ranked exact passage.
        let contribution = reciprocal_rank_contribution(rank) * KEYWORD_RRF_WEIGHT;
        fused
            .entry(hit.chunk.id)
            .and_modify(|existing| {
                existing.combined_score += contribution;
                existing.keyword_rank = Some(rank);
            })
            .or_insert(FusedHit {
                combined_score: contribution,
                vector_rank: None,
                keyword_rank: Some(rank),
                chunk: hit.chunk,
            });
    }
    let mut hits = fused
        .into_values()
        .map(|mut hit| {
            hit.combined_score *= section_priority(hit.chunk.section_kind);
            hit
        })
        .collect::<Vec<_>>();
    hits.sort_by(|left, right| {
        right
            .combined_score
            .total_cmp(&left.combined_score)
            .then_with(|| left.chunk.id.cmp(&right.chunk.id))
    });
    hits.truncate(limit);
    Ok(hits)
}

pub fn select_context(
    scope: RetrievalScope,
    hits: &[FusedHit],
    config: ContextSelectionConfig,
) -> Result<Vec<Chunk>, RetrievalError> {
    for hit in hits {
        validate_chunk(scope, &hit.chunk)?;
    }
    let mut selected: Vec<Chunk> = Vec::new();
    let mut tokens = 0usize;
    let keyword_reserve = config
        .reserved_keyword_chunks
        .min(config.maximum_chunks.get());
    let mut keyword_hits = hits
        .iter()
        .filter(|hit| hit.keyword_rank.is_some())
        .collect::<Vec<_>>();
    keyword_hits.sort_by(|left, right| {
        left.keyword_rank
            .cmp(&right.keyword_rank)
            .then_with(|| right.combined_score.total_cmp(&left.combined_score))
            .then_with(|| left.chunk.id.cmp(&right.chunk.id))
    });
    for hit in keyword_hits {
        if selected.len() >= keyword_reserve {
            break;
        }
        try_add_context(&mut selected, &mut tokens, hit, config);
    }
    for hit in hits {
        if selected.len() >= config.maximum_chunks.get() {
            break;
        }
        try_add_context(&mut selected, &mut tokens, hit, config);
    }
    Ok(selected)
}

fn try_add_context(
    selected: &mut Vec<Chunk>,
    tokens: &mut usize,
    hit: &FusedHit,
    config: ContextSelectionConfig,
) -> bool {
    if selected.iter().any(|existing| existing.id == hit.chunk.id)
        || tokens.saturating_add(hit.chunk.token_count) > config.maximum_tokens.get()
        || selected.iter().any(|existing| {
            text_similarity(&existing.text, &hit.chunk.text) >= config.duplicate_similarity
        })
    {
        return false;
    }
    *tokens += hit.chunk.token_count;
    selected.push(hit.chunk.clone());
    true
}

pub fn cosine_similarity(left: &[f32], right: &[f32]) -> Result<f32, RetrievalError> {
    if left.len() != right.len() {
        return Err(RetrievalError::EmbeddingDimension {
            left: left.len(),
            right: right.len(),
        });
    }
    if left.iter().chain(right).any(|value| !value.is_finite()) {
        return Err(RetrievalError::NonFiniteEmbedding);
    }
    let dot = left.iter().zip(right).map(|(a, b)| a * b).sum::<f32>();
    let left_norm = left.iter().map(|value| value * value).sum::<f32>().sqrt();
    let right_norm = right.iter().map(|value| value * value).sum::<f32>().sqrt();
    if left_norm == 0.0 || right_norm == 0.0 {
        return Err(RetrievalError::ZeroEmbedding);
    }
    Ok(dot / (left_norm * right_norm))
}

fn validate_hits(scope: RetrievalScope, hits: &[SearchHit]) -> Result<(), RetrievalError> {
    for hit in hits {
        validate_chunk(scope, &hit.chunk)?;
    }
    Ok(())
}

fn validate_chunk(scope: RetrievalScope, chunk: &Chunk) -> Result<(), RetrievalError> {
    if chunk.paper_id != scope.paper_id || chunk.generation != scope.generation {
        return Err(RetrievalError::ScopeViolation {
            chunk_id: chunk.id,
            actual_paper_id: chunk.paper_id,
            actual_generation: chunk.generation,
        });
    }
    Ok(())
}

const fn section_priority(kind: SectionKind) -> f32 {
    match kind {
        SectionKind::Method
        | SectionKind::Experiment
        | SectionKind::Result
        | SectionKind::Discussion
        | SectionKind::Limitation
        | SectionKind::Conclusion
        | SectionKind::Appendix => 1.15,
        SectionKind::RelatedWork | SectionKind::Background => 1.05,
        SectionKind::Introduction => 0.85,
        // GROBID headings are open-ended; substantive paper-specific sections
        // such as "Static vs. Dynamic Masking" and "Input and Output Format"
        // intentionally remain searchable even before a classifier learns
        // their vocabulary.
        SectionKind::Other => 1.0,
        _ => 0.7,
    }
}

fn text_similarity(left: &str, right: &str) -> f32 {
    let left = word_set(left);
    let right = word_set(right);
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let intersection = left.intersection(&right).count();
    let union = left.union(&right).count();
    let intersection = u16::try_from(intersection).unwrap_or(u16::MAX);
    let union = u16::try_from(union).unwrap_or(u16::MAX);
    f32::from(intersection) / f32::from(union)
}

fn word_set(text: &str) -> HashSet<String> {
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|word| word.len() > 2)
        .map(str::to_ascii_lowercase)
        .collect()
}

fn reciprocal_rank_contribution(rank: usize) -> f32 {
    let bounded_rank = u16::try_from(rank).unwrap_or(u16::MAX);
    1.0 / (60.0 + f32::from(bounded_rank))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(paper_id: Uuid, generation: i32, text: &str, kind: SectionKind) -> Chunk {
        Chunk {
            id: Uuid::new_v4(),
            paper_id,
            section_id: Uuid::new_v4(),
            generation,
            ordinal: 0,
            section_kind: kind,
            section_heading: None,
            text: text.into(),
            page_start: None,
            page_end: None,
            token_count: text.split_whitespace().count(),
        }
    }

    #[test]
    fn rejects_cross_paper_or_stale_generation_hits() {
        let requested = Uuid::new_v4();
        let foreign = chunk(Uuid::new_v4(), 1, "foreign evidence", SectionKind::Method);
        let error = hybrid_rank(
            RetrievalScope {
                paper_id: requested,
                generation: 1,
            },
            vec![SearchHit {
                chunk: foreign,
                score: 1.0,
            }],
            Vec::new(),
            6,
        )
        .unwrap_err();
        assert!(matches!(error, RetrievalError::ScopeViolation { .. }));
    }

    #[test]
    fn fuses_vector_and_keyword_rankings_and_boosts_later_sections() {
        let paper_id = Uuid::new_v4();
        let method = chunk(paper_id, 2, "method evidence", SectionKind::Method);
        let introduction = chunk(
            paper_id,
            2,
            "introduction evidence",
            SectionKind::Introduction,
        );
        let scope = RetrievalScope {
            paper_id,
            generation: 2,
        };
        let ranked = hybrid_rank(
            scope,
            vec![
                SearchHit {
                    chunk: introduction.clone(),
                    score: 0.95,
                },
                SearchHit {
                    chunk: method.clone(),
                    score: 0.9,
                },
            ],
            vec![
                SearchHit {
                    chunk: method.clone(),
                    score: 1.0,
                },
                SearchHit {
                    chunk: introduction,
                    score: 0.5,
                },
            ],
            6,
        )
        .unwrap();
        assert_eq!(ranked[0].chunk.id, method.id);
        assert!(ranked[0].vector_rank.is_some());
        assert!(ranked[0].keyword_rank.is_some());
    }

    #[test]
    fn first_lexical_hit_beats_a_vector_only_hash_collision() {
        let paper_id = Uuid::new_v4();
        let scope = RetrievalScope {
            paper_id,
            generation: 2,
        };
        let vector_decoy = chunk(
            paper_id,
            2,
            "unrelated appendix material",
            SectionKind::Method,
        );
        let lexical_answer = chunk(
            paper_id,
            2,
            "the exact terminology that answers the question",
            SectionKind::Introduction,
        );
        let ranked = hybrid_rank(
            scope,
            vec![SearchHit {
                chunk: vector_decoy,
                score: 1.0,
            }],
            vec![SearchHit {
                chunk: lexical_answer.clone(),
                score: 1.0,
            }],
            2,
        )
        .unwrap();
        assert_eq!(ranked[0].chunk.id, lexical_answer.id);
        assert_eq!(ranked[0].keyword_rank, Some(1));
    }

    #[test]
    fn deduplicates_near_identical_context() {
        let paper_id = Uuid::new_v4();
        let scope = RetrievalScope {
            paper_id,
            generation: 1,
        };
        let first = chunk(
            paper_id,
            1,
            "the model uses attention over scientific document tokens",
            SectionKind::Method,
        );
        let second = chunk(
            paper_id,
            1,
            "the model uses attention over scientific document tokens today",
            SectionKind::Method,
        );
        let hits = vec![
            FusedHit {
                chunk: first,
                combined_score: 1.0,
                vector_rank: Some(1),
                keyword_rank: Some(1),
            },
            FusedHit {
                chunk: second,
                combined_score: 0.9,
                vector_rank: Some(2),
                keyword_rank: Some(2),
            },
        ];
        let selected = select_context(scope, &hits, ContextSelectionConfig::default()).unwrap();
        assert_eq!(selected.len(), 1);
    }

    #[test]
    fn reserves_exact_lexical_context_within_the_six_chunk_bound() {
        let paper_id = Uuid::new_v4();
        let scope = RetrievalScope {
            paper_id,
            generation: 1,
        };
        let vector_terms = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"];
        let vector_scores = [1.0, 0.99, 0.98, 0.97, 0.96, 0.95];
        let mut hits = (0..6)
            .map(|index| FusedHit {
                chunk: chunk(
                    paper_id,
                    1,
                    &format!("vector favored decoy {}", vector_terms[index]),
                    SectionKind::Method,
                ),
                combined_score: vector_scores[index],
                vector_rank: Some(index + 1),
                keyword_rank: None,
            })
            .collect::<Vec<_>>();
        let lexical_terms = ["golf", "hotel", "india", "juliet"];
        let lexical_scores = [0.5, 0.49, 0.48, 0.47];
        let lexical_ids = (0..4)
            .map(|index| {
                let lexical = chunk(
                    paper_id,
                    1,
                    &format!("distinct exact lexical answer {}", lexical_terms[index]),
                    SectionKind::Introduction,
                );
                let id = lexical.id;
                hits.push(FusedHit {
                    chunk: lexical,
                    combined_score: lexical_scores[index],
                    vector_rank: None,
                    keyword_rank: Some(index + 1),
                });
                id
            })
            .collect::<HashSet<_>>();

        let selected = select_context(scope, &hits, ContextSelectionConfig::default()).unwrap();
        let selected_ids = selected
            .iter()
            .map(|candidate| candidate.id)
            .collect::<HashSet<_>>();

        assert_eq!(selected.len(), 6);
        assert!(lexical_ids.is_subset(&selected_ids));
    }

    #[test]
    fn computes_cosine_with_validation() {
        assert!((cosine_similarity(&[1.0, 0.0], &[1.0, 0.0]).unwrap() - 1.0).abs() < 1e-6);
        assert!(matches!(
            cosine_similarity(&[1.0], &[1.0, 2.0]),
            Err(RetrievalError::EmbeddingDimension { .. })
        ));
    }
}
