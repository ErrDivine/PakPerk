use std::{
    collections::{HashMap, HashSet},
    path::Path,
};

use anyhow::{Context as _, Result, bail};
use arxiv_client::normalize_arxiv_id;
use chrono::Utc;
use serde::{Deserialize, Serialize};

const CHAT_LABELS: [&str; 5] = [
    "answer_supported",
    "partially_supported",
    "unsupported",
    "correct_abstention",
    "wrong_source_attribution",
];
const CONNECTION_DIMENSIONS: [&str; 4] = [
    "reference_match_correctness",
    "relationship_label_correctness",
    "sentence_support_from_citation_context",
    "genuine_importance",
];
const SECTION_KINDS: [&str; 14] = [
    "abstract",
    "introduction",
    "background",
    "related_work",
    "method",
    "experiment",
    "result",
    "discussion",
    "limitation",
    "conclusion",
    "appendix",
    "acknowledgment",
    "references",
    "other",
];
const RELATION_LABELS: [&str; 9] = [
    "builds_on",
    "uses",
    "extends",
    "applies",
    "compares_with",
    "contrasts_with",
    "background",
    "related_work",
    "unknown",
];

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ContentEvaluationSummary {
    pub schema_version: u32,
    pub dataset_name: String,
    pub structural_validation_passed: bool,
    pub quality_results_status: EvaluationStatus,
    pub paper_count: usize,
    pub chat_case_count: usize,
    pub answerable_case_count: usize,
    pub abstention_case_count: usize,
    pub connection_case_count: usize,
    pub observed_chat_label_count: usize,
    pub reviewed_connection_count: usize,
    pub note: String,
}

impl ContentEvaluationSummary {
    pub(crate) fn verification_gate_failure(&self) -> Option<String> {
        (self.quality_results_status != EvaluationStatus::ManuallyEvaluated).then(|| {
            "content quality has not been manually evaluated; complete every observed chat and \
             connection judgment before verify-demo can pass"
                .to_owned()
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ContentEvaluationValidationReport {
    pub generated_at: chrono::DateTime<Utc>,
    #[serde(flatten)]
    pub summary: ContentEvaluationSummary,
    pub failures: Vec<String>,
}

impl ContentEvaluationValidationReport {
    pub(crate) fn require_valid(&self) -> Result<()> {
        if self.summary.structural_validation_passed {
            Ok(())
        } else {
            bail!(
                "content-evaluation structure is invalid: {}",
                self.failures.join("; ")
            )
        }
    }
}

pub(crate) async fn validate_content_evaluation_files(
    manifest_path: &Path,
    expected_connections_path: &Path,
    evaluation_path: &Path,
) -> Result<ContentEvaluationValidationReport> {
    let manifest: Manifest = read_json(manifest_path, "seed manifest").await?;
    let expected: ExpectedConnections =
        read_json(expected_connections_path, "expected connections").await?;
    let evaluation: ContentEvaluation = read_json(evaluation_path, "content evaluation").await?;
    Ok(validate_documents(&manifest, &expected, &evaluation))
}

pub(crate) async fn write_content_evaluation_report(
    report: &ContentEvaluationValidationReport,
    output: &Path,
) -> Result<()> {
    if let Some(parent) = output.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("could not create {}", parent.display()))?;
    }
    tokio::fs::write(output, serde_json::to_vec_pretty(report)?)
        .await
        .with_context(|| format!("could not write {}", output.display()))
}

async fn read_json<T>(path: &Path, label: &str) -> Result<T>
where
    T: for<'de> Deserialize<'de>,
{
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("could not read {label} {}", path.display()))?;
    serde_json::from_slice(&bytes)
        .with_context(|| format!("{label} {} is invalid JSON", path.display()))
}

fn validate_documents(
    manifest: &Manifest,
    expected: &ExpectedConnections,
    evaluation: &ContentEvaluation,
) -> ContentEvaluationValidationReport {
    let mut failures = Vec::new();
    if manifest.schema_version != 1 {
        failures.push("seed manifest schema_version must be 1".to_owned());
    }
    if expected.schema_version != 1 {
        failures.push("expected-connections schema_version must be 1".to_owned());
    }
    if evaluation.schema_version != 1 {
        failures.push("content-evaluation schema_version must be 1".to_owned());
    }
    if evaluation.dataset_name.trim().is_empty() {
        failures.push("content-evaluation dataset_name must not be empty".to_owned());
    }
    if evaluation.evaluation_state.note.trim().is_empty() {
        failures.push("evaluation_state.note must explain the result status".to_owned());
    }
    validate_rubric(&evaluation.rubric, &mut failures);

    let manifest_ids = normalized_unique_ids(
        manifest.papers.iter().map(|paper| paper.arxiv_id.as_str()),
        "seed manifest",
        &mut failures,
    );
    let prepared_manifest_ids = normalized_unique_ids(
        manifest
            .papers
            .iter()
            .filter(|paper| paper.prepared)
            .map(|paper| paper.arxiv_id.as_str()),
        "prepared seed manifest",
        &mut failures,
    );
    let evaluation_ids = normalized_unique_ids(
        evaluation
            .papers
            .iter()
            .map(|paper| paper.arxiv_id.as_str()),
        "content evaluation",
        &mut failures,
    );
    for missing in prepared_manifest_ids.difference(&evaluation_ids) {
        failures.push(format!(
            "content evaluation is missing prepared manifest paper {missing}"
        ));
    }
    for extra in evaluation_ids.difference(&prepared_manifest_ids) {
        failures.push(format!(
            "content evaluation contains non-prepared manifest paper {extra}"
        ));
    }

    let mut counts = EvaluationCounts::default();
    let mut case_ids = HashSet::new();
    for paper in &evaluation.papers {
        validate_paper(
            paper,
            expected,
            &manifest_ids,
            evaluation.evaluation_state.status,
            &mut case_ids,
            &mut counts,
            &mut failures,
        );
    }

    if counts.connection_cases == 0 {
        failures.push("content evaluation needs at least one connection review case".to_owned());
    }
    validate_evaluation_state(
        &evaluation.evaluation_state,
        counts.observed_chat_labels,
        counts.reviewed_connections,
        &mut failures,
    );

    let structural_validation_passed = failures.is_empty();
    ContentEvaluationValidationReport {
        generated_at: Utc::now(),
        summary: ContentEvaluationSummary {
            schema_version: evaluation.schema_version,
            dataset_name: evaluation.dataset_name.clone(),
            structural_validation_passed,
            quality_results_status: evaluation.evaluation_state.status,
            paper_count: evaluation.papers.len(),
            chat_case_count: counts.chat_cases,
            answerable_case_count: counts.answerable_cases,
            abstention_case_count: counts.abstention_cases,
            connection_case_count: counts.connection_cases,
            observed_chat_label_count: counts.observed_chat_labels,
            reviewed_connection_count: counts.reviewed_connections,
            note: evaluation.evaluation_state.note.clone(),
        },
        failures,
    }
}

#[derive(Debug, Default)]
struct EvaluationCounts {
    chat_cases: usize,
    answerable_cases: usize,
    abstention_cases: usize,
    connection_cases: usize,
    observed_chat_labels: usize,
    reviewed_connections: usize,
}

#[allow(clippy::too_many_arguments)]
fn validate_paper(
    paper: &EvaluationPaper,
    expected: &ExpectedConnections,
    manifest_ids: &HashSet<String>,
    status: EvaluationStatus,
    case_ids: &mut HashSet<String>,
    counts: &mut EvaluationCounts,
    failures: &mut Vec<String>,
) {
    let paper_id = normalized_id(&paper.arxiv_id, "evaluation paper", failures)
        .unwrap_or_else(|| paper.arxiv_id.clone());
    validate_chat_cases(paper, &paper_id, status, case_ids, counts, failures);

    let expected_paper = expected.papers.get(&paper_id);
    let mut covered_connections = HashSet::new();
    for case in &paper.connection_cases {
        counts.connection_cases += 1;
        validate_case_id(&case.case_id, case_ids, failures);
        let cited_id = normalized_id(
            &case.cited_arxiv_id,
            &format!("{} cited paper", case.case_id),
            failures,
        )
        .unwrap_or_else(|| case.cited_arxiv_id.clone());
        if cited_id == paper_id {
            failures.push(format!("{} cannot cite its own paper", case.case_id));
        }
        if !covered_connections.insert(cited_id.clone()) {
            failures.push(format!(
                "{paper_id} has duplicate connection review target {cited_id}"
            ));
        }
        if !manifest_ids.contains(&cited_id) {
            failures.push(format!(
                "{} cites non-manifest paper {cited_id}",
                case.case_id
            ));
        }
        if !expected_paper.is_some_and(|paper| paper.must_resolve.contains(&cited_id)) {
            failures.push(format!(
                "{} is not declared in expected_connections.must_resolve",
                case.case_id
            ));
        }
        validate_connection_case(case, status, &mut counts.reviewed_connections, failures);
    }
    if let Some(expected_paper) = expected_paper {
        for required in &expected_paper.must_resolve {
            if !covered_connections.contains(required) {
                failures.push(format!(
                    "{paper_id} lacks a connection review case for required target {required}"
                ));
            }
        }
    }
}

fn validate_chat_cases(
    paper: &EvaluationPaper,
    paper_id: &str,
    status: EvaluationStatus,
    case_ids: &mut HashSet<String>,
    counts: &mut EvaluationCounts,
    failures: &mut Vec<String>,
) {
    if paper.chat_cases.len() < 3 {
        failures.push(format!(
            "{paper_id} needs at least three labeled chat cases"
        ));
    }
    let mut paper_answers = 0;
    let mut paper_abstentions = 0;
    for case in &paper.chat_cases {
        counts.chat_cases += 1;
        validate_case_id(&case.case_id, case_ids, failures);
        validate_chat_case(case, status, counts, failures);
        match case.expected_behavior {
            ExpectedBehavior::Answer => paper_answers += 1,
            ExpectedBehavior::Abstain => paper_abstentions += 1,
        }
    }
    if paper_answers == 0 || paper_abstentions == 0 {
        failures.push(format!(
            "{paper_id} must include both answerable and abstention cases"
        ));
    }
}

fn validate_chat_case(
    case: &ChatCase,
    status: EvaluationStatus,
    counts: &mut EvaluationCounts,
    failures: &mut Vec<String>,
) {
    if case.question.trim().is_empty() {
        failures.push(format!("{} has an empty question", case.case_id));
    }
    match case.expected_behavior {
        ExpectedBehavior::Answer => {
            counts.answerable_cases += 1;
            if case.target_label != ChatLabel::AnswerSupported {
                failures.push(format!(
                    "{} answer target must be answer_supported",
                    case.case_id
                ));
            }
            if case.evidence_requirements.is_empty() {
                failures.push(format!(
                    "{} answer target needs evidence requirements",
                    case.case_id
                ));
            }
            if case.abstention_reason.is_some() {
                failures.push(format!(
                    "{} answer target must not have an abstention reason",
                    case.case_id
                ));
            }
        }
        ExpectedBehavior::Abstain => {
            counts.abstention_cases += 1;
            if case.target_label != ChatLabel::CorrectAbstention {
                failures.push(format!(
                    "{} abstention target must be correct_abstention",
                    case.case_id
                ));
            }
            if !case.evidence_requirements.is_empty() {
                failures.push(format!(
                    "{} abstention target must not require answer evidence",
                    case.case_id
                ));
            }
            if case.abstention_reason.as_deref().is_none_or(str::is_empty) {
                failures.push(format!("{} abstention target needs a reason", case.case_id));
            }
        }
    }
    for requirement in &case.evidence_requirements {
        validate_evidence_requirement(requirement, &case.case_id, failures);
    }
    if case.observed_label.is_some() {
        counts.observed_chat_labels += 1;
    }
    validate_review_text(
        case.review_notes.as_deref(),
        &case.case_id,
        status,
        failures,
    );
    validate_observation_presence(
        case.observed_label.is_some(),
        &case.case_id,
        status,
        failures,
    );
}

fn validate_rubric(rubric: &Rubric, failures: &mut Vec<String>) {
    let labels = normalized_named_definitions(&rubric.observed_chat_labels, "chat label", failures);
    if labels != string_set(CHAT_LABELS) {
        failures.push(format!(
            "rubric chat labels must be exactly {}",
            CHAT_LABELS.join(", ")
        ));
    }
    let dimensions = normalized_named_definitions(
        &rubric.connection_review_dimensions,
        "connection dimension",
        failures,
    );
    if dimensions != string_set(CONNECTION_DIMENSIONS) {
        failures.push(format!(
            "connection review dimensions must be exactly {}",
            CONNECTION_DIMENSIONS.join(", ")
        ));
    }
}

fn normalized_named_definitions(
    values: &[NamedDefinition],
    label: &str,
    failures: &mut Vec<String>,
) -> HashSet<String> {
    let mut names = HashSet::new();
    for value in values {
        if value.definition.trim().is_empty() {
            failures.push(format!("{label} {} has no definition", value.name()));
        }
        if !names.insert(value.name().to_owned()) {
            failures.push(format!("duplicate {label} {}", value.name()));
        }
    }
    names
}

fn validate_evidence_requirement(
    requirement: &EvidenceRequirement,
    case_id: &str,
    failures: &mut Vec<String>,
) {
    if requirement.section_kinds.is_empty() {
        failures.push(format!(
            "{case_id} has an evidence requirement without section kinds"
        ));
    }
    for kind in &requirement.section_kinds {
        if !SECTION_KINDS.contains(&kind.as_str()) {
            failures.push(format!(
                "{case_id} has unknown evidence section kind {kind}"
            ));
        }
    }
    if requirement.required_concepts.is_empty()
        || requirement
            .required_concepts
            .iter()
            .any(|concept| concept.trim().is_empty())
    {
        failures.push(format!(
            "{case_id} evidence requirements need nonempty concepts"
        ));
    }
}

fn validate_connection_case(
    case: &ConnectionCase,
    status: EvaluationStatus,
    reviewed_connection_count: &mut usize,
    failures: &mut Vec<String>,
) {
    if case.expected_reference_title.trim().is_empty() {
        failures.push(format!(
            "{} needs the expected reference title",
            case.case_id
        ));
    }
    if case.acceptable_relation_labels.is_empty() {
        failures.push(format!(
            "{} needs at least one acceptable relationship label",
            case.case_id
        ));
    }
    for label in &case.acceptable_relation_labels {
        if !RELATION_LABELS.contains(&label.as_str()) {
            failures.push(format!(
                "{} has unknown relationship label {label}",
                case.case_id
            ));
        }
    }
    if case.required_context_cues.is_empty()
        || case
            .required_context_cues
            .iter()
            .any(|cue| cue.trim().is_empty())
    {
        failures.push(format!(
            "{} needs nonempty citation-context support cues",
            case.case_id
        ));
    }
    if !case.expected_genuine_importance {
        failures.push(format!(
            "{} is a must-resolve connection but is not labeled genuinely important",
            case.case_id
        ));
    }
    let observed = &case.observed;
    let observed_values = [
        observed.reference_match_correct,
        observed.relationship_label_correct,
        observed.sentence_supported_by_context,
        observed.genuinely_important,
    ];
    let complete = observed_values.iter().all(Option::is_some);
    let empty = observed_values.iter().all(Option::is_none);
    match status {
        EvaluationStatus::NotRun if !empty || observed.review_notes.is_some() => {
            failures.push(format!(
                "{} has observed connection results while evaluation_state is not_run",
                case.case_id
            ));
        }
        EvaluationStatus::ManuallyEvaluated if !complete => failures.push(format!(
            "{} needs all four observed connection judgments",
            case.case_id
        )),
        EvaluationStatus::ManuallyEvaluated => {
            *reviewed_connection_count += 1;
            if observed.review_notes.as_deref().is_none_or(str::is_empty) {
                failures.push(format!(
                    "{} needs review_notes for a manual evaluation",
                    case.case_id
                ));
            }
        }
        EvaluationStatus::NotRun => {}
    }
}

fn validate_evaluation_state(
    state: &EvaluationState,
    observed_chat_label_count: usize,
    reviewed_connection_count: usize,
    failures: &mut Vec<String>,
) {
    match state.status {
        EvaluationStatus::NotRun => {
            if state.evaluated_at.is_some() || !state.model_ids.is_empty() {
                failures
                    .push("not_run evaluation must not claim evaluated_at or model_ids".to_owned());
            }
            if observed_chat_label_count != 0 || reviewed_connection_count != 0 {
                failures.push("not_run evaluation must not contain observed results".to_owned());
            }
        }
        EvaluationStatus::ManuallyEvaluated => {
            if state.evaluated_at.as_deref().is_none_or(str::is_empty) {
                failures.push("manually_evaluated state needs evaluated_at".to_owned());
            }
            if state.model_ids.is_empty()
                || state.model_ids.iter().any(|model| model.trim().is_empty())
            {
                failures.push("manually_evaluated state needs nonempty model_ids".to_owned());
            }
        }
    }
}

fn validate_observation_presence(
    present: bool,
    case_id: &str,
    status: EvaluationStatus,
    failures: &mut Vec<String>,
) {
    match (status, present) {
        (EvaluationStatus::NotRun, true) => failures.push(format!(
            "{case_id} has an observed label while evaluation_state is not_run"
        )),
        (EvaluationStatus::ManuallyEvaluated, false) => failures.push(format!(
            "{case_id} needs an observed label for a manual evaluation"
        )),
        _ => {}
    }
}

fn validate_review_text(
    review_notes: Option<&str>,
    case_id: &str,
    status: EvaluationStatus,
    failures: &mut Vec<String>,
) {
    match status {
        EvaluationStatus::NotRun if review_notes.is_some() => failures.push(format!(
            "{case_id} has review_notes while evaluation_state is not_run"
        )),
        EvaluationStatus::ManuallyEvaluated if review_notes.is_none_or(str::is_empty) => failures
            .push(format!(
                "{case_id} needs review_notes for a manual evaluation"
            )),
        _ => {}
    }
}

fn validate_case_id(case_id: &str, ids: &mut HashSet<String>, failures: &mut Vec<String>) {
    if case_id.trim().is_empty() {
        failures.push("evaluation case_id must not be empty".to_owned());
    } else if !ids.insert(case_id.to_owned()) {
        failures.push(format!("duplicate evaluation case_id {case_id}"));
    }
}

fn normalized_unique_ids<'a>(
    values: impl Iterator<Item = &'a str>,
    label: &str,
    failures: &mut Vec<String>,
) -> HashSet<String> {
    let mut result = HashSet::new();
    for value in values {
        if let Some(normalized) = normalized_id(value, label, failures)
            && !result.insert(normalized.clone())
        {
            failures.push(format!("{label} contains duplicate paper {normalized}"));
        }
    }
    result
}

fn normalized_id(value: &str, label: &str, failures: &mut Vec<String>) -> Option<String> {
    match normalize_arxiv_id(value) {
        Ok(normalized) => Some(normalized.base_id),
        Err(error) => {
            failures.push(format!("{label} has invalid arXiv ID {value}: {error}"));
            None
        }
    }
}

fn string_set<const N: usize>(items: [&str; N]) -> HashSet<String> {
    items.into_iter().map(str::to_owned).collect()
}

#[derive(Debug, Deserialize)]
struct Manifest {
    schema_version: u32,
    papers: Vec<ManifestPaper>,
}

#[derive(Debug, Deserialize)]
struct ManifestPaper {
    arxiv_id: String,
    prepared: bool,
}

#[derive(Debug, Deserialize)]
struct ExpectedConnections {
    schema_version: u32,
    papers: HashMap<String, ExpectedPaper>,
}

#[derive(Debug, Deserialize)]
struct ExpectedPaper {
    #[serde(default)]
    must_resolve: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ContentEvaluation {
    schema_version: u32,
    dataset_name: String,
    evaluation_state: EvaluationState,
    rubric: Rubric,
    papers: Vec<EvaluationPaper>,
}

#[derive(Debug, Deserialize)]
struct EvaluationState {
    status: EvaluationStatus,
    evaluated_at: Option<String>,
    #[serde(default)]
    model_ids: Vec<String>,
    note: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum EvaluationStatus {
    NotRun,
    ManuallyEvaluated,
}

#[derive(Debug, Deserialize)]
struct Rubric {
    observed_chat_labels: Vec<NamedDefinition>,
    connection_review_dimensions: Vec<NamedDefinition>,
}

#[derive(Debug, Deserialize)]
struct NamedDefinition {
    #[serde(alias = "name")]
    label: String,
    definition: String,
}

impl NamedDefinition {
    fn name(&self) -> &str {
        &self.label
    }
}

#[derive(Debug, Deserialize)]
struct EvaluationPaper {
    arxiv_id: String,
    chat_cases: Vec<ChatCase>,
    connection_cases: Vec<ConnectionCase>,
}

#[derive(Debug, Deserialize)]
struct ChatCase {
    case_id: String,
    question: String,
    expected_behavior: ExpectedBehavior,
    target_label: ChatLabel,
    evidence_requirements: Vec<EvidenceRequirement>,
    abstention_reason: Option<String>,
    observed_label: Option<ChatLabel>,
    review_notes: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExpectedBehavior {
    Answer,
    Abstain,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ChatLabel {
    AnswerSupported,
    PartiallySupported,
    Unsupported,
    CorrectAbstention,
    WrongSourceAttribution,
}

#[derive(Debug, Deserialize)]
struct EvidenceRequirement {
    section_kinds: Vec<String>,
    required_concepts: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ConnectionCase {
    case_id: String,
    cited_arxiv_id: String,
    expected_reference_title: String,
    acceptable_relation_labels: Vec<String>,
    required_context_cues: Vec<String>,
    expected_genuine_importance: bool,
    observed: ObservedConnection,
}

#[derive(Debug, Deserialize)]
struct ObservedConnection {
    reference_match_correct: Option<bool>,
    relationship_label_correct: Option<bool>,
    sentence_supported_by_context: Option<bool>,
    genuinely_important: Option<bool>,
    review_notes: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo_path(file: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../..")
            .join("demo")
            .join(file)
    }

    #[tokio::test]
    async fn checked_in_content_evaluation_is_structurally_valid_and_manually_reviewed() {
        let report = validate_content_evaluation_files(
            &demo_path("seed_manifest.json"),
            &demo_path("expected_connections.json"),
            &demo_path("content_evaluation.json"),
        )
        .await
        .unwrap();

        assert!(report.summary.structural_validation_passed);
        assert_eq!(
            report.summary.quality_results_status,
            EvaluationStatus::ManuallyEvaluated
        );
        assert_eq!(report.summary.paper_count, 5);
        assert_eq!(report.summary.chat_case_count, 15);
        assert_eq!(report.summary.answerable_case_count, 10);
        assert_eq!(report.summary.abstention_case_count, 5);
        assert_eq!(report.summary.connection_case_count, 6);
        assert_eq!(report.summary.observed_chat_label_count, 15);
        assert_eq!(report.summary.reviewed_connection_count, 6);
        assert!(report.failures.is_empty());
        assert!(report.summary.verification_gate_failure().is_none());
    }

    #[tokio::test]
    async fn checked_in_manifest_has_five_prepared_papers_and_one_lazy_trigger() {
        let manifest: Manifest = read_json(&demo_path("seed_manifest.json"), "manifest")
            .await
            .unwrap();
        let prepared = manifest
            .papers
            .iter()
            .filter(|paper| paper.prepared)
            .count();
        let lazy: Vec<_> = manifest
            .papers
            .iter()
            .filter(|paper| !paper.prepared)
            .collect();

        assert_eq!(manifest.papers.len(), 6);
        assert_eq!(prepared, 5);
        assert_eq!(lazy.len(), 1);
        assert_eq!(lazy[0].arxiv_id, "2106.09685v2");
    }

    #[test]
    fn verify_gate_accepts_only_manually_evaluated_quality_results() {
        let summary = ContentEvaluationSummary {
            schema_version: 1,
            dataset_name: "test".to_owned(),
            structural_validation_passed: true,
            quality_results_status: EvaluationStatus::ManuallyEvaluated,
            paper_count: 1,
            chat_case_count: 3,
            answerable_case_count: 2,
            abstention_case_count: 1,
            connection_case_count: 1,
            observed_chat_label_count: 3,
            reviewed_connection_count: 1,
            note: "reviewed".to_owned(),
        };

        assert!(summary.verification_gate_failure().is_none());
    }

    #[tokio::test]
    async fn not_run_status_rejects_observed_quality_claims() {
        let manifest: Manifest = read_json(&demo_path("seed_manifest.json"), "manifest")
            .await
            .unwrap();
        let expected: ExpectedConnections =
            read_json(&demo_path("expected_connections.json"), "connections")
                .await
                .unwrap();
        let mut evaluation: ContentEvaluation =
            read_json(&demo_path("content_evaluation.json"), "evaluation")
                .await
                .unwrap();
        evaluation.evaluation_state.status = EvaluationStatus::NotRun;
        evaluation.evaluation_state.evaluated_at = None;
        evaluation.evaluation_state.model_ids.clear();
        for paper in &mut evaluation.papers {
            for case in &mut paper.chat_cases {
                case.observed_label = None;
                case.review_notes = None;
            }
            for case in &mut paper.connection_cases {
                case.observed.reference_match_correct = None;
                case.observed.relationship_label_correct = None;
                case.observed.sentence_supported_by_context = None;
                case.observed.genuinely_important = None;
                case.observed.review_notes = None;
            }
        }
        evaluation.papers[0].chat_cases[0].observed_label = Some(ChatLabel::Unsupported);

        let report = validate_documents(&manifest, &expected, &evaluation);

        assert!(!report.summary.structural_validation_passed);
        assert!(
            report
                .failures
                .iter()
                .any(|failure| failure.contains("while evaluation_state is not_run"))
        );
    }
}
