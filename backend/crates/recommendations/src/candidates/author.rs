use std::collections::BTreeSet;

use chrono::{DateTime, Utc};

use crate::{
    CandidateDocument, CandidateSource, DiscoveryProfileSnapshot, GeneratedCandidate,
    ReasonEvidence,
};

use super::{
    CandidateGenerationError, CandidateGenerationRequest, CandidateGenerator, candidate,
    normalized, recency_score, validate_request,
};

#[derive(Debug, Clone, Copy, Default)]
pub struct AuthorGenerator;

impl CandidateGenerator for AuthorGenerator {
    fn source(&self) -> CandidateSource {
        CandidateSource::AuthorFollow
    }

    fn generate(
        &self,
        request: &CandidateGenerationRequest<'_>,
    ) -> Result<Vec<GeneratedCandidate>, CandidateGenerationError> {
        validate_request(request)?;
        let followed = Self::followed_names(request.profile);
        let mut generated = request
            .documents
            .iter()
            .filter_map(|document| Self::candidate_for(document, &followed, request.now))
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

impl AuthorGenerator {
    pub(crate) fn followed_names(profile: &DiscoveryProfileSnapshot) -> BTreeSet<String> {
        profile
            .authors
            .iter()
            .map(|author| normalized(author))
            .collect()
    }

    pub(crate) fn candidate_for(
        document: &CandidateDocument,
        followed: &BTreeSet<String>,
        now: DateTime<Utc>,
    ) -> Option<GeneratedCandidate> {
        let author = document
            .paper
            .authors
            .iter()
            .find(|author| followed.contains(&normalized(author)))?;
        let mut value = candidate(document, CandidateSource::AuthorFollow);
        value.features.explicit_follow = 1.0;
        value.features.recency = recency_score(document.paper.published_at, now);
        value.reasons.push(ReasonEvidence::FollowedAuthor {
            author: author.clone(),
        });
        Some(value)
    }
}
