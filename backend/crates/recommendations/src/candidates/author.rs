use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence};

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
        let followed = request
            .profile
            .authors
            .iter()
            .map(|author| normalized(author))
            .collect::<std::collections::BTreeSet<_>>();
        let mut generated = Vec::new();
        for document in request.documents {
            let Some(author) = document
                .paper
                .authors
                .iter()
                .find(|author| followed.contains(&normalized(author)))
            else {
                continue;
            };
            let mut value = candidate(document, self.source());
            value.features.explicit_follow = 1.0;
            value.features.recency = recency_score(document.paper.published_at, request.now);
            value.reasons.push(ReasonEvidence::FollowedAuthor {
                author: author.clone(),
            });
            generated.push(value);
        }
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
