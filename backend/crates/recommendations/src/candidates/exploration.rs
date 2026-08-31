use crate::model::ExplorationRole;
use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    recency_score, validate_request,
};

#[derive(Debug, Clone, Copy)]
pub struct ExplorationGenerator {
    pub minimum_metadata_completeness: f32,
}

impl Default for ExplorationGenerator {
    fn default() -> Self {
        Self {
            minimum_metadata_completeness: 0.5,
        }
    }
}

impl CandidateGenerator for ExplorationGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::Exploration
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        if !self.minimum_metadata_completeness.is_finite()
            || !(0.0..=1.0).contains(&self.minimum_metadata_completeness)
        {
            return Err(CandidateGenerationError::InvalidMetadataCompleteness);
        }
        let mut generated = request
            .documents
            .iter()
            .filter(|document| {
                document.metadata_completeness >= self.minimum_metadata_completeness
                    && !request
                        .profile
                        .categories
                        .contains(&document.paper.primary_category)
            })
            .map(|document| {
                let mut value = candidate(document, self.source());
                value.features.exploration_slot = 1.0;
                value.features.novelty = 1.0;
                value.features.recency = recency_score(document.paper.published_at, request.now);
                let role = if document
                    .topics
                    .iter()
                    .any(|topic| request.profile.topics.contains(topic))
                {
                    ExplorationRole::AdjacentTopic
                } else {
                    ExplorationRole::UnderrepresentedCategory
                };
                value.reasons.push(ReasonEvidence::Exploration { role });
                value
            })
            .collect::<Vec<_>>();
        generated.sort_by(|left, right| {
            right
                .features
                .recency
                .total_cmp(&left.features.recency)
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
