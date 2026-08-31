use crate::model::HistoricalRelation;
use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate, cosine,
    overlap, validate_request,
};

#[derive(Debug, Clone, Copy)]
pub struct SemanticGenerator {
    pub minimum_similarity: f32,
}

impl Default for SemanticGenerator {
    fn default() -> Self {
        Self {
            minimum_similarity: 0.55,
        }
    }
}

impl CandidateGenerator for SemanticGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::Semantic
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        if !request.profile.personalization_enabled {
            return Ok(Vec::new());
        }
        if !self.minimum_similarity.is_finite() || !(0.0..=1.0).contains(&self.minimum_similarity) {
            return Err(CandidateGenerationError::InvalidEmbedding);
        }
        let mut generated = Vec::new();
        for document in request.documents {
            let mut best = None;
            for seed in &request.profile.historical_seeds {
                if document.embedding.is_empty() || seed.embedding.is_empty() {
                    continue;
                }
                let similarity = cosine(&document.embedding, &seed.embedding)?;
                if best
                    .as_ref()
                    .is_none_or(|(best_similarity, _)| similarity > *best_similarity)
                {
                    best = Some((similarity, seed));
                }
            }
            let Some((similarity, seed)) = best else {
                continue;
            };
            if similarity < self.minimum_similarity {
                continue;
            }
            let mut value = candidate(document, self.source());
            value.features.semantic_similarity = similarity;
            value.features.topic_overlap = overlap(&document.topics, &seed.topics);
            value.reasons.push(ReasonEvidence::HistoricalSeed {
                paper_id: seed.paper_id,
                title: seed.title.clone(),
                state: seed.state,
                relation: HistoricalRelation::Semantic,
            });
            generated.push(value);
        }
        generated.sort_by(|left, right| {
            right
                .features
                .semantic_similarity
                .total_cmp(&left.features.semantic_similarity)
                .then_with(|| {
                    left.document
                        .paper
                        .paper_id
                        .cmp(&right.document.paper.paper_id)
                })
        });
        generated.truncate(request.limit);
        Ok(generated)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::{DiscoveryProfileSnapshot, HistoricalSeed, HistoricalSeedState};

    use super::super::tests::{document, request};
    use super::*;

    #[test]
    fn semantic_reasons_can_reference_only_typed_inactive_seeds() {
        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: true,
            categories: BTreeSet::new(),
            topics: BTreeSet::new(),
            authors: BTreeSet::new(),
            saved_query_matches: std::collections::BTreeMap::new(),
            feedback_categories: BTreeSet::new(),
            inferred_categories: BTreeSet::new(),
            historical_seeds: vec![HistoricalSeed {
                paper_id: domain::PaperId::from_u128(99),
                title: "Reviewed seed".to_owned(),
                state: HistoricalSeedState::Reviewed,
                topics: BTreeSet::new(),
                embedding: vec![1.0, 0.0],
            }],
        };
        let documents = vec![document(1, "cs.CL")];
        let values = SemanticGenerator::default()
            .generate(&request(&profile, &documents))
            .unwrap();
        assert_eq!(values.len(), 1);
        assert!(matches!(
            values[0].reasons.as_slice(),
            [ReasonEvidence::HistoricalSeed {
                state: HistoricalSeedState::Reviewed,
                relation: HistoricalRelation::Semantic,
                ..
            }]
        ));
    }
}
