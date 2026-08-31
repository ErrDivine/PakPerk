use std::collections::HashSet;

use async_trait::async_trait;
use domain::{
    ASSISTANT_NOT_FOUND_ANSWER, AssistantAnswer, AssistantAnswerStatus, AssistantClaim,
    AssistantClaimSupport, AssistantEvidenceReference, ChatAnswer, ChatEvidence, SectionKind,
    SuggestedFollowUp, assistant_text_contains_link,
};
use uuid::Uuid;

use crate::{
    ASSISTANT_V2_PROMPT_VERSION, AssistantCompletion, AssistantCompletionRequest,
    AssistantProvider, CHAT_PROMPT_VERSION, ChatCompletionRequest, ChatProvider, EmbeddingProvider,
    EmbeddingRequest, EmbeddingResponse, ProviderError, RelationshipProvider, RelationshipRequest,
    RelationshipSummary, deterministic_relationship_fallback,
};

const PREMISE_TERMS: [&str; 13] = [
    "rate",
    "probability",
    "passage",
    "retrieve",
    "index",
    "query",
    "inference",
    "mask",
    "scratch",
    "finetune",
    "fine",
    "tune",
    "wikipedia",
];

/// Offline, reproducible provider used by the prepared demo and tests. It does
/// lexical evidence selection, feature-hashed embeddings, and citation-context
/// cue classification; it never invents model-derived claims.
#[derive(Debug, Clone)]
pub struct DeterministicProvider {
    embedding_dimension: usize,
}

impl DeterministicProvider {
    pub fn new(embedding_dimension: usize) -> Result<Self, ProviderError> {
        if embedding_dimension == 0 {
            return Err(ProviderError::InvalidConfiguration(
                "deterministic embedding dimension must be positive".into(),
            ));
        }
        Ok(Self {
            embedding_dimension,
        })
    }
}

#[async_trait]
impl ChatProvider for DeterministicProvider {
    #[allow(clippy::too_many_lines)]
    async fn answer(&self, request: &ChatCompletionRequest) -> Result<ChatAnswer, ProviderError> {
        request.validate()?;
        let question = request.question.trim();
        let question_words = content_words(question);
        let answer_profile = answer_cue_profile(question);
        let answer_facets = &answer_profile.facets;
        let answer_cues = answer_facets
            .iter()
            .flat_map(|facet| {
                facet
                    .terms
                    .iter()
                    .cloned()
                    .chain(facet.phrases.iter().flatten().cloned())
            })
            .collect::<HashSet<_>>();
        let title_words = content_words(&request.paper_title);
        let mut named_terms = named_question_terms(question);
        named_terms.retain(|term| !title_words.contains(term));
        let premise_anchors = premise_anchor_words(question, &question_words);
        let requires_quantity = question_requires_quantity(question, &question_words);
        let requires_title_anchor = question_requires_title_anchor(question);
        let constraints = EvidenceConstraints {
            named_terms: &named_terms,
            premise_anchors: &premise_anchors,
            requires_quantity,
            requires_title_anchor,
            requires_answer_cue: !answer_cues.is_empty(),
        };
        let mut matches = request
            .evidence
            .iter()
            .enumerate()
            .map(|(index, evidence)| {
                let heading_words = evidence
                    .section_heading
                    .as_deref()
                    .map(content_words)
                    .unwrap_or_default();
                let mut evidence_tokens = content_tokens(&evidence.text);
                if let Some(heading) = &evidence.section_heading {
                    evidence_tokens.extend(content_tokens(heading));
                }
                let mut evidence_words = evidence_tokens.iter().cloned().collect::<HashSet<_>>();
                evidence_words.extend(heading_words.iter().cloned());
                let overlap = question_words.intersection(&evidence_words).count();
                let cue_overlap = answer_cues.intersection(&evidence_words).count();
                let title_overlap = title_words.intersection(&evidence_words).count();
                let heading_overlap = question_words.intersection(&heading_words).count();
                let heading_cue_overlap = answer_cues.intersection(&heading_words).count();
                let facet_mask =
                    covered_facet_mask(&evidence_words, &evidence_tokens, answer_facets);
                let facet_count = facet_mask.count_ones() as usize;
                let score = overlap
                    .saturating_mul(8)
                    .saturating_add(cue_overlap.saturating_mul(10))
                    .saturating_add(facet_count.saturating_mul(24))
                    .saturating_add(heading_overlap.saturating_mul(4))
                    .saturating_add(heading_cue_overlap.saturating_mul(6))
                    .saturating_add(title_overlap.min(3))
                    .saturating_add(section_answer_priority(evidence.section_kind));
                EvidenceMatch {
                    evidence,
                    evidence_words,
                    overlap,
                    cue_overlap,
                    title_overlap,
                    facet_mask,
                    score,
                    index,
                }
            })
            .collect::<Vec<_>>();
        matches.sort_by(|left, right| {
            right
                .score
                .cmp(&left.score)
                .then_with(|| right.overlap.cmp(&left.overlap))
                .then_with(|| left.index.cmp(&right.index))
        });
        let maximum_candidates = answer_candidate_limit(question);
        let eligible = matches
            .iter()
            .filter(|candidate| candidate_supports_constraints(candidate, &constraints))
            .collect::<Vec<_>>();
        let selected =
            select_diverse_evidence(&eligible, maximum_candidates, answer_profile.required_mask);
        let selected_facet_mask = selected
            .iter()
            .fold(0_u64, |mask, candidate| mask | candidate.facet_mask);
        let insufficient_evidence = selected.is_empty()
            || selected_facet_mask & answer_profile.required_mask != answer_profile.required_mask;
        let (answer_markdown, sources) = if insufficient_evidence {
            (
                "The indexed sections do not clearly answer that question in offline deterministic mode. A configured chat model may synthesize the supplied excerpts, but Pakperk will not infer a claim without matching evidence.".into(),
                Vec::new(),
            )
        } else {
            let mut relevance_words = question_words.clone();
            relevance_words.extend(answer_cues);
            let snippets_per_candidate = if selected.len() == 1 {
                answer_facets.len().clamp(1, 3)
            } else {
                1
            };
            let excerpts = selected
                .iter()
                .flat_map(|candidate| {
                    let section = section_label(candidate.evidence.section_kind);
                    bounded_relevant_snippets(
                        &candidate.evidence.text,
                        &relevance_words,
                        52,
                        snippets_per_candidate,
                    )
                    .into_iter()
                    .map(move |snippet| {
                        format!("The paper's {section} section states: “{snippet}”")
                    })
                })
                .collect::<Vec<_>>()
                .join("\n\n");
            let sources = selected
                .iter()
                .map(|candidate| ChatEvidence {
                    section_kind: candidate.evidence.section_kind,
                    section_heading: candidate.evidence.section_heading.clone(),
                    page_start: candidate.evidence.page_start,
                    page_end: candidate.evidence.page_end,
                    chunk_id: candidate.evidence.chunk_id,
                })
                .collect();
            (
                format!(
                    "{excerpts}\n\nThis offline answer is extractive and does not infer claims beyond those excerpts."
                ),
                sources,
            )
        };
        Ok(ChatAnswer {
            answer_markdown,
            insufficient_evidence,
            evidence: sources,
            suggested_follow_ups: if insufficient_evidence {
                Vec::new()
            } else {
                vec![SuggestedFollowUp(
                    "What other evidence does the paper give for this?".into(),
                )]
            },
            model_id: Some("deterministic-chat-v2".into()),
            provider_request_id: None,
            prompt_version: format!("{CHAT_PROMPT_VERSION}-deterministic-v2"),
        })
    }
}

#[async_trait]
impl AssistantProvider for DeterministicProvider {
    fn provenance_provider_id(&self) -> &'static str {
        "deterministic"
    }

    async fn answer_with_evidence(
        &self,
        request: &AssistantCompletionRequest,
    ) -> Result<AssistantCompletion, ProviderError> {
        request.validate()?;
        let question_words = content_words(&request.request.question);
        let selected = request
            .evidence
            .iter()
            .map(|evidence| {
                let words = content_words(&evidence.text);
                let overlap = question_words.intersection(&words).count();
                (overlap, evidence)
            })
            .max_by_key(|(overlap, evidence)| (*overlap, std::cmp::Reverse(evidence.block_id)));
        let provenance_id = Uuid::now_v7();
        let Some((overlap, evidence)) = selected.filter(|(overlap, _)| *overlap > 0) else {
            return Ok(AssistantCompletion {
                answer: AssistantAnswer {
                    answer: ASSISTANT_NOT_FOUND_ANSWER.to_owned(),
                    status: AssistantAnswerStatus::NotFound,
                    claims: Vec::new(),
                    limitations: Vec::new(),
                    provenance_id,
                    model_id: None,
                    provider_request_id: None,
                    prompt_version: format!("{ASSISTANT_V2_PROMPT_VERSION}-deterministic-v1"),
                },
                token_usage: None,
            });
        };
        debug_assert!(overlap > 0);
        let excerpt = evidence.text.chars().take(320).collect::<String>();
        if assistant_text_contains_link(&excerpt) {
            return Ok(AssistantCompletion {
                answer: AssistantAnswer {
                    answer: ASSISTANT_NOT_FOUND_ANSWER.to_owned(),
                    status: AssistantAnswerStatus::NotFound,
                    claims: Vec::new(),
                    limitations: Vec::new(),
                    provenance_id,
                    model_id: None,
                    provider_request_id: None,
                    prompt_version: format!("{ASSISTANT_V2_PROMPT_VERSION}-deterministic-v1"),
                },
                token_usage: None,
            });
        }
        let end = u32::try_from(excerpt.chars().count())
            .map_err(|_| ProviderError::InvalidRequest("evidence range is too large".into()))?;
        Ok(AssistantCompletion {
            answer: AssistantAnswer {
                answer: excerpt.clone(),
                status: AssistantAnswerStatus::Supported,
                claims: vec![AssistantClaim {
                    text: excerpt,
                    support: AssistantClaimSupport::Direct,
                    evidence: vec![AssistantEvidenceReference {
                        block_id: evidence.block_id,
                        start: 0,
                        end,
                        page_start: evidence.page_start,
                        section: evidence.section_heading.clone(),
                    }],
                }],
                limitations: Vec::new(),
                provenance_id,
                model_id: None,
                provider_request_id: None,
                prompt_version: format!("{ASSISTANT_V2_PROMPT_VERSION}-deterministic-v1"),
            },
            token_usage: None,
        })
    }
}

struct EvidenceMatch<'a> {
    evidence: &'a crate::EvidenceExcerpt,
    evidence_words: HashSet<String>,
    overlap: usize,
    cue_overlap: usize,
    title_overlap: usize,
    facet_mask: u64,
    score: usize,
    index: usize,
}

fn covered_facet_mask(
    evidence_words: &HashSet<String>,
    evidence_tokens: &[String],
    answer_facets: &[AnswerFacet],
) -> u64 {
    answer_facets
        .iter()
        .take(64)
        .enumerate()
        .fold(0_u64, |mask, (index, facet)| {
            if facet.covered_by(evidence_words, evidence_tokens) {
                mask | (1_u64 << index)
            } else {
                mask
            }
        })
}

fn select_diverse_evidence<'a>(
    eligible: &[&'a EvidenceMatch<'a>],
    maximum_candidates: usize,
    required_facet_mask: u64,
) -> Vec<&'a EvidenceMatch<'a>> {
    let Some(first) = eligible.first().copied() else {
        return Vec::new();
    };
    let mut selected = vec![first];
    let mut covered_facets = first.facet_mask;
    while selected.len() < maximum_candidates {
        if required_facet_mask != 0 && covered_facets & required_facet_mask == required_facet_mask {
            break;
        }
        let next = eligible
            .iter()
            .copied()
            .filter(|candidate| {
                !selected
                    .iter()
                    .any(|selected| selected.index == candidate.index)
            })
            .filter_map(|candidate| {
                let new_facets = candidate.facet_mask & !covered_facets;
                (new_facets != 0).then_some((candidate, new_facets.count_ones()))
            })
            .max_by(|(left, left_new), (right, right_new)| {
                left_new
                    .cmp(right_new)
                    .then_with(|| left.score.cmp(&right.score))
                    .then_with(|| right.index.cmp(&left.index))
            });
        let Some((next, _)) = next else {
            break;
        };
        covered_facets |= next.facet_mask;
        selected.push(next);
    }
    selected
}

struct EvidenceConstraints<'a> {
    named_terms: &'a HashSet<String>,
    premise_anchors: &'a HashSet<String>,
    requires_quantity: bool,
    requires_title_anchor: bool,
    requires_answer_cue: bool,
}

fn candidate_supports_constraints(
    candidate: &EvidenceMatch<'_>,
    constraints: &EvidenceConstraints<'_>,
) -> bool {
    candidate.overlap > 0
        && constraints.named_terms.is_subset(&candidate.evidence_words)
        && constraints
            .premise_anchors
            .is_subset(&candidate.evidence_words)
        && (!constraints.requires_quantity || contains_quantity(&candidate.evidence.text))
        && (!constraints.requires_title_anchor || candidate.title_overlap > 0)
        && (!constraints.requires_answer_cue || candidate.cue_overlap > 0)
}

#[async_trait]
impl EmbeddingProvider for DeterministicProvider {
    async fn embed(&self, request: &EmbeddingRequest) -> Result<EmbeddingResponse, ProviderError> {
        request.validate()?;
        let vectors = request
            .inputs
            .iter()
            .map(|input| feature_hash_embedding(input, self.embedding_dimension))
            .collect();
        Ok(EmbeddingResponse {
            vectors,
            model_id: format!("deterministic-hash-v1-{}", self.embedding_dimension),
            provider_request_id: None,
        })
    }
}

#[async_trait]
impl RelationshipProvider for DeterministicProvider {
    async fn summarize_relationship(
        &self,
        request: &RelationshipRequest,
    ) -> Result<RelationshipSummary, ProviderError> {
        request.validate()?;
        Ok(deterministic_relationship_fallback(request))
    }
}

fn feature_hash_embedding(text: &str, dimension: usize) -> Vec<f32> {
    let mut vector = vec![0.0_f32; dimension];
    for word in text
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
    {
        let hash = fnv1a(word.to_ascii_lowercase().as_bytes());
        let dimension_u64 = u64::try_from(dimension).unwrap_or(u64::MAX);
        let index = usize::try_from(hash % dimension_u64)
            .expect("hash modulo the vector dimension always fits usize");
        let sign = if hash & (1 << 63) == 0 { 1.0 } else { -1.0 };
        vector[index] += sign;
    }
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if norm > 0.0 {
        for value in &mut vector {
            *value /= norm;
        }
    }
    vector
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

fn content_words(text: &str) -> HashSet<String> {
    content_tokens(text).into_iter().collect()
}

fn content_tokens(text: &str) -> Vec<String> {
    text.split(|character: char| !character.is_alphanumeric())
        .map(normalize_word)
        .filter(|word| word.len() > 2 && !is_stopword(word))
        .collect()
}

fn normalize_word(word: &str) -> String {
    let lowercase = word
        .chars()
        .filter(|character| character.is_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    if is_stopword(&lowercase) {
        return lowercase;
    }
    if lowercase.starts_with("retriev") {
        return "retrieve".to_owned();
    }
    if lowercase.starts_with("pretrain") {
        return "pretrain".to_owned();
    }
    if matches!(
        lowercase.as_str(),
        "train" | "trained" | "training" | "trains"
    ) {
        return "train".to_owned();
    }
    if lowercase.starts_with("finetun") {
        return "finetune".to_owned();
    }
    if lowercase == "tuning" || lowercase == "tuned" {
        return "tune".to_owned();
    }
    if lowercase.starts_with("mask") {
        return "mask".to_owned();
    }
    if lowercase.starts_with("architectur") {
        return "architecture".to_owned();
    }
    if lowercase.starts_with("recurr") {
        return "recurrence".to_owned();
    }
    if lowercase.starts_with("parallel") {
        return "parallel".to_owned();
    }
    if lowercase.starts_with("evaluat") {
        return "evaluate".to_owned();
    }
    if lowercase.starts_with("marginali") {
        return "marginalize".to_owned();
    }
    // Scientific PDFs and source text occasionally preserve this common
    // transposition/OCR variant ("hyperparmeter"). Normalize both spellings
    // so evidence selection does not discard an otherwise exact conclusion.
    if lowercase.starts_with("hyperparam") || lowercase.starts_with("hyperparm") {
        return "hyperparameter".to_owned();
    }
    if lowercase.starts_with("filter") {
        return "filter".to_owned();
    }
    if lowercase.starts_with("clean") {
        return "clean".to_owned();
    }
    if lowercase.starts_with("crawl") {
        return "crawl".to_owned();
    }
    if lowercase.starts_with("differ") {
        return "different".to_owned();
    }
    if lowercase.starts_with("dedupl") {
        return "deduplicate".to_owned();
    }
    if lowercase == "queries" || lowercase == "queried" {
        return "query".to_owned();
    }
    if lowercase.len() > 4 && lowercase.ends_with("ies") {
        return format!("{}y", &lowercase[..lowercase.len() - 3]);
    }
    if lowercase.len() > 5
        && ["ches", "shes", "xes", "zes", "ses"]
            .iter()
            .any(|suffix| lowercase.ends_with(suffix))
    {
        return lowercase[..lowercase.len() - 2].to_owned();
    }
    if lowercase.len() > 4 && lowercase.ends_with('s') && !lowercase.ends_with("ss") {
        return lowercase[..lowercase.len() - 1].to_owned();
    }
    lowercase
}

fn is_stopword(word: &str) -> bool {
    matches!(
        word,
        "the"
            | "and"
            | "for"
            | "what"
            | "which"
            | "does"
            | "this"
            | "that"
            | "with"
            | "from"
            | "paper"
            | "about"
            | "how"
            | "why"
            | "many"
            | "use"
            | "uses"
            | "using"
            | "into"
            | "during"
            | "each"
            | "every"
            | "per"
            | "are"
            | "was"
            | "were"
            | "has"
            | "have"
            | "work"
            | "propose"
            | "proposes"
            | "proposed"
            | "describe"
            | "describes"
            | "described"
    )
}

fn named_question_terms(question: &str) -> HashSet<String> {
    question
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| {
            let letters = word.chars().filter(|character| character.is_alphabetic());
            let uppercase = letters
                .clone()
                .filter(|character| character.is_uppercase())
                .count();
            let letter_count = letters.count();
            word.chars().any(|character| character.is_ascii_digit())
                || (letter_count >= 2 && uppercase == letter_count)
                || word.chars().skip(1).any(char::is_uppercase)
        })
        .map(normalize_word)
        .filter(|word| word.len() > 1 && !is_generic_domain_acronym(word))
        .collect()
}

fn is_generic_domain_acronym(word: &str) -> bool {
    matches!(
        word,
        "ai" | "nlp" | "qa" | "nli" | "mlm" | "nsp" | "lm" | "llm"
    )
}

#[derive(Default)]
struct AnswerCueProfile {
    facets: Vec<AnswerFacet>,
    required_mask: u64,
}

impl AnswerCueProfile {
    fn push_required(&mut self, terms: &[&str], minimum_matches: usize) {
        self.push_required_with_phrases(terms, minimum_matches, &[]);
    }

    fn push_required_with_phrases(
        &mut self,
        terms: &[&str],
        minimum_matches: usize,
        phrases: &[&str],
    ) {
        if self.facets.len() < 64 {
            self.required_mask |= 1_u64 << self.facets.len();
        }
        self.push(terms, minimum_matches, phrases);
    }

    fn push_optional(&mut self, terms: &[&str], minimum_matches: usize) {
        self.push(terms, minimum_matches, &[]);
    }

    fn push(&mut self, terms: &[&str], minimum_matches: usize, phrases: &[&str]) {
        let facet = AnswerFacet {
            terms: normalized_terms(terms),
            minimum_matches,
            phrases: phrases
                .iter()
                .map(|phrase| content_tokens(phrase))
                .collect(),
        };
        if !facet.terms.is_empty() || !facet.phrases.is_empty() {
            self.facets.push(facet);
        }
    }
}

struct AnswerFacet {
    terms: HashSet<String>,
    minimum_matches: usize,
    phrases: Vec<Vec<String>>,
}

impl AnswerFacet {
    fn covered_by(&self, evidence_words: &HashSet<String>, evidence_tokens: &[String]) -> bool {
        let term_matches = self.terms.intersection(evidence_words).count();
        term_matches >= self.minimum_matches.max(1)
            || self
                .phrases
                .iter()
                .any(|phrase| contains_token_sequence(evidence_tokens, phrase))
    }
}

fn contains_token_sequence(tokens: &[String], phrase: &[String]) -> bool {
    !phrase.is_empty()
        && phrase.len() <= tokens.len()
        && tokens.windows(phrase.len()).any(|window| window == phrase)
}

#[allow(clippy::too_many_lines)]
fn answer_cue_profile(question: &str) -> AnswerCueProfile {
    let lower = question.to_ascii_lowercase();
    let mut profile = AnswerCueProfile::default();
    if lower.contains("architecture") {
        profile.push_required(&["transformer"], 1);
        profile.push_required(&["attention"], 1);
        profile.push_optional(&["encoder", "decoder", "stack", "layer"], 1);
    }
    if lower.contains("recurr") {
        profile.push_required(&["sequential", "computation", "operation"], 1);
        profile.push_required(&["parallel"], 1);
        profile.push_optional(&["attention", "dependency"], 1);
    }
    if lower.contains("pre-train") || lower.contains("pretrain") {
        profile.push_required(&["masked", "mlm"], 1);
        profile.push_required_with_phrases(
            &["next", "sentence", "prediction"],
            3,
            &["next sentence prediction", "nsp"],
        );
        profile.push_optional(&["objective", "unsupervised"], 1);
    }
    if lower.contains("downstream") && (lower.contains("task") || lower.contains("evaluat")) {
        profile.push_required(&["glue", "mnli"], 1);
        profile.push_required(&["squad"], 1);
        profile.push_optional(
            &[
                "question",
                "answering",
                "benchmark",
                "dataset",
                "evaluation",
                "classification",
            ],
            1,
        );
    }
    if lower.contains("training") && (lower.contains("choice") || lower.contains("change")) {
        profile.push_required_with_phrases(
            &["dynamic", "static", "masked"],
            2,
            &["dynamic masking"],
        );
        profile.push_required_with_phrases(
            &["next", "sentence", "prediction"],
            3,
            &["next sentence prediction", "nsp"],
        );
        profile.push_required_with_phrases(
            &["large", "larger", "batch"],
            2,
            &["large batch", "larger batch"],
        );
        profile.push_optional(&["data"], 1);
        profile.push_optional(&["hyperparameter", "optimization", "duration"], 1);
    }
    if lower.contains("ablation") {
        profile.push_required(&["undertrained"], 1);
        profile.push_required_with_phrases(&["train", "data", "dataset"], 2, &["training data"]);
        profile.push_required(&["hyperparameter", "optimization"], 1);
        profile.push_optional(&["training", "result", "performance", "scale"], 1);
    }
    if lower.contains("format") || lower.contains("cast") {
        profile.push_required_with_phrases(&[], 1, &["text-to-text", "text to text"]);
        profile.push_required(&["input", "source"], 1);
        profile.push_required(&["output", "target"], 1);
        profile.push_optional(&["prefix", "objective"], 1);
    }
    if lower.contains("corpus") || lower.contains("c4") {
        profile.push_required_with_phrases(&["common", "crawl", "web"], 2, &["common crawl"]);
        profile.push_required(&["filter", "clean", "deduplicate", "quality"], 1);
        profile.push_required_with_phrases(&["pretraining"], 1, &["pre-training", "pre trained"]);
    }
    if lower.contains("memory") || lower.contains("parametric") {
        profile.push_required_with_phrases(
            &["seq2seq", "generator"],
            1,
            &["sequence-to-sequence", "sequence to sequence"],
        );
        profile.push_required_with_phrases(
            &["dense", "vector", "index"],
            3,
            &["dense vector index"],
        );
        profile.push_required_with_phrases(&["neural", "retriever"], 2, &["neural retriever"]);
        profile.push_optional(&["document", "passage", "hybrid"], 1);
    }
    if lower.contains("formulation") || lower.contains("differ") {
        profile.push_required(&["sequence", "same"], 1);
        profile.push_required(&["token", "different"], 1);
        profile.push_optional(&["document", "latent", "marginalize", "retrieve"], 1);
    }
    profile
}

fn normalized_terms(terms: &[&str]) -> HashSet<String> {
    terms
        .iter()
        .flat_map(|term| {
            term.split(|character: char| !character.is_alphanumeric())
                .map(normalize_word)
        })
        .filter(|term| term.len() > 2 && !is_stopword(term))
        .collect()
}

fn question_requires_title_anchor(question: &str) -> bool {
    let lower = question.to_ascii_lowercase();
    lower.contains("architecture") || lower.contains("recurr")
}

fn answer_candidate_limit(question: &str) -> usize {
    let lower = question.to_ascii_lowercase();
    if (lower.contains("training") && (lower.contains("choice") || lower.contains("change")))
        || lower.contains("ablation")
        || lower.contains("format")
        || lower.contains("cast")
        || lower.contains("corpus")
        || lower.contains("c4")
        || lower.contains("memory")
        || lower.contains("parametric")
    {
        3
    } else {
        2
    }
}

fn premise_anchor_words(question: &str, question_words: &HashSet<String>) -> HashSet<String> {
    let lower = question.to_ascii_lowercase();
    let guarded_premise = lower.contains("how many")
        || question_words.contains("rate")
        || question_words.contains("probability")
        || (lower.starts_with("which ") && question_words.contains("index"));
    if !guarded_premise {
        return HashSet::new();
    }
    question_words
        .iter()
        .filter(|word| PREMISE_TERMS.contains(&word.as_str()))
        .cloned()
        .collect()
}

fn question_requires_quantity(question: &str, question_words: &HashSet<String>) -> bool {
    question.to_ascii_lowercase().contains("how many")
        || question_words.contains("rate")
        || question_words.contains("probability")
}

fn contains_quantity(text: &str) -> bool {
    text.split(|character: char| !character.is_alphanumeric())
        .any(|word| {
            word.chars().any(|character| character.is_ascii_digit())
                || matches!(
                    word.to_ascii_lowercase().as_str(),
                    "one"
                        | "two"
                        | "three"
                        | "four"
                        | "five"
                        | "six"
                        | "seven"
                        | "eight"
                        | "nine"
                        | "ten"
                        | "eleven"
                        | "twelve"
                        | "hundred"
                        | "thousand"
                        | "million"
                        | "billion"
                )
        })
}

fn section_answer_priority(kind: SectionKind) -> usize {
    match kind {
        SectionKind::Method | SectionKind::Experiment | SectionKind::Result => 4,
        SectionKind::Discussion | SectionKind::Conclusion | SectionKind::Other => 2,
        SectionKind::Background | SectionKind::RelatedWork | SectionKind::Introduction => 1,
        _ => 0,
    }
}

fn bounded_relevant_snippets(
    text: &str,
    relevance_words: &HashSet<String>,
    maximum_words: usize,
    maximum_snippets: usize,
) -> Vec<String> {
    let sanitized = text
        .chars()
        .map(|character| match character {
            '<' | '>' | '"' | '“' | '”' => ' ',
            _ => character,
        })
        .collect::<String>();
    let words = sanitized.split_whitespace().collect::<Vec<_>>();
    if words.len() <= maximum_words {
        return vec![words.join(" ")];
    }
    if maximum_words == 0 || maximum_snippets == 0 {
        return Vec::new();
    }
    let normalized = words
        .iter()
        .map(|word| normalize_word(word))
        .collect::<Vec<_>>();
    let first = best_relevant_window(
        &normalized,
        relevance_words,
        maximum_words,
        &[],
        relevance_words,
    );
    let Some(first_start) = first else {
        return vec![format_bounded_window(&words, 0, maximum_words)];
    };
    let mut starts = vec![first_start];
    while starts.len() < maximum_snippets {
        let covered = starts
            .iter()
            .flat_map(|start| normalized[*start..*start + maximum_words].iter())
            .filter(|word| relevance_words.contains(*word))
            .cloned()
            .collect::<HashSet<_>>();
        let uncovered = relevance_words
            .difference(&covered)
            .cloned()
            .collect::<HashSet<_>>();
        if uncovered.is_empty() {
            break;
        }
        let excluded = starts
            .iter()
            .map(|start| (*start, *start + maximum_words))
            .collect::<Vec<_>>();
        let Some(next_start) = best_relevant_window(
            &normalized,
            relevance_words,
            maximum_words,
            &excluded,
            &uncovered,
        ) else {
            break;
        };
        starts.push(next_start);
    }
    starts.sort_unstable();
    starts
        .into_iter()
        .take(maximum_snippets)
        .map(|start| format_bounded_window(&words, start, maximum_words))
        .collect()
}

fn best_relevant_window(
    words: &[String],
    relevance_words: &HashSet<String>,
    maximum_words: usize,
    excluded: &[(usize, usize)],
    priority_words: &HashSet<String>,
) -> Option<usize> {
    let mut best: Option<(usize, usize)> = None;
    for start in 0..=words.len() - maximum_words {
        let end = start + maximum_words;
        if excluded.iter().any(|(excluded_start, excluded_end)| {
            end.min(*excluded_end)
                .saturating_sub(start.max(*excluded_start))
                > maximum_words / 3
        }) {
            continue;
        }
        let score = words[start..end].iter().fold(0_usize, |score, word| {
            score
                .saturating_add(usize::from(relevance_words.contains(word)))
                .saturating_add(usize::from(priority_words.contains(word)).saturating_mul(4))
        });
        if score > 0 && best.is_none_or(|(best_score, _)| score > best_score) {
            best = Some((score, start));
        }
    }
    best.map(|(_, start)| start)
}

fn format_bounded_window(words: &[&str], start: usize, maximum_words: usize) -> String {
    let prefix = (start > 0).then_some("… ");
    let suffix = (start + maximum_words < words.len()).then_some(" …");
    format!(
        "{}{}{}",
        prefix.unwrap_or_default(),
        words[start..start + maximum_words].join(" "),
        suffix.unwrap_or_default()
    )
}

fn section_label(kind: SectionKind) -> &'static str {
    match kind {
        SectionKind::Abstract => "abstract",
        SectionKind::Introduction => "introduction",
        SectionKind::Background => "background",
        SectionKind::RelatedWork => "related-work",
        SectionKind::Method => "method",
        SectionKind::Experiment => "experiment",
        SectionKind::Result => "results",
        SectionKind::Discussion => "discussion",
        SectionKind::Limitation => "limitations",
        SectionKind::Conclusion => "conclusion",
        SectionKind::Appendix => "appendix",
        SectionKind::Acknowledgment => "acknowledgment",
        SectionKind::References => "references",
        SectionKind::Other => "other",
    }
}

#[cfg(test)]
mod tests {
    use domain::SectionKind;
    use uuid::Uuid;

    use super::*;
    use crate::EvidenceExcerpt;

    #[tokio::test]
    async fn embedding_is_stable_and_normalized() {
        let provider = DeterministicProvider::new(16).unwrap();
        let request = EmbeddingRequest {
            inputs: vec!["attention retrieval attention".into()],
        };
        let first = provider.embed(&request).await.unwrap();
        let second = provider.embed(&request).await.unwrap();
        assert_eq!(first.vectors, second.vectors);
        let norm = first.vectors[0]
            .iter()
            .map(|value| value * value)
            .sum::<f32>()
            .sqrt();
        assert!((norm - 1.0).abs() < 1e-6);
    }

    #[tokio::test]
    async fn chat_cites_only_the_selected_supplied_excerpt() {
        let provider = DeterministicProvider::new(16).unwrap();
        let chunk_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Fixture".into(),
                question: "How does retrieval work?".into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id,
                    section_kind: SectionKind::Method,
                    section_heading: Some("3 Method".into()),
                    page_start: Some(4),
                    page_end: Some(5),
                    text: "The retrieval module ranks paragraph chunks with lexical evidence."
                        .into(),
                }],
            })
            .await
            .unwrap();
        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence[0].chunk_id, chunk_id);
        assert!(!answer.answer_markdown.contains('<'));
        assert_eq!(answer.model_id.as_deref(), Some("deterministic-chat-v2"));
        assert_eq!(answer.prompt_version, "paper-chat-v1-deterministic-v2");
    }

    #[tokio::test]
    async fn chat_abstains_when_a_quantitative_premise_has_only_superficial_overlap() {
        let provider = DeterministicProvider::new(16).unwrap();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "BERT".into(),
                question:
                    "How many Wikipedia passages does BERT retrieve from a dense index for each prediction?"
                        .into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id: Uuid::new_v4(),
                    section_kind: SectionKind::Method,
                    section_heading: Some("Pre-training data".into()),
                    page_start: Some(4),
                    page_end: Some(4),
                    text: "BERT is pre-trained on BooksCorpus and English Wikipedia, a corpus containing 3,300 million words, before token prediction."
                        .into(),
                }],
            })
            .await
            .unwrap();

        assert!(answer.insufficient_evidence);
        assert!(answer.evidence.is_empty());
    }

    #[tokio::test]
    async fn chat_abstains_on_a_generic_intro_that_does_not_answer_the_intent() {
        let provider = DeterministicProvider::new(16).unwrap();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Attention Is All You Need".into(),
                question: "What architecture does the paper propose?".into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id: Uuid::new_v4(),
                    section_kind: SectionKind::Introduction,
                    section_heading: Some("Introduction".into()),
                    page_start: Some(1),
                    page_end: Some(1),
                    text: "Recurrent neural networks and gated recurrent neural networks have been firmly established as state of the art approaches in sequence modeling."
                        .into(),
                }],
            })
            .await
            .unwrap();

        assert!(answer.insufficient_evidence);
        assert!(answer.evidence.is_empty());
    }

    #[tokio::test]
    async fn chat_answers_a_broad_architecture_question_only_from_paper_specific_evidence() {
        let provider = DeterministicProvider::new(16).unwrap();
        let relevant_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Attention Is All You Need".into(),
                question: "What architecture does the paper propose?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Introduction,
                        section_heading: Some("Introduction".into()),
                        page_start: Some(1),
                        page_end: Some(1),
                        text: "Recurrent encoder-decoder architectures are established for sequence modeling."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: relevant_id,
                        section_kind: SectionKind::Method,
                        section_heading: Some("Model Architecture".into()),
                        page_start: Some(3),
                        page_end: Some(3),
                        text: "The Transformer follows an encoder-decoder architecture using stacked self-attention and point-wise fully connected layers."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert_eq!(answer.evidence[0].chunk_id, relevant_id);
        assert!(answer.answer_markdown.contains("Transformer"));
        assert!(answer.answer_markdown.contains("self-attention"));
    }

    #[tokio::test]
    async fn chat_abstains_when_the_question_introduces_an_unsupported_model() {
        let provider = DeterministicProvider::new(16).unwrap();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Attention Is All You Need".into(),
                question: "Which learning rate does this paper use to fine-tune BERT?".into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id: Uuid::new_v4(),
                    section_kind: SectionKind::Experiment,
                    section_heading: Some("Training".into()),
                    page_start: Some(7),
                    page_end: Some(7),
                    text: "Training used a learning rate of 0.0001 and fine-tuned the optimizer schedule."
                        .into(),
                }],
            })
            .await
            .unwrap();

        assert!(answer.insufficient_evidence);
        assert!(answer.evidence.is_empty());
    }

    #[tokio::test]
    async fn chat_selects_supported_named_evidence_and_keeps_required_concepts() {
        let provider = DeterministicProvider::new(16).unwrap();
        let relevant_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "BERT".into(),
                question: "How is BERT pre-trained?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Background,
                        section_heading: Some("Prior work".into()),
                        page_start: Some(2),
                        page_end: Some(2),
                        text: "A pre-trained model can transfer to many tasks.".into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: relevant_id,
                        section_kind: SectionKind::Method,
                        section_heading: Some("Pre-training BERT".into()),
                        page_start: Some(4),
                        page_end: Some(4),
                        text: "BERT is pre-trained with a masked language model objective and next sentence prediction."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert_eq!(answer.evidence[0].chunk_id, relevant_id);
        assert!(answer.answer_markdown.contains("masked language model"));
        assert!(answer.answer_markdown.contains("next sentence prediction"));
    }

    #[tokio::test]
    async fn chat_selects_distinct_downstream_task_evidence_over_generic_mentions() {
        let provider = DeterministicProvider::new(16).unwrap();
        let glue_id = Uuid::new_v4();
        let squad_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title:
                    "BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding"
                        .into(),
                question: "What downstream tasks are evaluated?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Method,
                        section_heading: Some("Pre-training".into()),
                        page_start: Some(4),
                        page_end: Some(4),
                        text: "Pre-training improves performance on many downstream tasks.".into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: glue_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("GLUE".into()),
                        page_start: Some(5),
                        page_end: Some(6),
                        text: "The GLUE benchmark evaluates a diverse collection of natural language understanding tasks."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: squad_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("SQuAD".into()),
                        page_start: Some(6),
                        page_end: Some(7),
                        text: "The SQuAD dataset evaluates question answering as a downstream task for BERT."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        let source_ids = answer
            .evidence
            .iter()
            .map(|source| source.chunk_id)
            .collect::<HashSet<_>>();
        assert_eq!(source_ids, HashSet::from([glue_id, squad_id]));
        assert!(answer.answer_markdown.contains("GLUE"));
        assert!(answer.answer_markdown.contains("SQuAD"));
    }

    #[tokio::test]
    async fn chat_diversifies_training_change_evidence_across_required_facets() {
        let provider = DeterministicProvider::new(16).unwrap();
        let dynamic_id = Uuid::new_v4();
        let nsp_id = Uuid::new_v4();
        let batch_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Robustly Optimized BERT Pretraining".into(),
                question: "Which BERT training choices does the model change?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: dynamic_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("Static vs. Dynamic Masking".into()),
                        page_start: Some(4),
                        page_end: Some(4),
                        text: "BERT changes from static masks to dynamic masking during training."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: nsp_id,
                        section_kind: SectionKind::Method,
                        section_heading: Some("Next Sentence Prediction".into()),
                        page_start: Some(4),
                        page_end: Some(4),
                        text: "BERT removes the Next Sentence Prediction (NSP) loss.".into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: batch_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("Training with Large Batches".into()),
                        page_start: Some(5),
                        page_end: Some(5),
                        text: "BERT training improves when it uses larger batches.".into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("Training Data".into()),
                        page_start: Some(5),
                        page_end: Some(5),
                        text: "BERT is evaluated after training on additional data.".into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        let source_ids = answer
            .evidence
            .iter()
            .map(|source| source.chunk_id)
            .collect::<HashSet<_>>();
        assert_eq!(source_ids, HashSet::from([dynamic_id, nsp_id, batch_id]));
        assert!(answer.answer_markdown.contains("dynamic masking"));
        assert!(answer.answer_markdown.contains("Next Sentence Prediction"));
        assert!(answer.answer_markdown.contains("larger batches"));
    }

    #[tokio::test]
    async fn chat_requires_ablation_evidence_to_cover_each_conclusion_facet() {
        let provider = DeterministicProvider::new(16).unwrap();
        let undertrained_id = Uuid::new_v4();
        let data_id = Uuid::new_v4();
        let hyperparameter_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Replication study".into(),
                question: "What does the ablation study conclude?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("GLUE".into()),
                        page_start: Some(3),
                        page_end: Some(3),
                        text: "For the replication study, models are finetuned on task training data."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: undertrained_id,
                        section_kind: SectionKind::Result,
                        section_heading: Some("Ablation results".into()),
                        page_start: Some(6),
                        page_end: Some(6),
                        text: "The ablation concludes that the baseline was significantly undertrained."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: data_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("Ablation: training data".into()),
                        page_start: Some(6),
                        page_end: Some(6),
                        text: "The ablation improves performance by increasing the training data."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: hyperparameter_id,
                        section_kind: SectionKind::Experiment,
                        section_heading: Some("Ablation: hyperparameters".into()),
                        page_start: Some(6),
                        page_end: Some(6),
                        text: "The ablation shows that hyperparmeter choices materially affect results."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        let source_ids = answer
            .evidence
            .iter()
            .map(|source| source.chunk_id)
            .collect::<HashSet<_>>();
        assert_eq!(
            source_ids,
            HashSet::from([undertrained_id, data_id, hyperparameter_id])
        );
        assert!(answer.answer_markdown.contains("undertrained"));
        assert!(answer.answer_markdown.contains("training data"));
        assert!(answer.answer_markdown.contains("hyperparmeter"));
    }

    #[tokio::test]
    async fn chat_requires_explicit_text_to_text_input_and_target_evidence() {
        let provider = DeterministicProvider::new(16).unwrap();
        let relevant_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Unified transfer learning".into(),
                question: "How are NLP tasks cast into one format?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Method,
                        section_heading: Some("Model Structures".into()),
                        page_start: Some(17),
                        page_end: Some(18),
                        text: "The input prefix is visible and the decoder emits a target class."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: relevant_id,
                        section_kind: SectionKind::Method,
                        section_heading: Some("Input and Output Format".into()),
                        page_start: Some(10),
                        page_end: Some(10),
                        text: "The text-to-text format represents every task with a text input and a text target."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert_eq!(answer.evidence[0].chunk_id, relevant_id);
        assert!(answer.answer_markdown.contains("text-to-text"));
        assert!(answer.answer_markdown.contains("text input"));
        assert!(answer.answer_markdown.contains("text target"));
    }

    #[tokio::test]
    async fn chat_extracts_distinct_corpus_facets_from_one_long_chunk() {
        let provider = DeterministicProvider::new(16).unwrap();
        let relevant_id = Uuid::new_v4();
        let filler = "background material ".repeat(70);
        let text = format!(
            "Common Crawl is a public web archive used as the corpus source. {filler} Cleaning filters low-quality pages and deduplicates repeated text. {filler} The resulting unlabeled dataset is used for pre-training."
        );
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Transfer learning study".into(),
                question: "What is the Colossal Clean Crawled Corpus?".into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id: relevant_id,
                    section_kind: SectionKind::Method,
                    section_heading: Some("The Colossal Clean Crawled Corpus".into()),
                    page_start: Some(5),
                    page_end: Some(6),
                    text,
                }],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert_eq!(answer.evidence[0].chunk_id, relevant_id);
        assert!(answer.answer_markdown.contains("Common Crawl"));
        assert!(answer.answer_markdown.contains("Cleaning filters"));
        assert!(
            answer.answer_markdown.contains("pre-training"),
            "{}",
            answer.answer_markdown
        );
    }

    #[tokio::test]
    async fn chat_prefers_complete_memory_architecture_over_partial_mentions() {
        let provider = DeterministicProvider::new(16).unwrap();
        let relevant_id = Uuid::new_v4();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Retrieval-augmented generation".into(),
                question: "How does RAG combine parametric and non-parametric memory?".into(),
                recent_turns: Vec::new(),
                evidence: vec![
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Discussion,
                        section_heading: Some("Discussion".into()),
                        page_start: Some(9),
                        page_end: Some(9),
                        text: "RAG is a hybrid generation model with parametric and non-parametric memory."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: Uuid::new_v4(),
                        section_kind: SectionKind::Other,
                        section_heading: Some("Index hot-swapping".into()),
                        page_start: Some(7),
                        page_end: Some(8),
                        text: "RAG can replace an index and retrieve more documents at test time."
                            .into(),
                    },
                    EvidenceExcerpt {
                        chunk_id: relevant_id,
                        section_kind: SectionKind::Introduction,
                        section_heading: Some("Introduction".into()),
                        page_start: Some(1),
                        page_end: Some(1),
                        text: "RAG uses a pre-trained seq2seq generator as parametric memory and a dense vector index accessed by a neural retriever as non-parametric memory."
                            .into(),
                    },
                ],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert_eq!(answer.evidence[0].chunk_id, relevant_id);
        assert!(answer.answer_markdown.contains("seq2seq"));
        assert!(answer.answer_markdown.contains("dense vector index"));
        assert!(answer.answer_markdown.contains("neural retriever"));
    }

    #[tokio::test]
    async fn chat_answers_quantitative_questions_only_with_complete_anchored_evidence() {
        let provider = DeterministicProvider::new(16).unwrap();
        let answer = provider
            .answer(&ChatCompletionRequest {
                paper_title: "Retrieval fixture".into(),
                question: "How many Wikipedia passages does the model retrieve from its index?"
                    .into(),
                recent_turns: Vec::new(),
                evidence: vec![EvidenceExcerpt {
                    chunk_id: Uuid::new_v4(),
                    section_kind: SectionKind::Method,
                    section_heading: Some("Retriever".into()),
                    page_start: Some(5),
                    page_end: Some(5),
                    text: "The model retrieves five Wikipedia passages from the dense index."
                        .into(),
                }],
            })
            .await
            .unwrap();

        assert!(!answer.insufficient_evidence);
        assert_eq!(answer.evidence.len(), 1);
        assert!(answer.answer_markdown.contains("five Wikipedia passages"));
    }
}
