use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
    time::Instant,
};

use chrono::Duration as ChronoDuration;
use domain::AuthenticatedUserId;
use observability::{ReadingFeedStageClass, ReadingFeedStageOutcome, record_reading_feed_stage};

use crate::{
    CursorCodecError, CursorKeyEpoch, FeedItemSource, FeedMode, QueueMetadata,
    READING_FEED_CURSOR_POLICY_VERSION, ReadingFeedContinuation, ReadingFeedCursorClaims,
    ReadingFeedCursorPosition, ReadingFeedDecision, ReadingFeedItem, ReadingFeedPage,
    ReadingFeedPolicy, ReadingFeedRequest, ReadingFeedServiceError, ReadingFeedSnapshot,
    ReadingFeedSnapshotRequest, ReadingFeedStore, ReadingFeedStoreError, RecommendationError,
    RecommendationMode, RecommendationRequest, RecommendationResultPage, RecommendationSource,
};

/// Account-scoped cursor cryptography injected into the policy service.
/// Implementations must authenticate `expected_user_id`, reject expired or
/// inactive-key claims, and collapse all untrusted-token failures to Invalid.
pub trait ReadingFeedCursorCodec: Send + Sync {
    fn active_key_epoch(&self) -> CursorKeyEpoch;

    fn seal(&self, claims: &ReadingFeedCursorClaims) -> Result<String, CursorCodecError>;

    fn open(
        &self,
        expected_user_id: AuthenticatedUserId,
        token: &str,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<ReadingFeedCursorClaims, CursorCodecError>;
}

#[derive(Clone)]
pub struct ReadingFeedService {
    store: Arc<dyn ReadingFeedStore>,
    recommendations: Arc<dyn RecommendationSource>,
    cursors: Arc<dyn ReadingFeedCursorCodec>,
    policy: ReadingFeedPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct EffectiveRequest {
    user_id: AuthenticatedUserId,
    category: Option<String>,
    recommendation_mode: RecommendationMode,
    continuation: Option<ReadingFeedContinuation>,
    limit: u32,
    now: chrono::DateTime<chrono::Utc>,
}

impl ReadingFeedService {
    #[must_use]
    pub const fn with_dependencies(
        store: Arc<dyn ReadingFeedStore>,
        recommendations: Arc<dyn RecommendationSource>,
        cursors: Arc<dyn ReadingFeedCursorCodec>,
        policy: ReadingFeedPolicy,
    ) -> Self {
        Self {
            store,
            recommendations,
            cursors,
            policy,
        }
    }

    #[must_use]
    pub const fn policy(&self) -> &ReadingFeedPolicy {
        &self.policy
    }

    pub async fn page(
        &self,
        request: ReadingFeedRequest,
    ) -> Result<ReadingFeedPage, ReadingFeedServiceError> {
        let limit = self.policy.page_limit(request.limit)?;
        let category = self.policy.category(request.category.as_deref())?;
        let continuation = request
            .cursor
            .as_deref()
            .map(|token| {
                self.open_continuation(
                    request.user_id,
                    token,
                    request.now,
                    category.as_deref(),
                    request.recommendation_mode,
                    limit,
                )
            })
            .transpose()?;
        let effective = EffectiveRequest {
            user_id: request.user_id,
            category,
            recommendation_mode: request.recommendation_mode,
            continuation,
            limit,
            now: request.now,
        };

        let snapshot_started = Instant::now();
        let snapshot = self
            .store
            .snapshot(&ReadingFeedSnapshotRequest {
                user_id: effective.user_id,
                category: effective.category.clone(),
                continuation: effective.continuation,
                limit: effective.limit,
            })
            .await;
        record_reading_feed_stage(
            ReadingFeedStageClass::QueueSnapshot,
            snapshot_stage_outcome(&snapshot),
            snapshot_started.elapsed(),
        );
        let snapshot = snapshot.map_err(map_store_error)?;

        match snapshot {
            queue @ ReadingFeedSnapshot::Queue { .. } => self.queue_page(&effective, queue),
            ReadingFeedSnapshot::Empty {
                library_revision,
                recommendations,
            } => {
                self.recommendation_page(&effective, library_revision, recommendations)
                    .await
            }
        }
    }

    #[tracing::instrument(name = "reading_feed.queue_page", skip_all)]
    fn queue_page(
        &self,
        request: &EffectiveRequest,
        snapshot: ReadingFeedSnapshot,
    ) -> Result<ReadingFeedPage, ReadingFeedServiceError> {
        let ReadingFeedSnapshot::Queue {
            library_revision,
            active_to_read_count,
            items,
            next_position,
        } = snapshot
        else {
            unreachable!("queue_page is called only for a queue snapshot")
        };
        Self::validate_snapshot_fence(request.continuation, FeedMode::ToRead, library_revision)?;
        if library_revision < 0
            || items.len() > usize::try_from(request.limit).unwrap_or(usize::MAX)
            || items
                .iter()
                .any(|item| item.revision < 0 || item.revision > library_revision)
            || !queue_page_is_fifo(&items, next_position)
        {
            return Err(ReadingFeedServiceError::QueueAuthorityUnavailable);
        }

        let next_cursor = next_position
            .map(|position| {
                self.seal_continuation(
                    request,
                    FeedMode::ToRead,
                    library_revision,
                    ReadingFeedCursorPosition::ToRead { position },
                )
            })
            .transpose()?;
        Ok(ReadingFeedPage {
            mode: FeedMode::ToRead,
            decision: ReadingFeedDecision {
                library_revision,
                active_to_read_count: active_to_read_count.get(),
                queue_proven_empty: false,
            },
            batch_id: None,
            batch_metadata: None,
            items: items
                .into_iter()
                .map(|item| ReadingFeedItem {
                    paper: item.paper,
                    queue: Some(QueueMetadata {
                        state: item.state,
                        saved_at: item.saved_at,
                        revision: item.revision,
                        save_source_kind: item.save_source_kind,
                    }),
                    source: FeedItemSource::ToRead,
                    recommendation: None,
                })
                .collect(),
            next_cursor,
            server_time: request.now,
        })
    }

    #[tracing::instrument(name = "reading_feed.recommendation_eligibility", skip_all)]
    async fn recommendation_page(
        &self,
        request: &EffectiveRequest,
        library_revision: i64,
        candidates: crate::RecommendationPage,
    ) -> Result<ReadingFeedPage, ReadingFeedServiceError> {
        Self::validate_snapshot_fence(
            request.continuation,
            FeedMode::Recommendations,
            library_revision,
        )?;
        if library_revision < 0 {
            return Err(ReadingFeedServiceError::QueueAuthorityUnavailable);
        }
        if candidates.items.len() > usize::try_from(request.limit).unwrap_or(usize::MAX)
            || !recommendation_page_is_ordered(&candidates.items, candidates.next_position)
        {
            return Err(ReadingFeedServiceError::QueueAuthorityUnavailable);
        }
        let position = request.continuation.map(|continuation| {
            let ReadingFeedCursorPosition::Recommendations { position } = continuation.position
            else {
                unreachable!("the snapshot fence rejects a cross-mode continuation")
            };
            position
        });
        let authorized_candidates = candidates
            .items
            .iter()
            .map(|paper| (paper.paper_id, paper.clone()))
            .collect::<BTreeMap<_, _>>();
        let authorized_next_position = candidates.next_position;
        if authorized_candidates.len() != candidates.items.len() {
            return Err(ReadingFeedServiceError::QueueAuthorityUnavailable);
        }
        let recommendation_started = Instant::now();
        let page = self
            .recommendations
            .page(RecommendationRequest {
                user_id: request.user_id,
                library_revision,
                category: request.category.clone(),
                recommendation_mode: request.recommendation_mode,
                position,
                limit: request.limit,
                now: request.now,
                candidates,
            })
            .await;
        record_reading_feed_stage(
            ReadingFeedStageClass::RecommendationPage,
            recommendation_stage_outcome(&page),
            recommendation_started.elapsed(),
        );
        let page =
            page.map_err(|error| map_recommendation_error(error, request.continuation.is_some()))?;
        if page.items.len() > usize::try_from(request.limit).unwrap_or(usize::MAX)
            || !recommendation_result_is_valid(
                &page,
                &authorized_candidates,
                authorized_next_position,
            )
        {
            return Err(ReadingFeedServiceError::QueueAuthorityUnavailable);
        }
        let next_cursor = page
            .next_position
            .map(|position| {
                self.seal_continuation(
                    request,
                    FeedMode::Recommendations,
                    library_revision,
                    ReadingFeedCursorPosition::Recommendations { position },
                )
            })
            .transpose()?;
        Ok(ReadingFeedPage {
            mode: FeedMode::Recommendations,
            decision: ReadingFeedDecision {
                library_revision,
                active_to_read_count: 0,
                queue_proven_empty: true,
            },
            batch_id: page.batch_id,
            batch_metadata: page.batch_metadata,
            items: page
                .items
                .into_iter()
                .map(|item| ReadingFeedItem {
                    paper: item.paper,
                    queue: None,
                    source: item.source,
                    recommendation: item.recommendation,
                })
                .collect(),
            next_cursor,
            server_time: request.now,
        })
    }

    fn open_continuation(
        &self,
        user_id: AuthenticatedUserId,
        token: &str,
        now: chrono::DateTime<chrono::Utc>,
        category: Option<&str>,
        recommendation_mode: RecommendationMode,
        limit: u32,
    ) -> Result<ReadingFeedContinuation, ReadingFeedServiceError> {
        let claims = self
            .cursors
            .open(user_id, token, now)
            .map_err(map_open_error)?;
        if !claims.structurally_valid()
            || claims.category.as_deref() != category
            || claims.recommendation_mode != recommendation_mode
            || claims.page_size != limit
            || claims.page_policy_version != READING_FEED_CURSOR_POLICY_VERSION
        {
            return Err(ReadingFeedServiceError::InvalidCursor);
        }
        Ok(ReadingFeedContinuation {
            mode: claims.mode,
            library_revision: claims.library_revision,
            position: claims.position,
        })
    }

    fn validate_snapshot_fence(
        continuation: Option<ReadingFeedContinuation>,
        mode: FeedMode,
        library_revision: i64,
    ) -> Result<(), ReadingFeedServiceError> {
        if continuation.is_some_and(|cursor| {
            cursor.library_revision != library_revision || cursor.mode != mode
        }) {
            return Err(ReadingFeedServiceError::CursorStale);
        }
        Ok(())
    }

    fn seal_continuation(
        &self,
        request: &EffectiveRequest,
        mode: FeedMode,
        library_revision: i64,
        position: ReadingFeedCursorPosition,
    ) -> Result<String, ReadingFeedServiceError> {
        let ttl = ChronoDuration::from_std(self.policy.cursor_ttl())
            .map_err(|_| ReadingFeedServiceError::CursorUnavailable)?;
        let claims = ReadingFeedCursorClaims {
            user_id: request.user_id,
            mode,
            library_revision,
            ordering: position.ordering(),
            position,
            category: request.category.clone(),
            recommendation_mode: request.recommendation_mode,
            page_size: request.limit,
            page_policy_version: READING_FEED_CURSOR_POLICY_VERSION,
            key_epoch: self.cursors.active_key_epoch(),
            expires_at: request
                .now
                .checked_add_signed(ttl)
                .ok_or(ReadingFeedServiceError::CursorUnavailable)?,
        };
        self.cursors.seal(&claims).map_err(map_seal_error)
    }
}

fn map_open_error(error: CursorCodecError) -> ReadingFeedServiceError {
    match error {
        CursorCodecError::Invalid => ReadingFeedServiceError::InvalidCursor,
        CursorCodecError::Unavailable => ReadingFeedServiceError::QueueAuthorityUnavailable,
    }
}

fn map_seal_error(_: CursorCodecError) -> ReadingFeedServiceError {
    ReadingFeedServiceError::CursorUnavailable
}

fn map_store_error(error: ReadingFeedStoreError) -> ReadingFeedServiceError {
    match error {
        ReadingFeedStoreError::AccountNotFound => ReadingFeedServiceError::AccountNotFound,
        ReadingFeedStoreError::Suspended => ReadingFeedServiceError::Suspended,
        ReadingFeedStoreError::DeletionPending => ReadingFeedServiceError::DeletionPending,
        ReadingFeedStoreError::Deleted => ReadingFeedServiceError::Deleted,
        ReadingFeedStoreError::RevisionStale => ReadingFeedServiceError::CursorStale,
        ReadingFeedStoreError::Unavailable => ReadingFeedServiceError::QueueAuthorityUnavailable,
    }
}

const fn snapshot_stage_outcome(
    result: &Result<ReadingFeedSnapshot, ReadingFeedStoreError>,
) -> ReadingFeedStageOutcome {
    match result {
        Ok(_) => ReadingFeedStageOutcome::Success,
        Err(ReadingFeedStoreError::RevisionStale) => ReadingFeedStageOutcome::Stale,
        Err(ReadingFeedStoreError::Unavailable) => ReadingFeedStageOutcome::Unavailable,
        Err(
            ReadingFeedStoreError::AccountNotFound
            | ReadingFeedStoreError::Suspended
            | ReadingFeedStoreError::DeletionPending
            | ReadingFeedStoreError::Deleted,
        ) => ReadingFeedStageOutcome::Rejected,
    }
}

const fn recommendation_stage_outcome(
    result: &Result<RecommendationResultPage, RecommendationError>,
) -> ReadingFeedStageOutcome {
    match result {
        Ok(_) => ReadingFeedStageOutcome::Success,
        Err(RecommendationError::RevisionStale) => ReadingFeedStageOutcome::Stale,
        Err(RecommendationError::Unavailable) => ReadingFeedStageOutcome::Unavailable,
    }
}

fn map_recommendation_error(
    error: RecommendationError,
    has_continuation: bool,
) -> ReadingFeedServiceError {
    match error {
        RecommendationError::RevisionStale if has_continuation => {
            ReadingFeedServiceError::CursorStale
        }
        RecommendationError::RevisionStale => ReadingFeedServiceError::QueueAuthorityUnavailable,
        RecommendationError::Unavailable => ReadingFeedServiceError::RecommendationsUnavailable,
    }
}

fn queue_page_is_fifo(
    items: &[crate::QueueSnapshotItem],
    next_position: Option<crate::ToReadPosition>,
) -> bool {
    let ordered = items.windows(2).all(|pair| {
        pair[0].saved_at < pair[1].saved_at
            || (pair[0].saved_at == pair[1].saved_at
                && pair[0].paper.paper_id < pair[1].paper.paper_id)
    });
    let continuation_matches = next_position.is_none_or(|position| {
        items.last().is_some_and(|item| {
            position.saved_at == item.saved_at && position.paper_id == item.paper.paper_id
        })
    });
    ordered && continuation_matches
}

fn recommendation_page_is_ordered(
    items: &[domain::PaperSummary],
    next_position: Option<crate::RecommendationPosition>,
) -> bool {
    let ordered = items.windows(2).all(|pair| {
        pair[0].published_at > pair[1].published_at
            || (pair[0].published_at == pair[1].published_at && pair[0].paper_id > pair[1].paper_id)
    });
    let continuation_matches = next_position.is_none_or(|position| {
        items.last().is_some_and(|paper| {
            position.published_at == paper.published_at && position.paper_id == paper.paper_id
        })
    });
    ordered && continuation_matches
}

fn recommendation_result_is_valid(
    page: &RecommendationResultPage,
    authorized: &BTreeMap<domain::PaperId, domain::PaperSummary>,
    authorized_next_position: Option<crate::RecommendationPosition>,
) -> bool {
    let valid_batch_contract = match (&page.batch_id, &page.batch_metadata) {
        (Some(batch_id), Some(metadata)) => !batch_id.is_nil() && metadata.structurally_valid(),
        (None, None) => true,
        _ => false,
    };
    if !valid_batch_contract {
        return false;
    }
    let mut returned = BTreeSet::new();
    let papers_are_authorized = page.items.iter().all(|item| {
        returned.insert(item.paper.paper_id)
            && authorized
                .get(&item.paper.paper_id)
                .is_some_and(|paper| paper == &item.paper)
    });
    if !papers_are_authorized {
        return false;
    }
    if page.batch_id.is_some() {
        page.next_position == authorized_next_position
            && page.items.iter().all(|item| {
                item.recommendation.as_ref().is_some_and(|metadata| {
                    source_matches_mode(item.source, metadata.mode)
                        && explanation_contract_is_valid(metadata)
                        && !metadata.reason_codes.is_empty()
                        && metadata.reason_codes.len() <= 16
                        && valid_reason_label(&metadata.reason_label)
                })
            })
    } else {
        page.items
            .iter()
            .all(|item| item.source == FeedItemSource::DiscoveryV1 && item.recommendation.is_none())
            && page.next_position == authorized_next_position
            && recommendation_page_is_ordered(
                &page
                    .items
                    .iter()
                    .map(|item| item.paper.clone())
                    .collect::<Vec<_>>(),
                page.next_position,
            )
    }
}

const fn explanation_contract_is_valid(metadata: &crate::RecommendationMetadata) -> bool {
    // Deterministic Recent remains available while the enhanced recommendation
    // feature (and its explanation route) is dark. Every advanced mode must
    // continue to prove that its batch explanations are reachable.
    metadata.explanation_available || matches!(metadata.mode, RecommendationMode::Recent)
}

const fn source_matches_mode(source: FeedItemSource, mode: RecommendationMode) -> bool {
    matches!(
        (source, mode),
        (FeedItemSource::RecentV1, RecommendationMode::Recent)
            | (FeedItemSource::FollowingV1, RecommendationMode::Following)
            | (FeedItemSource::ForYouV1, RecommendationMode::ForYou)
            | (FeedItemSource::ExploreV1, RecommendationMode::Explore)
    )
}

fn valid_reason_label(value: &str) -> bool {
    !value.is_empty()
        && value.chars().count() <= 96
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use std::{
        num::NonZeroU64,
        sync::{Arc, Mutex},
        time::Duration,
    };

    use async_trait::async_trait;
    use chrono::{TimeZone as _, Utc};
    use domain::{Capabilities, PaperSummary, RecommendationReasonCode};
    use url::Url;
    use uuid::Uuid;

    use super::*;
    use crate::{
        QueueSnapshotItem, RecommendationBatchMetadata, RecommendationMetadata, RecommendationPage,
        RecommendationPosition, ToReadPosition,
    };

    #[derive(Clone)]
    struct FakeStore {
        snapshot: Arc<Mutex<Result<ReadingFeedSnapshot, ReadingFeedStoreError>>>,
        requests: Arc<Mutex<Vec<ReadingFeedSnapshotRequest>>>,
    }

    #[async_trait]
    impl ReadingFeedStore for FakeStore {
        async fn snapshot(
            &self,
            request: &ReadingFeedSnapshotRequest,
        ) -> Result<ReadingFeedSnapshot, ReadingFeedStoreError> {
            self.requests.lock().unwrap().push(request.clone());
            self.snapshot.lock().unwrap().clone()
        }
    }

    #[derive(Clone)]
    struct FakeRecommendations {
        page: Arc<Mutex<Result<RecommendationResultPage, RecommendationError>>>,
        requests: Arc<Mutex<Vec<RecommendationRequest>>>,
    }

    #[async_trait]
    impl RecommendationSource for FakeRecommendations {
        async fn page(
            &self,
            request: RecommendationRequest,
        ) -> Result<RecommendationResultPage, RecommendationError> {
            self.requests.lock().unwrap().push(request);
            self.page.lock().unwrap().clone()
        }
    }

    #[derive(Clone)]
    struct FakeCursorCodec {
        epoch: CursorKeyEpoch,
        opened: Arc<Mutex<Option<ReadingFeedCursorClaims>>>,
        sealed: Arc<Mutex<Vec<ReadingFeedCursorClaims>>>,
    }

    impl ReadingFeedCursorCodec for FakeCursorCodec {
        fn active_key_epoch(&self) -> CursorKeyEpoch {
            self.epoch.clone()
        }

        fn seal(&self, claims: &ReadingFeedCursorClaims) -> Result<String, CursorCodecError> {
            self.sealed.lock().unwrap().push(claims.clone());
            Ok("opaque-next".to_owned())
        }

        fn open(
            &self,
            expected_user_id: AuthenticatedUserId,
            _token: &str,
            now: chrono::DateTime<Utc>,
        ) -> Result<ReadingFeedCursorClaims, CursorCodecError> {
            let claims = self
                .opened
                .lock()
                .unwrap()
                .clone()
                .ok_or(CursorCodecError::Invalid)?;
            if claims.user_id != expected_user_id
                || claims.key_epoch != self.epoch
                || claims.expires_at <= now
            {
                return Err(CursorCodecError::Invalid);
            }
            Ok(claims)
        }
    }

    struct Harness {
        service: ReadingFeedService,
        store: FakeStore,
        recommendations: FakeRecommendations,
        cursors: FakeCursorCodec,
    }

    #[tokio::test]
    async fn active_queue_never_invokes_recommendations() {
        let first = summary(1);
        let second = summary(2);
        let first_saved = time(10);
        let second_saved = time(11);
        let next = ToReadPosition {
            saved_at: second_saved,
            paper_id: second.paper_id,
        };
        let harness = harness(Ok(ReadingFeedSnapshot::Queue {
            library_revision: 8,
            active_to_read_count: NonZeroU64::new(2).unwrap(),
            items: vec![
                QueueSnapshotItem {
                    paper: first.clone(),
                    state: domain::LibraryState::Inbox,
                    saved_at: first_saved,
                    revision: 7,
                    save_source_kind: Some(domain::LibrarySaveSourceKind::TitleSearch),
                },
                QueueSnapshotItem {
                    paper: second.clone(),
                    state: domain::LibraryState::ReadNext,
                    saved_at: second_saved,
                    revision: 8,
                    save_source_kind: None,
                },
            ],
            next_position: Some(next),
        }));

        let page = harness.service.page(request(None)).await.unwrap();

        assert_eq!(page.mode, FeedMode::ToRead);
        assert_eq!(page.decision.active_to_read_count, 2);
        assert!(!page.decision.queue_proven_empty);
        assert!(page.batch_id.is_none());
        assert!(page.batch_metadata.is_none());
        assert_eq!(page.items[0].paper, first);
        assert_eq!(page.items[1].paper, second);
        assert_eq!(
            page.items[0].queue,
            Some(QueueMetadata {
                state: domain::LibraryState::Inbox,
                saved_at: first_saved,
                revision: 7,
                save_source_kind: Some(domain::LibrarySaveSourceKind::TitleSearch),
            })
        );
        assert_eq!(
            page.items[1].queue.as_ref().map(|queue| queue.state),
            Some(domain::LibraryState::ReadNext)
        );
        assert!(
            page.items
                .iter()
                .all(|item| { item.source == FeedItemSource::ToRead && item.queue.is_some() })
        );
        assert!(harness.recommendations.requests.lock().unwrap().is_empty());
        assert_eq!(page.next_cursor.as_deref(), Some("opaque-next"));
        let claims = harness.cursors.sealed.lock().unwrap();
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].mode, FeedMode::ToRead);
        assert_eq!(claims[0].library_revision, 8);
        assert_eq!(
            claims[0].position,
            ReadingFeedCursorPosition::ToRead { position: next }
        );
        assert_eq!(claims[0].category.as_deref(), Some("cs.AI"));
        assert_eq!(claims[0].page_size, 20);
    }

    #[tokio::test]
    async fn proven_empty_queue_invokes_recommendations_once() {
        let recommendation = summary(9);
        let next = RecommendationPosition {
            published_at: recommendation.published_at,
            paper_id: recommendation.paper_id,
        };
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 12,
            recommendations: RecommendationPage {
                items: vec![recommendation.clone()],
                next_position: Some(next),
            },
        }));
        *harness.recommendations.page.lock().unwrap() =
            Ok(result_page(vec![recommendation.clone()], Some(next)));

        let page = harness.service.page(request(None)).await.unwrap();

        assert_eq!(page.mode, FeedMode::Recommendations);
        assert_eq!(page.decision.library_revision, 12);
        assert_eq!(page.decision.active_to_read_count, 0);
        assert!(page.decision.queue_proven_empty);
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].paper, recommendation);
        assert_eq!(page.items[0].source, FeedItemSource::DiscoveryV1);
        assert!(page.items[0].queue.is_none());
        assert!(page.items[0].recommendation.is_none());
        assert!(page.batch_id.is_none());
        assert!(page.batch_metadata.is_none());
        let requests = harness.recommendations.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].library_revision, 12);
        assert_eq!(requests[0].category.as_deref(), Some("cs.AI"));
        assert_eq!(requests[0].limit, 20);
        assert_eq!(requests[0].candidates.items, vec![recommendation]);
    }

    #[tokio::test]
    async fn persisted_reranked_batch_may_publish_an_authorized_continuation() {
        let chronological = (1..=20).rev().map(summary).collect::<Vec<_>>();
        let reranked = chronological.iter().cloned().rev().collect::<Vec<_>>();
        let page_boundary = chronological.last().unwrap().clone();
        let next = RecommendationPosition {
            published_at: page_boundary.published_at,
            paper_id: page_boundary.paper_id,
        };
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 12,
            recommendations: RecommendationPage {
                items: chronological,
                next_position: Some(next),
            },
        }));
        let batch_id = Uuid::from_u128(77);
        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata()),
            // Persisted recommendation batches are allowed to rerank the
            // exact candidate page. Only the unbatched fallback promises
            // chronological item order.
            items: reranked
                .clone()
                .into_iter()
                .map(|paper| crate::RecommendationResultItem {
                    paper,
                    source: FeedItemSource::RecentV1,
                    recommendation: Some(RecommendationMetadata {
                        mode: RecommendationMode::Recent,
                        reason_codes: vec![domain::RecommendationReasonCode::RecentCategory],
                        reason_label: "Recent in this category".to_owned(),
                        explanation_available: false,
                    }),
                })
                .collect(),
            next_position: Some(next),
        });

        let page = harness.service.page(request(None)).await.unwrap();

        assert_eq!(page.batch_id, Some(batch_id));
        assert_eq!(page.batch_metadata, Some(batch_metadata()));
        assert_eq!(page.items.len(), 20);
        assert_eq!(page.items[0].paper, reranked[0]);
        assert_eq!(page.items[19].paper, reranked[19]);
        assert_eq!(page.next_cursor.as_deref(), Some("opaque-next"));
        let sealed = harness.cursors.sealed.lock().unwrap();
        assert_eq!(sealed.len(), 1);
        assert_eq!(sealed[0].library_revision, 12);
        assert_eq!(
            sealed[0].position,
            ReadingFeedCursorPosition::Recommendations { position: next }
        );
    }

    #[tokio::test]
    async fn recommendation_continuation_accepts_new_page_scoped_batch_identity() {
        let paper = summary(1);
        let position = RecommendationPosition {
            published_at: summary(2).published_at,
            paper_id: summary(2).paper_id,
        };
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 12,
            recommendations: RecommendationPage {
                items: vec![paper.clone()],
                next_position: None,
            },
        }));
        *harness.cursors.opened.lock().unwrap() = Some(claims(
            FeedMode::Recommendations,
            12,
            ReadingFeedCursorPosition::Recommendations { position },
        ));
        let continuation_batch_id = Uuid::from_u128(88);
        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(continuation_batch_id),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper: paper.clone(),
                source: FeedItemSource::RecentV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::Recent,
                    reason_codes: vec![domain::RecommendationReasonCode::RecentCategory],
                    reason_label: "Recent in this category".to_owned(),
                    explanation_available: false,
                }),
            }],
            next_position: None,
        });

        let page = harness.service.page(request(Some("cursor"))).await.unwrap();

        assert_eq!(page.batch_id, Some(continuation_batch_id));
        assert_eq!(page.batch_metadata, Some(batch_metadata()));
        assert_eq!(page.items[0].paper, paper);
        let requests = harness.recommendations.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].position, Some(position));
        assert_eq!(requests[0].library_revision, 12);
    }

    #[tokio::test]
    async fn revision_or_mode_change_stales_before_recommendation_call() {
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 43,
            recommendations: empty_recommendations(),
        }));
        *harness.cursors.opened.lock().unwrap() = Some(claims(
            FeedMode::ToRead,
            42,
            ReadingFeedCursorPosition::ToRead {
                position: ToReadPosition {
                    saved_at: time(10),
                    paper_id: Uuid::from_u128(1),
                },
            },
        ));

        assert_eq!(
            harness.service.page(request(Some("cursor"))).await,
            Err(ReadingFeedServiceError::CursorStale)
        );
        assert!(harness.recommendations.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cursor_query_policy_mismatch_is_rejected_before_store() {
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: empty_recommendations(),
        }));
        let position = RecommendationPosition {
            published_at: time(10),
            paper_id: Uuid::from_u128(1),
        };
        let mut cursor = claims(
            FeedMode::Recommendations,
            42,
            ReadingFeedCursorPosition::Recommendations { position },
        );
        cursor.category = Some("cs.CL".into());
        *harness.cursors.opened.lock().unwrap() = Some(cursor);

        assert_eq!(
            harness.service.page(request(Some("cursor"))).await,
            Err(ReadingFeedServiceError::InvalidCursor)
        );
        assert!(harness.store.requests.lock().unwrap().is_empty());
        assert!(harness.recommendations.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cursor_is_bound_to_the_requested_recommendation_mode() {
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: empty_recommendations(),
        }));
        let position = RecommendationPosition {
            published_at: time(10),
            paper_id: Uuid::from_u128(1),
        };
        *harness.cursors.opened.lock().unwrap() = Some(claims(
            FeedMode::Recommendations,
            42,
            ReadingFeedCursorPosition::Recommendations { position },
        ));
        let mut changed = request(Some("cursor"));
        changed.recommendation_mode = RecommendationMode::Explore;

        assert_eq!(
            harness.service.page(changed).await,
            Err(ReadingFeedServiceError::InvalidCursor)
        );
        assert!(harness.store.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn batch_items_without_immutable_recommendation_metadata_fail_closed() {
        let paper = summary(9);
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: RecommendationPage {
                items: vec![paper.clone()],
                next_position: None,
            },
        }));
        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(Uuid::from_u128(77)),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper,
                source: FeedItemSource::ForYouV1,
                recommendation: None,
            }],
            next_position: None,
        });

        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    #[tokio::test]
    async fn batch_metadata_is_present_iff_batch_id_and_invalid_values_fail_closed() {
        let paper = summary(9);
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: RecommendationPage {
                items: vec![paper.clone()],
                next_position: None,
            },
        }));
        let valid = RecommendationResultPage {
            batch_id: Some(Uuid::from_u128(77)),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper: paper.clone(),
                source: FeedItemSource::RecentV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::Recent,
                    reason_codes: vec![RecommendationReasonCode::RecentCategory],
                    reason_label: "Recent in this category".to_owned(),
                    explanation_available: false,
                }),
            }],
            next_position: None,
        };

        let mut missing = valid.clone();
        missing.batch_metadata = None;
        *harness.recommendations.page.lock().unwrap() = Ok(missing);
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );

        let mut orphaned = result_page(vec![paper], None);
        orphaned.batch_metadata = Some(batch_metadata());
        *harness.recommendations.page.lock().unwrap() = Ok(orphaned);
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );

        let mut corrupt = valid;
        corrupt.batch_metadata.as_mut().unwrap().algorithm_version = "Invalid version".to_owned();
        *harness.recommendations.page.lock().unwrap() = Ok(corrupt);
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    #[tokio::test]
    async fn recommendation_source_cannot_introduce_or_rewrite_snapshot_candidates() {
        let authorized = summary(9);
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: RecommendationPage {
                items: vec![authorized.clone()],
                next_position: None,
            },
        }));
        *harness.recommendations.page.lock().unwrap() = Ok(result_page(vec![summary(10)], None));
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );

        let mut rewritten = authorized;
        rewritten.title = "Untrusted rewritten title".to_owned();
        *harness.recommendations.page.lock().unwrap() = Ok(result_page(vec![rewritten], None));
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    #[tokio::test]
    async fn personalized_batch_requires_closed_matching_source_and_reason_metadata() {
        let paper = summary(9);
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: RecommendationPage {
                items: vec![paper.clone()],
                next_position: None,
            },
        }));
        let batch_id = Uuid::from_u128(77);
        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper: paper.clone(),
                source: FeedItemSource::RecentV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::Recent,
                    reason_codes: vec![RecommendationReasonCode::RecentCategory],
                    reason_label: "Recent in this category".to_owned(),
                    explanation_available: false,
                }),
            }],
            next_position: None,
        });
        let page = harness.service.page(request(None)).await.unwrap();
        assert_eq!(page.batch_id, Some(batch_id));
        assert_eq!(page.batch_metadata, Some(batch_metadata()));
        assert_eq!(page.items[0].paper, paper);

        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper: page.items[0].paper.clone(),
                source: FeedItemSource::ForYouV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::ForYou,
                    reason_codes: vec![RecommendationReasonCode::ReviewedPaperSimilarity],
                    reason_label: "Similar to a reviewed paper".to_owned(),
                    explanation_available: false,
                }),
            }],
            next_position: None,
        });
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable),
            "only the deterministic Recent fallback may omit explanation availability"
        );

        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper: page.items[0].paper.clone(),
                source: FeedItemSource::ForYouV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::Recent,
                    reason_codes: vec![RecommendationReasonCode::RecentCategory],
                    reason_label: "Forged".to_owned(),
                    explanation_available: true,
                }),
            }],
            next_position: None,
        });
        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    #[tokio::test]
    async fn for_you_affinity_reasons_are_published_but_empty_reasons_fail_closed() {
        let paper = summary(9);
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 42,
            recommendations: RecommendationPage {
                items: vec![paper.clone()],
                next_position: None,
            },
        }));
        let batch_id = Uuid::from_u128(77);
        let mut for_you_request = request(None);
        for_you_request.recommendation_mode = RecommendationMode::ForYou;

        for reason_code in [
            RecommendationReasonCode::FeedbackCategoryAffinity,
            RecommendationReasonCode::InferredCategoryAffinity,
        ] {
            *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
                batch_id: Some(batch_id),
                batch_metadata: Some(batch_metadata()),
                items: vec![crate::RecommendationResultItem {
                    paper: paper.clone(),
                    source: FeedItemSource::ForYouV1,
                    recommendation: Some(RecommendationMetadata {
                        mode: RecommendationMode::ForYou,
                        reason_codes: vec![reason_code],
                        reason_label: "Matches your category interests".to_owned(),
                        explanation_available: true,
                    }),
                }],
                next_position: None,
            });

            let page = harness.service.page(for_you_request.clone()).await.unwrap();
            assert_eq!(page.batch_id, Some(batch_id));
            assert_eq!(
                page.items[0].recommendation.as_ref().unwrap().reason_codes,
                vec![reason_code]
            );
        }

        *harness.recommendations.page.lock().unwrap() = Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata()),
            items: vec![crate::RecommendationResultItem {
                paper,
                source: FeedItemSource::ForYouV1,
                recommendation: Some(RecommendationMetadata {
                    mode: RecommendationMode::ForYou,
                    reason_codes: Vec::new(),
                    reason_label: "Forged".to_owned(),
                    explanation_available: true,
                }),
            }],
            next_position: None,
        });

        assert_eq!(
            harness.service.page(for_you_request).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    #[tokio::test]
    async fn unavailable_authority_never_falls_back_to_recommendations() {
        let harness = harness(Err(ReadingFeedStoreError::Unavailable));

        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
        assert!(harness.recommendations.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn out_of_order_queue_page_fails_closed_without_recommendations() {
        let harness = harness(Ok(ReadingFeedSnapshot::Queue {
            library_revision: 8,
            active_to_read_count: NonZeroU64::new(2).unwrap(),
            items: vec![
                QueueSnapshotItem {
                    paper: summary(2),
                    state: domain::LibraryState::Reading,
                    saved_at: time(11),
                    revision: 8,
                    save_source_kind: None,
                },
                QueueSnapshotItem {
                    paper: summary(1),
                    state: domain::LibraryState::Inbox,
                    saved_at: time(10),
                    revision: 7,
                    save_source_kind: None,
                },
            ],
            next_position: None,
        }));

        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
        assert!(harness.recommendations.requests.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn oversized_dependency_page_fails_closed() {
        let harness = harness(Ok(ReadingFeedSnapshot::Empty {
            library_revision: 4,
            recommendations: empty_recommendations(),
        }));
        *harness.recommendations.page.lock().unwrap() =
            Ok(result_page((0..21).map(summary).collect(), None));

        assert_eq!(
            harness.service.page(request(None)).await,
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        );
    }

    fn harness(snapshot: Result<ReadingFeedSnapshot, ReadingFeedStoreError>) -> Harness {
        let store = FakeStore {
            snapshot: Arc::new(Mutex::new(snapshot)),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let recommendations = FakeRecommendations {
            page: Arc::new(Mutex::new(Ok(result_page(Vec::new(), None)))),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let cursors = FakeCursorCodec {
            epoch: epoch(),
            opened: Arc::new(Mutex::new(None)),
            sealed: Arc::new(Mutex::new(Vec::new())),
        };
        let service = ReadingFeedService::with_dependencies(
            Arc::new(store.clone()),
            Arc::new(recommendations.clone()),
            Arc::new(cursors.clone()),
            ReadingFeedPolicy::new(20, 50, Duration::from_secs(86_400)).unwrap(),
        );
        Harness {
            service,
            store,
            recommendations,
            cursors,
        }
    }

    fn empty_recommendations() -> RecommendationPage {
        RecommendationPage {
            items: Vec::new(),
            next_position: None,
        }
    }

    fn request(cursor: Option<&str>) -> ReadingFeedRequest {
        ReadingFeedRequest {
            user_id: user(1),
            category: Some("cs.AI".into()),
            recommendation_mode: RecommendationMode::Recent,
            cursor: cursor.map(str::to_owned),
            limit: None,
            now: time(12),
        }
    }

    fn claims(
        mode: FeedMode,
        library_revision: i64,
        position: ReadingFeedCursorPosition,
    ) -> ReadingFeedCursorClaims {
        ReadingFeedCursorClaims {
            user_id: user(1),
            mode,
            library_revision,
            ordering: position.ordering(),
            position,
            category: Some("cs.AI".into()),
            recommendation_mode: RecommendationMode::Recent,
            page_size: 20,
            page_policy_version: READING_FEED_CURSOR_POLICY_VERSION,
            key_epoch: epoch(),
            expires_at: time(13),
        }
    }

    fn user(id: u128) -> AuthenticatedUserId {
        AuthenticatedUserId::new(Uuid::from_u128(id))
    }

    fn result_page(
        items: Vec<PaperSummary>,
        next_position: Option<RecommendationPosition>,
    ) -> RecommendationResultPage {
        RecommendationResultPage {
            batch_id: None,
            batch_metadata: None,
            items: items
                .into_iter()
                .map(|paper| crate::RecommendationResultItem {
                    paper,
                    source: FeedItemSource::DiscoveryV1,
                    recommendation: None,
                })
                .collect(),
            next_position,
        }
    }

    fn batch_metadata() -> RecommendationBatchMetadata {
        RecommendationBatchMetadata {
            profile_revision: Some(3),
            feedback_revision: 4,
            algorithm_version: "recommendations_v1".to_owned(),
            recommendation_policy_version: "weighted_v1".to_owned(),
        }
    }

    fn epoch() -> CursorKeyEpoch {
        CursorKeyEpoch::parse("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").unwrap()
    }

    fn time(hour: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 8, 19, hour, 0, 0).unwrap()
    }

    fn summary(id: u128) -> PaperSummary {
        let paper_id = Uuid::from_u128(id);
        PaperSummary {
            paper_id,
            arxiv_id: format!("2401.{id:05}v1"),
            title: format!("Paper {id}"),
            abstract_text: "Abstract".into(),
            authors: vec!["Ada Reader".into()],
            primary_category: "cs.AI".into(),
            categories: vec!["cs.AI".into()],
            published_at: time(9),
            updated_at: time(9),
            abs_url: Url::parse(&format!("https://arxiv.org/abs/2401.{id:05}v1")).unwrap(),
            pdf_url: Url::parse(&format!("https://arxiv.org/pdf/2401.{id:05}v1")).unwrap(),
            capabilities: Capabilities::metadata_only(),
        }
    }
}
