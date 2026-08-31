//! Inspectable recommendation policy for Plan 02 discovery fallbacks.
//!
//! This crate deliberately cannot decide whether recommendations are allowed.
//! Queue eligibility remains the responsibility of the `reading_feed` service,
//! which must prove an empty active library in one committed snapshot before
//! invoking any generator defined here.

mod batch;
pub mod candidates;
mod evaluation;
mod explanations;
mod features;
mod metadata_embedding;
mod model;
mod policy;
mod rerank;
mod scoring;

pub use batch::{
    BatchBuildError, BuiltRecommendationBatch, BuiltRecommendationCandidate, CandidateFanoutPolicy,
    ProvenEmptyQueueBinding, RECOMMENDATION_ALGORITHM_VERSION_V1, RecommendationBatchBuildRequest,
    RecommendationGeneratorClass, RecommendationGeneratorObserver, RecommendationGeneratorOutcome,
    RecommendationGeneratorRole, RecommendationGeneratorRun, build_recommendation_batch,
};
pub use candidates::{
    AffinityGenerator, AuthorGenerator, CandidateGenerationError, CandidateGenerationRequest,
    CandidateGenerator, CandidateMergeError, CitationGenerator, ExplorationGenerator,
    FollowingGenerator, RecentGenerator, SemanticGenerator, merge_generated_candidates,
};
pub use evaluation::{
    EvaluationCorpus, EvaluationError, EvaluationMeasurementSource, EvaluationMetrics,
    EvaluationResourceBudget, EvaluationResourceReport, EvaluationResourceUsage,
    RankingCompositionMetrics, RelevanceJudgment, evaluate_ranking,
    evaluate_ranking_with_resources, ranking_stability, summarize_ranking_composition,
};
pub use explanations::{
    ExplanationCode, ExplanationError, RecommendationExplanation, explain_candidate,
};
pub use features::{FeatureValidationError, RecommendationFeatures};
pub use metadata_embedding::{
    METADATA_EMBEDDING_DIMENSIONS_V1, METADATA_EMBEDDING_VERSION_V1, MetadataEmbeddingInput,
    metadata_embedding_v1,
};
pub use model::{
    CandidateDocument, CandidateSource, DiscoveryProfileSnapshot, ExplorationRole,
    GeneratedCandidate, HistoricalRelation, HistoricalSeed, HistoricalSeedState, ReasonEvidence,
    RecommendationCandidateHistory, RecommendationMode,
};
pub use policy::{DiscoveryPolicy, DiscoveryPolicyError};
pub use rerank::{RerankError, RerankPolicy, ScoredCandidate, rerank};
pub use scoring::{SCORING_POLICY_VERSION_V1, ScoringPolicy, ScoringPolicyError};
