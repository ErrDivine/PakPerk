use std::collections::{BTreeMap, BTreeSet};

use domain::PaperId;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{CandidateSource, CitationCandidateEvidence, GeneratedCandidate, ReasonEvidence};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScoredCandidate {
    pub candidate: GeneratedCandidate,
    pub base_score: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RerankPolicy {
    /// Stable seed recorded on the recommendation batch.
    pub batch_seed: u64,
    pub max_items: usize,
    pub max_per_author: usize,
    pub max_per_category: usize,
    pub max_per_topic: usize,
    pub diversity_penalty: f32,
    /// Zero-based positions reserved for a qualifying exploration candidate.
    pub exploration_positions: BTreeSet<usize>,
}

impl Default for RerankPolicy {
    fn default() -> Self {
        Self {
            batch_seed: 0,
            max_items: 20,
            max_per_author: 2,
            max_per_category: 6,
            max_per_topic: 5,
            diversity_penalty: 0.2,
            exploration_positions: BTreeSet::from([4, 9]),
        }
    }
}

pub fn rerank(
    candidates: Vec<ScoredCandidate>,
    policy: &RerankPolicy,
) -> Result<Vec<ScoredCandidate>, RerankError> {
    rerank_with_evidence(candidates, policy, None).map(|(selected, _)| selected)
}

pub(crate) fn rerank_with_evidence(
    candidates: Vec<ScoredCandidate>,
    policy: &RerankPolicy,
    citation: Option<&BTreeMap<PaperId, CitationCandidateEvidence>>,
) -> Result<(Vec<ScoredCandidate>, usize), RerankError> {
    validate_policy(policy)?;
    let mut remaining = prepare_candidates(candidates, policy.batch_seed, citation)?;
    Ok(select_candidates(&mut remaining, policy, citation))
}

fn tier(
    value: &ScoredCandidate,
    citation: Option<&BTreeMap<PaperId, CitationCandidateEvidence>>,
) -> u8 {
    citation
        .and_then(|evidence| evidence.get(&value.candidate.document.paper.paper_id))
        .map_or(0, |evidence| evidence.tier)
}

fn prepare_candidates(
    candidates: Vec<ScoredCandidate>,
    batch_seed: u64,
    citation: Option<&BTreeMap<PaperId, CitationCandidateEvidence>>,
) -> Result<Vec<ScoredCandidate>, RerankError> {
    let mut identities = BTreeSet::new();
    let mut eligible = Vec::new();
    for candidate in candidates {
        let paper = &candidate.candidate.document.paper;
        if !candidate.base_score.is_finite() {
            return Err(RerankError::InvalidScore);
        }
        if candidate.candidate.document.topics.len() > 256
            || candidate.candidate.document.paper.authors.len() > 128
        {
            return Err(RerankError::InvalidCandidate);
        }
        if !identities.insert(paper.paper_id) {
            return Err(RerankError::DuplicatePaper);
        }
        candidate
            .candidate
            .features
            .validate()
            .map_err(|_| RerankError::InvalidFeature)?;
        if candidate.candidate.hidden || candidate.candidate.negative_feedback {
            continue;
        }
        eligible.push(candidate);
    }
    if citation.is_none() {
        let mut versions = BTreeMap::<String, ScoredCandidate>::new();
        for candidate in eligible {
            let identity = base_arxiv_identity(&candidate.candidate.document.paper.arxiv_id);
            match versions.get(&identity) {
                Some(existing)
                    if preferred(existing, &candidate, batch_seed)
                        == std::cmp::Ordering::Greater => {}
                _ => {
                    versions.insert(identity, candidate);
                }
            }
        }
        return Ok(versions.into_values().collect());
    }
    Ok(eligible)
}

fn select_candidates(
    remaining: &mut Vec<ScoredCandidate>,
    policy: &RerankPolicy,
    citation: Option<&BTreeMap<PaperId, CitationCandidateEvidence>>,
) -> (Vec<ScoredCandidate>, usize) {
    let mut selected = Vec::new();
    let mut tier_inversions = 0;
    let mut author_counts = BTreeMap::<String, usize>::new();
    let mut category_counts = BTreeMap::<String, usize>::new();
    let mut topic_counts = BTreeMap::<String, usize>::new();
    while selected.len() < policy.max_items && !remaining.is_empty() {
        let wants_exploration = policy.exploration_positions.contains(&selected.len());
        let mut best: Option<(usize, u8, bool, f32)> = None;
        let mut highest_eligible_tier = 0;
        let eligible = remaining.iter().enumerate().filter(|(_, value)| {
            !exceeds_caps(
                value,
                policy,
                &author_counts,
                &category_counts,
                &topic_counts,
            )
        });
        let mut eligible = eligible.collect::<Vec<_>>();
        if let Some(evidence) = citation {
            eligible = preferred_eligible_versions(eligible, evidence, policy.batch_seed);
        }
        for (index, value) in eligible {
            let tier = tier(value, citation);
            highest_eligible_tier = highest_eligible_tier.max(tier);
            let explores = wants_exploration
                && value
                    .candidate
                    .sources
                    .contains(&CandidateSource::Exploration);
            if best.is_some_and(|(_, best_tier, best_explores, _)| {
                (tier, explores) < (best_tier, best_explores)
            }) {
                continue;
            }
            let similarity = selected
                .iter()
                .map(|prior| similarity(value, prior))
                .fold(0.0_f32, f32::max);
            let adjusted = value.base_score - policy.diversity_penalty * similarity;
            if best.is_none_or(|(best_index, best_tier, best_explores, best_score)| {
                (tier, explores) > (best_tier, best_explores)
                    || better_candidate(
                        value,
                        &remaining[best_index],
                        adjusted,
                        best_score,
                        policy.batch_seed,
                    )
            }) {
                best = Some((index, tier, explores, adjusted));
            }
        }
        let Some((index, selected_tier, _, _)) = best else {
            break;
        };
        tier_inversions += usize::from(selected_tier < highest_eligible_tier);
        let mut next = remaining.remove(index);
        if citation.is_some() {
            let base = base_arxiv_identity(&next.candidate.document.paper.arxiv_id);
            remaining.retain(|value| {
                base_arxiv_identity(&value.candidate.document.paper.arxiv_id) != base
            });
        }
        if wants_exploration
            && next
                .candidate
                .sources
                .contains(&CandidateSource::Exploration)
        {
            next.candidate.features.exploration_slot = 1.0;
            if !next
                .candidate
                .reasons
                .contains(&ReasonEvidence::DiversitySlot)
            {
                next.candidate.reasons.push(ReasonEvidence::DiversitySlot);
            }
        }
        add_counts(
            &mut author_counts,
            &next.candidate.document.paper.authors,
            citation.is_some(),
        );
        *category_counts
            .entry(next.candidate.document.paper.primary_category.clone())
            .or_default() += 1;
        add_counts(
            &mut topic_counts,
            &next.candidate.document.topics,
            citation.is_some(),
        );
        selected.push(next);
    }
    (selected, tier_inversions)
}

fn preferred_eligible_versions<'a>(
    eligible: Vec<(usize, &'a ScoredCandidate)>,
    citation: &BTreeMap<PaperId, CitationCandidateEvidence>,
    batch_seed: u64,
) -> Vec<(usize, &'a ScoredCandidate)> {
    let mut versions = BTreeMap::<String, (usize, &ScoredCandidate)>::new();
    for (index, candidate) in eligible {
        let identity = base_arxiv_identity(&candidate.candidate.document.paper.arxiv_id);
        match versions.get(&identity) {
            Some((_, existing))
                if tier(existing, Some(citation))
                    .cmp(&tier(candidate, Some(citation)))
                    .then_with(|| preferred(existing, candidate, batch_seed))
                    == std::cmp::Ordering::Greater => {}
            _ => {
                versions.insert(identity, (index, candidate));
            }
        }
    }
    versions.into_values().collect()
}

fn add_counts<'a>(
    counts: &mut BTreeMap<String, usize>,
    values: impl IntoIterator<Item = &'a String>,
    distinct: bool,
) {
    let normalized_values = values.into_iter().map(|value| normalized(value));
    if distinct {
        for value in normalized_values.collect::<BTreeSet<_>>() {
            *counts.entry(value).or_default() += 1;
        }
    } else {
        for value in normalized_values {
            *counts.entry(value).or_default() += 1;
        }
    }
}

fn better_candidate(
    value: &ScoredCandidate,
    best: &ScoredCandidate,
    adjusted: f32,
    best_score: f32,
    batch_seed: u64,
) -> bool {
    adjusted
        .total_cmp(&best_score)
        .then_with(|| preferred(value, best, batch_seed))
        == std::cmp::Ordering::Greater
}

fn validate_policy(policy: &RerankPolicy) -> Result<(), RerankError> {
    if !(1..=100).contains(&policy.max_items)
        || policy.max_per_author == 0
        || policy.max_per_category == 0
        || policy.max_per_topic == 0
        || !policy.diversity_penalty.is_finite()
        || !(0.0..=2.0).contains(&policy.diversity_penalty)
        || policy
            .exploration_positions
            .iter()
            .any(|position| *position >= policy.max_items)
    {
        return Err(RerankError::InvalidPolicy);
    }
    Ok(())
}

fn exceeds_caps(
    value: &ScoredCandidate,
    policy: &RerankPolicy,
    author_counts: &BTreeMap<String, usize>,
    category_counts: &BTreeMap<String, usize>,
    topic_counts: &BTreeMap<String, usize>,
) -> bool {
    value.candidate.document.paper.authors.iter().any(|author| {
        author_counts.get(&normalized(author)).copied().unwrap_or(0) >= policy.max_per_author
    }) || category_counts
        .get(&value.candidate.document.paper.primary_category)
        .copied()
        .unwrap_or(0)
        >= policy.max_per_category
        || value.candidate.document.topics.iter().any(|topic| {
            topic_counts.get(&normalized(topic)).copied().unwrap_or(0) >= policy.max_per_topic
        })
}

fn similarity(left: &ScoredCandidate, right: &ScoredCandidate) -> f32 {
    let left_topics = &left.candidate.document.topics;
    let right_topics = &right.candidate.document.topics;
    let topic_similarity = if left_topics.is_empty() || right_topics.is_empty() {
        0.0
    } else {
        let matches =
            u16::try_from(left_topics.intersection(right_topics).count()).unwrap_or(u16::MAX);
        let total = u16::try_from(left_topics.union(right_topics).count()).unwrap_or(u16::MAX);
        f32::from(matches) / f32::from(total)
    };
    let left_authors = left
        .candidate
        .document
        .paper
        .authors
        .iter()
        .map(|author| normalized(author))
        .collect::<BTreeSet<_>>();
    let right_authors = right
        .candidate
        .document
        .paper
        .authors
        .iter()
        .map(|author| normalized(author))
        .collect::<BTreeSet<_>>();
    let author_similarity = if left_authors.is_disjoint(&right_authors) {
        0.0
    } else {
        1.0
    };
    let category_similarity = if left.candidate.document.paper.primary_category
        == right.candidate.document.paper.primary_category
    {
        1.0
    } else {
        0.0
    };
    topic_similarity
        .max(author_similarity)
        .max(category_similarity)
}

fn preferred(
    left: &ScoredCandidate,
    right: &ScoredCandidate,
    batch_seed: u64,
) -> std::cmp::Ordering {
    left.base_score
        .total_cmp(&right.base_score)
        .then_with(|| {
            left.candidate
                .document
                .paper
                .updated_at
                .cmp(&right.candidate.document.paper.updated_at)
        })
        .then_with(|| {
            let left_key =
                seeded_tie_key(left.candidate.document.paper.paper_id.as_u128(), batch_seed);
            let right_key = seeded_tie_key(
                right.candidate.document.paper.paper_id.as_u128(),
                batch_seed,
            );
            // Smaller seeded key wins an otherwise exact tie.
            right_key.cmp(&left_key)
        })
}

fn seeded_tie_key(paper_id: u128, batch_seed: u64) -> u128 {
    let seed = u128::from(batch_seed);
    let mixed = paper_id ^ (seed << 64 | seed);
    mixed
        .wrapping_mul(0x9e37_79b9_7f4a_7c15_6a09_e667_f3bc_c909)
        .rotate_left(37)
}

pub(crate) fn base_arxiv_identity(value: &str) -> String {
    let Some(index) = value.rfind('v') else {
        return value.to_owned();
    };
    if value[index + 1..].bytes().all(|byte| byte.is_ascii_digit()) {
        value[..index].to_owned()
    } else {
        value.to_owned()
    }
}

fn normalized(value: &str) -> String {
    value.trim().to_lowercase()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RerankError {
    #[error("recommendation rerank policy is invalid")]
    InvalidPolicy,
    #[error("recommendation score is invalid")]
    InvalidScore,
    #[error("recommendation feature vector is invalid")]
    InvalidFeature,
    #[error("recommendation candidate contains a duplicate paper")]
    DuplicatePaper,
    #[error("recommendation candidate metadata shape is outside supported bounds")]
    InvalidCandidate,
}

#[cfg(test)]
mod tests {
    use crate::candidates::tests::document;
    use crate::{CandidateSource, RecommendationFeatures};

    use super::*;

    fn scored(id: u128, score: f32, category: &str) -> ScoredCandidate {
        ScoredCandidate {
            candidate: GeneratedCandidate {
                document: document(id, category),
                sources: BTreeSet::from([CandidateSource::Recent]),
                features: RecommendationFeatures::ZERO,
                reasons: Vec::new(),
                qualified_impressions: 0,
                hidden: false,
                negative_feedback: false,
            },
            base_score: score,
        }
    }

    #[test]
    fn citation_duplicate_version_falls_back_when_the_better_tier_is_capped() {
        let first = scored(1, 3.0, "cs.CL");
        let stronger = scored(2, 2.0, "cs.CL");
        let mut alternate = scored(3, 4.0, "cs.CL");
        alternate.candidate.document.paper.arxiv_id = "2401.00002v2".to_owned();
        alternate.candidate.document.paper.authors = vec!["Other author".to_owned()];
        let evidence = BTreeMap::from([
            (
                PaperId::from_u128(1),
                CitationCandidateEvidence {
                    tier: 4,
                    ..CitationCandidateEvidence::default()
                },
            ),
            (
                PaperId::from_u128(2),
                CitationCandidateEvidence {
                    tier: 4,
                    ..CitationCandidateEvidence::default()
                },
            ),
            (
                PaperId::from_u128(3),
                CitationCandidateEvidence {
                    tier: 3,
                    ..CitationCandidateEvidence::default()
                },
            ),
        ]);
        let policy = RerankPolicy {
            max_per_author: 1,
            ..RerankPolicy::default()
        };
        let (ranked, tier_inversions) =
            rerank_with_evidence(vec![first, stronger, alternate], &policy, Some(&evidence))
                .unwrap();
        assert_eq!(
            ranked
                .iter()
                .map(|item| item.candidate.document.paper.paper_id.as_u128())
                .collect::<Vec<_>>(),
            vec![1, 3],
        );
        assert_eq!(tier_inversions, 0);
    }

    #[test]
    fn hard_exclusions_caps_version_collapse_and_ties_are_deterministic() {
        let mut newer_version = scored(3, 0.8, "cs.CL");
        newer_version.candidate.document.paper.arxiv_id = "2401.00001v2".to_owned();
        let mut older_version = scored(1, 0.7, "cs.CL");
        older_version.candidate.document.paper.arxiv_id = "2401.00001v1".to_owned();
        let mut hidden = scored(4, 2.0, "cs.LG");
        hidden.candidate.hidden = true;
        let result = rerank(
            vec![
                older_version,
                newer_version,
                scored(2, 0.6, "cs.LG"),
                hidden,
            ],
            &RerankPolicy {
                batch_seed: 17,
                max_items: 3,
                max_per_author: 3,
                max_per_category: 2,
                max_per_topic: 3,
                diversity_penalty: 0.0,
                exploration_positions: BTreeSet::new(),
            },
        )
        .unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].candidate.document.paper.paper_id.as_u128(), 3);
        assert_eq!(result[1].candidate.document.paper.paper_id.as_u128(), 2);
    }
}
