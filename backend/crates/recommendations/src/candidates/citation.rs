use std::collections::BTreeMap;

use domain::PaperId;

use crate::model::HistoricalRelation;
use crate::{
    CandidateDocument, CandidateSource, CitationCandidateEvidence, GeneratedCandidate,
    HistoricalSeedState, ReasonEvidence,
};

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

impl CitationGenerator {
    pub(crate) fn generate_classified(
        request: &CandidateGenerationRequest<'_>,
        evidence: &BTreeMap<PaperId, CitationCandidateEvidence>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        if !request.profile.personalization_enabled {
            return Ok(Vec::new());
        }
        Ok(request
            .documents
            .iter()
            .filter_map(|document| {
                Self::candidate_for(document, evidence.get(&document.paper.paper_id)?)
            })
            .collect())
    }

    pub(crate) fn candidate_for(
        document: &CandidateDocument,
        evidence: &CitationCandidateEvidence,
    ) -> Option<GeneratedCandidate> {
        let reasons = Self::reasons(evidence);
        if reasons.is_empty() {
            return None;
        }
        let mut value = candidate(document, CandidateSource::Citation);
        value.features.citation_affinity = 1.0;
        value.reasons = reasons;
        Some(value)
    }

    pub(crate) fn reasons(evidence: &CitationCandidateEvidence) -> Vec<ReasonEvidence> {
        let mut seen = [false; 2];
        evidence
            .supporting_roots
            .iter()
            .filter_map(|support| {
                let root = support;
                let index = usize::from(root.state == HistoricalSeedState::Archived);
                if std::mem::replace(&mut seen[index], true) {
                    return None;
                }
                Some(ReasonEvidence::HistoricalSeed {
                    paper_id: root.paper_id,
                    title: root.title.clone(),
                    state: root.state,
                    relation: HistoricalRelation::Citation,
                })
            })
            .collect()
    }
}
