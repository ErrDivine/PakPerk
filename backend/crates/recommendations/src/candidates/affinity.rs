use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    normalized, recency_score, validate_request,
};

/// Behavioral category affinity kept deliberately separate from explicit
/// follows. The source and explanation remain inspectable, and disabling
/// personalization removes this generator without affecting Following.
#[derive(Debug, Clone, Copy, Default)]
pub struct AffinityGenerator;

impl CandidateGenerator for AffinityGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::FeedbackAffinity
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        if !request.profile.personalization_enabled {
            return Ok(Vec::new());
        }
        let feedback_categories = request
            .profile
            .feedback_categories
            .iter()
            .map(|category| normalized(category))
            .collect::<std::collections::BTreeSet<_>>();
        let inferred_categories = request
            .profile
            .inferred_categories
            .iter()
            .map(|category| normalized(category))
            .collect::<std::collections::BTreeSet<_>>();
        let mut generated = Vec::new();
        for document in request.documents {
            let category = &document.paper.primary_category;
            let normalized_category = normalized(category);
            let feedback = feedback_categories.contains(&normalized_category);
            let inferred = inferred_categories.contains(&normalized_category);
            if !feedback && !inferred {
                continue;
            }
            let source = if feedback {
                CandidateSource::FeedbackAffinity
            } else {
                CandidateSource::InferredAffinity
            };
            let mut value = candidate(document, source);
            // A category identity is an exact normalized topic overlap, but it
            // is not an explicit follow and therefore never sets that feature.
            value.features.topic_overlap = 1.0;
            value.features.recency = recency_score(document.paper.published_at, request.now);
            if feedback {
                value
                    .reasons
                    .push(ReasonEvidence::FeedbackCategoryAffinity {
                        category: category.clone(),
                    });
            }
            if inferred {
                value.sources.insert(CandidateSource::InferredAffinity);
                value
                    .reasons
                    .push(ReasonEvidence::InferredCategoryAffinity {
                        category: category.clone(),
                    });
            }
            generated.push(value);
        }
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::DiscoveryProfileSnapshot;

    use super::super::tests::{document, request};
    use super::*;

    #[test]
    fn feedback_and_inference_never_masquerade_as_follows() {
        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: true,
            categories: BTreeSet::new(),
            topics: BTreeSet::new(),
            authors: BTreeSet::new(),
            saved_query_matches: std::collections::BTreeMap::new(),
            feedback_categories: BTreeSet::from(["cs.cl".to_owned()]),
            inferred_categories: BTreeSet::from(["CS.LG".to_owned()]),
            historical_seeds: Vec::new(),
        };
        let documents = vec![document(1, "cs.CL"), document(2, "cs.LG")];
        let values = AffinityGenerator
            .generate(&request(&profile, &documents))
            .unwrap();
        assert_eq!(values.len(), 2);
        assert!(
            values
                .iter()
                .all(|value| value.features.explicit_follow == 0.0)
        );
        assert!(
            values
                .iter()
                .any(|value| { value.sources.contains(&CandidateSource::FeedbackAffinity) })
        );
        assert!(
            values
                .iter()
                .any(|value| { value.sources.contains(&CandidateSource::InferredAffinity) })
        );
    }
}
