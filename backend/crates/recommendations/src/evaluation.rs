use std::collections::{BTreeMap, BTreeSet};

use domain::PaperId;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{ScoredCandidate, explain_candidate};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelevanceJudgment {
    pub paper_id: PaperId,
    /// Closed manual grade: 0 = not relevant, 1..=3 = increasing relevance.
    pub relevance_grade: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationCorpus {
    pub catalog_size: usize,
    pub topic_count: usize,
    #[serde(default)]
    pub cold_start_paper_ids: BTreeSet<PaperId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationMetrics {
    pub k: usize,
    pub retrieved: usize,
    pub relevant_total: usize,
    pub relevant_retrieved: usize,
    pub recall_at_k: f64,
    pub ndcg_at_k: f64,
    pub catalog_coverage: f64,
    pub topic_coverage: f64,
    pub intra_list_diversity: f64,
    pub novelty: f64,
    pub max_author_concentration: f64,
    pub max_category_concentration: f64,
    pub cold_start_coverage: f64,
    pub explanation_correctness: f64,
    pub negative_feedback_response: f64,
    /// Optional deterministic or externally measured execution budget report.
    /// Legacy quality-only reports omit this field and remain decodable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_report: Option<EvaluationResourceReport>,
}

/// Content-free composition summary for a completed ranking. Labels and
/// identities are consumed only in-process to produce bounded aggregate
/// ratios; callers can export the result without exposing either.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RankingCompositionMetrics {
    pub candidate_count: usize,
    pub max_author_concentration: f64,
    pub max_category_concentration: f64,
    pub max_topic_concentration: f64,
}

/// Uses the same maximum-share definition as the offline evaluator. Repeated
/// metadata values within one paper count once, so every ratio stays in the
/// closed unit interval even if upstream metadata contains duplicates.
pub fn summarize_ranking_composition<'a>(
    ranked: impl IntoIterator<Item = &'a ScoredCandidate>,
) -> RankingCompositionMetrics {
    let selected = ranked.into_iter().collect::<Vec<_>>();
    RankingCompositionMetrics {
        candidate_count: selected.len(),
        max_author_concentration: concentration(&selected, |candidate| {
            candidate
                .candidate
                .document
                .paper
                .authors
                .iter()
                .map(|author| author.trim().to_lowercase())
                .collect()
        }),
        max_category_concentration: concentration(&selected, |candidate| {
            vec![candidate.candidate.document.paper.primary_category.clone()]
        }),
        max_topic_concentration: concentration(&selected, |candidate| {
            candidate
                .candidate
                .document
                .topics
                .iter()
                .map(|topic| topic.trim().to_lowercase())
                .collect()
        }),
    }
}

/// Identifies whether execution values came from deterministic fixture input
/// or from a real measurement supplied by an external benchmark harness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EvaluationMeasurementSource {
    Injected,
    Measured,
}

/// Execution inputs use integer units so offline gates never depend on the
/// wall-clock speed of the CI host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationResourceUsage {
    pub measurement_source: EvaluationMeasurementSource,
    /// End-to-end generation/ranking latency in microseconds.
    pub latency_micros: u64,
    /// Estimated spend in micro-US-dollars (1 USD = 1,000,000 micro-USD).
    pub estimated_cost_microusd: u64,
    /// Number of candidate-generator executions.
    pub generator_invocations: u64,
    /// Generator-document examinations; one generator scanning one document is
    /// one deterministic work unit.
    pub generator_document_work_units: u64,
    /// Calls to metered or remote enrichment/model services.
    pub external_requests: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationResourceBudget {
    pub max_latency_micros: u64,
    pub max_estimated_cost_microusd: u64,
    pub max_generator_invocations: u64,
    pub max_generator_document_work_units: u64,
    pub max_external_requests: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationResourceReport {
    pub usage: EvaluationResourceUsage,
    pub budget: EvaluationResourceBudget,
    pub passed: bool,
}

pub fn evaluate_ranking(
    ranked: &[ScoredCandidate],
    judgments: &[RelevanceJudgment],
    corpus: &EvaluationCorpus,
    k: usize,
) -> Result<EvaluationMetrics, EvaluationError> {
    evaluate_ranking_inner(ranked, judgments, corpus, k, None)
}

pub fn evaluate_ranking_with_resources(
    ranked: &[ScoredCandidate],
    judgments: &[RelevanceJudgment],
    corpus: &EvaluationCorpus,
    k: usize,
    usage: EvaluationResourceUsage,
    budget: EvaluationResourceBudget,
) -> Result<EvaluationMetrics, EvaluationError> {
    validate_resource_usage(usage, ranked.len())?;
    validate_resource_budget(budget)?;
    let report = EvaluationResourceReport {
        usage,
        budget,
        passed: resource_budget_passed(usage, budget),
    };
    evaluate_ranking_inner(ranked, judgments, corpus, k, Some(report))
}

fn evaluate_ranking_inner(
    ranked: &[ScoredCandidate],
    judgments: &[RelevanceJudgment],
    corpus: &EvaluationCorpus,
    k: usize,
    resource_report: Option<EvaluationResourceReport>,
) -> Result<EvaluationMetrics, EvaluationError> {
    validate_inputs(ranked, judgments, corpus, k)?;
    let selected = &ranked[..ranked.len().min(k)];
    let judgment_map = judgments
        .iter()
        .map(|judgment| (judgment.paper_id, judgment.relevance_grade))
        .collect::<BTreeMap<_, _>>();
    let relevant_total = judgments
        .iter()
        .filter(|judgment| judgment.relevance_grade > 0)
        .count();
    let relevant_retrieved = selected
        .iter()
        .filter(|candidate| {
            judgment_map
                .get(&candidate.candidate.document.paper.paper_id)
                .copied()
                .unwrap_or(0)
                > 0
        })
        .count();
    let recall_at_k = ratio(relevant_retrieved, relevant_total);
    let ndcg_at_k = ndcg(selected, judgments, &judgment_map);
    let retrieved_ids = selected
        .iter()
        .map(|candidate| candidate.candidate.document.paper.paper_id)
        .collect::<BTreeSet<_>>();
    let topics = selected
        .iter()
        .flat_map(|candidate| candidate.candidate.document.topics.iter().cloned())
        .collect::<BTreeSet<_>>();
    let cold_retrieved = retrieved_ids
        .intersection(&corpus.cold_start_paper_ids)
        .count();
    let explanation_correct = selected
        .iter()
        .filter(|candidate| explain_candidate(&candidate.candidate).is_ok())
        .count();
    let negative_safe = selected
        .iter()
        .filter(|candidate| {
            !candidate.candidate.negative_feedback
                && candidate.candidate.features.negative_feedback <= f32::EPSILON
        })
        .count();

    let composition = summarize_ranking_composition(selected);
    Ok(EvaluationMetrics {
        k,
        retrieved: selected.len(),
        relevant_total,
        relevant_retrieved,
        recall_at_k,
        ndcg_at_k,
        catalog_coverage: ratio(retrieved_ids.len(), corpus.catalog_size),
        topic_coverage: if corpus.topic_count == 0 {
            0.0
        } else {
            ratio(topics.len(), corpus.topic_count)
        },
        intra_list_diversity: intra_list_diversity(selected),
        novelty: average(
            selected
                .iter()
                .map(|candidate| f64::from(candidate.candidate.features.novelty)),
        ),
        max_author_concentration: composition.max_author_concentration,
        max_category_concentration: composition.max_category_concentration,
        cold_start_coverage: ratio(cold_retrieved, corpus.cold_start_paper_ids.len()),
        explanation_correctness: ratio(explanation_correct, selected.len()),
        negative_feedback_response: ratio(negative_safe, selected.len()),
        resource_report,
    })
}

fn validate_resource_usage(
    usage: EvaluationResourceUsage,
    ranked_count: usize,
) -> Result<(), EvaluationError> {
    let ranked_count = u64::try_from(ranked_count).unwrap_or(u64::MAX);
    if usage.latency_micros == 0
        || usage.latency_micros > 3_600_000_000
        || usage.estimated_cost_microusd > 1_000_000_000
        || !(1..=1_000).contains(&usage.generator_invocations)
        || usage.generator_document_work_units < ranked_count
        || usage.generator_document_work_units > 10_000_000
        || usage.external_requests > 100_000
    {
        return Err(EvaluationError::InvalidResourceUsage);
    }
    Ok(())
}

fn validate_resource_budget(budget: EvaluationResourceBudget) -> Result<(), EvaluationError> {
    if budget.max_latency_micros == 0
        || budget.max_latency_micros > 3_600_000_000
        || budget.max_estimated_cost_microusd > 1_000_000_000
        || !(1..=1_000).contains(&budget.max_generator_invocations)
        || budget.max_generator_document_work_units == 0
        || budget.max_generator_document_work_units > 10_000_000
        || budget.max_external_requests > 100_000
    {
        return Err(EvaluationError::InvalidResourceBudget);
    }
    Ok(())
}

const fn resource_budget_passed(
    usage: EvaluationResourceUsage,
    budget: EvaluationResourceBudget,
) -> bool {
    usage.latency_micros <= budget.max_latency_micros
        && usage.estimated_cost_microusd <= budget.max_estimated_cost_microusd
        && usage.generator_invocations <= budget.max_generator_invocations
        && usage.generator_document_work_units <= budget.max_generator_document_work_units
        && usage.external_requests <= budget.max_external_requests
}

/// Jaccard overlap of two ranked result sets. Kept separate so fixture suites
/// can assert stability under a deliberately small profile change.
pub fn ranking_stability(left: &[PaperId], right: &[PaperId]) -> f64 {
    let left = left.iter().copied().collect::<BTreeSet<_>>();
    let right = right.iter().copied().collect::<BTreeSet<_>>();
    if left.is_empty() && right.is_empty() {
        return 1.0;
    }
    ratio(
        left.intersection(&right).count(),
        left.union(&right).count(),
    )
}

fn validate_inputs(
    ranked: &[ScoredCandidate],
    judgments: &[RelevanceJudgment],
    corpus: &EvaluationCorpus,
    k: usize,
) -> Result<(), EvaluationError> {
    if k == 0
        || k > 500
        || ranked.len() > 500
        || judgments.len() > 500
        || corpus.catalog_size == 0
        || u32::try_from(corpus.catalog_size).is_err()
        || u32::try_from(corpus.topic_count).is_err()
    {
        return Err(EvaluationError::InvalidConfiguration);
    }
    let mut ranked_ids = BTreeSet::new();
    for candidate in ranked {
        if !candidate.base_score.is_finite()
            || !ranked_ids.insert(candidate.candidate.document.paper.paper_id)
        {
            return Err(EvaluationError::InvalidRanking);
        }
        candidate
            .candidate
            .features
            .validate()
            .map_err(|_| EvaluationError::InvalidRanking)?;
    }
    if corpus.catalog_size < ranked_ids.len() {
        return Err(EvaluationError::InvalidConfiguration);
    }
    let mut judgment_ids = BTreeSet::new();
    if judgments
        .iter()
        .any(|judgment| judgment.relevance_grade > 3 || !judgment_ids.insert(judgment.paper_id))
    {
        return Err(EvaluationError::InvalidJudgment);
    }
    Ok(())
}

fn ndcg(
    selected: &[ScoredCandidate],
    judgments: &[RelevanceJudgment],
    judgment_map: &BTreeMap<PaperId, u8>,
) -> f64 {
    let dcg = selected
        .iter()
        .enumerate()
        .map(|(index, candidate)| {
            discounted_gain(
                judgment_map
                    .get(&candidate.candidate.document.paper.paper_id)
                    .copied()
                    .unwrap_or(0),
                index,
            )
        })
        .sum::<f64>();
    let mut ideal = judgments
        .iter()
        .map(|judgment| judgment.relevance_grade)
        .collect::<Vec<_>>();
    ideal.sort_unstable_by(|left, right| right.cmp(left));
    let idcg = ideal
        .into_iter()
        .take(selected.len())
        .enumerate()
        .map(|(index, grade)| discounted_gain(grade, index))
        .sum::<f64>();
    if idcg <= f64::EPSILON {
        0.0
    } else {
        dcg / idcg
    }
}

fn discounted_gain(grade: u8, zero_based_position: usize) -> f64 {
    (2_f64.powi(i32::from(grade)) - 1.0) / (bounded_usize_to_f64(zero_based_position) + 2.0).log2()
}

fn intra_list_diversity(selected: &[ScoredCandidate]) -> f64 {
    let mut total = 0.0;
    let mut pairs = 0;
    for (index, left) in selected.iter().enumerate() {
        for right in &selected[index + 1..] {
            let left_topics = &left.candidate.document.topics;
            let right_topics = &right.candidate.document.topics;
            let similarity = if left_topics.is_empty() && right_topics.is_empty() {
                1.0
            } else {
                ratio(
                    left_topics.intersection(right_topics).count(),
                    left_topics.union(right_topics).count(),
                )
            };
            total += 1.0 - similarity;
            pairs += 1;
        }
    }
    if pairs == 0 {
        0.0
    } else {
        total / f64::from(pairs)
    }
}

fn concentration<F>(selected: &[&ScoredCandidate], keys: F) -> f64
where
    F: Fn(&ScoredCandidate) -> Vec<String>,
{
    let mut counts = BTreeMap::<String, usize>::new();
    for candidate in selected {
        for key in keys(candidate).into_iter().collect::<BTreeSet<_>>() {
            *counts.entry(key).or_default() += 1;
        }
    }
    ratio(counts.values().copied().max().unwrap_or(0), selected.len())
}

fn average(values: impl Iterator<Item = f64>) -> f64 {
    let values = values.collect::<Vec<_>>();
    if values.is_empty() {
        0.0
    } else {
        values.iter().sum::<f64>() / bounded_usize_to_f64(values.len())
    }
}

fn ratio(numerator: usize, denominator: usize) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        bounded_usize_to_f64(numerator) / bounded_usize_to_f64(denominator)
    }
}

fn bounded_usize_to_f64(value: usize) -> f64 {
    f64::from(u32::try_from(value).unwrap_or(u32::MAX))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum EvaluationError {
    #[error("recommendation evaluation configuration is invalid")]
    InvalidConfiguration,
    #[error("recommendation ranking is malformed")]
    InvalidRanking,
    #[error("recommendation relevance judgment is malformed")]
    InvalidJudgment,
    #[error("recommendation evaluation resource usage is malformed")]
    InvalidResourceUsage,
    #[error("recommendation evaluation resource budget is malformed")]
    InvalidResourceBudget,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::candidates::tests::document;
    use crate::{CandidateSource, GeneratedCandidate, ReasonEvidence, RecommendationFeatures};

    use super::*;

    fn scored(id: u128, score: f32, relevant_category: &str) -> ScoredCandidate {
        let mut document = document(id, relevant_category);
        document.topics = BTreeSet::from([format!("topic-{id}")]);
        ScoredCandidate {
            candidate: GeneratedCandidate {
                document,
                sources: BTreeSet::from([CandidateSource::Recent]),
                features: RecommendationFeatures {
                    novelty: 1.0,
                    ..RecommendationFeatures::ZERO
                },
                reasons: vec![ReasonEvidence::RecentCategory {
                    category: relevant_category.to_owned(),
                }],
                qualified_impressions: 0,
                hidden: false,
                negative_feedback: false,
            },
            base_score: score,
        }
    }

    #[test]
    fn computes_bounded_relevance_diversity_and_explanation_metrics() {
        let ranked = vec![scored(1, 1.0, "cs.CL"), scored(2, 0.8, "cs.LG")];
        let metrics = evaluate_ranking(
            &ranked,
            &[
                RelevanceJudgment {
                    paper_id: PaperId::from_u128(1),
                    relevance_grade: 3,
                },
                RelevanceJudgment {
                    paper_id: PaperId::from_u128(2),
                    relevance_grade: 1,
                },
            ],
            &EvaluationCorpus {
                catalog_size: 10,
                topic_count: 4,
                cold_start_paper_ids: BTreeSet::from([PaperId::from_u128(2)]),
            },
            2,
        )
        .unwrap();
        assert!((metrics.recall_at_k - 1.0).abs() <= f64::EPSILON);
        assert!((metrics.ndcg_at_k - 1.0).abs() <= f64::EPSILON);
        assert!((metrics.intra_list_diversity - 1.0).abs() <= f64::EPSILON);
        assert!((metrics.explanation_correctness - 1.0).abs() <= f64::EPSILON);
        assert!((metrics.cold_start_coverage - 1.0).abs() <= f64::EPSILON);
        assert!((metrics.negative_feedback_response - 1.0).abs() <= f64::EPSILON);
        assert!(metrics.resource_report.is_none());
    }

    #[test]
    fn completed_ranking_composition_uses_bounded_maximum_item_shares() {
        let mut ranked = vec![
            scored(1, 1.0, "cs.CL"),
            scored(2, 0.9, "cs.CL"),
            scored(3, 0.8, "cs.LG"),
            scored(4, 0.7, "cs.LG"),
        ];
        ranked[0].candidate.document.paper.authors = vec!["Ada".to_owned(), "Ada".to_owned()];
        ranked[1].candidate.document.paper.authors = vec![" ada ".to_owned()];
        ranked[2].candidate.document.paper.authors = vec!["Grace".to_owned()];
        ranked[3].candidate.document.paper.authors = vec!["Lin".to_owned()];
        ranked[0].candidate.document.topics = BTreeSet::from(["Retrieval".to_owned()]);
        ranked[1].candidate.document.topics = BTreeSet::from([" retrieval ".to_owned()]);
        ranked[2].candidate.document.topics = BTreeSet::from(["Planning".to_owned()]);
        ranked[3].candidate.document.topics = BTreeSet::from(["Planning".to_owned()]);

        let composition = summarize_ranking_composition(&ranked);

        assert_eq!(composition.candidate_count, 4);
        assert!((composition.max_author_concentration - 0.5).abs() <= f64::EPSILON);
        assert!((composition.max_category_concentration - 0.5).abs() <= f64::EPSILON);
        assert!((composition.max_topic_concentration - 0.5).abs() <= f64::EPSILON);
        assert_eq!(
            summarize_ranking_composition(std::iter::empty::<&ScoredCandidate>()),
            RankingCompositionMetrics {
                candidate_count: 0,
                max_author_concentration: 0.0,
                max_category_concentration: 0.0,
                max_topic_concentration: 0.0,
            }
        );
    }

    #[test]
    fn injected_execution_metrics_report_units_and_budget_without_a_clock() {
        let ranked = vec![scored(1, 1.0, "cs.CL")];
        let judgments = [RelevanceJudgment {
            paper_id: PaperId::from_u128(1),
            relevance_grade: 3,
        }];
        let corpus = EvaluationCorpus {
            catalog_size: 4,
            topic_count: 2,
            cold_start_paper_ids: BTreeSet::new(),
        };
        let usage = EvaluationResourceUsage {
            measurement_source: EvaluationMeasurementSource::Injected,
            latency_micros: 2_500,
            estimated_cost_microusd: 0,
            generator_invocations: 7,
            generator_document_work_units: 28,
            external_requests: 0,
        };
        let budget = EvaluationResourceBudget {
            max_latency_micros: 5_000,
            max_estimated_cost_microusd: 0,
            max_generator_invocations: 7,
            max_generator_document_work_units: 28,
            max_external_requests: 0,
        };

        let metrics =
            evaluate_ranking_with_resources(&ranked, &judgments, &corpus, 1, usage, budget)
                .unwrap();
        assert_eq!(
            metrics.resource_report,
            Some(EvaluationResourceReport {
                usage,
                budget,
                passed: true,
            })
        );

        let over_budget = evaluate_ranking_with_resources(
            &ranked,
            &judgments,
            &corpus,
            1,
            EvaluationResourceUsage {
                latency_micros: 5_001,
                ..usage
            },
            budget,
        )
        .unwrap();
        assert!(!over_budget.resource_report.unwrap().passed);
    }

    #[test]
    fn malformed_execution_inputs_fail_closed_and_legacy_reports_decode() {
        let ranked = vec![scored(1, 1.0, "cs.CL")];
        let judgments = [RelevanceJudgment {
            paper_id: PaperId::from_u128(1),
            relevance_grade: 3,
        }];
        let corpus = EvaluationCorpus {
            catalog_size: 4,
            topic_count: 2,
            cold_start_paper_ids: BTreeSet::new(),
        };
        let usage = EvaluationResourceUsage {
            measurement_source: EvaluationMeasurementSource::Measured,
            latency_micros: 0,
            estimated_cost_microusd: 0,
            generator_invocations: 7,
            generator_document_work_units: 28,
            external_requests: 0,
        };
        let budget = EvaluationResourceBudget {
            max_latency_micros: 5_000,
            max_estimated_cost_microusd: 0,
            max_generator_invocations: 7,
            max_generator_document_work_units: 28,
            max_external_requests: 0,
        };
        assert!(matches!(
            evaluate_ranking_with_resources(&ranked, &judgments, &corpus, 1, usage, budget),
            Err(EvaluationError::InvalidResourceUsage)
        ));
        assert!(matches!(
            evaluate_ranking_with_resources(
                &ranked,
                &judgments,
                &corpus,
                1,
                EvaluationResourceUsage {
                    latency_micros: 1,
                    ..usage
                },
                EvaluationResourceBudget {
                    max_latency_micros: 0,
                    ..budget
                },
            ),
            Err(EvaluationError::InvalidResourceBudget)
        ));

        let legacy_metrics = evaluate_ranking(&ranked, &judgments, &corpus, 1).unwrap();
        let legacy_json = serde_json::to_value(&legacy_metrics).unwrap();
        assert!(legacy_json.get("resource_report").is_none());
        let decoded: EvaluationMetrics = serde_json::from_value(legacy_json).unwrap();
        assert!(decoded.resource_report.is_none());
    }

    #[test]
    fn ranking_stability_is_jaccard_overlap() {
        let value = ranking_stability(
            &[PaperId::from_u128(1), PaperId::from_u128(2)],
            &[PaperId::from_u128(2), PaperId::from_u128(3)],
        );
        assert!((value - 1.0 / 3.0).abs() <= f64::EPSILON);
    }
}
