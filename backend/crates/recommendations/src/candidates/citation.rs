use crate::model::HistoricalRelation;
use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    validate_request,
};

#[derive(Debug, Clone, Copy, Default)]
pub struct CitationGenerator;

impl CandidateGenerator for CitationGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::Citation
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        if !request.profile.personalization_enabled {
            return Ok(Vec::new());
        }
        let mut generated = Vec::new();
        for document in request.documents {
            let Some(seed) = request
                .profile
                .historical_seeds
                .iter()
                .find(|seed| document.citation_neighbors.contains(&seed.paper_id))
            else {
                continue;
            };
            let mut value = candidate(document, self.source());
            value.features.citation_affinity = 1.0;
            value.reasons.push(ReasonEvidence::HistoricalSeed {
                paper_id: seed.paper_id,
                title: seed.title.clone(),
                state: seed.state,
                relation: HistoricalRelation::Citation,
            });
            generated.push(value);
        }
        generated.sort_by_key(|value| value.document.paper.paper_id);
        generated.truncate(request.limit);
        Ok(generated)
    }
}
