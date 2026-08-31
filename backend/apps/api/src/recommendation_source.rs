use std::{
    collections::{BTreeMap, BTreeSet},
    time::{Duration as StdDuration, Instant},
};

use async_trait::async_trait;
use chrono::Duration;
use db::{
    ClaimedRecommendationGeneration, RecommendationBatchBlockOutcome,
    RecommendationBatchBlockRequest, RecommendationBatchPersistOutcome,
    RecommendationBatchPersistRequest, RecommendationBatchRepository,
    RecommendationBatchServeOutcome, RecommendationBatchServeRequest,
    RecommendationGenerationEnqueue, RecommendationGenerationEnqueueOutcome,
    RecommendationGenerationJobState, RecommendationGenerationRepository,
    RecommendationGenerationRetryOutcome, StoredRecommendationBatchStatus,
};
use observability::{
    RecommendationBatchServeClass as BatchServeMetricClass,
    RecommendationBatchServeOutcome as BatchServeMetricOutcome,
    RecommendationGeneratorClass as GeneratorMetricClass,
    RecommendationGeneratorOutcome as GeneratorMetricOutcome,
    RecommendationGeneratorRole as GeneratorMetricRole, RecommendationModeClass as ModeMetricClass,
    RecommendationSourceClass, record_recommendation_batch_completion,
    record_recommendation_batch_serve, record_recommendation_generator,
    record_recommendation_source_invocation,
};
use reading_feed::{
    FeedItemSource, RecommendationError, RecommendationMetadata,
    RecommendationMode as FeedRecommendationMode, RecommendationRequest, RecommendationResultItem,
    RecommendationResultPage, RecommendationSource,
};
use recommendations::{
    CandidateDocument, DiscoveryProfileSnapshot, MetadataEmbeddingInput, ProvenEmptyQueueBinding,
    RECOMMENDATION_ALGORITHM_VERSION_V1, RecommendationBatchBuildRequest,
    RecommendationGeneratorClass, RecommendationGeneratorObserver, RecommendationGeneratorOutcome,
    RecommendationGeneratorRole, RecommendationGeneratorRun, RecommendationMode, RerankPolicy,
    ScoringPolicy, build_recommendation_batch, metadata_embedding_v1,
    summarize_ranking_composition,
};
use research_profiles::{
    DiscoveryMode, InterestGroup, ProfileSettings, ResearchProfileService, ResearchProfileSnapshot,
};
use sha2::{Digest as _, Sha256};
use tracing::warn;
use uuid::Uuid;

/// Application adapter below `ReadingFeedService`'s queue gate. It receives
/// only candidates selected by the same snapshot that proved emptiness, then
/// persists and serves a batch through a second serialized revision check.
#[derive(Clone)]
pub(crate) struct BatchRecommendationSource {
    batches: RecommendationBatchRepository,
    generation: RecommendationGenerationRepository,
    profiles: Option<ResearchProfileService>,
    policy: BatchSourcePolicy,
}

#[derive(Clone, Copy)]
enum BatchSourcePolicy {
    Configured,
    RecentOnly,
}

struct PreparedRecommendation {
    context: RecommendationContext,
    selected_mode: RecommendationMode,
    paper_ids: Vec<domain::PaperId>,
    feedback_revision: i64,
    candidate_history: BTreeMap<domain::PaperId, recommendations::RecommendationCandidateHistory>,
    saved_search_revision_digest: Option<[u8; 32]>,
    seed: u64,
    query_key: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExistingBatchResolution {
    Existing(Uuid),
    Miss,
    Blocked,
    Superseded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RecommendationGenerationRunOutcome {
    Idle,
    Completed,
    Superseded,
    Retrying,
    Failed,
    Unavailable,
}

struct GeneratorMetricsObserver;

static GENERATOR_METRICS_OBSERVER: GeneratorMetricsObserver = GeneratorMetricsObserver;

impl RecommendationGeneratorObserver for GeneratorMetricsObserver {
    fn record(&self, run: RecommendationGeneratorRun) {
        record_recommendation_generator(
            generator_metric_class(run.generator),
            generator_metric_role(run.role),
            generator_metric_outcome(run.outcome),
            run.duration,
            u64::try_from(run.candidate_count).unwrap_or(u64::MAX),
        );
    }
}

const fn generator_metric_class(class: RecommendationGeneratorClass) -> GeneratorMetricClass {
    match class {
        RecommendationGeneratorClass::Recent => GeneratorMetricClass::Recent,
        RecommendationGeneratorClass::Following => GeneratorMetricClass::Following,
        RecommendationGeneratorClass::Author => GeneratorMetricClass::Author,
        RecommendationGeneratorClass::Affinity => GeneratorMetricClass::Affinity,
        RecommendationGeneratorClass::Semantic => GeneratorMetricClass::Semantic,
        RecommendationGeneratorClass::Citation => GeneratorMetricClass::Citation,
        RecommendationGeneratorClass::Exploration => GeneratorMetricClass::Exploration,
    }
}

const fn generator_metric_role(role: RecommendationGeneratorRole) -> GeneratorMetricRole {
    match role {
        RecommendationGeneratorRole::Primary => GeneratorMetricRole::Primary,
        RecommendationGeneratorRole::Fallback => GeneratorMetricRole::Fallback,
    }
}

const fn generator_metric_outcome(
    outcome: RecommendationGeneratorOutcome,
) -> GeneratorMetricOutcome {
    match outcome {
        RecommendationGeneratorOutcome::Success => GeneratorMetricOutcome::Success,
        RecommendationGeneratorOutcome::Failure => GeneratorMetricOutcome::Failure,
        RecommendationGeneratorOutcome::Timeout => GeneratorMetricOutcome::Timeout,
    }
}

impl BatchSourcePolicy {
    const fn explanation_available(self) -> bool {
        matches!(self, Self::Configured)
    }
}

impl BatchRecommendationSource {
    pub(crate) fn new(
        batches: RecommendationBatchRepository,
        profiles: Option<ResearchProfileService>,
    ) -> Self {
        let generation = RecommendationGenerationRepository::new(batches.pool().clone());
        Self {
            batches,
            generation,
            profiles,
            policy: BatchSourcePolicy::Configured,
        }
    }

    /// Deterministic metadata-only fallback used while enhanced recommendation
    /// modes are dark. It still persists and serves an authority-bound Recent
    /// batch so a save racing the initial feed snapshot fails closed.
    pub(crate) fn recent_only(batches: RecommendationBatchRepository) -> Self {
        let generation = RecommendationGenerationRepository::new(batches.pool().clone());
        Self {
            batches,
            generation,
            profiles: None,
            policy: BatchSourcePolicy::RecentOnly,
        }
    }

    async fn profile_context(
        &self,
        user_id: domain::AuthenticatedUserId,
        limit: u32,
    ) -> Result<RecommendationContext, RecommendationError> {
        let max_items = usize::try_from(limit).unwrap_or(usize::MAX);
        let Some(service) = &self.profiles else {
            return Ok(fallback_context(max_items));
        };
        let snapshot = match service.get(user_id).await {
            Ok(snapshot) => snapshot,
            Err(_error_value) => {
                warn!(
                    error.kind = "recommendation_profile_unavailable",
                    "recommendation profile was unavailable; using deterministic defaults"
                );
                return Ok(fallback_context(max_items));
            }
        };
        let Some((rerank_policy, scoring_policy)) = ranking_policies(&snapshot.settings, max_items)
        else {
            warn!(
                error.kind = "recommendation_profile_invalid",
                "recommendation profile policy was invalid; using deterministic defaults"
            );
            return Ok(fallback_context(max_items));
        };
        let mut profile = map_profile(&snapshot);
        if profile.personalization_enabled {
            profile.historical_seeds = self
                .batches
                .historical_seeds(user_id, 50)
                .await
                .map_err(recommendation_unavailable)?;
        }
        Ok(RecommendationContext {
            profile_revision: Some(snapshot.profile_revision),
            profile,
            rerank_policy,
            scoring_policy,
        })
    }

    async fn candidate_documents(
        &self,
        mode: RecommendationMode,
        papers: &[domain::PaperSummary],
    ) -> Result<(Vec<domain::PaperId>, Vec<CandidateDocument>), RecommendationError> {
        let paper_ids = papers
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>();
        let mut citation_neighbors = if mode == RecommendationMode::ForYou {
            self.batches
                .citation_neighbors(&paper_ids)
                .await
                .map_err(recommendation_unavailable)?
        } else {
            std::collections::BTreeMap::new()
        };
        let documents = papers
            .iter()
            .cloned()
            .map(|paper| {
                let neighbors = citation_neighbors
                    .remove(&paper.paper_id)
                    .unwrap_or_default();
                candidate_document(paper, neighbors)
            })
            .collect();
        Ok((paper_ids, documents))
    }

    async fn prepare(
        &self,
        request: &RecommendationRequest,
    ) -> Result<PreparedRecommendation, RecommendationError> {
        let max_items = usize::try_from(request.limit).unwrap_or(usize::MAX);
        let mut context = match self.policy {
            BatchSourcePolicy::Configured => {
                self.profile_context(request.user_id, request.limit).await?
            }
            BatchSourcePolicy::RecentOnly => fallback_context(max_items),
        };
        let paper_ids = request
            .candidates
            .items
            .iter()
            .map(|paper| paper.paper_id)
            .collect::<Vec<_>>();
        let saved_search_context = if matches!(self.policy, BatchSourcePolicy::Configured)
            && request.recommendation_mode == FeedRecommendationMode::Following
        {
            Some(
                self.generation
                    .saved_search_context(request.user_id, &paper_ids)
                    .await
                    .map_err(recommendation_unavailable)?,
            )
        } else {
            None
        };
        if let Some(saved_search_context) = &saved_search_context {
            context.profile.saved_query_matches = saved_search_context.matches.clone();
        }
        let selected_mode = match self.policy {
            BatchSourcePolicy::Configured => {
                selected_mode(request.recommendation_mode, &context.profile)
            }
            BatchSourcePolicy::RecentOnly => RecommendationMode::Recent,
        };
        let saved_search_revision_digest = (selected_mode == RecommendationMode::Following)
            .then(|| saved_search_context.map(|context| context.revision_digest))
            .flatten();
        let feedback = self
            .batches
            .feedback_context(request.user_id, &paper_ids, request.now)
            .await
            .map_err(recommendation_unavailable)?;
        let feedback_revision = feedback.revision;
        let candidate_history = candidate_history_for_mode(
            self.policy,
            selected_mode,
            context.profile.personalization_enabled,
            feedback.history,
        );
        let seed = batch_seed(
            request,
            context.profile_revision,
            ranking_feedback_revision(selected_mode, feedback_revision),
            selected_mode,
            saved_search_revision_digest.as_ref(),
        );
        let query_key = query_key(
            selected_mode,
            request.category.as_deref(),
            request.position,
            request.limit,
            saved_search_revision_digest.as_ref(),
        );
        Ok(PreparedRecommendation {
            context,
            selected_mode,
            paper_ids,
            feedback_revision,
            candidate_history,
            saved_search_revision_digest,
            seed,
            query_key,
        })
    }

    async fn existing_or_prove_empty(
        &self,
        request: &RecommendationRequest,
        prepared: &PreparedRecommendation,
    ) -> Result<ExistingBatchResolution, RecommendationError> {
        let now = request.now;
        let outcome = self
            .batches
            .record_blocked_by_queue(RecommendationBatchBlockRequest {
                user_id: request.user_id,
                batch_id: Uuid::now_v7(),
                mode: prepared.selected_mode,
                query_key: &prepared.query_key,
                local_date: now.date_naive(),
                profile_revision: prepared.context.profile_revision,
                feedback_revision: prepared.feedback_revision,
                saved_search_revision_digest: prepared.saved_search_revision_digest,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: &prepared.context.scoring_policy.version,
                seed: prepared.seed,
                created_at: now,
                expires_at: now + Duration::hours(24),
            })
            .await
            .map_err(recommendation_unavailable)?;
        match outcome {
            RecommendationBatchBlockOutcome::QueueProvenEmpty { library_revision }
                if library_revision == request.library_revision =>
            {
                Ok(ExistingBatchResolution::Miss)
            }
            RecommendationBatchBlockOutcome::Replayed {
                batch_id,
                status:
                    StoredRecommendationBatchStatus::Ready | StoredRecommendationBatchStatus::Served,
            } => Ok(ExistingBatchResolution::Existing(batch_id)),
            RecommendationBatchBlockOutcome::BlockedByQueue { .. }
            | RecommendationBatchBlockOutcome::Replayed {
                status: StoredRecommendationBatchStatus::BlockedByQueue,
                ..
            } => Ok(ExistingBatchResolution::Blocked),
            RecommendationBatchBlockOutcome::QueueProvenEmpty { .. }
            | RecommendationBatchBlockOutcome::ContextChanged
            | RecommendationBatchBlockOutcome::Replayed {
                status: StoredRecommendationBatchStatus::Superseded,
                ..
            } => Ok(ExistingBatchResolution::Superseded),
            RecommendationBatchBlockOutcome::Replayed { .. } => {
                Err(RecommendationError::Unavailable)
            }
        }
    }

    async fn serve_batch(
        &self,
        request: &RecommendationRequest,
        mode: RecommendationMode,
        batch_id: Uuid,
        class: BatchServeMetricClass,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        let served = match self
            .batches
            .serve_ready(RecommendationBatchServeRequest {
                user_id: request.user_id,
                batch_id,
                mode,
                library_revision: request.library_revision,
                limit: request.limit,
                now: request.now,
            })
            .await
        {
            Ok(served) => served,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(mode),
                    BatchServeMetricOutcome::Unavailable,
                    class,
                    None,
                    0,
                );
                return Err(recommendation_unavailable(error));
            }
        };
        match &served {
            RecommendationBatchServeOutcome::Found {
                created_at, items, ..
            } => record_batch_serve_attempt(
                request.recommendation_mode,
                Some(mode),
                found_batch_metric_outcome(items.len()),
                class,
                Some(bounded_batch_age(request.now, *created_at)),
                u64::try_from(items.len()).unwrap_or(u64::MAX),
            ),
            RecommendationBatchServeOutcome::AuthorityChanged { active_count, .. } => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(mode),
                    if *active_count > 0 {
                        BatchServeMetricOutcome::Blocked
                    } else {
                        BatchServeMetricOutcome::Superseded
                    },
                    class,
                    None,
                    0,
                );
            }
            RecommendationBatchServeOutcome::NotFound => record_batch_serve_attempt(
                request.recommendation_mode,
                Some(mode),
                BatchServeMetricOutcome::Miss,
                class,
                None,
                0,
            ),
        }
        map_served_page(served, self.policy.explanation_available())
    }

    async fn generate_inline(
        &self,
        request: &RecommendationRequest,
        mut prepared: PreparedRecommendation,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        let effective_mode = prepared.selected_mode;
        let (_, documents) = match self
            .candidate_documents(prepared.selected_mode, &request.candidates.items)
            .await
        {
            Ok(documents) => documents,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(effective_mode),
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::InlineGeneration,
                    None,
                    0,
                );
                return Err(error);
            }
        };
        prepared.context.rerank_policy.batch_seed = prepared.seed;
        let batch = match build_batch(
            prepared.selected_mode,
            request.library_revision,
            prepared.context,
            prepared.feedback_revision,
            &documents,
            &prepared.candidate_history,
            request.now,
            request.limit,
        )
        .await
        {
            Ok(batch) => batch,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(effective_mode),
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::InlineGeneration,
                    None,
                    0,
                );
                return Err(error);
            }
        };
        let proposed_batch_id = Uuid::now_v7();
        let persisted = match self
            .batches
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: request.user_id,
                batch_id: proposed_batch_id,
                query_key: &prepared.query_key,
                local_date: request.now.date_naive(),
                created_at: request.now,
                expires_at: request.now + Duration::hours(24),
                next_position: request.candidates.next_position,
                saved_search_revision_digest: prepared.saved_search_revision_digest,
                batch: &batch,
            })
            .await
        {
            Ok(persisted) => persisted,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(effective_mode),
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::InlineGeneration,
                    None,
                    0,
                );
                return Err(recommendation_unavailable(error));
            }
        };
        let batch_id = match ready_batch_id(persisted) {
            Ok(batch_id) => batch_id,
            Err((error, outcome)) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(effective_mode),
                    outcome,
                    BatchServeMetricClass::InlineGeneration,
                    None,
                    0,
                );
                return Err(error);
            }
        };
        self.serve_batch(
            request,
            prepared.selected_mode,
            batch_id,
            BatchServeMetricClass::InlineGeneration,
        )
        .await
    }

    async fn enqueue_generation(
        &self,
        request: &RecommendationRequest,
        prepared: &PreparedRecommendation,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        let outcome = match self
            .generation
            .enqueue(RecommendationGenerationEnqueue {
                user_id: request.user_id,
                job_id: Uuid::now_v7(),
                batch_id: Uuid::now_v7(),
                mode: prepared.selected_mode,
                query_key: &prepared.query_key,
                local_date: request.now.date_naive(),
                profile_revision: prepared.context.profile_revision,
                feedback_revision: prepared.feedback_revision,
                library_revision: request.library_revision,
                algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
                policy_version: &prepared.context.scoring_policy.version,
                seed: prepared.seed,
                page_limit: request.limit,
                candidate_paper_ids: &prepared.paper_ids,
                saved_search_revision_digest: prepared.saved_search_revision_digest,
                next_position: request.candidates.next_position,
                max_attempts: 3,
                now: request.now,
            })
            .await
        {
            Ok(outcome) => outcome,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(prepared.selected_mode),
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::GenerationQueue,
                    None,
                    0,
                );
                return Err(recommendation_unavailable(error));
            }
        };
        match generation_enqueue_resolution(outcome) {
            Ok(batch_id) => {
                self.serve_batch(
                    request,
                    prepared.selected_mode,
                    batch_id,
                    BatchServeMetricClass::GenerationQueue,
                )
                .await
            }
            Err((error, outcome)) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(prepared.selected_mode),
                    outcome,
                    BatchServeMetricClass::GenerationQueue,
                    None,
                    0,
                );
                Err(error)
            }
        }
    }

    pub(crate) async fn run_generation_once(
        &self,
        worker_id: &str,
        now: chrono::DateTime<chrono::Utc>,
    ) -> RecommendationGenerationRunOutcome {
        if !matches!(self.policy, BatchSourcePolicy::Configured) {
            return RecommendationGenerationRunOutcome::Idle;
        }
        let claimed = match self
            .generation
            .claim(worker_id, now, StdDuration::from_secs(2 * 60))
            .await
        {
            Ok(Some(claimed)) => claimed,
            Ok(None) => return RecommendationGenerationRunOutcome::Idle,
            Err(_error_value) => return RecommendationGenerationRunOutcome::Unavailable,
        };
        let generation = self.process_generation(&claimed, now).await;
        // Lease checks must use wall clock time after generation. Reusing the
        // claim timestamp would let an expired owner mutate a reclaimed job.
        let completion_time = chrono::Utc::now();
        match generation {
            Ok(state) => {
                if self
                    .generation
                    .complete(claimed.job_id, worker_id, completion_time, state)
                    .await
                    .is_err()
                {
                    return RecommendationGenerationRunOutcome::Unavailable;
                }
                if state == RecommendationGenerationJobState::Completed {
                    RecommendationGenerationRunOutcome::Completed
                } else {
                    RecommendationGenerationRunOutcome::Superseded
                }
            }
            Err(RecommendationError::RevisionStale) => {
                if self
                    .generation
                    .complete(
                        claimed.job_id,
                        worker_id,
                        completion_time,
                        RecommendationGenerationJobState::Superseded,
                    )
                    .await
                    .is_ok()
                {
                    RecommendationGenerationRunOutcome::Superseded
                } else {
                    RecommendationGenerationRunOutcome::Unavailable
                }
            }
            Err(RecommendationError::Unavailable) => {
                let retry_at = completion_time + retry_delay(claimed.attempt);
                match self
                    .generation
                    .retry(
                        claimed.job_id,
                        worker_id,
                        completion_time,
                        retry_at,
                        "generation_unavailable",
                    )
                    .await
                {
                    Ok(RecommendationGenerationRetryOutcome::Queued { .. }) => {
                        RecommendationGenerationRunOutcome::Retrying
                    }
                    Ok(RecommendationGenerationRetryOutcome::Failed { .. }) => {
                        RecommendationGenerationRunOutcome::Failed
                    }
                    Err(_error_value) => RecommendationGenerationRunOutcome::Unavailable,
                }
            }
        }
    }

    #[allow(clippy::too_many_lines)] // Keep job authority, ranking, publication, and closed outcome handling in one ordered worker path.
    async fn process_generation(
        &self,
        claimed: &ClaimedRecommendationGeneration,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<RecommendationGenerationJobState, RecommendationError> {
        let papers = self
            .generation
            .candidates(claimed.job_id)
            .await
            .map_err(recommendation_unavailable)?;
        if papers.len() != usize::try_from(claimed.candidate_count).unwrap_or(usize::MAX) {
            return Err(RecommendationError::Unavailable);
        }
        let mut context = self
            .profile_context(claimed.user_id, claimed.page_limit)
            .await?;
        if claimed.profile_revision != context.profile_revision {
            return Err(RecommendationError::RevisionStale);
        }
        if claimed.mode == RecommendationMode::Following {
            let saved = self
                .generation
                .saved_search_context(
                    claimed.user_id,
                    &papers
                        .iter()
                        .map(|paper| paper.paper_id)
                        .collect::<Vec<_>>(),
                )
                .await
                .map_err(recommendation_unavailable)?;
            if Some(saved.revision_digest) != claimed.saved_search_revision_digest {
                return Err(RecommendationError::RevisionStale);
            }
            context.profile.saved_query_matches = saved.matches;
        }
        let feedback = self
            .batches
            .feedback_context(
                claimed.user_id,
                &papers
                    .iter()
                    .map(|paper| paper.paper_id)
                    .collect::<Vec<_>>(),
                now,
            )
            .await
            .map_err(recommendation_unavailable)?;
        if feedback.revision != claimed.feedback_revision {
            return Err(RecommendationError::RevisionStale);
        }
        context.rerank_policy.batch_seed = claimed.seed;
        let (_, documents) = self.candidate_documents(claimed.mode, &papers).await?;
        let candidate_history = candidate_history_for_mode(
            self.policy,
            claimed.mode,
            context.profile.personalization_enabled,
            feedback.history,
        );
        let batch = build_batch(
            claimed.mode,
            claimed.library_revision,
            context,
            feedback.revision,
            &documents,
            &candidate_history,
            now,
            claimed.page_limit,
        )
        .await?;
        if batch.algorithm_version != claimed.algorithm_version
            || batch.policy_version != claimed.policy_version
        {
            return Err(RecommendationError::RevisionStale);
        }
        let outcome = self
            .batches
            .persist_ready(RecommendationBatchPersistRequest {
                user_id: claimed.user_id,
                batch_id: claimed.batch_id,
                query_key: &claimed.query_key,
                local_date: claimed.local_date,
                created_at: now,
                expires_at: now + Duration::hours(24),
                next_position: claimed.next_position,
                saved_search_revision_digest: claimed.saved_search_revision_digest,
                batch: &batch,
            })
            .await
            .map_err(recommendation_unavailable)?;
        match outcome {
            RecommendationBatchPersistOutcome::Ready { .. }
            | RecommendationBatchPersistOutcome::Replayed {
                status:
                    StoredRecommendationBatchStatus::Ready | StoredRecommendationBatchStatus::Served,
                ..
            } => Ok(RecommendationGenerationJobState::Completed),
            RecommendationBatchPersistOutcome::Superseded { .. }
            | RecommendationBatchPersistOutcome::Replayed {
                status: StoredRecommendationBatchStatus::Superseded,
                ..
            } => Ok(RecommendationGenerationJobState::Superseded),
            RecommendationBatchPersistOutcome::Replayed { .. } => {
                Err(RecommendationError::Unavailable)
            }
        }
    }
}

#[async_trait]
impl RecommendationSource for BatchRecommendationSource {
    #[tracing::instrument(name = "reading_feed.recommendation_page", skip_all)]
    async fn page(
        &self,
        request: RecommendationRequest,
    ) -> Result<RecommendationResultPage, RecommendationError> {
        record_recommendation_source_invocation(match self.policy {
            BatchSourcePolicy::Configured => RecommendationSourceClass::Configured,
            BatchSourcePolicy::RecentOnly => RecommendationSourceClass::RecentFallback,
        });
        let prepared = match self.prepare(&request).await {
            Ok(prepared) => prepared,
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    None,
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::PreServe,
                    None,
                    0,
                );
                return Err(error);
            }
        };
        match self.existing_or_prove_empty(&request, &prepared).await {
            Ok(ExistingBatchResolution::Existing(batch_id)) => {
                return self
                    .serve_batch(
                        &request,
                        prepared.selected_mode,
                        batch_id,
                        BatchServeMetricClass::ExistingBatch,
                    )
                    .await;
            }
            Ok(ExistingBatchResolution::Miss) => {}
            Ok(ExistingBatchResolution::Blocked) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(prepared.selected_mode),
                    BatchServeMetricOutcome::Blocked,
                    BatchServeMetricClass::PreServe,
                    None,
                    0,
                );
                return Err(RecommendationError::RevisionStale);
            }
            Ok(ExistingBatchResolution::Superseded) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(prepared.selected_mode),
                    BatchServeMetricOutcome::Superseded,
                    BatchServeMetricClass::PreServe,
                    None,
                    0,
                );
                return Err(RecommendationError::RevisionStale);
            }
            Err(error) => {
                record_batch_serve_attempt(
                    request.recommendation_mode,
                    Some(prepared.selected_mode),
                    BatchServeMetricOutcome::Unavailable,
                    BatchServeMetricClass::PreServe,
                    None,
                    0,
                );
                return Err(error);
            }
        }
        match self.policy {
            BatchSourcePolicy::Configured => self.enqueue_generation(&request, &prepared).await,
            BatchSourcePolicy::RecentOnly => self.generate_inline(&request, prepared).await,
        }
    }
}

fn recommendation_unavailable<T>(_error: T) -> RecommendationError {
    RecommendationError::Unavailable
}

#[allow(clippy::too_many_arguments)] // Explicit authority and ranking inputs keep generation free of hidden mutable state.
async fn build_batch(
    mode: RecommendationMode,
    library_revision: i64,
    context: RecommendationContext,
    feedback_revision: i64,
    documents: &[CandidateDocument],
    candidate_history: &BTreeMap<domain::PaperId, recommendations::RecommendationCandidateHistory>,
    now: chrono::DateTime<chrono::Utc>,
    limit: u32,
) -> Result<recommendations::BuiltRecommendationBatch, RecommendationError> {
    let queue = ProvenEmptyQueueBinding::from_decision(library_revision, 0, true)
        .map_err(|_| RecommendationError::RevisionStale)?;
    let started = Instant::now();
    let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
        mode,
        queue,
        profile_revision: context.profile_revision,
        feedback_revision,
        profile: &context.profile,
        documents,
        candidate_history,
        now,
        candidate_limit: usize::try_from(limit).unwrap_or(usize::MAX),
        fanout_policy: recommendations::CandidateFanoutPolicy::default(),
        generator_observer: Some(&GENERATOR_METRICS_OBSERVER),
        rerank_policy: context.rerank_policy,
        scoring_policy: context.scoring_policy,
    })
    .await
    .map_err(recommendation_unavailable)?;
    let composition =
        summarize_ranking_composition(batch.candidates.iter().map(|candidate| &candidate.scored));
    record_recommendation_batch_completion(
        batch_metric_mode(mode),
        started.elapsed(),
        u64::try_from(composition.candidate_count).unwrap_or(u64::MAX),
        composition.max_author_concentration,
        composition.max_category_concentration,
        composition.max_topic_concentration,
    );
    Ok(batch)
}

fn ready_batch_id(
    outcome: RecommendationBatchPersistOutcome,
) -> Result<Uuid, (RecommendationError, BatchServeMetricOutcome)> {
    match outcome {
        RecommendationBatchPersistOutcome::Ready { batch_id, .. }
        | RecommendationBatchPersistOutcome::Replayed {
            batch_id,
            status: StoredRecommendationBatchStatus::Ready | StoredRecommendationBatchStatus::Served,
        } => Ok(batch_id),
        RecommendationBatchPersistOutcome::Superseded {
            active_count: 1.., ..
        } => Err((
            RecommendationError::RevisionStale,
            BatchServeMetricOutcome::Blocked,
        )),
        RecommendationBatchPersistOutcome::Superseded { .. }
        | RecommendationBatchPersistOutcome::Replayed {
            status: StoredRecommendationBatchStatus::Superseded,
            ..
        } => Err((
            RecommendationError::RevisionStale,
            BatchServeMetricOutcome::Superseded,
        )),
        RecommendationBatchPersistOutcome::Replayed { .. } => Err((
            RecommendationError::Unavailable,
            BatchServeMetricOutcome::Unavailable,
        )),
    }
}

fn generation_enqueue_resolution(
    outcome: RecommendationGenerationEnqueueOutcome,
) -> Result<Uuid, (RecommendationError, BatchServeMetricOutcome)> {
    match outcome {
        RecommendationGenerationEnqueueOutcome::Replayed {
            batch_id,
            state: RecommendationGenerationJobState::Completed,
            ..
        } => Ok(batch_id),
        RecommendationGenerationEnqueueOutcome::AuthorityChanged {
            active_count: 1.., ..
        } => Err((
            RecommendationError::RevisionStale,
            BatchServeMetricOutcome::Blocked,
        )),
        RecommendationGenerationEnqueueOutcome::AuthorityChanged { .. }
        | RecommendationGenerationEnqueueOutcome::ContextChanged
        | RecommendationGenerationEnqueueOutcome::Replayed {
            state: RecommendationGenerationJobState::Superseded,
            ..
        } => Err((
            RecommendationError::RevisionStale,
            BatchServeMetricOutcome::Superseded,
        )),
        RecommendationGenerationEnqueueOutcome::Queued { .. }
        | RecommendationGenerationEnqueueOutcome::Replayed {
            state:
                RecommendationGenerationJobState::Queued | RecommendationGenerationJobState::Running,
            ..
        } => Err((
            RecommendationError::Unavailable,
            BatchServeMetricOutcome::Miss,
        )),
        RecommendationGenerationEnqueueOutcome::Replayed {
            state: RecommendationGenerationJobState::Failed,
            ..
        } => Err((
            RecommendationError::Unavailable,
            BatchServeMetricOutcome::Unavailable,
        )),
    }
}

fn retry_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(6);
    Duration::seconds(i64::from(5_u32.saturating_mul(1_u32 << exponent).min(300)))
}

struct RecommendationContext {
    profile_revision: Option<i64>,
    profile: DiscoveryProfileSnapshot,
    rerank_policy: RerankPolicy,
    scoring_policy: ScoringPolicy,
}

fn fallback_context(max_items: usize) -> RecommendationContext {
    let (rerank_policy, scoring_policy) = fixed_ranking_policies(max_items);
    RecommendationContext {
        profile_revision: None,
        profile: default_profile(),
        rerank_policy,
        scoring_policy,
    }
}

fn fixed_ranking_policies(max_items: usize) -> (RerankPolicy, ScoringPolicy) {
    let mut rerank_policy = RerankPolicy {
        max_items,
        ..RerankPolicy::default()
    };
    rerank_policy
        .exploration_positions
        .retain(|position| *position < max_items);
    (rerank_policy, ScoringPolicy::default())
}

fn ranking_policies(
    settings: &ProfileSettings,
    max_items: usize,
) -> Option<(RerankPolicy, ScoringPolicy)> {
    if !(1..=100).contains(&max_items)
        || [
            settings.recency_weight,
            settings.novelty_weight,
            settings.diversity_weight,
        ]
        .into_iter()
        .any(|weight| !weight.is_finite() || !(0.0..=1.0).contains(&weight))
    {
        return None;
    }
    let rerank_policy = RerankPolicy {
        max_items,
        diversity_penalty: settings.diversity_weight,
        exploration_positions: exploration_positions(settings.discovery_mode, max_items),
        ..RerankPolicy::default()
    };
    let scoring_policy = ScoringPolicy {
        recency: settings.recency_weight,
        novelty: settings.novelty_weight,
        ..ScoringPolicy::default()
    };
    Some((rerank_policy, scoring_policy))
}

fn exploration_positions(mode: DiscoveryMode, max_items: usize) -> BTreeSet<usize> {
    match mode {
        DiscoveryMode::Focused => BTreeSet::new(),
        DiscoveryMode::Balanced => RerankPolicy::default()
            .exploration_positions
            .into_iter()
            .filter(|position| *position < max_items)
            .collect(),
        DiscoveryMode::Exploratory => (2..max_items).step_by(3).collect(),
    }
}

fn candidate_document(
    paper: domain::PaperSummary,
    citation_neighbors: BTreeSet<domain::PaperId>,
) -> CandidateDocument {
    let topics = paper.categories.iter().cloned().collect();
    let embedding = metadata_embedding_v1(MetadataEmbeddingInput {
        title: &paper.title,
        abstract_text: &paper.abstract_text,
        categories: &paper.categories,
    });
    CandidateDocument {
        paper,
        topics,
        embedding,
        citation_neighbors,
        metadata_completeness: 1.0,
    }
}

fn default_profile() -> DiscoveryProfileSnapshot {
    DiscoveryProfileSnapshot {
        personalization_enabled: false,
        categories: BTreeSet::new(),
        topics: BTreeSet::new(),
        authors: BTreeSet::new(),
        saved_query_matches: BTreeMap::new(),
        feedback_categories: BTreeSet::new(),
        inferred_categories: BTreeSet::new(),
        historical_seeds: Vec::new(),
    }
}

fn map_profile(snapshot: &ResearchProfileSnapshot) -> DiscoveryProfileSnapshot {
    let mut profile = default_profile();
    profile.personalization_enabled = snapshot.settings.personalization_enabled;
    collect_group(&snapshot.interests.explicit, &mut profile);
    if profile.personalization_enabled {
        profile.feedback_categories.extend(
            snapshot
                .interests
                .feedback
                .categories
                .iter()
                .map(|value| value.category.clone()),
        );
        profile.inferred_categories.extend(
            snapshot
                .interests
                .inferred
                .categories
                .iter()
                .map(|value| value.category.clone()),
        );
    }
    profile
}

fn collect_group(group: &InterestGroup, profile: &mut DiscoveryProfileSnapshot) {
    profile
        .categories
        .extend(group.categories.iter().map(|value| value.category.clone()));
    profile.topics.extend(
        group
            .topics
            .iter()
            .filter(|value| value.polarity == research_profiles::TopicPolarity::Positive)
            .map(|value| value.topic.normalized_label.clone()),
    );
    profile
        .authors
        .extend(group.authors.iter().map(|value| value.display_name.clone()));
}

fn selected_mode(
    requested: FeedRecommendationMode,
    profile: &DiscoveryProfileSnapshot,
) -> RecommendationMode {
    match requested {
        FeedRecommendationMode::Recent => RecommendationMode::Recent,
        FeedRecommendationMode::Explore => RecommendationMode::Explore,
        FeedRecommendationMode::Following
            if !(profile.categories.is_empty()
                && profile.topics.is_empty()
                && profile.authors.is_empty()
                && profile.saved_query_matches.is_empty()) =>
        {
            RecommendationMode::Following
        }
        FeedRecommendationMode::ForYou if profile.personalization_enabled => {
            RecommendationMode::ForYou
        }
        FeedRecommendationMode::Following | FeedRecommendationMode::ForYou => {
            RecommendationMode::Recent
        }
    }
}

fn candidate_history_for_mode(
    policy: BatchSourcePolicy,
    mode: RecommendationMode,
    personalization_enabled: bool,
    history: BTreeMap<domain::PaperId, recommendations::RecommendationCandidateHistory>,
) -> BTreeMap<domain::PaperId, recommendations::RecommendationCandidateHistory> {
    if matches!(policy, BatchSourcePolicy::Configured)
        && mode == RecommendationMode::ForYou
        && personalization_enabled
    {
        history
    } else {
        BTreeMap::new()
    }
}

const fn ranking_feedback_revision(mode: RecommendationMode, feedback_revision: i64) -> i64 {
    if matches!(mode, RecommendationMode::ForYou) {
        feedback_revision
    } else {
        0
    }
}

fn batch_seed(
    request: &RecommendationRequest,
    profile_revision: Option<i64>,
    feedback_revision: i64,
    mode: RecommendationMode,
    saved_search_revision_digest: Option<&[u8; 32]>,
) -> u64 {
    let mut hash = Sha256::new();
    hash.update(request.user_id.as_uuid().as_bytes());
    hash.update(request.library_revision.to_be_bytes());
    hash.update(profile_revision.unwrap_or(-1).to_be_bytes());
    hash.update(feedback_revision.to_be_bytes());
    hash.update(mode.as_str().as_bytes());
    if let Some(category) = &request.category {
        hash.update(category.as_bytes());
    }
    if let Some(position) = request.position {
        hash.update(position.published_at.timestamp_micros().to_be_bytes());
        hash.update(position.paper_id.as_bytes());
    }
    if let Some(saved_search_revision_digest) = saved_search_revision_digest {
        hash.update(saved_search_revision_digest);
    }
    let bytes: [u8; 8] = hash.finalize()[..8]
        .try_into()
        .expect("SHA-256 always has at least eight bytes");
    u64::from_be_bytes(bytes) & i64::MAX as u64
}

fn query_key(
    mode: RecommendationMode,
    category: Option<&str>,
    position: Option<reading_feed::RecommendationPosition>,
    limit: u32,
    saved_search_revision_digest: Option<&[u8; 32]>,
) -> String {
    let mut digest = Sha256::new();
    // v3 drops behavioral history and feedback-derived tie seeds from Recent,
    // Following, and Explore. The key revision prevents a pre-deploy v2 batch
    // from being replayed under the stricter policy.
    digest.update(b"recommendation_query_key_v3");
    digest.update(mode.as_str().as_bytes());
    digest.update(limit.to_be_bytes());
    if let Some(category) = category {
        digest.update(category.as_bytes());
    }
    if let Some(position) = position {
        digest.update(position.published_at.timestamp_micros().to_be_bytes());
        digest.update(position.paper_id.as_bytes());
    }
    if let Some(saved_search_revision_digest) = saved_search_revision_digest {
        digest.update(saved_search_revision_digest);
    }
    let digest = digest.finalize();
    let mut suffix = String::with_capacity(24);
    for byte in &digest[..12] {
        use std::fmt::Write as _;
        write!(&mut suffix, "{byte:02x}").expect("writing to a String cannot fail");
    }
    format!("{}:v3:l{limit}:{suffix}", mode.as_str())
}

fn map_served_page(
    outcome: RecommendationBatchServeOutcome,
    explanation_available: bool,
) -> Result<RecommendationResultPage, RecommendationError> {
    match outcome {
        RecommendationBatchServeOutcome::Found {
            batch_id,
            batch_metadata,
            mode,
            items,
            next_position,
            ..
        } => Ok(RecommendationResultPage {
            batch_id: Some(batch_id),
            batch_metadata: Some(batch_metadata),
            items: items
                .into_iter()
                .map(|item| {
                    let reason_label = item
                        .reason_codes
                        .first()
                        .map_or("Why this paper", |code| code.title())
                        .to_owned();
                    RecommendationResultItem {
                        paper: item.paper,
                        source: feed_source(mode),
                        recommendation: Some(RecommendationMetadata {
                            mode: feed_mode(mode),
                            reason_codes: item.reason_codes,
                            reason_label,
                            explanation_available,
                        }),
                    }
                })
                .collect(),
            next_position,
        }),
        RecommendationBatchServeOutcome::AuthorityChanged { .. } => {
            Err(RecommendationError::RevisionStale)
        }
        RecommendationBatchServeOutcome::NotFound => Err(RecommendationError::Unavailable),
    }
}

fn record_batch_serve_attempt(
    requested_mode: FeedRecommendationMode,
    effective_mode: Option<RecommendationMode>,
    outcome: BatchServeMetricOutcome,
    class: BatchServeMetricClass,
    batch_age: Option<StdDuration>,
    returned_candidates: u64,
) {
    record_recommendation_batch_serve(
        feed_metric_mode(requested_mode),
        effective_mode.map(batch_metric_mode),
        outcome,
        class,
        batch_age,
        returned_candidates,
    );
}

const fn found_batch_metric_outcome(returned_candidates: usize) -> BatchServeMetricOutcome {
    if returned_candidates == 0 {
        BatchServeMetricOutcome::NoResult
    } else {
        BatchServeMetricOutcome::Hit
    }
}

const fn feed_metric_mode(mode: FeedRecommendationMode) -> ModeMetricClass {
    match mode {
        FeedRecommendationMode::Recent => ModeMetricClass::Recent,
        FeedRecommendationMode::Following => ModeMetricClass::Following,
        FeedRecommendationMode::ForYou => ModeMetricClass::ForYou,
        FeedRecommendationMode::Explore => ModeMetricClass::Explore,
    }
}

const fn batch_metric_mode(mode: RecommendationMode) -> ModeMetricClass {
    match mode {
        RecommendationMode::Recent => ModeMetricClass::Recent,
        RecommendationMode::Following => ModeMetricClass::Following,
        RecommendationMode::ForYou => ModeMetricClass::ForYou,
        RecommendationMode::Explore => ModeMetricClass::Explore,
    }
}

fn bounded_batch_age(
    now: chrono::DateTime<chrono::Utc>,
    created_at: chrono::DateTime<chrono::Utc>,
) -> StdDuration {
    const MAX_AGE: StdDuration = StdDuration::from_secs(30 * 24 * 60 * 60);
    now.signed_duration_since(created_at)
        .to_std()
        .unwrap_or_default()
        .min(MAX_AGE)
}

const fn feed_mode(mode: RecommendationMode) -> FeedRecommendationMode {
    match mode {
        RecommendationMode::Recent => FeedRecommendationMode::Recent,
        RecommendationMode::Following => FeedRecommendationMode::Following,
        RecommendationMode::ForYou => FeedRecommendationMode::ForYou,
        RecommendationMode::Explore => FeedRecommendationMode::Explore,
    }
}

const fn feed_source(mode: RecommendationMode) -> FeedItemSource {
    match mode {
        RecommendationMode::Recent => FeedItemSource::RecentV1,
        RecommendationMode::Following => FeedItemSource::FollowingV1,
        RecommendationMode::ForYou => FeedItemSource::ForYouV1,
        RecommendationMode::Explore => FeedItemSource::ExploreV1,
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::Arc, time::Duration as StdDuration};

    use async_trait::async_trait;
    use chrono::{TimeDelta, Utc};
    use db::{Database, LibraryMutationIntent, LibraryMutationOutcome};
    use domain::{
        ArxivIdentifier, AuthenticatedUserId, Author, Capabilities, LibraryState, PaperMetadata,
        PaperSummary,
    };
    use engagement::{BriefCreateCommand, BriefMode, EngagementPolicy, EngagementService};
    use reading_feed::{
        CursorCodecError, CursorKeyEpoch, ReadingFeedCursorClaims, ReadingFeedCursorCodec,
        ReadingFeedPolicy, ReadingFeedRequest, ReadingFeedService, ReadingFeedServiceError,
        RecommendationBatchMetadata,
    };
    use research_profiles::{InterestSource, ProfileCategory, ProfileInterests, ProfileSettings};
    use tokio::sync::Notify;
    use url::Url;

    use super::*;

    #[test]
    fn unavailable_personalization_and_empty_follows_fall_back_to_recent() {
        let profile = default_profile();
        assert_eq!(
            selected_mode(FeedRecommendationMode::ForYou, &profile),
            RecommendationMode::Recent
        );
        assert_eq!(
            selected_mode(FeedRecommendationMode::Following, &profile),
            RecommendationMode::Recent
        );
        assert_eq!(
            selected_mode(FeedRecommendationMode::Explore, &profile),
            RecommendationMode::Explore
        );
    }

    #[test]
    fn behavioral_history_and_feedback_seed_affect_only_for_you() {
        let paper_id = Uuid::from_u128(7);
        let history = BTreeMap::from([(
            paper_id,
            recommendations::RecommendationCandidateHistory {
                qualified_impressions: 3,
                hidden: false,
                negative_feedback: true,
            },
        )]);

        for mode in [
            RecommendationMode::Recent,
            RecommendationMode::Following,
            RecommendationMode::Explore,
        ] {
            assert!(
                candidate_history_for_mode(
                    BatchSourcePolicy::Configured,
                    mode,
                    true,
                    history.clone()
                )
                .is_empty()
            );
            assert_eq!(ranking_feedback_revision(mode, 9), 0);
        }
        assert_eq!(
            candidate_history_for_mode(
                BatchSourcePolicy::Configured,
                RecommendationMode::ForYou,
                true,
                history.clone(),
            ),
            history
        );
        assert_eq!(ranking_feedback_revision(RecommendationMode::ForYou, 9), 9);
        assert!(
            candidate_history_for_mode(
                BatchSourcePolicy::Configured,
                RecommendationMode::ForYou,
                false,
                BTreeMap::from([(
                    paper_id,
                    recommendations::RecommendationCandidateHistory::default(),
                )]),
            )
            .is_empty()
        );
    }

    #[test]
    fn for_you_requires_explicit_personalization_and_following_requires_a_signal() {
        let mut profile = default_profile();
        profile.personalization_enabled = true;
        assert_eq!(
            selected_mode(FeedRecommendationMode::ForYou, &profile),
            RecommendationMode::ForYou
        );
        profile.categories.insert("cs.CL".to_owned());
        assert_eq!(
            selected_mode(FeedRecommendationMode::Following, &profile),
            RecommendationMode::Following
        );
    }

    #[test]
    fn source_and_mode_labels_are_closed() {
        assert!(BatchSourcePolicy::Configured.explanation_available());
        assert!(!BatchSourcePolicy::RecentOnly.explanation_available());
        for (mode, expected_source, expected_mode) in [
            (
                RecommendationMode::Recent,
                FeedItemSource::RecentV1,
                FeedRecommendationMode::Recent,
            ),
            (
                RecommendationMode::Following,
                FeedItemSource::FollowingV1,
                FeedRecommendationMode::Following,
            ),
            (
                RecommendationMode::ForYou,
                FeedItemSource::ForYouV1,
                FeedRecommendationMode::ForYou,
            ),
            (
                RecommendationMode::Explore,
                FeedItemSource::ExploreV1,
                FeedRecommendationMode::Explore,
            ),
        ] {
            assert_eq!(feed_source(mode), expected_source);
            assert_eq!(feed_mode(mode), expected_mode);
        }
        assert_ne!(
            query_key(RecommendationMode::Recent, Some("cs.AI"), None, 20, None),
            query_key(RecommendationMode::Recent, Some("cs.CL"), None, 20, None)
        );
        assert_ne!(
            query_key(RecommendationMode::ForYou, None, None, 20, None),
            query_key(RecommendationMode::ForYou, Some("cs.AI"), None, 20, None,)
        );
        assert!(
            query_key(RecommendationMode::Recent, None, None, 20, None).starts_with("recent:v3:")
        );
    }

    #[test]
    fn recommendation_batch_identity_is_scoped_to_one_authorized_cursor_page() {
        let position = reading_feed::RecommendationPosition {
            published_at: Utc::now(),
            paper_id: Uuid::from_u128(42),
        };

        assert_ne!(
            query_key(RecommendationMode::Recent, None, None, 20, None),
            query_key(RecommendationMode::Recent, None, Some(position), 20, None,),
            "a continuation is a separately persisted candidate-page batch"
        );
    }

    #[test]
    fn recommendation_serve_metric_mapping_and_bounds_are_closed() {
        for (feed, batch, metric) in [
            (
                FeedRecommendationMode::Recent,
                RecommendationMode::Recent,
                ModeMetricClass::Recent,
            ),
            (
                FeedRecommendationMode::Following,
                RecommendationMode::Following,
                ModeMetricClass::Following,
            ),
            (
                FeedRecommendationMode::ForYou,
                RecommendationMode::ForYou,
                ModeMetricClass::ForYou,
            ),
            (
                FeedRecommendationMode::Explore,
                RecommendationMode::Explore,
                ModeMetricClass::Explore,
            ),
        ] {
            assert_eq!(feed_metric_mode(feed), metric);
            assert_eq!(batch_metric_mode(batch), metric);
        }

        let now = Utc::now();
        assert_eq!(
            bounded_batch_age(now, now + TimeDelta::seconds(1)),
            StdDuration::ZERO
        );
        assert_eq!(
            bounded_batch_age(now, now - TimeDelta::days(31)),
            StdDuration::from_secs(30 * 24 * 60 * 60)
        );
        assert_eq!(
            found_batch_metric_outcome(0),
            BatchServeMetricOutcome::NoResult
        );
        assert_eq!(found_batch_metric_outcome(1), BatchServeMetricOutcome::Hit);
        assert!(matches!(
            ready_batch_id(RecommendationBatchPersistOutcome::Superseded {
                batch_id: Uuid::from_u128(1),
                current_library_revision: 8,
                active_count: 1,
            }),
            Err((
                RecommendationError::RevisionStale,
                BatchServeMetricOutcome::Blocked
            ))
        ));
        assert!(matches!(
            ready_batch_id(RecommendationBatchPersistOutcome::Superseded {
                batch_id: Uuid::from_u128(1),
                current_library_revision: 8,
                active_count: 0,
            }),
            Err((
                RecommendationError::RevisionStale,
                BatchServeMetricOutcome::Superseded
            ))
        ));
    }

    #[test]
    fn generation_queue_resolution_covers_every_persisted_state() {
        let job_id = Uuid::from_u128(1);
        let batch_id = Uuid::from_u128(2);
        assert_eq!(
            generation_enqueue_resolution(RecommendationGenerationEnqueueOutcome::Replayed {
                job_id,
                batch_id,
                state: RecommendationGenerationJobState::Completed,
            }),
            Ok(batch_id)
        );

        for outcome in [
            RecommendationGenerationEnqueueOutcome::Queued { job_id, batch_id },
            RecommendationGenerationEnqueueOutcome::Replayed {
                job_id,
                batch_id,
                state: RecommendationGenerationJobState::Queued,
            },
            RecommendationGenerationEnqueueOutcome::Replayed {
                job_id,
                batch_id,
                state: RecommendationGenerationJobState::Running,
            },
        ] {
            assert_eq!(
                generation_enqueue_resolution(outcome),
                Err((
                    RecommendationError::Unavailable,
                    BatchServeMetricOutcome::Miss,
                ))
            );
        }
        assert_eq!(
            generation_enqueue_resolution(RecommendationGenerationEnqueueOutcome::Replayed {
                job_id,
                batch_id,
                state: RecommendationGenerationJobState::Failed,
            }),
            Err((
                RecommendationError::Unavailable,
                BatchServeMetricOutcome::Unavailable,
            ))
        );

        for outcome in [
            RecommendationGenerationEnqueueOutcome::ContextChanged,
            RecommendationGenerationEnqueueOutcome::AuthorityChanged {
                library_revision: 4,
                active_count: 0,
            },
            RecommendationGenerationEnqueueOutcome::Replayed {
                job_id,
                batch_id,
                state: RecommendationGenerationJobState::Superseded,
            },
        ] {
            assert_eq!(
                generation_enqueue_resolution(outcome),
                Err((
                    RecommendationError::RevisionStale,
                    BatchServeMetricOutcome::Superseded,
                ))
            );
        }
        assert_eq!(
            generation_enqueue_resolution(
                RecommendationGenerationEnqueueOutcome::AuthorityChanged {
                    library_revision: 4,
                    active_count: 1,
                }
            ),
            Err((
                RecommendationError::RevisionStale,
                BatchServeMetricOutcome::Blocked,
            ))
        );
    }

    #[test]
    fn served_page_propagates_exact_persisted_batch_metadata() {
        let published_at = Utc::now();
        let paper = PaperSummary {
            paper_id: Uuid::from_u128(42),
            arxiv_id: "2608.00042v1".to_owned(),
            title: "Auditable recommendation metadata".to_owned(),
            abstract_text: "Abstract".to_owned(),
            authors: vec!["Ada Reader".to_owned()],
            primary_category: "cs.IR".to_owned(),
            categories: vec!["cs.IR".to_owned()],
            published_at,
            updated_at: published_at,
            abs_url: Url::parse("https://arxiv.org/abs/2608.00042v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2608.00042v1").unwrap(),
            capabilities: Capabilities::metadata_only(),
        };
        let metadata = RecommendationBatchMetadata {
            profile_revision: Some(3),
            feedback_revision: 4,
            algorithm_version: "recommendations_v1".to_owned(),
            recommendation_policy_version: "weighted_v1".to_owned(),
        };
        let next_position = reading_feed::RecommendationPosition {
            published_at,
            paper_id: Uuid::from_u128(41),
        };

        let page = map_served_page(
            RecommendationBatchServeOutcome::Found {
                batch_id: Uuid::from_u128(77),
                batch_metadata: metadata.clone(),
                created_at: published_at - TimeDelta::minutes(5),
                mode: RecommendationMode::Recent,
                library_revision: 7,
                items: vec![db::StoredRecommendationCandidate {
                    paper,
                    position: 0,
                    reason_codes: vec![domain::RecommendationReasonCode::RecentCategory],
                }],
                next_position: Some(next_position),
            },
            false,
        )
        .unwrap();

        assert_eq!(page.batch_id, Some(Uuid::from_u128(77)));
        assert_eq!(page.batch_metadata, Some(metadata));
        assert_eq!(page.next_position, Some(next_position));
        assert_eq!(
            page.items[0].recommendation.as_ref().unwrap().reason_codes,
            vec![domain::RecommendationReasonCode::RecentCategory]
        );
    }

    #[test]
    fn generator_metrics_map_every_closed_engine_dimension() {
        for (source, metric) in [
            (
                RecommendationGeneratorClass::Recent,
                GeneratorMetricClass::Recent,
            ),
            (
                RecommendationGeneratorClass::Following,
                GeneratorMetricClass::Following,
            ),
            (
                RecommendationGeneratorClass::Author,
                GeneratorMetricClass::Author,
            ),
            (
                RecommendationGeneratorClass::Affinity,
                GeneratorMetricClass::Affinity,
            ),
            (
                RecommendationGeneratorClass::Semantic,
                GeneratorMetricClass::Semantic,
            ),
            (
                RecommendationGeneratorClass::Citation,
                GeneratorMetricClass::Citation,
            ),
            (
                RecommendationGeneratorClass::Exploration,
                GeneratorMetricClass::Exploration,
            ),
        ] {
            assert_eq!(generator_metric_class(source), metric);
        }
        assert_eq!(
            generator_metric_role(RecommendationGeneratorRole::Primary),
            GeneratorMetricRole::Primary
        );
        assert_eq!(
            generator_metric_role(RecommendationGeneratorRole::Fallback),
            GeneratorMetricRole::Fallback
        );
        for (source, metric) in [
            (
                RecommendationGeneratorOutcome::Success,
                GeneratorMetricOutcome::Success,
            ),
            (
                RecommendationGeneratorOutcome::Failure,
                GeneratorMetricOutcome::Failure,
            ),
            (
                RecommendationGeneratorOutcome::Timeout,
                GeneratorMetricOutcome::Timeout,
            ),
        ] {
            assert_eq!(generator_metric_outcome(source), metric);
        }
    }

    #[test]
    fn profile_weights_and_discovery_modes_change_ranking_only() {
        let mut settings = ProfileSettings {
            recency_weight: 0.8,
            novelty_weight: 0.6,
            diversity_weight: 0.4,
            discovery_mode: DiscoveryMode::Focused,
            ..ProfileSettings::default()
        };
        let (focused, scoring) = ranking_policies(&settings, 20).unwrap();
        assert_close(scoring.recency, 0.8);
        assert_close(scoring.novelty, 0.6);
        assert_close(focused.diversity_penalty, 0.4);
        assert!(focused.exploration_positions.is_empty());

        settings.discovery_mode = DiscoveryMode::Balanced;
        let (balanced, _) = ranking_policies(&settings, 20).unwrap();
        assert_eq!(balanced.exploration_positions, BTreeSet::from([4, 9]));

        settings.discovery_mode = DiscoveryMode::Exploratory;
        let (exploratory, _) = ranking_policies(&settings, 20).unwrap();
        assert_eq!(
            exploratory.exploration_positions,
            BTreeSet::from([2, 5, 8, 11, 14, 17])
        );
        assert!(
            exploratory
                .exploration_positions
                .iter()
                .all(|position| *position < exploratory.max_items)
        );
        assert!(
            ProvenEmptyQueueBinding::from_decision(7, 1, false).is_err(),
            "ranking preferences must never weaken the independent queue proof"
        );
    }

    #[test]
    fn recent_only_fallback_keeps_fixed_bounded_policies() {
        let (rerank, scoring) = fixed_ranking_policies(5);
        let default_rerank = RerankPolicy::default();
        let default_scoring = ScoringPolicy::default();
        assert_close(rerank.diversity_penalty, default_rerank.diversity_penalty);
        assert_eq!(rerank.exploration_positions, BTreeSet::from([4]));
        assert_close(scoring.recency, default_scoring.recency);
        assert_close(scoring.novelty, default_scoring.novelty);
    }

    #[test]
    fn production_metadata_documents_activate_the_semantic_generator() {
        let published_at = Utc::now() - TimeDelta::days(1);
        let paper = PaperSummary {
            paper_id: Uuid::from_u128(42),
            arxiv_id: "2608.00042v1".to_owned(),
            title: "Auditable semantic retrieval".to_owned(),
            abstract_text: "Deterministic metadata vectors for research discovery.".to_owned(),
            authors: vec!["Ada Reader".to_owned()],
            primary_category: "cs.IR".to_owned(),
            categories: vec!["cs.IR".to_owned(), "cs.AI".to_owned()],
            published_at,
            updated_at: published_at,
            abs_url: Url::parse("https://arxiv.org/abs/2608.00042v1").unwrap(),
            pdf_url: Url::parse("https://arxiv.org/pdf/2608.00042v1").unwrap(),
            capabilities: Capabilities::metadata_only(),
        };
        let document = candidate_document(paper.clone(), BTreeSet::new());
        let replay = candidate_document(paper, BTreeSet::new());
        assert_eq!(document.embedding, replay.embedding);
        assert_eq!(
            document.embedding.len(),
            recommendations::METADATA_EMBEDDING_DIMENSIONS_V1
        );

        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: true,
            historical_seeds: vec![recommendations::HistoricalSeed {
                paper_id: Uuid::from_u128(7),
                title: "Reviewed semantic retrieval".to_owned(),
                state: recommendations::HistoricalSeedState::Reviewed,
                topics: document.topics.clone(),
                embedding: document.embedding.clone(),
            }],
            ..default_profile()
        };
        let generated = recommendations::CandidateGenerator::generate(
            &recommendations::SemanticGenerator::default(),
            &recommendations::CandidateGenerationRequest {
                profile: &profile,
                documents: std::slice::from_ref(&document),
                now: Utc::now(),
                limit: 20,
            },
        )
        .unwrap();
        assert_eq!(generated.len(), 1);
        assert!(
            generated[0]
                .sources
                .contains(&recommendations::CandidateSource::Semantic)
        );
    }

    fn assert_close(left: f32, right: f32) {
        assert!((left - right).abs() <= f32::EPSILON);
    }

    #[test]
    fn feedback_and_inference_remain_separate_from_explicit_follows() {
        let now = chrono::DateTime::UNIX_EPOCH;
        let category = |name: &str, source| ProfileCategory {
            category: name.to_owned(),
            weight: 1.0,
            source,
            created_at: now,
            updated_at: now,
        };
        let snapshot = ResearchProfileSnapshot {
            user_id: AuthenticatedUserId::new(Uuid::from_u128(1)),
            settings: ProfileSettings {
                personalization_enabled: true,
                ..ProfileSettings::default()
            },
            profile_revision: 1,
            interests: ProfileInterests {
                explicit: InterestGroup::default(),
                feedback: InterestGroup {
                    categories: vec![category("cs.CL", InterestSource::Feedback)],
                    ..InterestGroup::default()
                },
                inferred: InterestGroup {
                    categories: vec![category("cs.LG", InterestSource::Inferred)],
                    ..InterestGroup::default()
                },
            },
            created_at: now,
            updated_at: now,
        };
        let profile = map_profile(&snapshot);
        assert!(profile.categories.is_empty());
        assert!(profile.feedback_categories.contains("cs.CL"));
        assert!(profile.inferred_categories.contains("cs.LG"));
        assert_eq!(
            selected_mode(FeedRecommendationMode::Following, &profile),
            RecommendationMode::Recent
        );
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn postgres_recent_fallback_rechecks_empty_authority_and_supports_briefs() {
        let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
            eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL Recent fallback race");
            return;
        };
        let database = Database::connect(&database_url, 10).await.unwrap();
        database.migrate_embedded().await.unwrap();
        let unique = Uuid::now_v7().simple().to_string();
        let category = format!("rf.A{}", &unique[..8]);
        let account = database
            .accounts()
            .provision_oidc_identity(
                &format!("https://recent-fallback.test/{unique}"),
                "owner",
                StdDuration::from_secs(900),
            )
            .await
            .unwrap();
        let papers = database.papers();
        let raced_paper = papers
            .upsert_metadata(&metadata(&unique, &category, 0))
            .await
            .unwrap()
            .id;
        let brief_paper = papers
            .upsert_metadata(&metadata(&unique, &category, 1))
            .await
            .unwrap()
            .id;

        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let source = PausingRecommendationSource {
            inner: BatchRecommendationSource::recent_only(database.recommendation_batches()),
            entered: entered.clone(),
            release: release.clone(),
        };
        let feed = ReadingFeedService::with_dependencies(
            Arc::new(database.reading_feed()),
            Arc::new(source),
            Arc::new(UnusedCursorCodec::new()),
            ReadingFeedPolicy::new(20, 50, StdDuration::from_secs(86_400)).unwrap(),
        );
        let race_user_id = account.id;
        let race_category = category.clone();
        let race = tokio::spawn(async move {
            feed.page(ReadingFeedRequest {
                user_id: race_user_id,
                category: Some(race_category),
                recommendation_mode: FeedRecommendationMode::ForYou,
                cursor: None,
                limit: Some(20),
                now: Utc::now(),
            })
            .await
        });
        tokio::time::timeout(StdDuration::from_secs(5), entered.notified())
            .await
            .expect("reading-feed fallback did not receive the empty snapshot");
        assert!(matches!(
            database
                .library()
                .mutate(
                    account.id,
                    raced_paper,
                    Uuid::now_v7(),
                    LibraryMutationIntent::Save,
                    LibraryState::Inbox,
                )
                .await
                .unwrap(),
            LibraryMutationOutcome::Applied { .. }
        ));
        release.notify_one();
        assert!(matches!(
            tokio::time::timeout(StdDuration::from_secs(5), race)
                .await
                .unwrap()
                .unwrap(),
            Err(ReadingFeedServiceError::QueueAuthorityUnavailable)
        ));

        assert!(matches!(
            database
                .library()
                .mutate(
                    account.id,
                    raced_paper,
                    Uuid::now_v7(),
                    LibraryMutationIntent::Remove,
                    LibraryState::Inbox,
                )
                .await
                .unwrap(),
            LibraryMutationOutcome::Applied { .. }
        ));
        let feed = ReadingFeedService::with_dependencies(
            Arc::new(database.reading_feed()),
            Arc::new(BatchRecommendationSource::recent_only(
                database.recommendation_batches(),
            )),
            Arc::new(UnusedCursorCodec::new()),
            ReadingFeedPolicy::new(20, 50, StdDuration::from_secs(86_400)).unwrap(),
        );
        let engagement = EngagementService::new(
            Arc::new(database.engagement()),
            feed,
            EngagementPolicy::default(),
        );
        let now = Utc::now();
        let brief = engagement
            .create_brief(BriefCreateCommand {
                user_id: account.id,
                operation_id: Uuid::now_v7(),
                requested_recommendation_mode: Some(FeedRecommendationMode::ForYou),
                effective_recommendation_mode: FeedRecommendationMode::ForYou,
                brief_size: 20,
                category: Some(category),
                local_date: now.date_naive(),
                now,
            })
            .await
            .unwrap();
        assert_eq!(brief.mode, BriefMode::Discovery);
        assert_eq!(
            brief.recommendation_mode,
            Some(FeedRecommendationMode::Recent),
            "the disabled enhanced recommender must remain server-authoritative"
        );
        assert!(brief.recommendation_batch_id.is_some());
        assert_eq!(brief.items.len(), 1);
        assert_eq!(brief.items[0].paper.paper_id, brief_paper);

        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(account.id.into_inner())
            .execute(database.pool())
            .await
            .unwrap();
    }

    #[derive(Clone)]
    struct PausingRecommendationSource {
        inner: BatchRecommendationSource,
        entered: Arc<Notify>,
        release: Arc<Notify>,
    }

    #[async_trait]
    impl RecommendationSource for PausingRecommendationSource {
        async fn page(
            &self,
            request: RecommendationRequest,
        ) -> Result<RecommendationResultPage, RecommendationError> {
            self.entered.notify_one();
            self.release.notified().await;
            self.inner.page(request).await
        }
    }

    struct UnusedCursorCodec {
        epoch: CursorKeyEpoch,
    }

    impl UnusedCursorCodec {
        fn new() -> Self {
            Self {
                epoch: CursorKeyEpoch::parse("A".repeat(CursorKeyEpoch::ENCODED_BYTES)).unwrap(),
            }
        }
    }

    impl ReadingFeedCursorCodec for UnusedCursorCodec {
        fn active_key_epoch(&self) -> CursorKeyEpoch {
            self.epoch.clone()
        }

        fn seal(&self, _claims: &ReadingFeedCursorClaims) -> Result<String, CursorCodecError> {
            Err(CursorCodecError::Unavailable)
        }

        fn open(
            &self,
            _expected_user_id: AuthenticatedUserId,
            _token: &str,
            _now: chrono::DateTime<Utc>,
        ) -> Result<ReadingFeedCursorClaims, CursorCodecError> {
            Err(CursorCodecError::Invalid)
        }
    }

    fn metadata(unique: &str, category: &str, index: i64) -> PaperMetadata {
        let base_id = format!("recent-fallback.{unique}.{index}");
        let published_at = Utc::now() - TimeDelta::hours(index + 1);
        PaperMetadata {
            arxiv_id: ArxivIdentifier {
                base_id: base_id.clone(),
                version: 1,
            },
            title: format!("Recent fallback fixture {index}"),
            abstract_text: "A metadata-only Recent fallback fixture.".to_owned(),
            authors: vec![Author::from("Ada Reader".to_owned())],
            primary_category: category.to_owned(),
            categories: vec![category.to_owned()],
            published_at,
            updated_at: published_at,
            abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
            pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
            doi: None,
            journal_reference: None,
            comment: None,
            license_uri: None,
            metadata_fetched_at: Utc::now(),
        }
    }
}
