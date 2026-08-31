mod affinity;
mod author;
mod citation;
mod exploration;
mod following;
mod recent;
mod semantic;

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use domain::PaperId;
use thiserror::Error;

use crate::{
    CandidateDocument, CandidateSource, DiscoveryProfileSnapshot, GeneratedCandidate,
    RecommendationFeatures,
};

pub use affinity::AffinityGenerator;
pub use author::AuthorGenerator;
pub use citation::CitationGenerator;
pub use exploration::ExplorationGenerator;
pub use following::FollowingGenerator;
pub use recent::RecentGenerator;
pub use semantic::SemanticGenerator;

pub struct CandidateGenerationRequest<'a> {
    pub profile: &'a DiscoveryProfileSnapshot,
    pub documents: &'a [CandidateDocument],
    pub now: DateTime<Utc>,
    pub limit: usize,
}

pub trait CandidateGenerator {
    fn source(&self) -> CandidateSource;

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError>;
}

/// Combines independent generator outputs before scoring. A paper may be
/// discovered by several legitimate sources; document disagreement is closed
/// rather than silently choosing one source's metadata.
pub fn merge_generated_candidates(
    generated: impl IntoIterator<Item = Vec<GeneratedCandidate>>,
) -> Result<Vec<GeneratedCandidate>, CandidateMergeError> {
    let mut merged = std::collections::BTreeMap::<PaperId, GeneratedCandidate>::new();
    for candidate in generated.into_iter().flatten() {
        candidate
            .features
            .validate()
            .map_err(|_| CandidateMergeError::InvalidFeature)?;
        let paper_id = candidate.document.paper.paper_id;
        if let Some(existing) = merged.get_mut(&paper_id) {
            if existing.document != candidate.document {
                return Err(CandidateMergeError::DocumentConflict);
            }
            existing.sources.extend(candidate.sources);
            existing.features = merge_features(existing.features, candidate.features);
            for reason in candidate.reasons {
                if !existing.reasons.contains(&reason) {
                    existing.reasons.push(reason);
                }
            }
            existing.qualified_impressions = existing
                .qualified_impressions
                .max(candidate.qualified_impressions);
            existing.hidden |= candidate.hidden;
            existing.negative_feedback |= candidate.negative_feedback;
        } else {
            merged.insert(paper_id, candidate);
        }
    }
    Ok(merged.into_values().collect())
}

fn merge_features(
    left: RecommendationFeatures,
    right: RecommendationFeatures,
) -> RecommendationFeatures {
    RecommendationFeatures {
        semantic_similarity: left.semantic_similarity.max(right.semantic_similarity),
        topic_overlap: left.topic_overlap.max(right.topic_overlap),
        explicit_follow: left.explicit_follow.max(right.explicit_follow),
        citation_affinity: left.citation_affinity.max(right.citation_affinity),
        recency: left.recency.max(right.recency),
        novelty: left.novelty.max(right.novelty),
        repeat_exposure: left.repeat_exposure.max(right.repeat_exposure),
        negative_feedback: left.negative_feedback.max(right.negative_feedback),
        exploration_slot: left.exploration_slot.max(right.exploration_slot),
        metadata_completeness: left.metadata_completeness.max(right.metadata_completeness),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CandidateGenerationError {
    #[error("recommendation candidate limit is invalid")]
    InvalidLimit,
    #[error("recommendation metadata completeness is invalid")]
    InvalidMetadataCompleteness,
    #[error("recommendation embedding is malformed")]
    InvalidEmbedding,
    #[error("recommendation candidate metadata shape is outside supported bounds")]
    InvalidCandidateShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CandidateMergeError {
    #[error("recommendation generators disagree on canonical paper metadata")]
    DocumentConflict,
    #[error("recommendation generator emitted an invalid feature")]
    InvalidFeature,
}

fn validate_request(
    request: &CandidateGenerationRequest<'_>,
) -> Result<(), CandidateGenerationError> {
    if !(1..=500).contains(&request.limit) {
        return Err(CandidateGenerationError::InvalidLimit);
    }
    if request.documents.iter().any(|document| {
        !document.metadata_completeness.is_finite()
            || !(0.0..=1.0).contains(&document.metadata_completeness)
    }) {
        return Err(CandidateGenerationError::InvalidMetadataCompleteness);
    }
    if request.documents.iter().any(|document| {
        document.topics.len() > 256
            || document.paper.authors.len() > 128
            || document.embedding.len() > 4096
            || document.citation_neighbors.len() > 5000
    }) {
        return Err(CandidateGenerationError::InvalidCandidateShape);
    }
    if request.profile.categories.len() > 256
        || request.profile.topics.len() > 256
        || request.profile.authors.len() > 256
        || request.profile.historical_seeds.len() > 256
        || request
            .profile
            .historical_seeds
            .iter()
            .any(|seed| seed.topics.len() > 256 || seed.embedding.len() > 4096)
    {
        return Err(CandidateGenerationError::InvalidCandidateShape);
    }
    Ok(())
}

fn candidate(document: &CandidateDocument, source: CandidateSource) -> GeneratedCandidate {
    GeneratedCandidate {
        document: document.clone(),
        sources: BTreeSet::from([source]),
        features: RecommendationFeatures {
            metadata_completeness: document.metadata_completeness,
            ..RecommendationFeatures::ZERO
        },
        reasons: Vec::new(),
        qualified_impressions: 0,
        hidden: false,
        negative_feedback: false,
    }
}

fn normalized(value: &str) -> String {
    value.trim().to_lowercase()
}

fn recency_score(published_at: DateTime<Utc>, now: DateTime<Utc>) -> f32 {
    let age_days = (now - published_at).num_days().clamp(0, 365);
    let age_days = u16::try_from(age_days).unwrap_or(365);
    (1.0 - f32::from(age_days) / 365.0).clamp(0.0, 1.0)
}

fn overlap(left: &BTreeSet<String>, right: &BTreeSet<String>) -> f32 {
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let matches = u16::try_from(left.intersection(right).count()).unwrap_or(u16::MAX);
    let union = u16::try_from(left.union(right).count()).unwrap_or(u16::MAX);
    f32::from(matches) / f32::from(union)
}

fn cosine(left: &[f32], right: &[f32]) -> Result<f32, CandidateGenerationError> {
    if left.is_empty() || left.len() != right.len() {
        return Err(CandidateGenerationError::InvalidEmbedding);
    }
    if left.iter().chain(right).any(|value| !value.is_finite()) {
        return Err(CandidateGenerationError::InvalidEmbedding);
    }
    let dot = left.iter().zip(right).map(|(a, b)| a * b).sum::<f32>();
    let left_norm = left.iter().map(|value| value * value).sum::<f32>().sqrt();
    let right_norm = right.iter().map(|value| value * value).sum::<f32>().sqrt();
    if left_norm <= f32::EPSILON || right_norm <= f32::EPSILON {
        return Err(CandidateGenerationError::InvalidEmbedding);
    }
    Ok(f32::midpoint(dot / (left_norm * right_norm), 1.0))
}

#[cfg(test)]
pub(crate) mod tests {
    use chrono::{TimeZone as _, Utc};
    use domain::{Capabilities, PaperSummary};
    use url::Url;
    use uuid::Uuid;

    use super::*;

    pub(crate) fn document(id: u128, category: &str) -> CandidateDocument {
        let published_at = Utc.with_ymd_and_hms(2026, 8, 18, 12, 0, 0).unwrap();
        CandidateDocument {
            paper: PaperSummary {
                paper_id: Uuid::from_u128(id),
                arxiv_id: format!("2401.{id:05}v1"),
                title: format!("Candidate {id}"),
                abstract_text: "Metadata-only abstract".to_owned(),
                authors: vec!["Ada Reader".to_owned()],
                primary_category: category.to_owned(),
                categories: vec![category.to_owned()],
                published_at,
                updated_at: published_at,
                abs_url: Url::parse(&format!("https://arxiv.org/abs/2401.{id:05}v1")).unwrap(),
                pdf_url: Url::parse(&format!("https://arxiv.org/pdf/2401.{id:05}v1")).unwrap(),
                capabilities: Capabilities::metadata_only(),
            },
            topics: BTreeSet::new(),
            embedding: vec![1.0, 0.0],
            citation_neighbors: BTreeSet::new(),
            metadata_completeness: 1.0,
        }
    }

    pub(crate) fn request<'a>(
        profile: &'a DiscoveryProfileSnapshot,
        documents: &'a [CandidateDocument],
    ) -> CandidateGenerationRequest<'a> {
        CandidateGenerationRequest {
            profile,
            documents,
            now: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
            limit: 20,
        }
    }

    #[test]
    fn merge_preserves_every_source_reason_and_strongest_feature() {
        let document = document(1, "cs.CL");
        let mut recent = candidate(&document, CandidateSource::Recent);
        recent.features.recency = 0.8;
        recent.reasons.push(crate::ReasonEvidence::RecentCategory {
            category: "cs.CL".to_owned(),
        });
        let mut followed = candidate(&document, CandidateSource::CategoryFollow);
        followed.features.explicit_follow = 1.0;
        followed
            .reasons
            .push(crate::ReasonEvidence::FollowedCategory {
                category: "cs.CL".to_owned(),
            });

        let merged = merge_generated_candidates([vec![recent], vec![followed]]).unwrap();
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].sources.len(), 2);
        assert_eq!(merged[0].reasons.len(), 2);
        assert!((merged[0].features.recency - 0.8).abs() <= f32::EPSILON);
        assert!((merged[0].features.explicit_follow - 1.0).abs() <= f32::EPSILON);
    }
}
