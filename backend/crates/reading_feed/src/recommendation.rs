use async_trait::async_trait;
use domain::{AuthenticatedUserId, PaperSummary};
use uuid::Uuid;

use crate::{
    FeedItemSource, RecommendationBatchMetadata, RecommendationError, RecommendationMetadata,
    RecommendationMode, RecommendationPosition,
};

#[derive(Debug, Clone, PartialEq)]
pub struct RecommendationRequest {
    pub user_id: AuthenticatedUserId,
    /// The account revision at which the store proved the queue empty and
    /// selected the bounded candidate page.
    pub library_revision: i64,
    pub category: Option<String>,
    pub recommendation_mode: RecommendationMode,
    pub position: Option<RecommendationPosition>,
    pub limit: u32,
    /// Injected observation time keeps batch expiry and tests deterministic.
    pub now: chrono::DateTime<chrono::Utc>,
    /// Eligible candidates selected under the same database snapshot as the
    /// empty-queue decision. Sources may rank or filter only this bounded page.
    pub candidates: RecommendationPage,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecommendationPage {
    pub items: Vec<PaperSummary>,
    pub next_position: Option<RecommendationPosition>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecommendationResultItem {
    pub paper: PaperSummary,
    pub source: FeedItemSource,
    pub recommendation: Option<RecommendationMetadata>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecommendationResultPage {
    /// Identity of the persisted batch that produced this page's items.
    ///
    /// Recommendation cursors are authorized chronological page boundaries,
    /// not offsets into this batch. A continuation may therefore be produced
    /// by a different batch after the next queue-empty snapshot authorizes its
    /// candidates.
    pub batch_id: Option<Uuid>,
    pub batch_metadata: Option<RecommendationBatchMetadata>,
    pub items: Vec<RecommendationResultItem>,
    pub next_position: Option<RecommendationPosition>,
}

/// Recommendation ranking is deliberately below queue authority. Eligibility
/// and exclusions belong to the snapshot store; a source may only filter or
/// order the supplied candidates and must never introduce another paper. The
/// v1 cursor policy requires chronological order, so a differently ranked
/// source must ship with a new explicit ordering/cursor policy.
#[async_trait]
pub trait RecommendationSource: Send + Sync {
    async fn page(
        &self,
        request: RecommendationRequest,
    ) -> Result<RecommendationResultPage, RecommendationError>;
}

/// The first release's deterministic chronological recommendation policy.
/// Eligibility, exclusions, and pagination are database responsibilities;
/// this source deliberately performs no I/O and preserves their order.
#[derive(Debug, Clone, Copy, Default)]
pub struct ChronologicalRecommendationSource;

#[async_trait]
impl RecommendationSource for ChronologicalRecommendationSource {
    async fn page(
        &self,
        request: RecommendationRequest,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        Ok(RecommendationResultPage {
            batch_id: None,
            batch_metadata: None,
            items: request
                .candidates
                .items
                .into_iter()
                .map(|paper| RecommendationResultItem {
                    paper,
                    source: FeedItemSource::DiscoveryV1,
                    recommendation: None,
                })
                .collect(),
            next_position: request.candidates.next_position,
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone as _, Utc};
    use domain::{Capabilities, PaperSummary};
    use url::Url;
    use uuid::Uuid;

    use super::*;

    #[tokio::test]
    async fn chronological_source_preserves_the_authoritative_candidate_page() {
        let paper = summary();
        let position = RecommendationPosition {
            published_at: paper.published_at,
            paper_id: paper.paper_id,
        };
        let candidates = RecommendationPage {
            items: vec![paper],
            next_position: Some(position),
        };

        let page = ChronologicalRecommendationSource
            .page(RecommendationRequest {
                user_id: AuthenticatedUserId::new(Uuid::from_u128(1)),
                library_revision: 4,
                category: Some("cs.AI".to_owned()),
                recommendation_mode: RecommendationMode::Recent,
                position: None,
                limit: 20,
                now: Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap(),
                candidates: candidates.clone(),
            })
            .await
            .unwrap();

        assert_eq!(page.batch_id, None);
        assert_eq!(page.batch_metadata, None);
        assert_eq!(page.next_position, candidates.next_position);
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].paper, candidates.items[0]);
        assert_eq!(page.items[0].source, FeedItemSource::DiscoveryV1);
        assert_eq!(page.items[0].recommendation, None);
    }

    fn summary() -> PaperSummary {
        let published_at = Utc.with_ymd_and_hms(2026, 8, 19, 12, 0, 0).unwrap();
        PaperSummary {
            paper_id: Uuid::from_u128(9),
            arxiv_id: "2401.12345v1".to_owned(),
            title: "Candidate".to_owned(),
            abstract_text: "Abstract".to_owned(),
            authors: vec!["Ada Reader".to_owned()],
            primary_category: "cs.AI".to_owned(),
            categories: vec!["cs.AI".to_owned()],
            published_at,
            updated_at: published_at,
            abs_url: Url::parse("https://arxiv.org/abs/2401.12345v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2401.12345v1").unwrap(),
            capabilities: Capabilities::metadata_only(),
        }
    }
}
