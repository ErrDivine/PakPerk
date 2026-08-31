use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use domain::{Capabilities, PaperId, PaperSummary};
use recommendations::{
    AffinityGenerator, AuthorGenerator, CandidateDocument, CandidateGenerationRequest,
    CandidateGenerator, CitationGenerator, DiscoveryProfileSnapshot, EvaluationCorpus,
    EvaluationResourceBudget, EvaluationResourceUsage, ExplorationGenerator, FollowingGenerator,
    GeneratedCandidate, HistoricalSeedState, ReasonEvidence, RecentGenerator, RelevanceJudgment,
    RerankPolicy, ScoredCandidate, ScoringPolicy, SemanticGenerator, evaluate_ranking,
    evaluate_ranking_with_resources, merge_generated_candidates, ranking_stability, rerank,
};
use serde::Deserialize;
use url::Url;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    schema_version: u32,
    #[serde(rename = "fixture_id")]
    id: String,
    queue_decision: QueueDecision,
    profile: DiscoveryProfileSnapshot,
    documents: Vec<FixtureDocument>,
    expected_candidate_pool_ids: BTreeSet<PaperId>,
    expected_unique_ranked_base_arxiv_ids: usize,
    #[serde(default)]
    expected_ranked_paper_ids: Vec<PaperId>,
    evaluation_k: usize,
    #[serde(default)]
    covered_cases: BTreeSet<String>,
    #[serde(default)]
    negative_feedback_paper_ids: BTreeSet<PaperId>,
    #[serde(default)]
    resource_evaluation: Option<FixtureResourceEvaluation>,
    small_profile_change: ProfileChange,
    thresholds: Thresholds,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct QueueDecision {
    active_count: u64,
    library_revision: u64,
    proven_empty: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureDocument {
    paper_id: PaperId,
    arxiv_id: String,
    title: String,
    authors: Vec<String>,
    primary_category: String,
    topics: BTreeSet<String>,
    embedding: Vec<f32>,
    citation_neighbors: BTreeSet<PaperId>,
    metadata_completeness: f32,
    published_at: DateTime<Utc>,
    relevance_grade: u8,
    cold_start: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Thresholds {
    min_recall_at_k: f64,
    min_ndcg_at_k: f64,
    min_catalog_coverage: f64,
    min_topic_coverage: f64,
    min_intra_list_diversity: f64,
    min_novelty: f64,
    max_author_concentration: f64,
    max_category_concentration: f64,
    min_cold_start_coverage: f64,
    explanation_correctness: f64,
    negative_feedback_response: f64,
    min_ranking_stability: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureResourceEvaluation {
    usage: EvaluationResourceUsage,
    budget: EvaluationResourceBudget,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DemoResourceReport {
    schema_version: u32,
    units: DemoResourceUnits,
    fixtures: Vec<DemoResourceFixture>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DemoResourceUnits {
    latency_micros: String,
    estimated_cost_microusd: String,
    generator_invocations: String,
    generator_document_work_units: String,
    external_requests: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DemoResourceFixture {
    fixture_id: String,
    resource_evaluation: FixtureResourceEvaluation,
    expected_pass: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProfileChange {
    #[serde(default)]
    categories: BTreeSet<String>,
    #[serde(default)]
    topics: BTreeSet<String>,
    #[serde(default)]
    authors: BTreeSet<String>,
}

struct FixtureRun {
    candidate_pool: Vec<GeneratedCandidate>,
    ranked: Vec<ScoredCandidate>,
    metrics: recommendations::EvaluationMetrics,
    stability: f64,
}

#[test]
fn versioned_empty_queue_fixture_passes_quality_and_truthfulness_gates() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("fixtures/empty_queue_mixed_v1.json")).unwrap();
    assert_eq!(fixture.schema_version, 1);
    assert_eq!(fixture.id, "empty_queue_mixed_v1");
    assert_eq!(fixture.queue_decision.active_count, 0);
    assert!(fixture.queue_decision.proven_empty);
    assert!(fixture.queue_decision.library_revision > 0);

    assert_fixture_gates(&fixture);
}

#[test]
fn plan_02_edge_fixture_covers_sparse_ambiguous_duplicate_and_truthful_cases() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("fixtures/empty_queue_edge_cases_v2.json")).unwrap();
    assert_eq!(fixture.schema_version, 2);
    assert_eq!(fixture.id, "empty_queue_edge_cases_v2");
    assert_eq!(fixture.queue_decision.active_count, 0);
    assert!(fixture.queue_decision.proven_empty);
    assert!(fixture.queue_decision.library_revision > 0);
    assert_eq!(
        fixture.covered_cases,
        BTreeSet::from([
            "author_name_ambiguity".to_owned(),
            "curated_explicit_profile".to_owned(),
            "expected_candidate_pool".to_owned(),
            "inactive_historical_seed_reasons".to_owned(),
            "misleading_title".to_owned(),
            "negative_feedback".to_owned(),
            "sparse_categories".to_owned(),
            "version_duplicates".to_owned(),
        ])
    );

    let run = assert_fixture_gates(&fixture);
    assert!(
        fixture
            .documents
            .iter()
            .any(|document| document.topics.is_empty())
    );
    assert!(has_ambiguous_author_name(&fixture.documents));

    let duplicate_family_count = fixture
        .documents
        .iter()
        .map(|document| base_arxiv_identity(&document.arxiv_id))
        .collect::<BTreeSet<_>>()
        .len();
    assert!(duplicate_family_count < fixture.documents.len());
    assert_eq!(
        run.ranked
            .iter()
            .map(|candidate| base_arxiv_identity(&candidate.candidate.document.paper.arxiv_id))
            .collect::<BTreeSet<_>>()
            .len(),
        run.ranked.len()
    );

    let misleading = fixture
        .documents
        .iter()
        .find(|document| {
            document.relevance_grade == 0 && document.title.to_lowercase().contains("retrieval")
        })
        .unwrap();
    let misleading_candidate = run
        .candidate_pool
        .iter()
        .find(|candidate| candidate.document.paper.paper_id == misleading.paper_id)
        .unwrap();
    assert_eq!(
        misleading_candidate.sources,
        BTreeSet::from([recommendations::CandidateSource::Exploration])
    );

    for candidate in &run.ranked {
        for reason in &candidate.candidate.reasons {
            if let ReasonEvidence::HistoricalSeed {
                paper_id,
                title,
                state,
                ..
            } = reason
            {
                assert!(matches!(
                    state,
                    HistoricalSeedState::Reviewed | HistoricalSeedState::Archived
                ));
                assert!(fixture.profile.historical_seeds.iter().any(|seed| {
                    seed.paper_id == *paper_id && seed.title == *title && seed.state == *state
                }));
            }
        }
    }
    assert!(run.ranked.iter().any(|candidate| {
        candidate
            .candidate
            .reasons
            .iter()
            .any(|reason| matches!(reason, ReasonEvidence::HistoricalSeed { .. }))
    }));
    assert!(run.ranked.iter().all(|candidate| {
        !fixture
            .negative_feedback_paper_ids
            .contains(&candidate.candidate.document.paper.paper_id)
    }));
}

#[test]
fn cold_start_user_and_paper_fixture_gates_deterministic_recent_fallback() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("fixtures/empty_queue_cold_start_v3.json")).unwrap();
    assert_eq!(fixture.schema_version, 3);
    assert_eq!(fixture.id, "empty_queue_cold_start_v3");
    assert_eq!(fixture.queue_decision.active_count, 0);
    assert!(fixture.queue_decision.proven_empty);
    assert!(fixture.queue_decision.library_revision > 0);

    assert!(fixture.profile.personalization_enabled);
    assert!(fixture.profile.categories.is_empty());
    assert!(fixture.profile.topics.is_empty());
    assert!(fixture.profile.authors.is_empty());
    assert!(fixture.profile.saved_query_matches.is_empty());
    assert!(fixture.profile.feedback_categories.is_empty());
    assert!(fixture.profile.inferred_categories.is_empty());
    assert!(fixture.profile.historical_seeds.is_empty());
    assert!(fixture.negative_feedback_paper_ids.is_empty());
    assert!(fixture.small_profile_change.categories.is_empty());
    assert!(fixture.small_profile_change.topics.is_empty());
    assert!(fixture.small_profile_change.authors.is_empty());
    assert_eq!(
        fixture.covered_cases,
        BTreeSet::from([
            "cold_start_paper_cohort".to_owned(),
            "cold_start_user".to_owned(),
            "deterministic_recent_fallback".to_owned(),
            "empty_profile".to_owned(),
            "expected_candidate_pool".to_owned(),
            "proven_empty_queue".to_owned(),
        ])
    );
    assert!(fixture.documents.iter().all(|document| document.cold_start));

    // These bounds are release criteria, not descriptive values that may be
    // silently weakened while retaining a passing fixture.
    assert_threshold(fixture.thresholds.min_catalog_coverage, 0.8);
    assert_threshold(fixture.thresholds.min_topic_coverage, 0.8);
    assert_threshold(fixture.thresholds.min_intra_list_diversity, 0.9);
    assert_threshold(fixture.thresholds.max_author_concentration, 0.2);
    assert_threshold(fixture.thresholds.max_category_concentration, 0.2);
    assert_threshold(fixture.thresholds.min_cold_start_coverage, 0.8);
    let resources = fixture.resource_evaluation.unwrap();
    assert_eq!(resources.usage.generator_invocations, 7);
    assert_eq!(resources.usage.generator_document_work_units, 42);
    assert_eq!(resources.usage.external_requests, 0);
    assert_eq!(resources.usage.estimated_cost_microusd, 0);

    let run = assert_fixture_gates(&fixture);
    let non_personalized_sources = BTreeSet::from([
        recommendations::CandidateSource::Recent,
        recommendations::CandidateSource::Exploration,
    ]);
    assert!(run.candidate_pool.iter().all(|candidate| {
        candidate
            .sources
            .contains(&recommendations::CandidateSource::Recent)
            && candidate.sources.is_subset(&non_personalized_sources)
    }));
    assert!(run.candidate_pool.iter().all(|candidate| {
        candidate.reasons.iter().all(|reason| {
            matches!(
                reason,
                ReasonEvidence::RecentCategory { .. }
                    | ReasonEvidence::Exploration { .. }
                    | ReasonEvidence::DiversitySlot
            )
        })
    }));
}

#[test]
fn legacy_fixture_without_resource_metadata_remains_decodable() {
    let mut value: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/empty_queue_mixed_v1.json")).unwrap();
    value.as_object_mut().unwrap().remove("resource_evaluation");
    let fixture: Fixture = serde_json::from_value(value).unwrap();
    assert!(fixture.resource_evaluation.is_none());
}

#[test]
fn demo_resource_report_matches_the_executable_fixture_contract() {
    let report: DemoResourceReport = serde_json::from_str(include_str!(
        "../../../../demo/recommendation_evaluation/offline_resource_report_v1.json"
    ))
    .unwrap();
    assert_eq!(report.schema_version, 1);
    assert_eq!(report.units.latency_micros, "microseconds");
    assert_eq!(
        report.units.estimated_cost_microusd,
        "micro-US-dollars (1 USD = 1000000 micro-USD)"
    );
    assert_eq!(report.units.generator_invocations, "generator executions");
    assert_eq!(
        report.units.generator_document_work_units,
        "one generator examining one candidate document"
    );
    assert_eq!(
        report.units.external_requests,
        "metered or remote service calls"
    );

    let fixtures = [
        serde_json::from_str::<Fixture>(include_str!("fixtures/empty_queue_mixed_v1.json"))
            .unwrap(),
        serde_json::from_str::<Fixture>(include_str!("fixtures/empty_queue_edge_cases_v2.json"))
            .unwrap(),
        serde_json::from_str::<Fixture>(include_str!("fixtures/empty_queue_cold_start_v3.json"))
            .unwrap(),
    ];
    assert_eq!(report.fixtures.len(), fixtures.len());
    for fixture in fixtures {
        let entry = report
            .fixtures
            .iter()
            .find(|entry| entry.fixture_id == fixture.id)
            .unwrap();
        assert!(entry.expected_pass);
        assert_eq!(
            entry.resource_evaluation,
            fixture.resource_evaluation.unwrap()
        );
    }
}

fn assert_fixture_gates(fixture: &Fixture) -> FixtureRun {
    let run = run_fixture(fixture);

    assert!(
        run.metrics.recall_at_k >= fixture.thresholds.min_recall_at_k,
        "{} recall_at_k {}",
        fixture.id,
        run.metrics.recall_at_k
    );
    assert!(
        run.metrics.ndcg_at_k >= fixture.thresholds.min_ndcg_at_k,
        "{} ndcg_at_k {}",
        fixture.id,
        run.metrics.ndcg_at_k
    );
    assert!(
        run.metrics.catalog_coverage >= fixture.thresholds.min_catalog_coverage,
        "{} catalog_coverage {}",
        fixture.id,
        run.metrics.catalog_coverage
    );
    assert!(
        run.metrics.topic_coverage >= fixture.thresholds.min_topic_coverage,
        "{} topic_coverage {}",
        fixture.id,
        run.metrics.topic_coverage
    );
    assert!(
        run.metrics.intra_list_diversity >= fixture.thresholds.min_intra_list_diversity,
        "{} intra_list_diversity {}",
        fixture.id,
        run.metrics.intra_list_diversity
    );
    assert!(
        run.metrics.novelty >= fixture.thresholds.min_novelty,
        "{} novelty {}",
        fixture.id,
        run.metrics.novelty
    );
    assert!(
        run.metrics.max_author_concentration <= fixture.thresholds.max_author_concentration,
        "{} max_author_concentration {}",
        fixture.id,
        run.metrics.max_author_concentration
    );
    assert!(
        run.metrics.max_category_concentration <= fixture.thresholds.max_category_concentration,
        "{} max_category_concentration {}",
        fixture.id,
        run.metrics.max_category_concentration
    );
    assert!(
        run.metrics.cold_start_coverage >= fixture.thresholds.min_cold_start_coverage,
        "{} cold_start_coverage {}",
        fixture.id,
        run.metrics.cold_start_coverage
    );
    assert!(
        (run.metrics.explanation_correctness - fixture.thresholds.explanation_correctness).abs()
            <= f64::EPSILON
    );
    assert!(
        (run.metrics.negative_feedback_response - fixture.thresholds.negative_feedback_response)
            .abs()
            <= f64::EPSILON
    );
    assert!(
        run.stability >= fixture.thresholds.min_ranking_stability,
        "{} ranking_stability {}",
        fixture.id,
        run.stability
    );
    if let Some(expected) = fixture.resource_evaluation {
        let report = run
            .metrics
            .resource_report
            .expect("resource-enabled fixtures produce a resource report");
        assert_eq!(report.usage, expected.usage);
        assert_eq!(report.budget, expected.budget);
        assert!(
            report.passed,
            "{} resource budget exceeded: {report:?}",
            fixture.id
        );
    } else {
        assert!(run.metrics.resource_report.is_none());
    }
    assert_ranked_identity_gates(fixture, &run.ranked);

    run
}

fn assert_ranked_identity_gates(fixture: &Fixture, ranked: &[ScoredCandidate]) {
    assert_eq!(
        ranked
            .iter()
            .map(|candidate| base_arxiv_identity(&candidate.candidate.document.paper.arxiv_id))
            .collect::<BTreeSet<_>>()
            .len(),
        fixture.expected_unique_ranked_base_arxiv_ids
    );
    if !fixture.expected_ranked_paper_ids.is_empty() {
        assert_eq!(
            ranked
                .iter()
                .map(|candidate| candidate.candidate.document.paper.paper_id)
                .collect::<Vec<_>>(),
            fixture.expected_ranked_paper_ids,
            "{} deterministic ranked order",
            fixture.id
        );
    }
}

fn assert_threshold(actual: f64, expected: f64) {
    assert!((actual - expected).abs() <= f64::EPSILON);
}

fn run_fixture(fixture: &Fixture) -> FixtureRun {
    let candidate_pool = generate_candidates(fixture, &fixture.profile);
    assert_eq!(
        candidate_pool
            .iter()
            .map(|candidate| candidate.document.paper.paper_id)
            .collect::<BTreeSet<_>>(),
        fixture.expected_candidate_pool_ids
    );
    let ranked = rank_candidates(fixture, candidate_pool.clone());
    let judgments = fixture
        .documents
        .iter()
        .map(|document| RelevanceJudgment {
            paper_id: document.paper_id,
            relevance_grade: document.relevance_grade,
        })
        .collect::<Vec<_>>();
    let cold_start_paper_ids = fixture
        .documents
        .iter()
        .filter(|document| document.cold_start)
        .map(|document| document.paper_id)
        .collect();
    let topic_count = fixture
        .documents
        .iter()
        .flat_map(|document| document.topics.iter().cloned())
        .collect::<BTreeSet<_>>()
        .len();
    let corpus = EvaluationCorpus {
        catalog_size: fixture.documents.len(),
        topic_count,
        cold_start_paper_ids,
    };
    let metrics = fixture
        .resource_evaluation
        .map_or_else(
            || evaluate_ranking(&ranked, &judgments, &corpus, fixture.evaluation_k),
            |resources| {
                evaluate_ranking_with_resources(
                    &ranked,
                    &judgments,
                    &corpus,
                    fixture.evaluation_k,
                    resources.usage,
                    resources.budget,
                )
            },
        )
        .unwrap();

    let mut perturbed_profile = fixture.profile.clone();
    perturbed_profile
        .categories
        .extend(fixture.small_profile_change.categories.iter().cloned());
    perturbed_profile
        .topics
        .extend(fixture.small_profile_change.topics.iter().cloned());
    perturbed_profile
        .authors
        .extend(fixture.small_profile_change.authors.iter().cloned());
    let perturbed = rank_candidates(fixture, generate_candidates(fixture, &perturbed_profile));
    let stability = ranking_stability(
        &ranked
            .iter()
            .map(|candidate| candidate.candidate.document.paper.paper_id)
            .collect::<Vec<_>>(),
        &perturbed
            .iter()
            .map(|candidate| candidate.candidate.document.paper.paper_id)
            .collect::<Vec<_>>(),
    );

    FixtureRun {
        candidate_pool,
        ranked,
        metrics,
        stability,
    }
}

fn generate_candidates(
    fixture: &Fixture,
    profile: &DiscoveryProfileSnapshot,
) -> Vec<GeneratedCandidate> {
    let documents = fixture
        .documents
        .iter()
        .map(FixtureDocument::candidate_document)
        .collect::<Vec<_>>();
    let request = CandidateGenerationRequest {
        profile,
        documents: &documents,
        now: "2026-08-19T12:00:00Z".parse().unwrap(),
        limit: 50,
    };
    let generated = vec![
        RecentGenerator.generate(&request).unwrap(),
        FollowingGenerator.generate(&request).unwrap(),
        AuthorGenerator.generate(&request).unwrap(),
        AffinityGenerator.generate(&request).unwrap(),
        SemanticGenerator::default().generate(&request).unwrap(),
        CitationGenerator.generate(&request).unwrap(),
        ExplorationGenerator::default().generate(&request).unwrap(),
    ];
    merge_generated_candidates(generated).unwrap()
}

fn rank_candidates(
    fixture: &Fixture,
    candidate_pool: Vec<GeneratedCandidate>,
) -> Vec<ScoredCandidate> {
    let scoring = ScoringPolicy::default();
    let scored = candidate_pool
        .into_iter()
        .map(|mut candidate| {
            if fixture
                .negative_feedback_paper_ids
                .contains(&candidate.document.paper.paper_id)
            {
                candidate.negative_feedback = true;
                candidate.features.negative_feedback = 1.0;
            }
            let base_score = scoring.score(candidate.features).unwrap();
            ScoredCandidate {
                candidate,
                base_score,
            }
        })
        .collect::<Vec<_>>();
    rerank(
        scored,
        &RerankPolicy {
            batch_seed: 20_260_819,
            max_items: fixture.evaluation_k,
            max_per_author: 2,
            max_per_category: 2,
            max_per_topic: 2,
            diversity_penalty: 0.2,
            exploration_positions: BTreeSet::from([2]),
        },
    )
    .unwrap()
}

fn base_arxiv_identity(arxiv_id: &str) -> String {
    arxiv_id
        .rsplit_once('v')
        .filter(|(_, version)| {
            !version.is_empty() && version.bytes().all(|byte| byte.is_ascii_digit())
        })
        .map_or_else(|| arxiv_id.to_owned(), |(base, _)| base.to_owned())
}

fn has_ambiguous_author_name(documents: &[FixtureDocument]) -> bool {
    let mut categories_by_author = std::collections::BTreeMap::<String, BTreeSet<String>>::new();
    for document in documents {
        for author in &document.authors {
            categories_by_author
                .entry(author.trim().to_lowercase())
                .or_default()
                .insert(document.primary_category.clone());
        }
    }
    categories_by_author
        .values()
        .any(|categories| categories.len() > 1)
}

impl FixtureDocument {
    fn candidate_document(&self) -> CandidateDocument {
        CandidateDocument {
            paper: PaperSummary {
                paper_id: self.paper_id,
                arxiv_id: self.arxiv_id.clone(),
                title: self.title.clone(),
                abstract_text: "Metadata-only fixture abstract".to_owned(),
                authors: self.authors.clone(),
                primary_category: self.primary_category.clone(),
                categories: vec![self.primary_category.clone()],
                published_at: self.published_at,
                updated_at: self.published_at,
                abs_url: Url::parse(&format!("https://arxiv.org/abs/{}", self.arxiv_id)).unwrap(),
                pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{}", self.arxiv_id)).unwrap(),
                capabilities: Capabilities::metadata_only(),
            },
            topics: self.topics.clone(),
            embedding: self.embedding.clone(),
            citation_neighbors: self.citation_neighbors.clone(),
            metadata_completeness: self.metadata_completeness,
        }
    }
}
