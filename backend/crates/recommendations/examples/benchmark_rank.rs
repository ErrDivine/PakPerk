//! Offline public-dataset adapter. Ranking always calls the production builder.
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, Read},
    time::Instant,
};

use chrono::{DateTime, Utc};
use domain::{Capabilities, PaperSummary};
use recommendations::{
    CandidateDocument, CandidateFanoutPolicy, CitationDirection, CitationOnlineInputs,
    CitationPair, CitationRoot, DiscoveryProfileSnapshot, HistoricalSeed, HistoricalSeedState,
    LearnerWeights, MetadataEmbeddingInput, ProvenEmptyQueueBinding,
    RecommendationBatchBuildRequest, RecommendationMode, RerankPolicy,
    SCORING_POLICY_VERSION_CITATION_ONLINE_V1, ScoringPolicy, build_recommendation_batch,
    metadata_embedding_v1,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Deserialize)]
struct Item {
    title: String,
    abstract_text: String,
    neighbors: Vec<usize>,
}
#[derive(Deserialize)]
struct Case {
    id: String,
    history: Vec<usize>,
    candidates: Vec<usize>,
    seed: u64,
}
#[derive(Deserialize)]
struct Input {
    items: Vec<Item>,
    cases: Vec<Case>,
    #[serde(default)]
    weighted_only: bool,
}
#[derive(Serialize)]
struct Ranked {
    indices: Vec<usize>,
    elapsed_us: u128,
    root_neighbors: usize,
}
#[derive(Serialize)]
struct Output {
    id: String,
    weighted: Ranked,
    citation: Option<Ranked>,
}

fn identity(index: usize) -> Uuid {
    Uuid::from_u128(index as u128 + 1)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    io::stdin().read_to_string(&mut text)?;
    let input: Input = serde_json::from_str(&text)?;
    let now: DateTime<Utc> = "2026-11-22T00:00:00Z".parse()?;
    let documents: Vec<_> = input
        .items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let categories = Vec::new();
            CandidateDocument {
                embedding: metadata_embedding_v1(MetadataEmbeddingInput {
                    title: &item.title,
                    abstract_text: &item.abstract_text,
                    categories: &categories,
                }),
                paper: PaperSummary {
                    paper_id: identity(index),
                    arxiv_id: format!("benchmark-{index}v1"),
                    title: item.title.clone(),
                    abstract_text: item.abstract_text.clone(),
                    authors: Vec::new(),
                    primary_category: "unknown".to_owned(),
                    categories,
                    // The dataset has no publication timestamps. Keep age constant.
                    published_at: now,
                    updated_at: now,
                    abs_url: format!("https://example.invalid/{index}").parse().unwrap(),
                    pdf_url: format!("https://example.invalid/{index}.pdf")
                        .parse()
                        .unwrap(),
                    capabilities: Capabilities::metadata_only(),
                },
                topics: BTreeSet::new(),
                citation_neighbors: item.neighbors.iter().copied().map(identity).collect(),
                metadata_completeness: 1.0,
            }
        })
        .collect();
    let empty = BTreeSet::new();
    for case in input.cases {
        let profile = DiscoveryProfileSnapshot {
            personalization_enabled: true,
            categories: empty.clone(),
            topics: empty.clone(),
            authors: empty.clone(),
            saved_query_matches: BTreeMap::new(),
            feedback_categories: empty.clone(),
            inferred_categories: empty.clone(),
            historical_seeds: case
                .history
                .iter()
                .take(50)
                .map(|&index| HistoricalSeed {
                    paper_id: identity(index),
                    title: documents[index].paper.title.clone(),
                    state: HistoricalSeedState::Archived,
                    topics: empty.clone(),
                    embedding: documents[index].embedding.clone(),
                })
                .collect(),
        };
        let candidates: Vec<_> = case
            .candidates
            .iter()
            .map(|&i| documents[i].clone())
            .collect();
        let pairs: Vec<_> = case
            .history
            .iter()
            .take(10)
            .flat_map(|&root| {
                case.candidates
                    .iter()
                    .filter_map(|&candidate| {
                        documents[candidate]
                            .citation_neighbors
                            .contains(&identity(root))
                            .then(|| CitationPair {
                                candidate_paper_id: identity(candidate),
                                root: CitationRoot {
                                    paper_id: identity(root),
                                    base_arxiv_id: format!("benchmark-{root}"),
                                    // Production evidence titles have a 256-byte bound.
                                    title: documents[root].paper.title.chars().take(60).collect(),
                                    state: HistoricalSeedState::Archived,
                                    tier: 2,
                                    updated_at: now,
                                },
                                // This dataset releases a symmetric citation graph.
                                direction: CitationDirection::Reciprocal,
                            })
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let citation = CitationOnlineInputs {
            pairs,
            weights: LearnerWeights::default(),
        };
        let mut rankings = Vec::new();
        for is_citation in [false, true] {
            if is_citation && input.weighted_only {
                continue;
            }
            let mut scoring_policy = ScoringPolicy::default();
            if is_citation {
                scoring_policy.version = SCORING_POLICY_VERSION_CITATION_ONLINE_V1.into();
            }
            let started = Instant::now();
            let batch = build_recommendation_batch(RecommendationBatchBuildRequest {
                mode: RecommendationMode::ForYou,
                queue: ProvenEmptyQueueBinding::from_decision(1, 0, true)?,
                profile_revision: Some(1),
                feedback_revision: 0,
                profile: &profile,
                documents: &candidates,
                candidate_history: &BTreeMap::new(),
                now,
                candidate_limit: candidates.len(),
                fanout_policy: CandidateFanoutPolicy::default(),
                generator_observer: None,
                // Missing categories/authors must not turn one "unknown" bucket
                // into an artificial six-result cap. This is ranking-only QA.
                rerank_policy: RerankPolicy {
                    batch_seed: case.seed,
                    max_items: 10,
                    max_per_category: 50,
                    max_per_author: 50,
                    max_per_topic: 50,
                    ..RerankPolicy::default()
                },
                scoring_policy,
                citation_online: is_citation.then_some(&citation),
            })
            .await?;
            rankings.push(Ranked {
                indices: batch
                    .candidates
                    .iter()
                    .map(|x| (x.scored.candidate.document.paper.paper_id.as_u128() - 1) as usize)
                    .collect(),
                elapsed_us: started.elapsed().as_micros(),
                root_neighbors: batch.citation_coverage.map_or(0, |x| x.root_neighbor_count),
            });
        }
        let citation = if input.weighted_only {
            None
        } else {
            Some(rankings.pop().unwrap())
        };
        let weighted = rankings.pop().unwrap();
        println!(
            "{}",
            serde_json::to_string(&Output {
                id: case.id,
                weighted,
                citation
            })?
        );
    }
    Ok(())
}
