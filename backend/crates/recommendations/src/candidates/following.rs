use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    normalized, overlap, recency_score, validate_request,
};

/// Topic and category following. Author follows are kept in their own module
/// so every candidate source remains independently measurable.
#[derive(Debug, Clone, Copy, Default)]
pub struct FollowingGenerator;

impl CandidateGenerator for FollowingGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::TopicFollow
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        let normalized_categories = request
            .profile
            .categories
            .iter()
            .map(|category| normalized(category))
            .collect::<std::collections::BTreeSet<_>>();
        let normalized_topics = request
            .profile
            .topics
            .iter()
            .map(|topic| normalized(topic))
            .collect();
        let mut generated = Vec::new();
        for document in request.documents {
            let saved_search_id = request
                .profile
                .saved_query_matches
                .get(&document.paper.paper_id)
                .copied();
            let category =
                normalized_categories.contains(&normalized(&document.paper.primary_category));
            let document_topics = document
                .topics
                .iter()
                .map(|topic| normalized(topic))
                .collect();
            let topic_overlap = overlap(&normalized_topics, &document_topics);
            if !category && topic_overlap <= 0.0 && saved_search_id.is_none() {
                continue;
            }
            let source = if saved_search_id.is_some() {
                CandidateSource::SavedQuery
            } else if topic_overlap > 0.0 {
                CandidateSource::TopicFollow
            } else {
                CandidateSource::CategoryFollow
            };
            let mut value = candidate(document, source);
            value.features.explicit_follow = 1.0;
            value.features.topic_overlap = topic_overlap;
            value.features.recency = recency_score(document.paper.published_at, request.now);
            if category {
                value.sources.insert(CandidateSource::CategoryFollow);
                value.reasons.push(ReasonEvidence::FollowedCategory {
                    category: document.paper.primary_category.clone(),
                });
            }
            if let Some(topic) = document_topics
                .intersection(&normalized_topics)
                .next()
                .cloned()
            {
                value.sources.insert(CandidateSource::TopicFollow);
                value.reasons.push(ReasonEvidence::FollowedTopic { topic });
            }
            if let Some(saved_search_id) = saved_search_id {
                value.sources.insert(CandidateSource::SavedQuery);
                value
                    .reasons
                    .push(ReasonEvidence::SavedQuery { saved_search_id });
            }
            generated.push(value);
        }
        generated.sort_by(|left, right| {
            right
                .features
                .topic_overlap
                .total_cmp(&left.features.topic_overlap)
                .then_with(|| {
                    right
                        .document
                        .paper
                        .published_at
                        .cmp(&left.document.paper.published_at)
                })
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
    use std::collections::{BTreeMap, BTreeSet};

    use crate::{DiscoveryProfileSnapshot, ExplanationCode, explain_candidate};

    use super::super::tests::{document, request};
    use super::*;

    #[test]
    fn saved_query_identity_is_a_following_signal_with_generic_explanation() {
        let saved_search_id = uuid::Uuid::from_u128(41);
        let matching = document(1, "cs.CL");
        let unrelated = document(2, "cs.CL");
        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: true,
            categories: BTreeSet::new(),
            topics: BTreeSet::new(),
            authors: BTreeSet::new(),
            saved_query_matches: BTreeMap::from([(matching.paper.paper_id, saved_search_id)]),
            feedback_categories: BTreeSet::new(),
            inferred_categories: BTreeSet::new(),
            historical_seeds: Vec::new(),
        };
        let documents = vec![matching, unrelated];

        let generated = FollowingGenerator
            .generate(&request(&profile, &documents))
            .unwrap();

        assert_eq!(generated.len(), 1);
        assert!(generated[0].sources.contains(&CandidateSource::SavedQuery));
        assert_eq!(
            generated[0].reasons,
            vec![ReasonEvidence::SavedQuery { saved_search_id }]
        );
        let explanations = explain_candidate(&generated[0]).unwrap();
        assert_eq!(explanations[0].code, ExplanationCode::SavedQueryMatch);
        assert_eq!(
            explanations[0].detail,
            "This paper matches one of your saved searches."
        );
        assert!(
            !explanations[0]
                .detail
                .contains(&saved_search_id.to_string())
        );
    }
}
