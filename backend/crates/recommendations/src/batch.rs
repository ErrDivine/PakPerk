use std::{
    collections::BTreeMap,
    sync::Arc,
    time::{Duration, Instant},
};

use chrono::{DateTime, Utc};
use domain::PaperId;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    AffinityGenerator, AuthorGenerator, CandidateDocument, CandidateGenerationError,
    CandidateGenerationRequest, CandidateGenerator, CandidateMergeError, CandidateSource,
    CitationCandidateEvidence, CitationCoverage, CitationEvidenceError, CitationGenerator,
    CitationOnlineInputs, DiscoveryPolicy, DiscoveryPolicyError, DiscoveryProfileSnapshot,
    ExplanationError, ExplorationGenerator, FollowingGenerator, RecentGenerator,
    RecommendationCandidateHistory, RecommendationExplanation, RecommendationMode, RerankError,
    RerankPolicy, SCORING_POLICY_VERSION_CITATION_ONLINE_V1, ScoredCandidate, ScoringPolicy,
    ScoringPolicyError, SemanticGenerator, explain_candidate, explain_candidate_with_citation,
    explanations::order_citation_reasons, merge_generated_candidates, rerank::rerank_with_evidence,
};

pub const RECOMMENDATION_ALGORITHM_VERSION_V1: &str = "recommendations_v1";
const DEFAULT_GENERATOR_TIMEOUT: Duration = Duration::from_secs(2);
const MIN_GENERATOR_TIMEOUT: Duration = Duration::from_millis(1);
const MAX_GENERATOR_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_GENERATION_DOCUMENTS: usize = 500;

/// Proof-shaped input supplied by the queue authority above this crate. The
/// private fields prevent callers from accidentally using an unchecked count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "QueueDecisionInput", into = "QueueDecisionInput")]
pub struct ProvenEmptyQueueBinding {
    library_revision: i64,
}

impl ProvenEmptyQueueBinding {
    pub fn from_decision(
        library_revision: i64,
        active_count: u64,
        queue_proven_empty: bool,
    ) -> Result<Self, BatchBuildError> {
        if library_revision < 0 || active_count != 0 || !queue_proven_empty {
            return Err(BatchBuildError::QueueNotProvenEmpty);
        }
        Ok(Self { library_revision })
    }

    #[must_use]
    pub const fn library_revision(self) -> i64 {
        self.library_revision
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct QueueDecisionInput {
    library_revision: i64,
    active_count: u64,
    queue_proven_empty: bool,
}

impl TryFrom<QueueDecisionInput> for ProvenEmptyQueueBinding {
    type Error = BatchBuildError;

    fn try_from(value: QueueDecisionInput) -> Result<Self, Self::Error> {
        Self::from_decision(
            value.library_revision,
            value.active_count,
            value.queue_proven_empty,
        )
    }
}

impl From<ProvenEmptyQueueBinding> for QueueDecisionInput {
    fn from(value: ProvenEmptyQueueBinding) -> Self {
        Self {
            library_revision: value.library_revision,
            active_count: 0,
            queue_proven_empty: true,
        }
    }
}

/// Closed candidate-generator identity used by execution policy and telemetry.
/// It deliberately describes implementation classes, never a query, account,
/// paper, or profile value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorClass {
    Recent,
    Following,
    Author,
    Affinity,
    Semantic,
    Citation,
    Exploration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorRole {
    Primary,
    Fallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorOutcome {
    Success,
    Failure,
    Timeout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecommendationGeneratorRun {
    pub generator: RecommendationGeneratorClass,
    pub role: RecommendationGeneratorRole,
    pub outcome: RecommendationGeneratorOutcome,
    pub duration: Duration,
    pub candidate_count: usize,
}

/// Content-free observation seam. Implementations receive only closed enums,
/// bounded timing, and aggregate candidate counts.
pub trait RecommendationGeneratorObserver: Send + Sync {
    fn record(&self, run: RecommendationGeneratorRun);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CandidateFanoutPolicy {
    pub per_generator_timeout: Duration,
}

impl Default for CandidateFanoutPolicy {
    fn default() -> Self {
        Self {
            per_generator_timeout: DEFAULT_GENERATOR_TIMEOUT,
        }
    }
}

impl CandidateFanoutPolicy {
    const fn is_valid(self) -> bool {
        self.per_generator_timeout.as_nanos() >= MIN_GENERATOR_TIMEOUT.as_nanos()
            && self.per_generator_timeout.as_nanos() <= MAX_GENERATOR_TIMEOUT.as_nanos()
    }
}

#[derive(Clone)]
pub struct RecommendationBatchBuildRequest<'a> {
    pub mode: RecommendationMode,
    pub queue: ProvenEmptyQueueBinding,
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub profile: &'a DiscoveryProfileSnapshot,
    pub documents: &'a [CandidateDocument],
    pub candidate_history: &'a BTreeMap<PaperId, RecommendationCandidateHistory>,
    pub now: DateTime<Utc>,
    pub candidate_limit: usize,
    pub fanout_policy: CandidateFanoutPolicy,
    pub generator_observer: Option<&'a dyn RecommendationGeneratorObserver>,
    pub rerank_policy: RerankPolicy,
    pub scoring_policy: ScoringPolicy,
    pub citation_online: Option<&'a CitationOnlineInputs>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BuiltRecommendationCandidate {
    pub scored: ScoredCandidate,
    pub explanations: Vec<RecommendationExplanation>,
    pub citation_evidence: Option<CitationCandidateEvidence>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BuiltRecommendationBatch {
    pub mode: RecommendationMode,
    pub library_revision: i64,
    pub profile_revision: Option<i64>,
    pub feedback_revision: i64,
    pub algorithm_version: &'static str,
    pub policy_version: String,
    pub seed: u64,
    pub candidates: Vec<BuiltRecommendationCandidate>,
    pub citation_coverage: Option<CitationCoverage>,
}

/// Inspectable generation pipeline. It has no queue reads and therefore cannot
/// weaken the proof supplied by the caller. Independent generators run in a
/// bounded concurrent fan-out; a local Recent fallback is attempted only when
/// every primary generator failed or timed out in a mode whose documented
/// outage fallback permits metadata candidates.
pub async fn build_recommendation_batch(
    request: RecommendationBatchBuildRequest<'_>,
) -> Result<BuiltRecommendationBatch, BatchBuildError> {
    build_recommendation_batch_with_specs(request, None).await
}

#[allow(clippy::too_many_lines)] // Keep validation, generation, and ranking in pipeline order.
async fn build_recommendation_batch_with_specs(
    request: RecommendationBatchBuildRequest<'_>,
    override_specs: Option<Vec<GeneratorSpec>>,
) -> Result<BuiltRecommendationBatch, BatchBuildError> {
    DiscoveryPolicy {
        personalization_enabled: request.profile.personalization_enabled,
        preferred_mode: request.mode,
    }
    .selected_mode()?;
    if request
        .profile_revision
        .is_some_and(|revision| revision < 0)
        || request.feedback_revision < 0
        || !(1..=500).contains(&request.candidate_limit)
        || request.documents.len() > MAX_GENERATION_DOCUMENTS
        || !request.fanout_policy.is_valid()
    {
        return Err(BatchBuildError::InvalidRequest);
    }
    request.scoring_policy.validate()?;

    let uses_citation = request.scoring_policy.version == SCORING_POLICY_VERSION_CITATION_ONLINE_V1;
    if uses_citation != request.citation_online.is_some()
        || (uses_citation
            && (request.mode != RecommendationMode::ForYou || request.profile_revision.is_none()))
    {
        return Err(BatchBuildError::InvalidRequest);
    }
    let citation = request
        .citation_online
        .map(|input| input.classify(request.documents).map(Arc::new))
        .transpose()?;
    let generation_request = Arc::new(OwnedCandidateGenerationRequest {
        profile: request.profile.clone(),
        documents: request.documents.to_vec(),
        now: request.now,
        limit: if uses_citation {
            request.documents.len().max(1)
        } else {
            request.candidate_limit
        },
        citation: citation.clone(),
    });
    let specs = override_specs.unwrap_or_else(|| primary_generator_specs(request.mode));
    let mut fanout = run_generator_fanout(
        Arc::clone(&generation_request),
        &specs,
        request.fanout_policy,
        request.generator_observer,
    )
    .await;
    if fanout.successful_generators == 0 && supports_recent_fallback(request.mode) {
        let fallback = run_generator_fanout(
            Arc::clone(&generation_request),
            &[GeneratorSpec::fallback(
                RecommendationGeneratorClass::Recent,
            )],
            request.fanout_policy,
            request.generator_observer,
        )
        .await;
        fanout.generated.extend(fallback.generated);
        fanout.successful_generators = fallback.successful_generators;
    }
    if fanout.successful_generators == 0 {
        return Err(BatchBuildError::GeneratorsUnavailable);
    }
    let generated = if let Some(citation) = &citation {
        preserve_classified_candidates(fanout.generated, &generation_request, citation)
    } else {
        fanout.generated
    };
    let behavior_history_enabled =
        request.mode == RecommendationMode::ForYou && request.profile.personalization_enabled;
    let mut evidence_by_paper = BTreeMap::new();
    let mut scored = Vec::new();
    for mut candidate in merge_generated_candidates(generated)? {
        let paper_id = candidate.document.paper.paper_id;
        if let Some(history) = request
            .candidate_history
            .get(&paper_id)
            .filter(|_| behavior_history_enabled)
        {
            candidate.qualified_impressions = history.qualified_impressions;
            candidate.hidden = history.hidden;
            candidate.negative_feedback = history.negative_feedback;
            let bounded_impressions =
                u16::try_from(history.qualified_impressions.min(5)).unwrap_or(5);
            candidate.features.repeat_exposure = f32::from(bounded_impressions) / 5.0;
            candidate.features.negative_feedback =
                if history.negative_feedback { 1.0 } else { 0.0 };
        }
        let mut base_score = request.scoring_policy.score(candidate.features)?;
        if let (Some(citation), Some(input)) = (&citation, request.citation_online) {
            let mut evidence = citation.get(&paper_id).cloned().unwrap_or_default();
            evidence.apply_author(
                candidate.sources.contains(&CandidateSource::AuthorFollow),
                input.weights,
            );
            evidence.validate()?;
            base_score += evidence.score_adjustment();
            evidence_by_paper.insert(paper_id, evidence);
        }
        scored.push(ScoredCandidate {
            candidate,
            base_score,
        });
    }
    let (ranked, cap_eligible_tier_inversions) = rerank_with_evidence(
        scored,
        &request.rerank_policy,
        uses_citation.then_some(&evidence_by_paper),
    )?;
    let citation_coverage = citation.as_ref().map(|evidence| CitationCoverage {
        authorized_candidate_count: request.documents.len(),
        root_neighbor_count: evidence.len(),
        cap_eligible_tier_inversions,
    });
    let candidates = ranked
        .into_iter()
        .map(|mut scored| {
            let citation_evidence =
                evidence_by_paper.remove(&scored.candidate.document.paper.paper_id);
            let explanations = match &citation_evidence {
                Some(evidence) => {
                    order_citation_reasons(&mut scored.candidate, evidence)?;
                    explain_candidate_with_citation(&scored.candidate, evidence)?
                }
                None => explain_candidate(&scored.candidate)?,
            };
            Ok(BuiltRecommendationCandidate {
                scored,
                explanations,
                citation_evidence,
            })
        })
        .collect::<Result<Vec<_>, ExplanationError>>()?;

    Ok(BuiltRecommendationBatch {
        mode: request.mode,
        library_revision: request.queue.library_revision(),
        profile_revision: request.profile_revision,
        feedback_revision: request.feedback_revision,
        algorithm_version: RECOMMENDATION_ALGORITHM_VERSION_V1,
        policy_version: request.scoring_policy.version,
        seed: request.rerank_policy.batch_seed,
        candidates,
        citation_coverage,
    })
}

// Structured citation and author evidence is complete for the authorized
// page, even if an independent fanout task times out. Fill those two sources
// from the same matchers without dropping or demoting their candidates.
fn preserve_classified_candidates(
    mut generated: Vec<Vec<crate::GeneratedCandidate>>,
    request: &OwnedCandidateGenerationRequest,
    citation: &BTreeMap<PaperId, CitationCandidateEvidence>,
) -> Vec<Vec<crate::GeneratedCandidate>> {
    let classified =
        generated
            .iter()
            .flatten()
            .fold(BTreeMap::<_, _>::new(), |mut seen, candidate| {
                let sources = seen
                    .entry(candidate.document.paper.paper_id)
                    .or_insert((false, false));
                sources.0 |= candidate.sources.contains(&CandidateSource::Citation);
                sources.1 |= candidate.sources.contains(&CandidateSource::AuthorFollow);
                seen
            });
    let followed = AuthorGenerator::followed_names(&request.profile);
    let mut recovered = Vec::new();
    for document in &request.documents {
        let paper_id = document.paper.paper_id;
        let (has_citation, has_author) = classified.get(&paper_id).copied().unwrap_or_default();
        if !has_citation && let Some(evidence) = citation.get(&paper_id) {
            recovered.extend(CitationGenerator::candidate_for(document, evidence));
        }
        if !has_author {
            recovered.extend(AuthorGenerator::candidate_for(
                document,
                &followed,
                request.now,
            ));
        }
    }
    generated.push(recovered);
    generated
}

#[derive(Debug, Clone)]
struct OwnedCandidateGenerationRequest {
    profile: DiscoveryProfileSnapshot,
    documents: Vec<CandidateDocument>,
    now: DateTime<Utc>,
    limit: usize,
    citation: Option<Arc<BTreeMap<PaperId, CitationCandidateEvidence>>>,
}

impl OwnedCandidateGenerationRequest {
    fn borrowed(&self) -> CandidateGenerationRequest<'_> {
        CandidateGenerationRequest {
            profile: &self.profile,
            documents: &self.documents,
            now: self.now,
            limit: self.limit,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct GeneratorSpec {
    class: RecommendationGeneratorClass,
    role: RecommendationGeneratorRole,
    implementation: GeneratorImplementation,
}

impl GeneratorSpec {
    const fn primary(class: RecommendationGeneratorClass) -> Self {
        Self {
            class,
            role: RecommendationGeneratorRole::Primary,
            implementation: GeneratorImplementation::from_class(class),
        }
    }

    const fn fallback(class: RecommendationGeneratorClass) -> Self {
        Self {
            class,
            role: RecommendationGeneratorRole::Fallback,
            implementation: GeneratorImplementation::from_class(class),
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum GeneratorImplementation {
    Recent,
    Following,
    Author,
    Affinity,
    Semantic,
    Citation,
    Exploration,
    #[cfg(test)]
    Delayed {
        delay: Duration,
        delegate: RecommendationGeneratorClass,
    },
    #[cfg(test)]
    Failure,
}

impl GeneratorImplementation {
    const fn from_class(class: RecommendationGeneratorClass) -> Self {
        match class {
            RecommendationGeneratorClass::Recent => Self::Recent,
            RecommendationGeneratorClass::Following => Self::Following,
            RecommendationGeneratorClass::Author => Self::Author,
            RecommendationGeneratorClass::Affinity => Self::Affinity,
            RecommendationGeneratorClass::Semantic => Self::Semantic,
            RecommendationGeneratorClass::Citation => Self::Citation,
            RecommendationGeneratorClass::Exploration => Self::Exploration,
        }
    }

    fn generate(
        self,
        request: &OwnedCandidateGenerationRequest,
    ) -> Result<Vec<crate::GeneratedCandidate>, CandidateGenerationError> {
        let borrowed = request.borrowed();
        match self {
            Self::Recent => RecentGenerator.generate(&borrowed),
            Self::Following => FollowingGenerator.generate(&borrowed),
            Self::Author => AuthorGenerator.generate(&borrowed),
            Self::Affinity => AffinityGenerator.generate(&borrowed),
            Self::Semantic => SemanticGenerator::default().generate(&borrowed),
            Self::Citation => match &request.citation {
                Some(evidence) => CitationGenerator::generate_classified(&borrowed, evidence),
                None => CitationGenerator.generate(&borrowed),
            },
            Self::Exploration => ExplorationGenerator::default().generate(&borrowed),
            #[cfg(test)]
            Self::Delayed { delay, delegate } => {
                std::thread::sleep(delay);
                Self::from_class(delegate).generate(request)
            }
            #[cfg(test)]
            Self::Failure => Err(CandidateGenerationError::InvalidEmbedding),
        }
    }
}

fn primary_generator_specs(mode: RecommendationMode) -> Vec<GeneratorSpec> {
    let classes: &[RecommendationGeneratorClass] = match mode {
        RecommendationMode::Recent => &[RecommendationGeneratorClass::Recent],
        RecommendationMode::Following => &[
            RecommendationGeneratorClass::Following,
            RecommendationGeneratorClass::Author,
        ],
        RecommendationMode::ForYou => &[
            RecommendationGeneratorClass::Recent,
            RecommendationGeneratorClass::Following,
            RecommendationGeneratorClass::Author,
            RecommendationGeneratorClass::Affinity,
            RecommendationGeneratorClass::Semantic,
            RecommendationGeneratorClass::Citation,
            RecommendationGeneratorClass::Exploration,
        ],
        RecommendationMode::Explore => &[RecommendationGeneratorClass::Exploration],
    };
    classes
        .iter()
        .copied()
        .map(GeneratorSpec::primary)
        .collect()
}

const fn supports_recent_fallback(mode: RecommendationMode) -> bool {
    matches!(
        mode,
        RecommendationMode::Following | RecommendationMode::ForYou | RecommendationMode::Explore
    )
}

struct GeneratorFanout {
    generated: Vec<Vec<crate::GeneratedCandidate>>,
    successful_generators: usize,
}

struct GeneratorTaskOutput {
    run: RecommendationGeneratorRun,
    candidates: Option<Vec<crate::GeneratedCandidate>>,
}

async fn run_generator_fanout(
    request: Arc<OwnedCandidateGenerationRequest>,
    specs: &[GeneratorSpec],
    policy: CandidateFanoutPolicy,
    observer: Option<&dyn RecommendationGeneratorObserver>,
) -> GeneratorFanout {
    let tasks = specs
        .iter()
        .copied()
        .map(|spec| {
            let request = Arc::clone(&request);
            (
                spec,
                tokio::spawn(run_generator_task(
                    spec,
                    request,
                    policy.per_generator_timeout,
                )),
            )
        })
        .collect::<Vec<_>>();
    let mut generated = Vec::with_capacity(tasks.len());
    let mut successful_generators = 0;
    for (spec, task) in tasks {
        let output = task.await.unwrap_or(GeneratorTaskOutput {
            run: RecommendationGeneratorRun {
                generator: spec.class,
                role: spec.role,
                outcome: RecommendationGeneratorOutcome::Failure,
                duration: Duration::ZERO,
                candidate_count: 0,
            },
            candidates: None,
        });
        if let Some(observer) = observer {
            observer.record(output.run);
        }
        if let Some(candidates) = output.candidates {
            successful_generators += 1;
            generated.push(candidates);
        }
    }
    GeneratorFanout {
        generated,
        successful_generators,
    }
}

async fn run_generator_task(
    spec: GeneratorSpec,
    request: Arc<OwnedCandidateGenerationRequest>,
    timeout: Duration,
) -> GeneratorTaskOutput {
    let started = Instant::now();
    let task = tokio::task::spawn_blocking(move || spec.implementation.generate(&request));
    match tokio::time::timeout(timeout, task).await {
        Ok(Ok(Ok(candidates))) => GeneratorTaskOutput {
            run: RecommendationGeneratorRun {
                generator: spec.class,
                role: spec.role,
                outcome: RecommendationGeneratorOutcome::Success,
                duration: started.elapsed().min(timeout),
                candidate_count: candidates.len(),
            },
            candidates: Some(candidates),
        },
        Ok(Ok(Err(_)) | Err(_)) => GeneratorTaskOutput {
            run: RecommendationGeneratorRun {
                generator: spec.class,
                role: spec.role,
                outcome: RecommendationGeneratorOutcome::Failure,
                duration: started.elapsed().min(timeout),
                candidate_count: 0,
            },
            candidates: None,
        },
        Err(_) => GeneratorTaskOutput {
            run: RecommendationGeneratorRun {
                generator: spec.class,
                role: spec.role,
                outcome: RecommendationGeneratorOutcome::Timeout,
                duration: timeout,
                candidate_count: 0,
            },
            candidates: None,
        },
    }
}

#[derive(Debug, Error)]
pub enum BatchBuildError {
    #[error("recommendation batch requires a proven-empty queue at a current revision")]
    QueueNotProvenEmpty,
    #[error("recommendation batch request is invalid")]
    InvalidRequest,
    #[error("all recommendation candidate generators failed or timed out")]
    GeneratorsUnavailable,
    #[error(transparent)]
    Policy(#[from] DiscoveryPolicyError),
    #[error(transparent)]
    Generation(#[from] CandidateGenerationError),
    #[error(transparent)]
    Merge(#[from] CandidateMergeError),
    #[error(transparent)]
    Scoring(#[from] ScoringPolicyError),
    #[error(transparent)]
    Rerank(#[from] RerankError),
    #[error(transparent)]
    Explanation(#[from] ExplanationError),
    #[error(transparent)]
    Citation(#[from] CitationEvidenceError),
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeSet, sync::Mutex};

    use crate::candidates::tests::document;
    use crate::{HistoricalSeed, HistoricalSeedState};

    use super::*;

    #[derive(Default)]
    struct RecordingObserver {
        runs: Mutex<Vec<RecommendationGeneratorRun>>,
    }

    impl RecommendationGeneratorObserver for RecordingObserver {
        fn record(&self, run: RecommendationGeneratorRun) {
            self.runs.lock().unwrap().push(run);
        }
    }

    impl RecordingObserver {
        fn runs(&self) -> Vec<RecommendationGeneratorRun> {
            self.runs.lock().unwrap().clone()
        }
    }

    fn profile(personalization_enabled: bool) -> DiscoveryProfileSnapshot {
        DiscoveryProfileSnapshot {
            personalization_enabled,
            categories: BTreeSet::from(["cs.CL".to_owned()]),
            topics: BTreeSet::new(),
            authors: BTreeSet::new(),
            saved_query_matches: BTreeMap::new(),
            feedback_categories: BTreeSet::new(),
            inferred_categories: BTreeSet::new(),
            historical_seeds: vec![HistoricalSeed {
                paper_id: domain::PaperId::from_u128(99),
                title: "Reviewed seed".to_owned(),
                state: HistoricalSeedState::Reviewed,
                topics: BTreeSet::new(),
                embedding: vec![1.0, 0.0],
            }],
        }
    }

    fn fanout_request<'a>(
        mode: RecommendationMode,
        profile: &'a DiscoveryProfileSnapshot,
        documents: &'a [CandidateDocument],
        history: &'a BTreeMap<PaperId, RecommendationCandidateHistory>,
        observer: &'a dyn RecommendationGeneratorObserver,
        timeout: Duration,
    ) -> RecommendationBatchBuildRequest<'a> {
        RecommendationBatchBuildRequest {
            mode,
            queue: ProvenEmptyQueueBinding::from_decision(7, 0, true).unwrap(),
            profile_revision: Some(3),
            feedback_revision: 0,
            profile,
            documents,
            candidate_history: history,
            now: chrono::DateTime::UNIX_EPOCH,
            candidate_limit: 20,
            fanout_policy: CandidateFanoutPolicy {
                per_generator_timeout: timeout,
            },
            generator_observer: Some(observer),
            rerank_policy: RerankPolicy {
                max_items: 10,
                exploration_positions: BTreeSet::new(),
                ..RerankPolicy::default()
            },
            scoring_policy: ScoringPolicy::default(),
            citation_online: None,
        }
    }

    #[tokio::test]
    async fn citation_slots_share_caps_and_choose_best_eligible_version_before_exploration() {
        use crate::{CitationDirection::Reference, citation_online::tests::pair};

        let mut profile = profile(true);
        profile.historical_seeds.clear();
        profile.authors.insert("Followed Author".to_owned());
        let mut documents = [
            document(1, "cs.CL"),
            document(2, "cs.CL"),
            document(3, "cs.CL"),
            document(4, "cs.AI"),
            document(5, "cs.CL"),
        ];
        documents[0].paper.updated_at += chrono::TimeDelta::days(1);
        documents[2].paper.authors = vec!["Another author".to_owned()];
        documents[3].paper.authors = vec!["Explorer author".to_owned()];
        documents[4].paper.authors = vec!["Followed Author".to_owned()];
        documents[4].paper.arxiv_id = "2401.00001v2".to_owned();
        let input = CitationOnlineInputs {
            pairs: vec![
                pair(1, 20, 4, Reference),
                pair(2, 20, 4, Reference),
                pair(3, 21, 3, Reference),
            ],
            ..CitationOnlineInputs::default()
        };
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let mut request = fanout_request(
            RecommendationMode::ForYou,
            &profile,
            &documents,
            &history,
            &observer,
            DEFAULT_GENERATOR_TIMEOUT,
        );
        request.scoring_policy.version = SCORING_POLICY_VERSION_CITATION_ONLINE_V1.to_owned();
        request.scoring_policy.follow = 4.0;
        request.scoring_policy.graph = 0.0;
        request.citation_online = Some(&input);
        request.rerank_policy.max_per_author = 1;
        request.rerank_policy.exploration_positions = BTreeSet::from([0, 1, 2]);
        let batch = build_recommendation_batch(request).await.unwrap();
        assert_eq!(
            batch
                .candidates
                .iter()
                .map(|candidate| {
                    (
                        candidate.scored.candidate.document.paper.paper_id.as_u128(),
                        candidate.citation_evidence.as_ref().unwrap().tier,
                    )
                })
                .collect::<Vec<_>>(),
            vec![(1, 4), (3, 3), (4, 0)],
        );
        assert_eq!(
            batch.candidates[0].scored.candidate.document.paper,
            documents[0].paper
        );
        let coverage = batch.citation_coverage.unwrap();
        assert_eq!(coverage.root_neighbor_count, 3);
        assert_eq!(coverage.cap_eligible_tier_inversions, 0);
    }

    #[tokio::test]
    async fn unavailable_fanout_cannot_drop_classified_sources_or_credit_generic_follows() {
        use crate::{
            CitationDirection::Citing, ExplanationCode, LearnerVote, LearnerWeights,
            citation_online::tests::pair,
        };

        let mut profile = profile(true);
        profile.historical_seeds.clear();
        profile.authors.insert(" ada reader ".to_owned());
        let mut documents = [
            document(1, "cs.AI"),
            document(2, "cs.AI"),
            document(3, "cs.CL"),
        ];
        documents[0].paper.authors.clear();
        documents[2].paper.authors.clear();
        let input = CitationOnlineInputs {
            pairs: vec![pair(1, 20, 2, Citing)],
            weights: LearnerWeights::from_votes(
                DateTime::UNIX_EPOCH,
                &[LearnerVote {
                    id: PaperId::from_u128(101),
                    base_arxiv_id: "2401.00101".to_owned(),
                    created_at: DateTime::UNIX_EPOCH,
                    feature_mask: 4,
                    relevant: true,
                }],
            )
            .unwrap(),
        };
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let mut request = fanout_request(
            RecommendationMode::ForYou,
            &profile,
            &documents,
            &history,
            &observer,
            DEFAULT_GENERATOR_TIMEOUT,
        );
        request.scoring_policy.version = SCORING_POLICY_VERSION_CITATION_ONLINE_V1.to_owned();
        request.citation_online = Some(&input);
        let batch = build_recommendation_batch_with_specs(
            request,
            Some(vec![
                GeneratorSpec::primary(RecommendationGeneratorClass::Following),
                GeneratorSpec {
                    implementation: GeneratorImplementation::Failure,
                    ..GeneratorSpec::primary(RecommendationGeneratorClass::Author)
                },
                GeneratorSpec {
                    implementation: GeneratorImplementation::Failure,
                    ..GeneratorSpec::primary(RecommendationGeneratorClass::Citation)
                },
            ]),
        )
        .await
        .unwrap();
        assert_eq!(
            batch
                .candidates
                .iter()
                .map(|candidate| {
                    let evidence = candidate.citation_evidence.as_ref().unwrap();
                    (
                        evidence.tier,
                        evidence.feature_mask,
                        candidate.explanations[0].code,
                    )
                })
                .collect::<Vec<_>>(),
            vec![
                (2, 2, ExplanationCode::ArchivedPaperCitation),
                (1, 4, ExplanationCode::FollowedAuthor),
                (0, 0, ExplanationCode::FollowedCategory),
            ],
        );
        assert_eq!(
            batch.candidates[0].explanations[0].detail,
            "This paper cites your archived paper ‘Historical root 20’."
        );
        assert!(batch.candidates[1].explanations[0].behavior_used);
        assert!(!batch.candidates[2].explanations[0].behavior_used);
    }

    #[test]
    fn proof_constructor_rejects_active_stale_or_unknown_decisions() {
        assert!(matches!(
            ProvenEmptyQueueBinding::from_decision(4, 1, false),
            Err(BatchBuildError::QueueNotProvenEmpty)
        ));
        assert!(matches!(
            ProvenEmptyQueueBinding::from_decision(-1, 0, true),
            Err(BatchBuildError::QueueNotProvenEmpty)
        ));
        assert!(matches!(
            ProvenEmptyQueueBinding::from_decision(4, 0, false),
            Err(BatchBuildError::QueueNotProvenEmpty)
        ));
        assert_eq!(
            ProvenEmptyQueueBinding::from_decision(4, 0, true)
                .unwrap()
                .library_revision(),
            4
        );
    }

    #[tokio::test]
    async fn for_you_pipeline_is_bound_to_the_empty_revision_and_explanations() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
            mode: RecommendationMode::ForYou,
            queue: ProvenEmptyQueueBinding::from_decision(7, 0, true).unwrap(),
            profile_revision: Some(3),
            feedback_revision: 0,
            profile: &profile,
            documents: &documents,
            candidate_history: &BTreeMap::new(),
            now: chrono::DateTime::UNIX_EPOCH,
            candidate_limit: 20,
            fanout_policy: CandidateFanoutPolicy::default(),
            generator_observer: None,
            rerank_policy: RerankPolicy {
                max_items: 10,
                exploration_positions: BTreeSet::new(),
                ..RerankPolicy::default()
            },
            scoring_policy: ScoringPolicy::default(),
            citation_online: None,
        })
        .await
        .unwrap();
        assert_eq!(batch.library_revision, 7);
        assert_eq!(batch.profile_revision, Some(3));
        assert_eq!(batch.candidates.len(), 1);
        assert_ne!(batch.candidates[0].explanations, []);
    }

    #[tokio::test]
    async fn personalization_disabled_cannot_build_for_you() {
        let profile = profile(false);
        assert!(matches!(
            build_recommendation_batch(RecommendationBatchBuildRequest {
                mode: RecommendationMode::ForYou,
                queue: ProvenEmptyQueueBinding::from_decision(7, 0, true).unwrap(),
                profile_revision: None,
                feedback_revision: 0,
                profile: &profile,
                documents: &[],
                candidate_history: &BTreeMap::new(),
                now: chrono::DateTime::UNIX_EPOCH,
                candidate_limit: 20,
                fanout_policy: CandidateFanoutPolicy::default(),
                generator_observer: None,
                rerank_policy: RerankPolicy::default(),
                scoring_policy: ScoringPolicy::default(),
                citation_online: None,
            })
            .await,
            Err(BatchBuildError::Policy(
                DiscoveryPolicyError::PersonalizationDisabled
            ))
        ));
    }

    #[tokio::test]
    async fn explicit_negative_feedback_is_a_hard_exclusion_for_for_you() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::from([(
            domain::PaperId::from_u128(1),
            RecommendationCandidateHistory {
                qualified_impressions: 3,
                hidden: false,
                negative_feedback: true,
            },
        )]);
        let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
            mode: RecommendationMode::ForYou,
            queue: ProvenEmptyQueueBinding::from_decision(7, 0, true).unwrap(),
            profile_revision: None,
            feedback_revision: 4,
            profile: &profile,
            documents: &documents,
            candidate_history: &history,
            now: chrono::DateTime::UNIX_EPOCH,
            candidate_limit: 20,
            fanout_policy: CandidateFanoutPolicy::default(),
            generator_observer: None,
            rerank_policy: RerankPolicy::default(),
            scoring_policy: ScoringPolicy::default(),
            citation_online: None,
        })
        .await
        .unwrap();
        assert_eq!(batch.feedback_revision, 4);
        assert_eq!(batch.candidates, []);
    }

    #[tokio::test]
    async fn behavioral_history_cannot_change_non_personalized_modes() {
        let profile = profile(true);
        let history = BTreeMap::from([(
            domain::PaperId::from_u128(1),
            RecommendationCandidateHistory {
                qualified_impressions: 5,
                hidden: true,
                negative_feedback: true,
            },
        )]);

        for mode in [
            RecommendationMode::Recent,
            RecommendationMode::Following,
            RecommendationMode::Explore,
        ] {
            let category = if mode == RecommendationMode::Explore {
                "cs.AI"
            } else {
                "cs.CL"
            };
            let documents = vec![document(1, category)];
            let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
                mode,
                queue: ProvenEmptyQueueBinding::from_decision(7, 0, true).unwrap(),
                profile_revision: Some(3),
                feedback_revision: 4,
                profile: &profile,
                documents: &documents,
                candidate_history: &history,
                now: chrono::DateTime::UNIX_EPOCH,
                candidate_limit: 20,
                fanout_policy: CandidateFanoutPolicy::default(),
                generator_observer: None,
                rerank_policy: RerankPolicy::default(),
                scoring_policy: ScoringPolicy::default(),
                citation_online: None,
            })
            .await
            .unwrap();

            assert_eq!(batch.candidates.len(), 1, "history changed {mode:?}");
            let candidate = &batch.candidates[0].scored.candidate;
            assert_eq!(candidate.qualified_impressions, 0);
            assert!(!candidate.hidden);
            assert!(!candidate.negative_feedback);
            assert!(candidate.features.repeat_exposure.abs() <= f32::EPSILON);
            assert!(candidate.features.negative_feedback.abs() <= f32::EPSILON);
        }
    }

    #[tokio::test]
    async fn timed_out_generator_is_isolated_and_uses_local_metadata_fallback() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let specs = vec![GeneratorSpec {
            class: RecommendationGeneratorClass::Semantic,
            role: RecommendationGeneratorRole::Primary,
            implementation: GeneratorImplementation::Delayed {
                delay: Duration::from_millis(100),
                delegate: RecommendationGeneratorClass::Semantic,
            },
        }];

        let batch = build_recommendation_batch_with_specs(
            fanout_request(
                RecommendationMode::ForYou,
                &profile,
                &documents,
                &history,
                &observer,
                Duration::from_millis(10),
            ),
            Some(specs),
        )
        .await
        .unwrap();

        assert_eq!(batch.candidates.len(), 1);
        assert_eq!(
            observer
                .runs()
                .iter()
                .map(|run| (run.generator, run.role, run.outcome, run.candidate_count))
                .collect::<Vec<_>>(),
            vec![
                (
                    RecommendationGeneratorClass::Semantic,
                    RecommendationGeneratorRole::Primary,
                    RecommendationGeneratorOutcome::Timeout,
                    0,
                ),
                (
                    RecommendationGeneratorClass::Recent,
                    RecommendationGeneratorRole::Fallback,
                    RecommendationGeneratorOutcome::Success,
                    1,
                ),
            ]
        );
    }

    #[tokio::test]
    async fn one_generator_failure_keeps_surviving_generator_candidates() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let specs = vec![
            GeneratorSpec {
                class: RecommendationGeneratorClass::Semantic,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Failure,
            },
            GeneratorSpec::primary(RecommendationGeneratorClass::Recent),
        ];

        let batch = build_recommendation_batch_with_specs(
            fanout_request(
                RecommendationMode::ForYou,
                &profile,
                &documents,
                &history,
                &observer,
                Duration::from_secs(1),
            ),
            Some(specs),
        )
        .await
        .unwrap();

        assert_eq!(batch.candidates.len(), 1);
        assert_eq!(observer.runs().len(), 2);
        assert_eq!(
            observer.runs()[0].outcome,
            RecommendationGeneratorOutcome::Failure
        );
        assert_eq!(
            observer.runs()[1].outcome,
            RecommendationGeneratorOutcome::Success
        );
        assert!(
            observer
                .runs()
                .iter()
                .all(|run| run.role == RecommendationGeneratorRole::Primary)
        );
    }

    #[tokio::test]
    async fn all_primary_failures_attempt_exactly_one_recent_fallback() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let specs = vec![
            GeneratorSpec {
                class: RecommendationGeneratorClass::Following,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Failure,
            },
            GeneratorSpec {
                class: RecommendationGeneratorClass::Author,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Failure,
            },
        ];

        let batch = build_recommendation_batch_with_specs(
            fanout_request(
                RecommendationMode::Following,
                &profile,
                &documents,
                &history,
                &observer,
                Duration::from_secs(1),
            ),
            Some(specs),
        )
        .await
        .unwrap();

        assert_eq!(batch.candidates.len(), 1);
        let runs = observer.runs();
        assert_eq!(runs.len(), 3);
        assert!(
            runs[..2]
                .iter()
                .all(|run| run.outcome == RecommendationGeneratorOutcome::Failure)
        );
        assert_eq!(runs[2].generator, RecommendationGeneratorClass::Recent);
        assert_eq!(runs[2].role, RecommendationGeneratorRole::Fallback);
        assert_eq!(runs[2].outcome, RecommendationGeneratorOutcome::Success);
    }

    #[tokio::test]
    async fn completion_race_cannot_change_merge_or_observation_order() {
        let profile = profile(true);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let specs = vec![
            GeneratorSpec {
                class: RecommendationGeneratorClass::Following,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Delayed {
                    delay: Duration::from_millis(40),
                    delegate: RecommendationGeneratorClass::Following,
                },
            },
            GeneratorSpec {
                class: RecommendationGeneratorClass::Recent,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Delayed {
                    delay: Duration::from_millis(1),
                    delegate: RecommendationGeneratorClass::Recent,
                },
            },
        ];

        let batch = build_recommendation_batch_with_specs(
            fanout_request(
                RecommendationMode::ForYou,
                &profile,
                &documents,
                &history,
                &observer,
                Duration::from_secs(1),
            ),
            Some(specs),
        )
        .await
        .unwrap();

        assert_eq!(
            observer
                .runs()
                .iter()
                .map(|run| run.generator)
                .collect::<Vec<_>>(),
            vec![
                RecommendationGeneratorClass::Following,
                RecommendationGeneratorClass::Recent,
            ]
        );
        assert!(matches!(
            batch.candidates[0].scored.candidate.reasons.as_slice(),
            [
                crate::ReasonEvidence::FollowedCategory { .. },
                crate::ReasonEvidence::RecentCategory { .. }
            ]
        ));
    }

    #[tokio::test]
    async fn recent_mode_does_not_recursively_retry_a_failed_fallback() {
        let profile = profile(false);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        let result = build_recommendation_batch_with_specs(
            fanout_request(
                RecommendationMode::Recent,
                &profile,
                &documents,
                &history,
                &observer,
                Duration::from_secs(1),
            ),
            Some(vec![GeneratorSpec {
                class: RecommendationGeneratorClass::Recent,
                role: RecommendationGeneratorRole::Primary,
                implementation: GeneratorImplementation::Failure,
            }]),
        )
        .await;

        assert!(matches!(
            result,
            Err(BatchBuildError::GeneratorsUnavailable)
        ));
        assert_eq!(observer.runs().len(), 1);
    }

    #[tokio::test]
    async fn fanout_timeout_configuration_is_strictly_bounded() {
        let profile = profile(false);
        let documents = vec![document(1, "cs.CL")];
        let history = BTreeMap::new();
        let observer = RecordingObserver::default();
        for timeout in [Duration::ZERO, Duration::from_secs(31)] {
            let result = build_recommendation_batch(fanout_request(
                RecommendationMode::Recent,
                &profile,
                &documents,
                &history,
                &observer,
                timeout,
            ))
            .await;
            assert!(matches!(result, Err(BatchBuildError::InvalidRequest)));
        }
        assert_eq!(observer.runs(), []);
    }
}
