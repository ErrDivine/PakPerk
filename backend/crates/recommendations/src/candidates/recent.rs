use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    recency_score, validate_request,
};

#[derive(Debug, Clone, Copy, Default)]
pub struct RecentGenerator;

impl CandidateGenerator for RecentGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::Recent
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        let mut generated = request
            .documents
            .iter()
            .filter(|document| {
                request.profile.categories.is_empty()
                    || request
                        .profile
                        .categories
                        .contains(&document.paper.primary_category)
            })
            .map(|document| {
                let mut value = candidate(document, self.source());
                value.features.recency = recency_score(document.paper.published_at, request.now);
                value.features.novelty = 1.0;
                value.reasons.push(ReasonEvidence::RecentCategory {
                    category: document.paper.primary_category.clone(),
                });
                value
            })
            .collect::<Vec<_>>();
        generated.sort_by(|left, right| {
            right
                .document
                .paper
                .published_at
                .cmp(&left.document.paper.published_at)
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

    use crate::DiscoveryProfileSnapshot;

    use super::super::tests::{document, request};
    use super::*;

    #[test]
    fn recent_is_category_bounded_and_deterministic() {
        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: false,
            categories: BTreeSet::from(["cs.CL".to_owned()]),
            topics: BTreeSet::new(),
            authors: BTreeSet::new(),
            saved_query_matches: std::collections::BTreeMap::new(),
            feedback_categories: BTreeSet::new(),
            inferred_categories: BTreeSet::new(),
            historical_seeds: Vec::new(),
        };
        let documents = vec![document(2, "cs.LG"), document(1, "cs.CL")];
        let values = RecentGenerator
            .generate(&request(&profile, &documents))
            .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].document.paper.paper_id.as_u128(), 1);
    }
}
